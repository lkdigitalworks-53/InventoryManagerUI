'use strict';

// PR #186 device test (2026-11-10): after an order document was edited by hand in the Firestore console, every
// edit, completion and delete of that order answered 409 ("updated elsewhere") for ever, and a refused delete
// still wrote an "Order deleted" Activity entry. Root cause: `before` was REBUILT from the local copy
// (_normalizeOrder recomputes the totals from the lines, drops unknown keys, fills defaults) while the server
// deep-compares it with the stored doc. These tests run the REAL function bodies of OrdersStore.qml in a vm
// against the REAL server compare (functions/lib/gatewayLogic.js _deepEqual). No Qt.
// Design and plan: docs/superpowers/specs/2026-11-10-order-cas-base-design.md

const { test } = require('node:test');
const assertStrict = require('node:assert/strict');
const assert = Object.assign((...a) => assertStrict(...a), assertStrict, {
  // Values built inside the vm come from another realm: compare structurally through JSON.
  jsonEqual: (a, b, m) => assertStrict.equal(JSON.stringify(a), JSON.stringify(b), m),
});
const vm = require('vm');
const fs = require('fs');
const path = require('path');
const { extractFunction } = require(path.join('..', '..', '..', 'functions', 'test', 'testSupport', 'qmlHelpers.js'));
const { _deepEqual } = require(path.join('..', '..', '..', 'functions', 'lib', 'gatewayLogic.js'));

const FILE = 'model/OrdersStore.qml';
const SRC = fs.readFileSync(path.join(__dirname, '..', '..', '..', 'qml', FILE), 'utf8');
const FNS = ['_snap', '_rememberBase', '_beforeFor', '_dropPendingDelete', '_onMutationApplied', '_onParkedWriteDiscarded',
  '_onMutationConflicted', '_onBatchMutationFailedPermanently', '_normalizeOrders', '_normalizeOrder', 'computeOrderTotals',
  'parseCurrency', 'formatCurrency', 'findIndexById', '_refreshCounts', '_commit', '_clone', 'buildOrderUpdate', 'updateOrder',
  'deleteOrder', 'applyRemoteOrder', 'applyAdjustment', '_commitRefresh', 'refreshFromFirebase', '_finishRefresh',
  '_cancelRefresh', '_refreshPage', '_fetchFromFirebase', 'clear', '_resetAndFetch', '_setOrders'];

// A QML `onOrdersChanged` handler cannot run in a vm: model it with the real handler body, fired on every write.
const ON_CHANGED = SRC.slice(SRC.indexOf('onOrdersChanged: {') + 'onOrdersChanged: {'.length);
const ON_CHANGED_BODY = ON_CHANGED.slice(0, ON_CHANGED.indexOf('\n    }'));

function makeStore() {
  const log = { sent: [], activity: [], toasts: [], queries: [] };
  const ctx = {
    console: { warn() {}, log() {} },
    orders: [], revision: 0, loadingMore: false, hasMore: true, _resetPending: false, _cursor: null, _pageSize: 2,
    refreshing: false, _refreshSeq: 0, _refreshDone: null, _serverBase: {}, _refreshBases: {}, _pendingDeletes: {},
    _internalOrdersWrite: false, pendingOrderCount: 0, completedOrderCount: 0, outOfStockCount: 0,
    Qt: { formatDate: () => '2026-11-10' },
    InventoryStore: { getById: () => null },
    Gateway: { recordMutation(entity, id, action, before, after) { log.sent.push({ entity, id, action, before, after }); } },
    ActivityLog: { record(...a) { log.activity.push(a); } },
    Toast: { show(m) { log.toasts.push(String(m)); } },
    qsTr: (s) => { const o = new String(s); o.arg = () => o; return o; },
    AuthStore: { tenantId: 't1' },
    FirebaseService: { lastStatusCode: 0, lastError: '', query(coll, q, cb) { log.queries.push({ coll, q, cb }); } },
  };
  vm.createContext(ctx);
  // `orders` is a QML property: writing it fires onOrdersChanged. Model that with an accessor on the context.
  let held = [];
  Object.defineProperty(ctx, 'orders', {
    get: () => held,
    set: (v) => { held = v; vm.runInContext('(function(){' + ON_CHANGED_BODY + '})()', ctx); },
    configurable: true,
  });
  for (const fn of FNS) vm.runInContext(extractFunction(FILE, fn).replace(/^function /, 'this.' + fn + ' = function '), ctx);
  const run = (code) => vm.runInContext(code, ctx);
  return { ctx, log, run };
}

