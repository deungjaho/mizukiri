/**
 * engine.test.js — GameEngine 与 MinimaxAI 单元测试
 *
 * 运行方式：
 *   node --test test/engine.test.js
 *
 * 需要 Node.js >= 18（内置 test runner）。
 */

'use strict';

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const WIN_LINES = [
  [0, 1, 2], [3, 4, 5], [6, 7, 8],
  [0, 3, 6], [1, 4, 7], [2, 5, 8],
  [0, 4, 8], [2, 4, 6],
];

const GameEngine = {
  newGame(first = 'X') {
    return {
      board: Array(9).fill(null),
      queues: { X: [], O: [] },
      currentPlayer: first,
      winner: null,
      winCells: null,
      scores: { X: 0, O: 0 },
      moveCount: 0,
      gameOver: false,
    };
  },

  checkWin(queues, player) {
    const q = queues[player];
    if (q.length < 3) return null;
    const s = new Set(q);
    for (const line of WIN_LINES) {
      if (line.every(i => s.has(i))) return line;
    }
    return null;
  },

  applyMove(game, pos) {
    if (game.gameOver || game.board[pos] !== null) return false;
    const p = game.currentPlayer;
    const q = game.queues[p];
    if (q.length >= 3) {
      const old = q.shift();
      if (!q.includes(old)) game.board[old] = null;
    }
    q.push(pos);
    game.board[pos] = p;
    game.moveCount++;
    const win = this.checkWin(game.queues, p);
    if (win) {
      game.winner = p;
      game.winCells = win;
      game.gameOver = true;
      game.scores[p]++;
    }
    game.currentPlayer = p === 'X' ? 'O' : 'X';
    return true;
  },
};

const MinimaxAI = {
  simulateMove(board, queues, player, pos) {
    const nextBoard = [...board];
    const nextQueues = { X: [...queues.X], O: [...queues.O] };
    nextBoard[pos] = player;
    nextQueues[player].push(pos);
    if (nextQueues[player].length > 3) {
      const old = nextQueues[player].shift();
      if (!nextQueues[player].includes(old)) nextBoard[old] = null;
    }
    return { board: nextBoard, queues: nextQueues, currentPlayer: player === 'X' ? 'O' : 'X' };
  },

  checkWinFor(board, queues, player) {
    const q = queues[player];
    if (q.length < 3) return false;
    const s = new Set(q);
    return WIN_LINES.some(line => line.every(i => s.has(i)));
  },

  minimax(board, queues, currentPlayer, depth, alpha, beta, isMaximizing) {
    if (this.checkWinFor(board, queues, 'O')) return 100 - depth;
    if (this.checkWinFor(board, queues, 'X')) return depth - 100;
    if (depth >= 6) return 0;
    const moves = board.map((v, i) => v === null ? i : -1).filter(i => i !== -1);
    if (isMaximizing) {
      let best = -Infinity;
      for (const m of moves) {
        const n = this.simulateMove(board, queues, currentPlayer, m);
        const v = this.minimax(n.board, n.queues, n.currentPlayer, depth+1, alpha, beta, false);
        best = Math.max(best, v); alpha = Math.max(alpha, best);
        if (beta <= alpha) break;
      }
      return best;
    } else {
      let best = Infinity;
      for (const m of moves) {
        const n = this.simulateMove(board, queues, currentPlayer, m);
        const v = this.minimax(n.board, n.queues, n.currentPlayer, depth+1, alpha, beta, true);
        best = Math.min(best, v); beta = Math.min(beta, best);
        if (beta <= alpha) break;
      }
      return best;
    }
  },

  getBestMove(board, queues) {
    const moves = board.map((v, i) => v === null ? i : -1).filter(i => i !== -1);
    if (!moves.length) return -1;
    let bestVal = -Infinity, bestMove = moves[0];
    for (const m of moves) {
      const n = this.simulateMove(board, queues, 'O', m);
      const v = this.minimax(n.board, n.queues, n.currentPlayer, 1, -Infinity, Infinity, false);
      if (v > bestVal) { bestVal = v; bestMove = m; }
    }
    return bestMove;
  },
};

// --- Tests ---

describe('GameEngine.newGame', () => {
  test('初始状态正确', () => {
    const game = GameEngine.newGame('X');
    assert.deepEqual(game.board, Array(9).fill(null));
    assert.equal(game.currentPlayer, 'X');
    assert.equal(game.winner, null);
    assert.equal(game.moveCount, 0);
    assert.equal(game.gameOver, false);
    assert.deepEqual(game.scores, { X: 0, O: 0 });
  });

  test('先手参数生效', () => {
    assert.equal(GameEngine.newGame('O').currentPlayer, 'O');
  });
});

