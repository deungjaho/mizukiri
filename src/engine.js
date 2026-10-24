// ---------------------------------------------------------------------------
// 游戏纯逻辑引擎 (移植自 test/engine.test.js，对齐 server.el 契约)
// ---------------------------------------------------------------------------
export const WIN_LINES = [
  [0, 1, 2], [3, 4, 5], [6, 7, 8],
  [0, 3, 6], [1, 4, 7], [2, 5, 8],
  [0, 4, 8], [2, 4, 6],
];

export const GameEngine = {
  newGame(first = 'X') {
    return {
      board: Array(9).fill(null),
      queues: { X: [], O: [] },
      current: first,
      winner: null,
      winCells: null,
      scores: { X: 0, O: 0 },
      moveCount: 0,
      gameOver: false,
    };
  },

  checkWin(queues, player) {
    const q = queues[player];
    if (!q || q.length < 3) return null;
    const s = new Set(q);
    for (const line of WIN_LINES) {
      if (line.every(i => s.has(i))) return line;
    }
    return null;
  },

  applyMove(game, pos) {
    if (game.gameOver || game.board[pos] !== null) return false;
    const p = game.current;
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
    } else {
      game.current = p === 'X' ? 'O' : 'X';
    }
    return true;
  },
};