// A stored order in the exact shape the app writes, then damaged the way a hand edit damages it.
const LINE = { productId: 'P1', name: 'Kurta', price: 100, quantity: 2, taxable: true, taxPercent: 5, discountType: 'flat', discountValue: 0, consumption: [] };
function canonicalDoc(s, over) {
  return JSON.parse(JSON.stringify(s.ctx._normalizeOrder(Object.assign({ orderId: 'O1', customer: 'Asha', updatedAt: '2026-11-01T10:00:00.000Z', date: '2026-11-01', status: 'pending', products: [LINE] }, over || {}))));
}
// Hand edit: customer renamed, a line price raised WITHOUT recomputing the totals, an unknown key added.
function consoleEdited(s) {
  const d = canonicalDoc(s);
  d.customer = 'Zainab';
  d.products[0].price = 120;
  d.internalNote = 'checked by hand';
  return d;
}
// The server: applies a write only when the stored doc deep-equals `before` (applyMutation's real compare).
function makeServer(s) {
  const docs = {};
  return {
    docs,
    put(doc) { docs[doc.orderId] = JSON.parse(JSON.stringify(doc)); },
    apply(w) {
      const cur = docs[w.id] === undefined ? null : docs[w.id];
      if (!_deepEqual(cur, w.before)) return { conflict: true, current: cur };
      if (w.action === 'delete') delete docs[w.id]; else docs[w.id] = JSON.parse(JSON.stringify(w.after));
      return { ok: true };
    },
  };
}
function load(s, docs) {
  const items = JSON.parse(JSON.stringify(docs));
  s.ctx._normalizeOrders(items, s.ctx._serverBase);
  s.ctx._setOrders(items);
}

test('CB-1 the reported bug: an order edited by hand in the console can still be edited', () => {
  const s = makeStore(); const srv = makeServer(s);
  const stored = consoleEdited(s); srv.put(stored);
  load(s, [stored]);
  const r = s.ctx.buildOrderUpdate('O1', { customer: 'Zainab K' });
  assert(_deepEqual(srv.docs.O1, r.before), 'before must be the stored doc, key for key');
  s.ctx.updateOrder('O1', { customer: 'Zainab K' });
  assert.equal(srv.apply(s.log.sent[0]).ok, true);
  assert.equal(srv.docs.O1.customer, 'Zainab K');
});

test('CB-1b control: the rebuilt copy really differs from such a doc (the test can fail)', () => {
  const s = makeStore();
  const stored = consoleEdited(s);
  const rebuilt = JSON.parse(JSON.stringify(s.ctx._normalizeOrder(stored)));
  assert.equal(_deepEqual(stored, rebuilt), false);
  assert.notEqual(rebuilt.total, stored.total, 'totals are recomputed from the lines');
  assert.equal('internalNote' in rebuilt, false, 'unknown keys are dropped');
});

test('CB-2 after one accepted write the doc is canonical and later edits keep working', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(consoleEdited(s)); load(s, [srv.docs.O1]);
  for (let i = 0; i < 4; i++) {
    s.ctx.updateOrder('O1', { notes: 'n' + i });
    assert.equal(srv.apply(s.log.sent[i]).ok, true, 'edit ' + i);
  }
  assert.equal('internalNote' in srv.docs.O1, false);
});

test('CB-3 two edits before the first ack: the second before is the first after', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(consoleEdited(s)); load(s, [srv.docs.O1]);
  s.ctx.updateOrder('O1', { notes: 'a' });
  s.ctx.updateOrder('O1', { notes: 'b' });
  assert(_deepEqual(s.log.sent[1].before, s.log.sent[0].after));
  assert.equal(srv.apply(s.log.sent[0]).ok, true);
  assert.equal(srv.apply(s.log.sent[1]).ok, true);
});

test('CB-4 the before handed out is a copy: editing it cannot damage the stored base', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(consoleEdited(s)); load(s, [srv.docs.O1]);
  const r = s.ctx.buildOrderUpdate('O1', { customer: 'X' });
  r.before.products[0].price = 999; r.before.customer = 'tampered';
  assert(_deepEqual(srv.docs.O1, s.ctx.buildOrderUpdate('O1', { customer: 'Y' }).before));
});

