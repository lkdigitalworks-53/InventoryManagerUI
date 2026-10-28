'use strict';
// P1 S2d-1: the client helper qml/helper/StockMovements.js (a QML `.pragma library` file) must agree with
// the server (lib/movementLogic.js + lib/gatewayLogic.js validateDeltaRequest) on what a valid explicit
// `movements` delta is. A client that sends what the server rejects gets a TERMINAL 4xx on a queued stock
// change, so drift here loses stock writes, not just labels. Also runs the helper's own unit cases
// (the QML file tests/tst_StockMovements.qml mirrors them; this is the copy that runs without Qt).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ML = require('../lib/movementLogic');
const GL = require('../lib/gatewayLogic');

const file = path.join(__dirname, '..', '..', 'qml', 'helper', 'StockMovements.js');
const src = fs.readFileSync(file, 'utf8');
assert.match(src, /^\.pragma library\s*$/m, 'helper must stay a pragma library file');
const ctx = {};
vm.runInNewContext(src.replace(/^\.pragma library\s*$/m, '') +
  '\nthis.api = { KIND_DIRECTION, MAX_MOVEMENTS, MAX_REASON, EPSILON, hasMovements, make, validate, canCoalesce, mergeMovements };', ctx);
// values come from another realm: JSON round trip gives plain objects strict deepEqual accepts
const plain = (v) => JSON.parse(JSON.stringify(v));
const H = ctx.api;

// What the server decides for the same call, with no floors or clamps: request validation, then the
// applied-delta check (applied == requested when nothing clamps).
function serverAccepts(entity, deltas, movements) {
  const body = { entity, entityId: 'p1', requestId: 'r1', deltas, movements };
  const v = GL.validateDeltaRequest(body);
  if (!v.ok) return { ok: false, error: v.error };
  if (v.movements.length > 0 && !ML.totalsMatch(v.movements, deltas.stock)) return { ok: false, error: 'movement-qty-mismatch' };
  return { ok: true };
}

test('SM-1 constants mirror the server: kinds + directions, caps, epsilon', () => {
  assert.deepEqual(plain(H.KIND_DIRECTION), ML.KIND_DIRECTION);
  assert.equal(H.MAX_MOVEMENTS, ML.MAX_MOVEMENTS);
  assert.equal(H.MAX_REASON, ML.MAX_REASON);
});

test('SM-2 make: trims, defaults a missing/non-string reason to "", cuts to the server limit, never sends valueAtCost', () => {
  assert.deepEqual(plain(H.make('receipt', 5, '  hello  ')), { kind: 'receipt', qty: 5, reason: 'hello' });
  assert.equal(H.make('receipt', 5).reason, '');
  assert.equal(H.make('receipt', 5, null).reason, '');
  assert.equal(H.make('receipt', 5, 42).reason, '');
  const long = H.make('receipt', 5, 'x'.repeat(900));
  assert.equal(long.reason.length, ML.MAX_REASON);
  assert.equal(H.validate('inventory', { stock: 5 }, {}, [long]), '');
  // cut that lands on a space: the cut text is trimmed again, so it is still within the limit
  const spaced = H.make('receipt', 5, 'x'.repeat(ML.MAX_REASON - 1) + ' ' + 'y'.repeat(50));
  assert.equal(spaced.reason, 'x'.repeat(ML.MAX_REASON - 1));
  assert.ok(!('valueAtCost' in H.make('sale', -1, 'r')));
});

test('SM-3 validate: no movements is always fine (server derives the row)', () => {
  assert.equal(H.validate('inventory', { stock: 5 }, {}, undefined), '');
  assert.equal(H.validate('inventory', { stock: 5 }, { stock: 0 }, null), '');
  assert.equal(H.validate('stock_batch', { qtyRemaining: -1 }, {}, undefined), '');
});