describe('GameEngine.applyMove', () => {
  test('正常落子：棋盘更新、回合切换、moveCount 递增', () => {
    const game = GameEngine.newGame('X');
    assert.equal(GameEngine.applyMove(game, 4), true);
    assert.equal(game.board[4], 'X');
    assert.equal(game.currentPlayer, 'O');
    assert.equal(game.moveCount, 1);
  });

  test('FIFO 消子：最旧棋子消除', () => {
    const g = GameEngine.newGame('X');
    GameEngine.applyMove(g, 0); GameEngine.applyMove(g, 8);
    GameEngine.applyMove(g, 1); GameEngine.applyMove(g, 7);
    GameEngine.applyMove(g, 6); GameEngine.applyMove(g, 5);
    // X queue=[0,1,6] 满，shift 0，落 3
    GameEngine.applyMove(g, 3);
    assert.equal(g.board[0], null, 'pos=0 应已消除');
    assert.equal(g.board[3], 'X');
  });

  test('shift 出的位置仍在队列中则不清除棋盘', () => {
    const g = GameEngine.newGame('X');
    GameEngine.applyMove(g, 0); GameEngine.applyMove(g, 5);
    GameEngine.applyMove(g, 1); GameEngine.applyMove(g, 6);
    GameEngine.applyMove(g, 8); GameEngine.applyMove(g, 7);
    // X queue=[0,1,8] 满，shift 0，落 2 → 0 不再队列 → 清除
    GameEngine.applyMove(g, 2);
    assert.equal(g.board[0], null);
    assert.equal(g.board[2], 'X');
  });

  test('拒绝：已占用格子返回 false', () => {
    const game = GameEngine.newGame('X');
    GameEngine.applyMove(game, 4);
    assert.equal(GameEngine.applyMove(game, 4), false);
    assert.equal(game.board[4], 'X');
  });

  test('拒绝：游戏结束后返回 false', () => {
    const game = GameEngine.newGame('X');
    GameEngine.applyMove(game, 0); GameEngine.applyMove(game, 3);
    GameEngine.applyMove(game, 1); GameEngine.applyMove(game, 4);
    GameEngine.applyMove(game, 2); // X 赢
    assert.equal(game.gameOver, true);
    assert.equal(GameEngine.applyMove(game, 8), false);
  });

  test('行连线胜利检测', () => {
    const game = GameEngine.newGame('X');
    GameEngine.applyMove(game, 0); GameEngine.applyMove(game, 3);
    GameEngine.applyMove(game, 1); GameEngine.applyMove(game, 4);
    GameEngine.applyMove(game, 2);
    assert.equal(game.winner, 'X');
    assert.deepEqual(game.winCells, [0, 1, 2]);
    assert.equal(game.scores.X, 1);
  });

  test('对角线胜利检测', () => {
    const game = GameEngine.newGame('X');
    GameEngine.applyMove(game, 0); GameEngine.applyMove(game, 1);
    GameEngine.applyMove(game, 4); GameEngine.applyMove(game, 2);
    GameEngine.applyMove(game, 8);
    assert.equal(game.winner, 'X');
    assert.deepEqual(game.winCells, [0, 4, 8]);
  });

  test('不变量：queues 长度永不超过 3', () => {
    const game = GameEngine.newGame('X');
    for (const pos of [4, 0, 8, 2, 6, 3, 5, 1, 7]) {
      GameEngine.applyMove(game, pos);
      assert.ok(game.queues.X.length <= 3);
      assert.ok(game.queues.O.length <= 3);
      if (game.gameOver) break;
    }
  });

  test('不变量：board 上 X 的位置与 queues.X 完全一致', () => {
    const game = GameEngine.newGame('X');
    for (const pos of [4, 0, 8, 2, 6]) {
      GameEngine.applyMove(game, pos);
      if (game.gameOver) break;
      const onBoard = game.board.map((v, i) => v==='X'?i:-1).filter(i=>i!==-1).sort((a,b)=>a-b);
      const inQueue = [...game.queues.X].sort((a,b)=>a-b);
      assert.deepEqual(onBoard, inQueue);
    }
  });
});

describe('MinimaxAI.getBestMove', () => {
  test('拦截对手即将连成三子', () => {
    const board = Array(9).fill(null);
    board[0] = 'X'; board[1] = 'X';
    const move = MinimaxAI.getBestMove(board, { X: [0, 1], O: [] });
    assert.equal(move, 2, 'AI 应落 2 阻断 [0,1,2]');
  });

  test('能赢时优先取胜', () => {
    const board = Array(9).fill(null);
    board[3] = 'O'; board[4] = 'O';
    const move = MinimaxAI.getBestMove(board, { X: [], O: [3, 4] });
    assert.equal(move, 5, 'AI 应落 5 完成 [3,4,5]');
  });

  test('空棋盘上返回合法索引', () => {
    const move = MinimaxAI.getBestMove(Array(9).fill(null), { X: [], O: [] });
    assert.ok(move >= 0 && move <= 8);
  });
});