test('CB-5 a conflict makes the server answer the next before, even when that answer is not canonical', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  srv.put(consoleEdited(s));                       // hand edit AFTER the device read the doc
  s.ctx.updateOrder('O1', { notes: 'x' });
  const res = srv.apply(s.log.sent[0]);
  assert.equal(res.conflict, true);
  s.ctx._onMutationConflicted('order', 'O1', res.current, 'update');
  assert.equal(s.log.toasts.length, 1);
  s.ctx.updateOrder('O1', { notes: 'y' });
  assert.equal(srv.apply(s.log.sent[1]).ok, true, 'the retry must not conflict again');
});

test('CB-6 a conflict with current=null (deleted elsewhere) forgets the base and removes the order', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  s.ctx._onMutationConflicted('order', 'O1', null, 'update');
  assert.equal(s.ctx.orders.length, 0);
  assert.equal('O1' in s.ctx._serverBase, false);
});

test('CB-7 delete: before is the stored doc; nothing is logged until the server acks', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(consoleEdited(s)); load(s, [srv.docs.O1]);
  s.ctx.deleteOrder('O1');
  assert(_deepEqual(srv.docs.O1, s.log.sent[0].before));
  assert.equal(s.log.activity.length, 0, 'no entry before the ack');
  assert.equal(srv.apply(s.log.sent[0]).ok, true);
  s.ctx._onMutationApplied('order', 'O1', 'delete');
  assert.equal(s.log.activity.length, 1);
  assert.equal(s.log.activity[0][0], 'order_deleted');
  assert.match(s.log.activity[0][1], /Zainab/);
  assert.equal(s.log.activity[0][3], 'O1');
  s.ctx._onMutationApplied('order', 'O1', 'delete');
  assert.equal(s.log.activity.length, 1, 'a duplicate ack logs once');
});

test('CB-8 a refused delete logs nothing, ever, and the order is back', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  srv.put(consoleEdited(s));
  s.ctx.deleteOrder('O1');
  const res = srv.apply(s.log.sent[0]);
  assert.equal(res.conflict, true);
  s.ctx._onMutationConflicted('order', 'O1', res.current, 'delete');
  s.ctx._onMutationApplied('order', 'O1', 'delete');           // a stray late signal
  assert.equal(s.log.activity.length, 0);
  assert.equal(s.ctx.orders.length, 1);
  assert.match(s.log.toasts[0], /Couldn't delete/);
  s.ctx.deleteOrder('O1');                                     // and the retry now works
  assert.equal(srv.apply(s.log.sent[1]).ok, true);
});

test('CB-9 ack handler ignores other entities, other actions and unknown ids', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  s.ctx.deleteOrder('O1');
  s.ctx._onMutationApplied('inventory', 'O1', 'delete');
  s.ctx._onMutationApplied('order', 'O1', 'update');
  s.ctx._onMutationApplied('order', 'O2', 'delete');
  assert.equal(s.log.activity.length, 0);
});

test('CB-10 discarding a parked write drops the pending delete: a later ack logs nothing', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  s.ctx.deleteOrder('O1');
  s.ctx._onParkedWriteDiscarded('req', []);
  s.ctx._onMutationApplied('order', 'O1', 'delete');
  assert.equal(s.log.activity.length, 0);
});

test('CB-11 delete of an unknown id changes nothing and logs nothing', () => {
  const s = makeStore();
  s.ctx.deleteOrder('NOPE');
  assert.equal(s.log.sent.length, 0);
  assert.equal(Object.keys(s.ctx._pendingDeletes).length, 0);
});

test('CB-12 paged load snapshots every page BEFORE the defaults touch the docs', () => {
  const s = makeStore(); const srv = makeServer(s);
  const docs = ['O1', 'O2', 'O3'].map((id) => Object.assign(consoleEdited(s), { orderId: id }));
  docs.forEach((d) => { delete d.notes; delete d.adjustments; srv.put(d); });   // missing keys the defaults would add
  s.ctx._fetchFromFirebase();
  s.log.queries[0].cb(true, { items: JSON.parse(JSON.stringify(docs.slice(0, 2))), hasMore: true, nextCursor: 'c' });
  s.log.queries[1].cb(true, { items: JSON.parse(JSON.stringify(docs.slice(2))), hasMore: false, nextCursor: null });
  for (const id of ['O1', 'O2', 'O3']) {
    s.ctx.updateOrder(id, { notes: 'z' });
    assert.equal(srv.apply(s.log.sent[s.log.sent.length - 1]).ok, true, id);
  }
});