test('SM-4 validate: one error code per fault, same codes as the server', () => {
  const ok = [{ kind: 'receipt', qty: 5, reason: '' }];
  const cases = [
    ['inventory', { stock: 5 }, {}, [], 'invalid-movements'],
    ['inventory', { stock: 5 }, {}, 'x', 'invalid-movements'],
    ['inventory', { stock: 5 }, {}, { kind: 'receipt', qty: 5 }, 'invalid-movements'],
    ['inventory', { stock: 5 }, {}, [null], 'invalid-movements'],
    ['inventory', { stock: 5 }, {}, [5], 'invalid-movements'],
    ['inventory', { stock: 5 }, {}, new Array(51).fill({ kind: 'adjustment', qty: 1 }), 'too-many-movements'],
    ['stock_batch', { stock: 5 }, {}, ok, 'movements-require-inventory'],
    ['inventory', { qty: 5 }, {}, ok, 'movements-require-stock-delta'],
    ['inventory', undefined, {}, ok, 'movements-require-stock-delta'],
    ['inventory', { stock: '5' }, {}, ok, 'movements-require-stock-delta'],
    ['inventory', { stock: NaN }, {}, ok, 'movements-require-stock-delta'],
    ['inventory', { stock: 5 }, {}, [{ kind: 'bogus', qty: 5 }], 'invalid-movement-kind'],
    ['inventory', { stock: 5 }, {}, [{ qty: 5 }], 'invalid-movement-kind'],
    ['inventory', { stock: 5 }, {}, [{ kind: 'toString', qty: 5 }], 'invalid-movement-kind'],
    ['inventory', { stock: 0 }, {}, [{ kind: 'adjustment', qty: 0 }], 'invalid-movement-qty'],
    ['inventory', { stock: 5 }, {}, [{ kind: 'receipt', qty: '5' }], 'invalid-movement-qty'],
    ['inventory', { stock: 5 }, {}, [{ kind: 'receipt', qty: Infinity }], 'invalid-movement-qty'],
    ['inventory', { stock: -5 }, {}, [{ kind: 'receipt', qty: -5 }], 'invalid-movement-qty'],
    ['inventory', { stock: 5 }, {}, [{ kind: 'sale', qty: 5 }], 'invalid-movement-qty'],
    ['inventory', { stock: 5 }, {}, [{ kind: 'receipt', qty: 5, reason: 7 }], 'invalid-movement-reason'],
    ['inventory', { stock: 5 }, {}, [{ kind: 'receipt', qty: 5, reason: 'x'.repeat(501) }], 'invalid-movement-reason'],
    ['inventory', { stock: 5 }, { stock: 0 }, ok, 'movements-with-clamps'],
    ['inventory', { stock: 6 }, {}, ok, 'movement-qty-mismatch'],
  ];
  for (const [entity, deltas, clamps, movements, code] of cases) {
    assert.equal(H.validate(entity, deltas, clamps, movements), code, JSON.stringify([entity, deltas, clamps, movements]));
  }
});

test('SM-5 validate: accepts every kind with its own direction, a split that sums, float noise, a null reason', () => {
  for (const kind of Object.keys(ML.KIND_DIRECTION)) {
    const dir = ML.KIND_DIRECTION[kind] || 1;
    assert.equal(H.validate('inventory', { stock: 3 * dir }, {}, [{ kind, qty: 3 * dir }]), '', kind);
  }
  assert.equal(H.validate('inventory', { stock: 7 }, {}, [{ kind: 'receipt', qty: 10 }, { kind: 'sale', qty: -3 }]), '');
  assert.equal(H.validate('inventory', { stock: 0.3 }, {}, [{ kind: 'receipt', qty: 0.1 }, { kind: 'receipt', qty: 0.2 }]), '');
  assert.equal(H.validate('inventory', { stock: 5 }, {}, [{ kind: 'receipt', qty: 5, reason: null }]), '');
  assert.equal(H.validate('inventory', { stock: 5 }, { }, new Array(1).fill({ kind: 'receipt', qty: 5 })), '');
  assert.equal(H.validate('inventory', { stock: 50 }, {}, new Array(50).fill({ kind: 'receipt', qty: 1 })), '');
  // a non-object clamps is ignored, exactly as the server does (typeof body.clamps === 'object' else {})
  assert.equal(H.validate('inventory', { stock: 5 }, 'x', [{ kind: 'receipt', qty: 5 }]), '');
  assert.equal(H.validate('inventory', { stock: 5 }, null, [{ kind: 'receipt', qty: 5 }]), '');
});

test('SM-6 hasMovements: only a non-empty array counts', () => {
  assert.equal(H.hasMovements([{}]), true);
  for (const v of [undefined, null, [], {}, 'x', 0]) assert.equal(H.hasMovements(v), false);
});

test('SM-7 canCoalesce: derived+derived keeps the old rule; explicit mixed with derived never merges', () => {
  const ex = (n, clamps) => ({ movements: new Array(n).fill({ kind: 'adjustment', qty: 1 }), clamps: clamps || {} });
  assert.equal(H.canCoalesce({}, {}), true);
  assert.equal(H.canCoalesce({ clamps: { stock: 0 } }, { clamps: {} }), true);
  assert.equal(H.canCoalesce(undefined, undefined), true);
  assert.equal(H.canCoalesce(ex(1), {}), false);
  assert.equal(H.canCoalesce({}, ex(1)), false);
  assert.equal(H.canCoalesce(ex(1), { movements: [] }), false);
  assert.equal(H.canCoalesce(ex(1), ex(1)), true);
  assert.equal(H.canCoalesce(ex(25), ex(25)), true);
  assert.equal(H.canCoalesce(ex(25), ex(26)), false);
  assert.equal(H.canCoalesce(ex(1, { stock: 0 }), ex(1)), false);
  assert.equal(H.canCoalesce(ex(1), ex(1, { stock: 0 })), false);
});

