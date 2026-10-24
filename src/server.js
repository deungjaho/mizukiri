import { DurableObject } from 'cloudflare:workers';
import { GameEngine } from './engine.js';
import { makeQrDataUrl } from './qr.js';

// ---------------------------------------------------------------------------
// 状态化游戏服务 (Durable Object 替代 server.el)
// ---------------------------------------------------------------------------
export class GameServer extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.env = env;
    this.rooms = new Map(); // roomCode -> roomData
  }

  // 格式化输出，严格对齐 server.el 的 state 消息规范与 index.html 期望
  formatState(room) {
    return {
      type: 'state',
      board: room.game.board,
      queues: {
        X: [...room.game.queues.X],
        O: [...room.game.queues.O],
      },
      current: room.game.current,
      winner: room.game.winner,
      winCells: room.game.winCells,
      scores: { ...room.game.scores },
      gameOver: room.game.gameOver,
      swapped: room.swapped,
      moveCount: room.game.moveCount,
    };
  }

  broadcast(room, data) {
    const payload = JSON.stringify(data);
    try {
      if (room.host && room.host.readyState === WebSocket.OPEN) {
        room.host.send(payload);
      }
    } catch {}
    try {
      if (room.guest && room.guest.readyState === WebSocket.OPEN) {
        room.guest.send(payload);
      }
    } catch {}
  }

  generateCode() {
    let code;
    do {
      code = Math.floor(1000 + Math.random() * 9000).toString();
    } while (this.rooms.has(code));
    return code;
  }

  // 清理超时僵尸房间 (waiting 超过 30 分钟，playing 超过 2 小时)
  sweepRooms() {
    const now = Date.now();
    for (const [code, room] of this.rooms.entries()) {
      const elapsed = now - room.created;
      if (
        (room.state === 'waiting' && elapsed > 1800000) ||
        (room.state === 'playing' && elapsed > 7200000)
      ) {
        this.broadcast(room, { type: 'room_closed' });
        try { room.host?.close(); } catch {}
        try { room.guest?.close(); } catch {}
        this.rooms.delete(code);
      }
    }
  }

  // 接收进来的 WebSocket 连接
  async fetch(request) {
    const webSocketPair = new WebSocketPair();
    const [client, server] = Object.values(webSocketPair);

    // 获取客户端请求源地址（如 http://localhost:8787 或 https://mizukiri.xxx.workers.dev）
    const origin = new URL(request.url).origin;
    // 启用 WebSocket Hibernation API：空闲时自动休眠，零算力损耗
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ origin });

    return new Response(null, { status: 101, webSocket: client });
  }

  // 消息派发处理 (1:1 对齐 server.el 中的 mz-on-message)
  async webSocketMessage(ws, message) {
    let msg;
    try {
      msg = JSON.parse(typeof message === 'string' ? message : new TextDecoder().decode(message));
    } catch {
      return;
    }

    const { type } = msg;
    if (!type) return;

    // 每次收到消息时顺带进行房间超时清理
    this.sweepRooms();

    const att = ws.deserializeAttachment() || {};

    if (type === 'create') {
      const code = this.generateCode();
      const room = {
        code,
        host: ws,
        guest: null,
        state: 'waiting',
        game: GameEngine.newGame('X'),
        swapped: false,
        created: Date.now(),
      };
      this.rooms.set(code, room);
      ws.serializeAttachment({ ...att, room: code, player: 'X' });

      const baseUrl = att.origin || this.env?.MIZUKIRI_BASE_URL || 'https://mizukiri.dengzihao.me';
      const inviteUrl = `${baseUrl}/?room=${code}`;
      const qrDataUrl = makeQrDataUrl(inviteUrl);

      ws.send(JSON.stringify({
        type: 'created',
        code,
        qr: qrDataUrl,
      }));
      return;
    }

    if (type === 'join') {
      const code = String(msg.code || '').trim();
      const room = this.rooms.get(code);

      if (!room || room.state !== 'waiting') {
        ws.send(JSON.stringify({ type: 'error', msg: '房间不存在或已满' }));
        return;
      }

      room.guest = ws;
      room.state = 'playing';
      ws.serializeAttachment({ ...att, room: code, player: 'O' });

      try {
        room.host.send(JSON.stringify({ type: 'start', player: 'X', mode: 'remote' }));
      } catch {}
      ws.send(JSON.stringify({ type: 'start', player: 'O', mode: 'remote' }));

      this.broadcast(room, this.formatState(room));
      return;
    }

    // 校验对局中状态
    if (!att.room) return;
    const room = this.rooms.get(att.room);
    if (!room) return;

    if (type === 'move') {
      const pos = msg.position;
      if (
        room.state === 'playing' &&
        room.game.current === att.player &&
        typeof pos === 'number' &&
        pos >= 0 && pos <= 8
      ) {
        if (GameEngine.applyMove(room.game, pos)) {
          this.broadcast(room, this.formatState(room));
        } else {
          ws.send(JSON.stringify({ type: 'rejected', position: pos }));
        }
      }
      return;
    }

    if (type === 'swap') {
      if (room.state === 'playing') {
        room.swapped = !room.swapped;
        const first = room.swapped ? 'O' : 'X';
        const scores = { ...room.game.scores };
        room.game = GameEngine.newGame(first);
        room.game.scores = scores;
        this.broadcast(room, this.formatState(room));
      }
      return;
    }

    if (type === 'reset') {
      if (room.state === 'playing') {
        const first = room.swapped ? 'O' : 'X';
        const scores = { ...room.game.scores };
        room.game = GameEngine.newGame(first);
        room.game.scores = scores;
        this.broadcast(room, this.formatState(room));
      }
      return;
    }

    if (type === 'leave') {
      this.closeRoom(ws);
      return;
    }

    if (type === 'ping') {
      ws.send(JSON.stringify({ type: 'pong' }));
    }
  }

  closeRoom(ws) {
    const att = ws.deserializeAttachment() || {};
    if (att.room && this.rooms.has(att.room)) {
      const room = this.rooms.get(att.room);
      const other = att.player === 'X' ? room.guest : room.host;
      if (other && other.readyState === WebSocket.OPEN) {
        try {
          other.send(JSON.stringify({ type: 'opponent_left' }));
        } catch {}
      }
      this.rooms.delete(att.room);
    }
  }

  async webSocketClose(ws) {
    this.closeRoom(ws);
  }
}

// ---------------------------------------------------------------------------
// Worker 主路由入口
// ---------------------------------------------------------------------------
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // 拦截 /ws 升级为 WebSocket
    if (url.pathname === '/ws') {
      if (request.headers.get('Upgrade') !== 'websocket') {
        return new Response('Expected WebSocket', { status: 426 });
      }
      const id = env.GAME_SERVER.idFromName('mizukiri-lobby');
      const stub = env.GAME_SERVER.get(id);
      return stub.fetch(request);
    }

    // 静态资源兜底
    if (env.ASSETS) {
      return env.ASSETS.fetch(request);
    }

    return new Response('Not Found', { status: 404 });
  },
};