test('CB-13 refresh: a committed refresh replaces the bases with the fresh server images', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  srv.put(consoleEdited(s));                                    // edited by hand while the app was away
  let outcome = null;
  s.ctx.refreshFromFirebase(() => true, (k) => { outcome = k; });
  s.log.queries[0].cb(true, { items: [JSON.parse(JSON.stringify(srv.docs.O1))], hasMore: false, nextCursor: null });
  assert.equal(outcome, 'committed');
  assert.equal(s.ctx.orders[0].customer, 'Zainab');
  s.ctx.updateOrder('O1', { customer: 'Zainab K' });
  assert.equal(srv.apply(s.log.sent[0]).ok, true, 'the exact first symptom of the report');
});

test('CB-14 refresh: a refused or failed refresh keeps the old bases', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  const before = JSON.stringify(s.ctx._serverBase);
  let outcome = null;
  s.ctx.refreshFromFirebase(() => false, (k) => { outcome = k; });
  s.log.queries[0].cb(true, { items: [consoleEdited(s)], hasMore: false, nextCursor: null });
  assert.equal(outcome, 'discarded');
  assert.equal(JSON.stringify(s.ctx._serverBase), before);
  s.ctx.refreshFromFirebase(() => true, (k) => { outcome = k; });
  s.log.queries[1].cb(false, null);
  assert.equal(outcome, 'failed');
  assert.equal(JSON.stringify(s.ctx._serverBase), before);
});

test('CB-15 refresh buffer never leaks into the live bases while a run is open', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  const live = JSON.stringify(s.ctx._serverBase);
  s.ctx.refreshFromFirebase(() => true, () => {});
  s.log.queries[0].cb(true, { items: [consoleEdited(s)], hasMore: true, nextCursor: 'c' });
  assert.equal(JSON.stringify(s.ctx._serverBase), live, 'half a refresh is not a base');
});

test('CB-16 clear and reset forget every base and pending delete', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  s.ctx.deleteOrder('O1');
  s.ctx.clear();
  assert.equal(Object.keys(s.ctx._serverBase).length, 0);
  assert.equal(Object.keys(s.ctx._pendingDeletes).length, 0);
  load(s, [srv.docs.O1]);
  s.ctx._resetAndFetch();
  assert.equal(Object.keys(s.ctx._serverBase).length, 0);
});

test('CB-17 a remote result (applyRemoteOrder) becomes the base untouched', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  const remote = consoleEdited(s);
  s.ctx.applyRemoteOrder(remote);
  assert(_deepEqual(remote, s.ctx.buildOrderUpdate('O1', { notes: 'q' }).before));
});

test('CB-18 an adjustment uses the stored doc as before too', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(consoleEdited(s)); load(s, [srv.docs.O1]);
  s.ctx.applyAdjustment('O1', [Object.assign({}, LINE, { quantity: 1 })], { date: 'd', reason: 'r', refundAmount: 0 });
  assert.equal(srv.apply(s.log.sent[0]).ok, true);
  assert.equal(srv.docs.O1.adjustments.length, 1);
});

test('CB-19 a write of `orders` from outside the store drops every base (falls back to the rebuilt copy)', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(consoleEdited(s)); load(s, [srv.docs.O1]);
  s.ctx.orders = [canonicalDoc(s, { customer: 'Seeded by a test' })];
  assert.equal(Object.keys(s.ctx._serverBase).length, 0);
  const r = s.ctx.buildOrderUpdate('O1', { notes: 'x' });
  assert.equal(r.before.customer, 'Seeded by a test');
});

test('CB-20 an internal write (_setOrders) keeps the bases', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  assert.equal(Object.keys(s.ctx._serverBase).length, 1);
});

test('CB-21 failed batch import forgets the bases of the removed orders', () => {
  const s = makeStore(); const srv = makeServer(s);
  srv.put(canonicalDoc(s)); load(s, [srv.docs.O1]);
  s.ctx._onBatchMutationFailedPermanently('order', [{ entityId: 'O1' }], 'x');
  assert.equal(s.ctx.orders.length, 0);
  assert.equal('O1' in s.ctx._serverBase, false);
});

test('CB-22 no base for an order (never read from the server): the rebuilt copy is used as before', () => {
  const s = makeStore();
  s.ctx._setOrders([canonicalDoc(s)]);
  const r = s.ctx.buildOrderUpdate('O1', { notes: 'x' });
  assert(_deepEqual(canonicalDoc(s), r.before));
});