test('SM-11 canCoalesce: explicit items need EQUAL floors (a merged item keeps one floor map); derived keeps the old rule', () => {
  const ex = (floors, n, clamps) => ({ movements: new Array(n || 1).fill({ kind: 'adjustment', qty: 1 }), floors, clamps: clamps || {} });
  // equal: same keys and values, absent counts as empty
  assert.equal(H.canCoalesce(ex({}), ex({})), true);
  assert.equal(H.canCoalesce(ex(undefined), ex({})), true);
  assert.equal(H.canCoalesce(ex(null), ex(undefined)), true);
  assert.equal(H.canCoalesce(ex({ stock: 0 }), ex({ stock: 0 })), true);
  // a non-object floors value is treated as empty, never throws
  assert.equal(H.canCoalesce(ex('x'), ex({})), true);
  assert.equal(H.canCoalesce(ex(5), ex(undefined)), true);
  // different: a floored sale never merges with an unfloored restock, either order
  assert.equal(H.canCoalesce(ex({ stock: 0 }), ex({})), false);
  assert.equal(H.canCoalesce(ex({}), ex({ stock: 0 })), false);
  assert.equal(H.canCoalesce(ex({ stock: 0 }), ex({ stock: 1 })), false);
  assert.equal(H.canCoalesce(ex({ stock: 0 }), ex({ qty: 0 })), false);
  assert.equal(H.canCoalesce(ex({ stock: 0, qty: 0 }), ex({ stock: 0 })), false);
  assert.equal(H.canCoalesce(ex({ stock: undefined }), ex({ qty: undefined })), false); // same count, key absent on one side
  // the other rules still apply with equal floors
  assert.equal(H.canCoalesce(ex({ stock: 0 }, 1, { stock: 0 }), ex({ stock: 0 })), false);
  assert.equal(H.canCoalesce(ex({ stock: 0 }, 25), ex({ stock: 0 }, 26)), false);
  assert.equal(H.canCoalesce(ex({ stock: 0 }, 25), ex({ stock: 0 }, 25)), true);
  // derived + derived: floors never mattered here, rule unchanged (legacy behaviour pinned elsewhere)
  assert.equal(H.canCoalesce({ floors: { stock: 0 } }, { floors: {} }), true);
});

test('SM-8 mergeMovements: call order, no mutation of either input, tolerates an empty side', () => {
  const a = [{ kind: 'receipt', qty: 10 }];
  const b = [{ kind: 'sale', qty: -3 }];
  const m = plain(H.mergeMovements(a, b));
  assert.deepEqual(m, [{ kind: 'receipt', qty: 10 }, { kind: 'sale', qty: -3 }]);
  assert.equal(a.length, 1);
  assert.equal(b.length, 1);
  assert.deepEqual(plain(H.mergeMovements(undefined, b)), plain(b));
  assert.deepEqual(plain(H.mergeMovements(a, undefined)), plain(a));
  assert.deepEqual(plain(H.mergeMovements(undefined, undefined)), []);
});

test('SM-9 parity matrix: client validate agrees with the server on every kind x sign x total', () => {
  const kinds = Object.keys(ML.KIND_DIRECTION);
  let compared = 0;
  for (const kind of kinds) {
    for (const qty of [-2.5, -1, 1, 4]) {
      for (const stock of [qty, qty + 1, 0]) {
        const movements = [{ kind, qty, reason: 'r' }];
        const s = serverAccepts('inventory', { stock }, movements);
        const c = H.validate('inventory', { stock }, {}, movements);
        assert.equal(c === '', s.ok, JSON.stringify({ kind, qty, stock, c, s }));
        if (!s.ok) assert.equal(c, s.error, JSON.stringify({ kind, qty, stock }));
        compared++;
      }
    }
  }
  assert.equal(compared, kinds.length * 12);
});

test('SM-10 seeded monkey: 4000 random delta calls, client and server never disagree on accept vs reject', () => {
  let seed = 20261028;
  const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const kinds = Object.keys(ML.KIND_DIRECTION).concat(['bogus', undefined, 7]);
  const qtys = [1, -1, 2, -2, 0.5, -0.5, 0, NaN, '3', null, 10, -10];
  let accepted = 0;
  for (let i = 0; i < 4000; ++i) {
    const n = 1 + Math.floor(rnd() * 4);
    const movements = [];
    let sum = 0;
    for (let j = 0; j < n; ++j) {
      const m = { kind: pick(kinds), qty: pick(qtys) };
      if (rnd() < 0.3) m.reason = pick(['', 'x', 'y'.repeat(500), 'z'.repeat(501), 5, null]);
      movements.push(m);
      if (typeof m.qty === 'number' && isFinite(m.qty)) sum += m.qty;
    }
    const stock = rnd() < 0.7 ? sum : pick([sum + 1, 0, 5]);
    const entity = rnd() < 0.9 ? 'inventory' : 'stock_batch';
    const deltas = rnd() < 0.95 ? { stock } : { qty: stock };
    const s = serverAccepts(entity, deltas, movements);
    const c = H.validate(entity, deltas, {}, movements);
    assert.equal(c === '', s.ok, JSON.stringify({ entity, deltas, movements, c, s }));
    if (s.ok) accepted++;
  }
  assert.ok(accepted > 100, 'monkey must reach the accept branch (' + accepted + ')');
});
