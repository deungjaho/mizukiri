/**
 * test/server.test.js — Cloudflare Serverless GameEngine & Server 单元测试
 *
 * 运行方式：
 *   node --test test/server.test.js
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { GameEngine } from '../src/engine.js';
import { makeQrDataUrl } from '../src/qr.js';

describe('GameEngine (Server implementation)', () => {
  test('初始状态与 invariants', () => {
    const game = GameEngine.newGame('X');
    assert.equal(game.board.length, 9);
    assert.deepEqual(game.board, Array(9).fill(null));
    assert.deepEqual(game.queues, { X: [], O: [] });
    assert.equal(game.current, 'X');
    assert.equal(game.winner, null);
    assert.equal(game.gameOver, false);
    assert.equal(game.moveCount, 0);
  });

  test('正常落子与回合切换', () => {
    const game = GameEngine.newGame('X');
    const ok = GameEngine.applyMove(game, 0);
    assert.equal(ok, true);
    assert.equal(game.board[0], 'X');
    assert.deepEqual(game.queues.X, [0]);
    assert.equal(game.current, 'O');
    assert.equal(game.moveCount, 1);
  });

  test('FIFO 淘汰机制：第 4 子淘汰第 1 子', () => {
    const game = GameEngine.newGame('X');
    // X 落 0, O 落 3
    GameEngine.applyMove(game, 0);
    GameEngine.applyMove(game, 3);
    // X 落 1, O 落 4
    GameEngine.applyMove(game, 1);
    GameEngine.applyMove(game, 4);
    // X 落 8, O 落 7
    GameEngine.applyMove(game, 8);
    GameEngine.applyMove(game, 7);

    // 此时 X 有 [0, 1, 8]，O 有 [3, 4, 7]
    assert.deepEqual(game.queues.X, [0, 1, 8]);
    assert.equal(game.board[0], 'X');

    // X 下第 4 颗子（落 5），最早的 0 必须被 FIFO 淘汰
    const ok = GameEngine.applyMove(game, 5);
    assert.equal(ok, true);
    assert.deepEqual(game.queues.X, [1, 8, 5]);
    assert.equal(game.board[0], null, '位置 0 应当被清空淘汰');
    assert.equal(game.board[5], 'X', '位置 5 应当有 X');
  });

  test('胜负判定与得分增加', () => {
    const game = GameEngine.newGame('X');
    // X 占 0, 1, 2 胜利
    GameEngine.applyMove(game, 0); // X: 0
    GameEngine.applyMove(game, 3); // O: 3
    GameEngine.applyMove(game, 1); // X: 1
    GameEngine.applyMove(game, 4); // O: 4
    GameEngine.applyMove(game, 2); // X: 2 -> 胜!

    assert.equal(game.gameOver, true);
    assert.equal(game.winner, 'X');
    assert.deepEqual(game.winCells, [0, 1, 2]);
    assert.equal(game.scores.X, 1);
    assert.equal(game.scores.O, 0);

    // 结束后无法再落子
    assert.equal(GameEngine.applyMove(game, 5), false);
  });

  test('拒绝非法落子', () => {
    const game = GameEngine.newGame('X');
    GameEngine.applyMove(game, 0);
    // O 尝试落在已被占用的 0 号位
    assert.equal(GameEngine.applyMove(game, 0), false);
  });
});

describe('QR Code Generation', () => {
  test('生成合法的和风配色 SVG Data URI', () => {
    const url = 'https://mizukiri.example.com/?room=1234';
    const dataUrl = makeQrDataUrl(url);
    assert.ok(dataUrl.startsWith('data:image/svg+xml;utf8,'));
    const svg = decodeURIComponent(dataUrl.replace('data:image/svg+xml;utf8,', ''));
    assert.ok(svg.includes('<svg'));
    assert.ok(svg.includes('fill="#2c2416"'));
    assert.ok(svg.includes('fill="#fffef9"'));
  });
});