// ── Property test: random histories, a server that applies the real compare, hand edits at random times ──
function rng(seed) { let x = seed >>> 0; return () => { x = (x * 1664525 + 1013904223) >>> 0; return x / 4294967296; }; }

test('CB-23 monkey: a conflict never repeats for an order unless the doc changed again behind the device', () => {
  for (let seed = 1; seed <= 300; seed++) {
    const rnd = rng(seed);
    const s = makeStore(); const srv = makeServer(s);
    const ids = ['A', 'B', 'C'];
    ids.forEach((id) => srv.put(rnd() < 0.5 ? consoleEdited(s) && Object.assign(consoleEdited(s), { orderId: id }) : canonicalDoc(s, { orderId: id })));
    load(s, ids.map((id) => srv.docs[id]));
    const lastConflictAt = {};   // id -> hand-edit counter at the last conflict
    const handEdits = { A: 0, B: 0, C: 0 };
    const sentBefore = () => s.log.sent.length;
    for (let step = 0; step < 40; step++) {
      const id = ids[Math.floor(rnd() * 3)];
      const roll = rnd();
      if (!s.ctx.orders.some((o) => o.orderId === id)) continue;
      if (roll < 0.15) {                                         // hand edit in the console
        const d = JSON.parse(JSON.stringify(srv.docs[id])); d.customer = 'H' + step; if (rnd() < 0.5) d.products[0].price += 7;
        if (rnd() < 0.3) d.extra = step; srv.put(d); handEdits[id]++;
      } else if (roll < 0.25) {                                  // refresh
        let outcome = null;
        s.ctx.refreshFromFirebase(() => true, (k) => { outcome = k; });
        s.log.queries[s.log.queries.length - 1].cb(true, { items: ids.filter((i) => srv.docs[i]).map((i) => JSON.parse(JSON.stringify(srv.docs[i]))), hasMore: false, nextCursor: null });
        assert.equal(outcome, 'committed');
      } else {
        const del = roll > 0.93;
        const n0 = sentBefore();
        if (del) s.ctx.deleteOrder(id); else s.ctx.updateOrder(id, { notes: 'n' + step });
        if (sentBefore() === n0) continue;
        const w = s.log.sent[s.log.sent.length - 1];
        const res = srv.apply(w);
        if (res.conflict) {
          assert.notEqual(lastConflictAt[id], handEdits[id], 'seed ' + seed + ' step ' + step + ': repeated conflict for ' + id + ' without a new hand edit');
          lastConflictAt[id] = handEdits[id];
          s.ctx._onMutationConflicted('order', id, res.current, del ? 'delete' : 'update');
        } else if (del) {
          s.ctx._onMutationApplied('order', id, 'delete');
        }
      }
    }
    // Every logged delete corresponds to an applied delete.
    const deletedOnServer = ids.filter((i) => !srv.docs[i]).length;
    assert.ok(s.log.activity.length <= deletedOnServer, 'seed ' + seed + ': an Activity entry without a delete');
  }
});

test('CB-24 wiring: no write path rebuilds `before` from the local copy, and the delete log lives only in the ack handler', () => {
  for (const fn of ['buildOrderUpdate', 'applyAdjustment', 'deleteOrder']) {
    const body = extractFunction(FILE, fn);
    assert.equal(/before\s*=\s*Object\.assign\(\{\}/.test(body), false, fn + ' must use _beforeFor');
    assert.ok(body.includes('_beforeFor('), fn + ' uses _beforeFor');
  }
  assert.equal(extractFunction(FILE, 'deleteOrder').includes('ActivityLog.record'), false);
  assert.equal((SRC.match(/ActivityLog\.record\("order_deleted"/g) || []).length, 1);
  assert.ok(extractFunction(FILE, '_onMutationApplied').includes('ActivityLog.record("order_deleted"'));
  assert.ok(SRC.includes('Gateway.mutationApplied.connect(_onMutationApplied)'));
  assert.ok(SRC.includes('Gateway.parkedWriteDiscarded.connect(_onParkedWriteDiscarded)'));
  // every internal write of `orders` goes through _setOrders: the only raw write left is inside it
  const raw = SRC.split('\n').filter((l) => /^\s+orders = /.test(l) && !l.trim().startsWith('property'));
  assert.equal(raw.length, 1);
  assert.ok(extractFunction(FILE, '_setOrders').includes('orders = arr'));
});
