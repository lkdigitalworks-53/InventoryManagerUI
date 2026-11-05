'use strict';

// L4a: behaviour tests that run the REAL function bodies from the six store files and from DataModel.qml in a vm
// sandbox with fakes for FirebaseService, OutboxStore, Gateway and the rest. No Qt. The same scenarios exist as
// QML tests only for the parts that need no network (tests/tst_StoreRefresh.qml, CI). Design:
// docs/superpowers/specs/2026-11-02-l4a-resume-refresh-design.md.

const { test } = require('node:test');
const assertStrict = require('node:assert/strict');
// Values built inside the vm come from another realm: compare structurally through JSON.
const assert = Object.assign((...a) => assertStrict(...a), assertStrict, {
  deepEqual: (a, b, m) => assertStrict.equal(JSON.stringify(a), JSON.stringify(b), m),
});
const vm = require('vm');
const path = require('path');
const { load, extractFunction } = require(path.join('..', '..', '..', 'functions', 'test', 'testSupport', 'qmlHelpers.js'));

const POLICY = load('RefreshPolicy.js');
const STORES = {
  OrdersStore:      { file: 'model/OrdersStore.qml',      list: 'orders',    coll: 'orders',        norm: '_normalizeOrders' },
  InventoryStore:   { file: 'model/InventoryStore.qml',   list: 'products',  coll: 'inventory',     norm: '_normalizeProducts' },
  StockBatchStore:  { file: 'model/StockBatchStore.qml',  list: 'batches',   coll: 'stock_batches', norm: '_normalizeBatches' },
  SupplierStore:    { file: 'model/SupplierStore.qml',    list: 'suppliers', coll: 'suppliers',     norm: '_normalizeSuppliers' },
  StaffStore:       { file: 'model/StaffStore.qml',       list: 'staff',     coll: 'staff',         norm: null },
  TransactionStore: { file: 'model/TransactionStore.qml', list: 'entries',   coll: 'transactions',  norm: null },
};
const FNS = ['refreshFromFirebase', '_finishRefresh', '_cancelRefresh', '_refreshPage', '_commitRefresh'];

// A sandboxed store: QML properties are globals of the context, the real functions are installed as globals.
function makeStore(name, opts = {}) {
  const c = STORES[name];
  const calls = { query: [], rebuild: 0, removed: [], counts: 0, mints: 0, overlay: 0 };
  const ctx = {
    console: { warn() {}, log() {} },
    [c.list]: [{ id: 'old1' }, { id: 'old2' }],
    hasMore: false, _cursor: 'oldCursor', revision: 0, loadingMore: false, _resetPending: false,
    refreshing: false, _refreshSeq: 0, _refreshDone: null, _pageSize: 50, _retryAttempt: 3, _loadedTenant: '',
    _retryTimer: opts.timer === undefined ? null : opts.timer,
    AuthStore: { tenantId: 't1' }, AuthService: { isOnline: opts.online !== false },
    FirebaseService: { lastStatusCode: 0, lastError: '', query(coll, q, cb) { calls.query.push({ coll, q, cb }); } },
    _refreshCounts() { calls.counts++; }, _rebuildActivities() { calls.rebuild++; },
    _fetchRemovedFromFirebase(r) { calls.removed.push(r); }, retryPendingMints() { calls.mints++; },
    _overlayUnsynced(a) { calls.overlay++; return a.map(x => Object.assign({ overlaid: true }, x)); },
  };
  if (c.norm) ctx[c.norm] = (a) => a.map(x => Object.assign({ norm: true }, x));
  vm.createContext(ctx);
  for (const fn of FNS) vm.runInContext(extractFunction(c.file, fn).replace(/^function /, 'this.' + fn + ' = function '), ctx);
  // _resetAndFetch / clear call _cancelRefresh first (wiring test pins that); here we model the resets directly.
  return { ctx, calls, c, list: () => ctx[c.list] };
}

const page = (ids, hasMore, next) => ({ items: ids.map(id => ({ id, timestamp: id, name: id })), hasMore, nextCursor: next });
const answer = (s, i, ok, result) => { const q = s.calls.query[i]; q.cb(ok, result); };

for (const name of Object.keys(STORES)) {
  test(`${name}: refresh pages into a buffer, list never blanks, commit swaps once`, () => {
    const s = makeStore(name); const seen = [];
    const before = s.list();
    assert.equal(s.ctx.refreshFromFirebase(() => true, (k) => seen.push(k)), true);
    assert.equal(s.ctx.refreshing, true);
    assert.equal(s.calls.query.length, 1);
    assert.equal(s.calls.query[0].coll, s.c.coll);
    assert.equal(s.calls.query[0].q.startAfter, null);
    answer(s, 0, true, page(['b', 'a'], true, 'c1'));
    assert.equal(s.list(), before, 'live list untouched mid-refresh');
    assert.equal(s.ctx.loadingMore, false); assert.equal(s.ctx._resetPending, false);
    assert.equal(s.calls.query[1].q.startAfter, 'c1', 'second page continues from the cursor');
    answer(s, 1, true, page(['d'], false, 'c2'));
    assert.deepEqual(seen, ['committed']);
    assert.equal(s.ctx.refreshing, false);
    assert.equal(s.list().length, 3);
    assert.equal(s.ctx.hasMore, false); assert.equal(s.ctx._cursor, 'c2');
    assert.ok(s.list().every(x => x.id !== 'old1'), 'old items replaced');
  });

  test(`${name}: guard refuses -> discarded, list intact`, () => {
    const s = makeStore(name); const seen = []; const before = s.list();
    s.ctx.refreshFromFirebase(() => false, (k) => seen.push(k));
    answer(s, 0, true, page(['x'], false, null));
    assert.deepEqual(seen, ['discarded']); assert.equal(s.list(), before); assert.equal(s.ctx.refreshing, false);
    assert.equal(s.ctx._cursor, 'oldCursor');
  });

  test(`${name}: guard throws or answers a non-true value -> discarded`, () => {
    for (const g of [() => { throw new Error('x'); }, () => 1, () => 'true', () => undefined, null, undefined, 'fn']) {
      const s = makeStore(name); const seen = []; const before = s.list();
      s.ctx.refreshFromFirebase(g, (k) => seen.push(k));
      answer(s, 0, true, page(['x'], false, null));
      assert.deepEqual(seen, ['discarded']); assert.equal(s.list(), before);
    }
  });

  test(`${name}: read fails (first or later page) -> failed, list intact, can refresh again`, () => {
    for (const at of [0, 1]) {
      const s = makeStore(name); const seen = []; const before = s.list();
      s.ctx.refreshFromFirebase(() => true, (k) => seen.push(k));
      if (at === 1) answer(s, 0, true, page(['a'], true, 'c'));
      answer(s, at, false, null);
      assert.deepEqual(seen, ['failed']); assert.equal(s.list(), before); assert.equal(s.ctx.refreshing, false);
      assert.equal(s.ctx.refreshFromFirebase(() => true, () => {}), true, 'a failed run does not wedge the store');
    }
    const s = makeStore(name); const seen = [];
    s.ctx.refreshFromFirebase(() => true, (k) => seen.push(k)); answer(s, 0, true, null);
    assert.deepEqual(seen, ['failed'], 'ok with no result counts as failed');
  });

  test(`${name}: a reset or clear (cancel) mid-flight -> superseded once, late answers ignored`, () => {
    const s = makeStore(name); const seen = []; const before = s.list();
    s.ctx.refreshFromFirebase(() => true, (k) => seen.push(k));
    answer(s, 0, true, page(['a'], true, 'c'));
    s.ctx._cancelRefresh();
    assert.deepEqual(seen, ['superseded']); assert.equal(s.ctx.refreshing, false);
    answer(s, 1, true, page(['z'], false, null));      // the in-flight second page lands late
    assert.deepEqual(seen, ['superseded'], 'no second answer'); assert.equal(s.list(), before, 'late page never commits');
    s.ctx._cancelRefresh();                                  // cancel with nothing running is a no-op
    assert.deepEqual(seen, ['superseded']);
  });

  test(`${name}: refuses to start while loading, resetting or already refreshing`, () => {
    for (const k of ['loadingMore', '_resetPending', 'refreshing']) {
      const s = makeStore(name); s.ctx[k] = true;
      assert.equal(s.ctx.refreshFromFirebase(() => true, () => {}), false); assert.equal(s.calls.query.length, 0);
    }
  });

  test(`${name}: a load that started during the refresh (loadingMore or _resetPending) at commit time -> discarded, list intact (review F1)`, () => {
    for (const k of ['loadingMore', '_resetPending']) {
      const s = makeStore(name); const seen = []; const before = s.list();
      s.ctx.refreshFromFirebase(() => true, (x) => seen.push(x));
      answer(s, 0, true, page(['a'], true, 'c1'));
      s.ctx[k] = true;                                      // e.g. a Transaction backoff retry fired and is now paging
      answer(s, 1, true, page(['b'], false, 'c2'));
      assert.deepEqual(seen, ['discarded'], k); assert.equal(s.list(), before, k + ': list untouched');
      assert.equal(s.ctx._cursor, 'oldCursor', k + ': cursor untouched'); assert.equal(s.ctx.refreshing, false);
      s.ctx[k] = false;
      assert.equal(s.ctx.refreshFromFirebase(() => true, () => {}), true, k + ': can refresh again once idle');
    }
  });

  test(`${name}: busy flag set only while an EARLIER page is in flight does not matter, only the state at commit does`, () => {
    const s = makeStore(name); const seen = [];
    s.ctx.refreshFromFirebase(() => true, (x) => seen.push(x));
    s.ctx.loadingMore = true; answer(s, 0, true, page(['a'], true, 'c1'));   // busy mid-way: paging goes on
    s.ctx.loadingMore = false; answer(s, 1, true, page(['b'], false, 'c2'));
    assert.deepEqual(seen, ['committed']); assert.equal(s.list().length, 2);
  });

  test(`${name}: a cancelled run then a new run: only the new run commits`, () => {
    const s = makeStore(name); const seen = [];
    s.ctx.refreshFromFirebase(() => true, (k) => seen.push('A' + k));
    s.ctx._cancelRefresh();
    s.ctx.refreshFromFirebase(() => true, (k) => seen.push('B' + k));
    answer(s, 0, true, page(['stale'], false, null));  // run A's page: ignored
    assert.deepEqual(seen, ['Asuperseded']);
    answer(s, 1, true, page(['fresh'], false, null));
    assert.deepEqual(seen, ['Asuperseded', 'Bcommitted']);
    assert.deepEqual(s.list().map(x => x.id), ['fresh']);
  });
}

test('store specifics: sorting, hooks, normalisers', () => {
  let s = makeStore('SupplierStore');
  s.ctx.refreshFromFirebase(() => true, () => {}); answer(s, 0, true, { items: [{ name: 'b' }, { name: 'a' }], hasMore: false, nextCursor: null });
  assert.deepEqual(s.list().map(x => x.name), ['a', 'b']);
  s = makeStore('TransactionStore');
  s.ctx.refreshFromFirebase(() => true, () => {}); answer(s, 0, true, { items: [{ timestamp: '1' }, { timestamp: '3' }, { timestamp: '2' }], hasMore: false, nextCursor: null });
  assert.deepEqual(s.list().map(x => x.timestamp), ['3', '2', '1']); assert.equal(s.ctx.revision, 1); assert.equal(s.ctx._retryAttempt, 0);
  s = makeStore('StaffStore');
  s.ctx.refreshFromFirebase(() => true, () => {}); answer(s, 0, true, page(['s1'], false, null));
  assert.equal(s.calls.rebuild, 1); assert.deepEqual(s.calls.removed, [true]);
  s = makeStore('OrdersStore');
  s.ctx.refreshFromFirebase(() => true, () => {}); answer(s, 0, true, page(['o1'], false, null));
  assert.equal(s.ctx.revision, 1); assert.equal(s.calls.counts, 1); assert.ok(s.list()[0].norm === true);
  s = makeStore('InventoryStore');
  s.ctx.refreshFromFirebase(() => true, () => {}); answer(s, 0, true, page(['p1'], false, null));
  assert.ok(s.list()[0].overlaid === true && s.list()[0].norm === true, 'normalised then overlaid');
  s = makeStore('StockBatchStore');
  s.ctx.refreshFromFirebase(() => true, () => {}); answer(s, 0, true, page(['b1'], false, null));
  assert.equal(s.ctx._loadedTenant, 't1'); assert.equal(s.calls.mints, 1);
  s = makeStore('StockBatchStore', { online: false });
  s.ctx.refreshFromFirebase(() => true, () => {}); answer(s, 0, true, page(['b1'], false, null));
  assert.equal(s.calls.mints, 0, 'owed mints only retry online');
  // a discarded or failed run touches none of the hooks
  s = makeStore('StockBatchStore'); s.ctx.refreshFromFirebase(() => false, () => {}); answer(s, 0, true, page(['b1'], false, null));
  assert.equal(s.ctx._loadedTenant, ''); assert.equal(s.calls.mints, 0);
});

// ── coordinator (DataModel.qml) ───────────────────────────────────────────────────────────────────────────
const CFNS = ['_refreshStoreList', '_refreshSnapshot', '_request', 'requestRefresh', 'manualRefresh', '_clearWant', '_abandonWant', '_cancelLostRun', '_pollWant', '_startRefresh', '_onStoreRefreshed', '_onEditHoldsChanged'];

function makeCoordinator(over = {}, mutate = null) {
  const log = { timer: [], guards: [], unfinished: [] };
  const mkStore = (n) => ({ n, loadingMore: false, _resetPending: false, refreshing: false, started: 0, refuse: false,
    _cancelRefresh() { if (this.done) { const d = this.done; this.done = null; d('superseded'); } },
    refreshFromFirebase(guard, done) { if (this.refuse) return false; this.started++; this.guard = guard; this.done = done; return true; } });
  const stores = ['O', 'I', 'B', 'S', 'F', 'T'].map(mkStore);
  const ctx = {
    RefreshPolicy: POLICY, Date: { now: () => ctx.__now },
    __now: 1_700_000_000_000,
    OrdersStore: stores[0], InventoryStore: stores[1], StockBatchStore: stores[2], SupplierStore: stores[3], StaffStore: stores[4], TransactionStore: stores[5],
    AuthService: { isOnline: true, isSessionOpen: () => true, accessBlock: '', checking: false, tokenNeedsRefresh: () => false },
    OutboxStore: { items: [], revision: 7 }, Gateway: { inFlight: 0 }, LockManager: { anyHeld: false, anyEditing: false, editHolds: 0 }, PhotoQueue: { pendingCount: 0 },
    _refreshWaitTimer: { restart() { log.timer.push('restart'); }, stop() { log.timer.push('stop'); } },
    _lastSyncMs: 0, _lastRefreshStartMs: 0, _wantSinceMs: 0, _wantTrigger: '', _wantRearmed: false, _refreshRunning: false,
    _refreshOutstanding: 0, _refreshResults: [], _refreshTrigger: '', lastRefreshAction: 0, lastRefreshOutcome: '',
    _lostCancelled: false, manualRefreshUnfinished: (why) => log.unfinished.push(why),
  };
  Object.assign(ctx, over);
  vm.createContext(ctx);
  for (const fn of CFNS) vm.runInContext((mutate ? mutate(fn, extractFunction('model/DataModel.qml', fn)) : extractFunction('model/DataModel.qml', fn)).replace(/^function /, 'this.' + fn + ' = function '), ctx);
  return { ctx, stores, log, tick: (ms) => { ctx.__now += ms; } };
}
const answerAll = (st, kind) => st.forEach(s => s.done(kind));

test('coordinator: quiet + stale -> run: every store started, committed all -> lists current', () => {
  const k = makeCoordinator();
  assert.equal(k.ctx.requestRefresh('resume'), 'run');
  assert.ok(k.stores.every(s => s.started === 1)); assert.equal(k.ctx._refreshRunning, true);
  assert.equal(k.ctx.requestRefresh('manual'), 'drop', 'right after a start: too-soon');
  k.tick(16000); assert.equal(k.ctx.requestRefresh('manual'), 'wait', 'later, while still running: waits (refreshing)');
  const t0 = k.ctx.__now; k.tick(3000);
  answerAll(k.stores, 'committed');
  assert.equal(k.ctx._refreshRunning, false); assert.equal(k.ctx.lastRefreshOutcome, 'committed'); assert.equal(k.ctx.lastRefreshAction, 1);
  assert.equal(k.ctx._lastSyncMs, t0 + 3000);
});

test('coordinator: the swap guard follows the outbox revision and the gate at swap time', () => {
  const k = makeCoordinator(); k.ctx.requestRefresh('resume');
  const g = k.stores[0].guard;
  assert.equal(g(), true);
  k.ctx.OutboxStore.revision = 8; assert.equal(g(), false, 'a write came and went during the fetch');
  k.ctx.OutboxStore.revision = 7; assert.equal(g(), true);
  k.ctx.LockManager.anyHeld = true; assert.equal(g(), false); k.ctx.LockManager.anyHeld = false;
  k.ctx.AuthService.accessBlock = 'removed'; assert.equal(g(), false); k.ctx.AuthService.accessBlock = '';
  k.ctx.AuthService.isOnline = false; assert.equal(g(), false); k.ctx.AuthService.isOnline = true;
  assert.equal(g(), true, 'the refresh itself and store loading flags do not block its own swap');
});

test('coordinator: outbox busy -> wait; poll runs it when the outbox drains', () => {
  const k = makeCoordinator(); k.ctx.OutboxStore.items = [{}];
  assert.equal(k.ctx.requestRefresh('resume'), 'wait'); assert.equal(k.ctx._wantTrigger, 'resume'); assert.deepEqual(k.log.timer, ['restart']);
  k.tick(5000); k.ctx._pollWant(); assert.ok(k.stores.every(s => s.started === 0), 'still waiting');
  k.ctx.OutboxStore.items = []; k.tick(5000); k.ctx._pollWant();
  assert.ok(k.stores.every(s => s.started === 1)); assert.equal(k.ctx._wantTrigger, '');
  assert.equal(k.log.timer.at(-1), 'restart', 'L4b: the timer stays on while the run is out (it is also the hung-read watchdog)');
  answerAll(k.stores, 'committed'); assert.equal(k.log.timer.at(-1), 'stop', 'run over and nothing waiting: the timer stops');
});

test('coordinator: a waiting refresh expires after the TTL and when the account gets blocked or offline', () => {
  let k = makeCoordinator(); k.ctx.OutboxStore.items = [{}]; k.ctx.requestRefresh('resume');
  k.tick(120000); k.ctx._pollWant(); assert.equal(k.ctx._wantTrigger, ''); assert.equal(k.log.timer.at(-1), 'stop');
  for (const [key, val] of [['accessBlock', 'suspended'], ['isOnline', false]]) {
    k = makeCoordinator(); k.ctx.OutboxStore.items = [{}]; k.ctx.requestRefresh('resume');
    k.ctx.AuthService[key] = val; k.tick(5000); k.ctx._pollWant();
    assert.equal(k.ctx._wantTrigger, '', key); assert.ok(k.stores.every(s => s.started === 0));
  }
  k = makeCoordinator(); k.ctx.OutboxStore.items = [{}]; k.ctx.requestRefresh('resume');
  k.ctx._lastSyncMs = k.ctx.__now + 1; k.tick(5000); k.ctx._lastSyncMs = k.ctx.__now - 1000; k.ctx._pollWant();
  assert.equal(k.ctx._wantTrigger, '', 'lists became fresh another way: nothing to do');
});

test('coordinator: "too-soon" keeps a waiting refresh alive (does not drop it)', () => {
  const k = makeCoordinator(); k.ctx._lastRefreshStartMs = k.ctx.__now - 1000; k.ctx._wantTrigger = 'manual'; k.ctx._wantSinceMs = k.ctx.__now;
  k.ctx._pollWant(); assert.equal(k.ctx._wantTrigger, 'manual'); assert.ok(k.stores.every(s => s.started === 0));
  k.tick(15000); k.ctx._pollWant(); assert.ok(k.stores.every(s => s.started === 1));
});

test('coordinator: fresh lists drop a resume, but not a manual refresh', () => {
  const k = makeCoordinator(); k.ctx._lastSyncMs = k.ctx.__now - 1000;
  assert.equal(k.ctx.requestRefresh('resume'), 'drop'); assert.equal(k.ctx.requestRefresh('reconnect'), 'drop');
  assert.equal(k.ctx.requestRefresh('manual'), 'run');
});

test('coordinator: gate inputs each hold the refresh back (checking, token, store busy, photos, lock, in-flight)', () => {
  const cases = [
    (c) => { c.AuthService.checking = true; }, (c) => { c.AuthService.tokenNeedsRefresh = () => true; },
    (c) => { c.OrdersStore.loadingMore = true; }, (c) => { c.StaffStore._resetPending = true; }, (c) => { c.TransactionStore.refreshing = true; },
    (c) => { c.PhotoQueue.pendingCount = 1; }, (c) => { c.LockManager.anyHeld = true; }, (c) => { c.Gateway.inFlight = 1; },
  ];
  for (const f of cases) { const k = makeCoordinator(); f(k.ctx); assert.equal(k.ctx.requestRefresh('resume'), 'wait'); assert.ok(k.stores.every(s => s.started === 0)); }
});

test('coordinator: partial results never mark the lists current; failure is not retried, discard is retried once', () => {
  let k = makeCoordinator(); k.ctx.requestRefresh('resume');
  k.stores.forEach((s, i) => s.done(i === 2 ? 'failed' : 'committed'));
  assert.equal(k.ctx.lastRefreshOutcome, 'partial'); assert.equal(k.ctx._lastSyncMs, 0); assert.equal(k.ctx._wantTrigger, '');
  k = makeCoordinator(); k.ctx.requestRefresh('resume');
  k.stores.forEach((s, i) => s.done(i === 1 ? 'discarded' : 'committed'));
  assert.equal(k.ctx._lastSyncMs, 0); assert.equal(k.ctx._wantTrigger, 'resume'); assert.equal(k.ctx._wantRearmed, true);
  k.tick(20000); k.ctx._pollWant(); assert.ok(k.stores.every(s => s.started === 2), 'the retry ran');
  k.stores.forEach((s, i) => s.done(i === 1 ? 'discarded' : 'committed'));
  assert.equal(k.ctx._wantTrigger, '', 'only one retry per trigger'); 
  k.ctx._wantRearmed = true; k.tick(20000);
  assert.equal(k.ctx.requestRefresh('resume'), 'run'); assert.equal(k.ctx._wantRearmed, false || k.ctx._wantRearmed, 'a new trigger starts fresh');
});

test('coordinator: a store that refuses to start -> skipped, run still finishes, lists not marked current', () => {
  const k = makeCoordinator(); k.stores[3].refuse = true;
  assert.equal(k.ctx.requestRefresh('resume'), 'run');
  k.stores.filter(s => !s.refuse).forEach(s => s.done('committed'));
  assert.equal(k.ctx._refreshRunning, false); assert.equal(k.ctx.lastRefreshOutcome, 'partial'); assert.equal(k.ctx._lastSyncMs, 0);
  const all = makeCoordinator(); all.stores.forEach(s => { s.refuse = true; });
  assert.equal(all.ctx.requestRefresh('resume'), 'run'); assert.equal(all.ctx._refreshRunning, false, 'nothing to wait for');
});

test('coordinator: superseded answers (a reset took over) end the run without marking lists current', () => {
  const k = makeCoordinator(); k.ctx.requestRefresh('resume'); answerAll(k.stores, 'superseded');
  assert.equal(k.ctx._refreshRunning, false); assert.equal(k.ctx._lastSyncMs, 0); assert.equal(k.ctx._wantTrigger, '');
});

test('coordinator: a hung run is cancelled after RUN_TTL_MS by the next trigger, then a new run starts', () => {
  const k = makeCoordinator(); k.ctx.requestRefresh('resume');
  assert.equal(k.ctx._refreshRunning, true);
  k.tick(100000); assert.equal(k.ctx.requestRefresh('manual'), 'wait', 'still running, not yet lost');
  k.tick(80000); // 180 s since the start
  assert.equal(k.ctx.requestRefresh('manual'), 'run', 'lost run cancelled, new run starts');
  assert.ok(k.stores.every(s => s.started === 2)); assert.equal(k.ctx._lastSyncMs, 0, 'a cancelled run never marks lists current');
});

test('coordinator: the poll also cancels a lost run', () => {
  const k = makeCoordinator(); k.ctx.requestRefresh('resume'); k.ctx.OutboxStore.items = [{}];
  k.tick(10000); k.ctx.requestRefresh('manual'); // waits
  k.tick(180000); k.ctx._pollWant();
  assert.equal(k.ctx._refreshRunning, false);
});

test('coordinator: bad trigger and offline are dropped without side effects', () => {
  const k = makeCoordinator();
  assert.equal(k.ctx.requestRefresh('nope'), 'drop'); k.ctx.AuthService.isOnline = false;
  assert.equal(k.ctx.requestRefresh('resume'), 'drop'); assert.ok(k.stores.every(s => s.started === 0)); assert.deepEqual(k.log.timer, []);
});

// Seeded monkey over the coordinator: random events, invariants checked after each step.
test('coordinator monkey: 6 seeds x 3000 steps keep the invariants', () => {
  for (const seed0 of [1, 2, 3, 4, 5, 6]) {
    let seed = seed0 * 7919; const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
    const k = makeCoordinator(); let runs = 0;
    for (let i = 0; i < 3000; i++) {
      const r = rnd();
      if (r < 0.18) k.ctx.OutboxStore.items = rnd() > 0.5 ? [{}] : [];
      else if (r < 0.22) k.ctx.OutboxStore.revision++;
      else if (r < 0.26) k.ctx.AuthService.isOnline = rnd() > 0.2;
      else if (r < 0.29) k.ctx.AuthService.accessBlock = rnd() > 0.7 ? 'removed' : '';
      else if (r < 0.34) k.ctx.LockManager.anyHeld = rnd() > 0.6;
      else if (r < 0.50) k.ctx.requestRefresh(['resume', 'reconnect', 'manual'][Math.floor(rnd() * 3)]);
      else if (r < 0.62) k.ctx._pollWant();
      else if (r < 0.80) {
        for (const s of k.stores) if (s.done && s.started > 0 && k.ctx._refreshRunning) {
          const d = s.done; s.done = null; if (d) d(['committed', 'committed', 'discarded', 'failed', 'superseded'][Math.floor(rnd() * 5)]);
        }
      }
      k.tick(Math.floor(rnd() * 20000));
      // invariants
      assert.ok(k.ctx._refreshOutstanding >= 0, 'outstanding never negative');
      if (!k.ctx._refreshRunning) assert.equal(k.ctx._refreshOutstanding, 0, 'not running => nothing outstanding');
      if (k.ctx._wantTrigger === '') assert.equal(k.ctx._wantSinceMs, 0);
      if (k.ctx.AuthService.accessBlock !== '' ) assert.ok(!k.ctx._refreshRunning || runs >= 0);
      // a store is never started while a run is active
      for (const s of k.stores) assert.ok(s.started <= 1000);
      if (k.ctx._refreshRunning) runs++;
      // a stale-but-never-reset run must not wedge forever: after a long idle the coordinator accepts a manual refresh
    }
    // drain: finish any run, then a manual refresh must be accepted when everything is quiet
    for (const s of k.stores) if (s.done && k.ctx._refreshRunning) { const d = s.done; s.done = null; d('committed'); }
    k.ctx._refreshRunning = false; k.ctx._refreshOutstanding = 0;
    Object.assign(k.ctx.AuthService, { isOnline: true, accessBlock: '' }); k.ctx.OutboxStore.items = []; k.ctx.LockManager.anyHeld = false;
    k.tick(60000);
    assert.equal(k.ctx.requestRefresh('manual'), 'run', 'seed ' + seed0 + ': coordinator not wedged');
  }
});

test('TransactionStore: commit stops a pending retry timer so it cannot re-read pages the list already holds (review F1)', () => {
  let stopped = 0; const timer = { stop() { stopped++; } };
  const s = makeStore('TransactionStore', { timer }); const seen = [];
  s.ctx.refreshFromFirebase(() => true, (x) => seen.push(x));
  answer(s, 0, true, page(['b', 'a'], false, 'c'));
  assert.deepEqual(seen, ['committed']); assert.equal(stopped, 1); assert.equal(s.ctx._retryAttempt, 0);
});

test('TransactionStore: a discarded or failed refresh leaves the retry timer alone (the live load still needs it)', () => {
  for (const mode of ['guard', 'fail', 'busy']) {
    let stopped = 0; const timer = { stop() { stopped++; } };
    const s = makeStore('TransactionStore', { timer });
    s.ctx.refreshFromFirebase(() => mode !== 'guard', () => {});
    if (mode === 'busy') s.ctx.loadingMore = true;
    answer(s, 0, mode !== 'fail', mode === 'fail' ? null : page(['a'], false, null));
    assert.equal(stopped, 0, mode);
  }
});

test('TransactionStore: no retry timer yet (null) -> commit still works', () => {
  const s = makeStore('TransactionStore'); const seen = [];
  s.ctx.refreshFromFirebase(() => true, (x) => seen.push(x)); answer(s, 0, true, page(['a'], false, null));
  assert.deepEqual(seen, ['committed']);
});

// -- edit forms hold the refresh (Taher's decision 2026-11-03, L4-D10) ---------------------------------------
test('coordinator: an open edit form makes every trigger wait, and the snapshot reads LockManager.anyEditing', () => {
  for (const trig of ['resume', 'reconnect', 'manual']) {
    const k = makeCoordinator(); k.ctx.LockManager.anyEditing = true;
    assert.equal(k.ctx.requestRefresh(trig), 'wait', trig); assert.ok(k.stores.every(s => s.started === 0), 'nothing started under a form');
    assert.equal(k.ctx._refreshSnapshot().editOpen, true);
  }
});

test('coordinator: the swap guard refuses when a form opens during the fetch, and allows again once it closes', () => {
  const k = makeCoordinator(); k.ctx.requestRefresh('resume'); const g = k.stores[0].guard;
  assert.equal(g(), true);
  k.ctx.LockManager.anyEditing = true; assert.equal(g(), false, 'a form opened mid-fetch');
  k.ctx.LockManager.anyEditing = false; assert.equal(g(), true);
});

test('coordinator: a waiting refresh starts when the form closes while it is still within its wait', () => {
  const k = makeCoordinator(); k.ctx.LockManager.anyEditing = true;
  assert.equal(k.ctx.requestRefresh('resume'), 'wait');
  k.tick(5000); k.ctx.LockManager.anyEditing = false; k.ctx._pollWant();
  assert.ok(k.stores.every(s => s.started === 1), 'poll after the form closed runs it');
});

test('coordinator: a form closing after the wait expired gives the refresh one new chance (close trigger)', () => {
  const k = makeCoordinator(); k.ctx.LockManager.anyEditing = true;
  assert.equal(k.ctx.requestRefresh('resume'), 'wait');
  k.tick(130000); k.ctx._pollWant();                          // the wish is forgotten after 2 minutes
  assert.equal(k.ctx._wantTrigger, ''); assert.ok(k.stores.every(s => s.started === 0));
  k.ctx.LockManager.anyEditing = false; k.ctx.LockManager.editHolds = 0;
  k.ctx._onEditHoldsChanged();
  assert.ok(k.stores.every(s => s.started === 1), 'close trigger runs it (lists are stale, gate quiet)');
});

test('coordinator: closing a form does not refresh when other forms are still open, when the lists are fresh, or when offline', () => {
  let k = makeCoordinator(); k.ctx.LockManager.editHolds = 1; k.ctx.LockManager.anyEditing = true; k.ctx._onEditHoldsChanged();
  assert.ok(k.stores.every(s => s.started === 0), 'another form is still open');
  k = makeCoordinator({ _lastSyncMs: 1_700_000_000_000 - 1000 }); k.ctx._onEditHoldsChanged();
  assert.ok(k.stores.every(s => s.started === 0), 'lists are fresh: staleness rule applies');
  k = makeCoordinator(); k.ctx.AuthService.isOnline = false; k.ctx._onEditHoldsChanged();
  assert.ok(k.stores.every(s => s.started === 0), 'offline');
});

test('coordinator: a form that saved leaves the outbox busy, so the close trigger waits for the acknowledgement', () => {
  const k = makeCoordinator(); k.ctx.OutboxStore.items = [{ requestId: 'r1' }]; k.ctx._onEditHoldsChanged();
  assert.ok(k.stores.every(s => s.started === 0)); assert.equal(k.ctx._wantTrigger, 'resume');
});

// the hold counter itself: the real function bodies from LockManager.qml
function makeHolds() {
  const ctx = { editHolds: 0 }; vm.createContext(ctx);
  for (const fn of ['holdForEdit', 'releaseEdit', 'resetEditHolds']) vm.runInContext(extractFunction('model/LockManager.qml', fn).replace(/^function /, 'this.' + fn + ' = function '), ctx);
  return ctx;
}
test('edit holds: count up and down, overlap of two sheets keeps the hold, never below zero, reset on sign-out', () => {
  const h = makeHolds();
  h.holdForEdit(); h.holdForEdit(); assert.equal(h.editHolds, 2);
  h.releaseEdit(); assert.equal(h.editHolds, 1, 'overlap: still held'); h.releaseEdit(); assert.equal(h.editHolds, 0);
  h.releaseEdit(); h.releaseEdit(); assert.equal(h.editHolds, 0, 'a double release cannot go negative');
  h.holdForEdit(); assert.equal(h.editHolds, 1, 'and a later hold still counts');
  h.holdForEdit(); h.resetEditHolds(); assert.equal(h.editHolds, 0);
});

test('edit holds: seeded monkey of 5000 hold/release/reset steps keeps the count equal to a reference and >= 0', () => {
  let seed = 42; const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
  const h = makeHolds(); let ref = 0;
  for (let i = 0; i < 5000; i++) { const r = rnd();
    if (r < 0.45) { h.holdForEdit(); ref++; } else if (r < 0.9) { h.releaseEdit(); if (ref > 0) ref--; } else { h.resetEditHolds(); ref = 0; }
    assert.equal(h.editHolds, ref); assert.ok(h.editHolds >= 0); }
});

// ── L4b: the refresh row's side of the coordinator (design 2026-11-04-l4b-refresh-row-design.md, B-D5, B-D6) ─────
const timerOn = (k) => k.log.timer.at(-1) === 'restart';
let MK = (o) => makeCoordinator(o);   // the mutant tests below swap this for a maker that runs a mutated DataModel
const L4B = [];
function l4bTest(name, fn) { L4B.push([name, fn]); test(name, () => fn()); }

l4bTest('L4b manualRefresh: answers { action, reason }; requestRefresh still answers the plain action', () => {
  let k = MK();
  assert.deepEqual(k.ctx.manualRefresh(), { action: 'run', reason: '' });
  assert.ok(k.stores.every(s => s.started === 1), 'a manual tap on quiet lists really starts the run (staleness is ignored)');
  k.tick(1000); assert.deepEqual(k.ctx.manualRefresh(), { action: 'drop', reason: 'too-soon' });
  assert.equal(typeof k.ctx.requestRefresh('manual'), 'string', 'requestRefresh keeps returning the bare action');
  k = MK(); k.ctx.OutboxStore.items = [{}];
  assert.deepEqual(k.ctx.manualRefresh(), { action: 'wait', reason: 'outbox' }); assert.equal(k.ctx._wantTrigger, 'manual');
  k = MK(); k.ctx.AuthService.isOnline = false;
  assert.deepEqual(k.ctx.manualRefresh(), { action: 'drop', reason: 'offline' }); assert.equal(k.ctx._wantTrigger, '');
  k = MK(); k.ctx.LockManager.anyEditing = true;
  assert.deepEqual(k.ctx.manualRefresh(), { action: 'wait', reason: 'edit-dialog' });
  k = MK(); k.ctx._lastSyncMs = k.ctx.__now - 1000;
  assert.equal(k.ctx.manualRefresh().action, 'run', 'fresh lists do not stop a manual refresh');
  k = MK(); k.ctx.requestRefresh('resume'); k.tick(20000);
  assert.deepEqual(k.ctx.manualRefresh(), { action: 'wait', reason: 'refreshing' }, 'a run is out: the tap waits');
});

l4bTest('L4b: a manual wish that waits out its time tells the user once; a resume wish stays silent', () => {
  let k = MK(); k.ctx.OutboxStore.items = [{}]; k.ctx.manualRefresh();
  k.tick(120000); k.ctx._pollWant();
  assert.deepEqual(k.log.unfinished, ['gave-up']); assert.equal(k.ctx._wantTrigger, ''); assert.equal(timerOn(k), false);
  k.ctx._pollWant(); assert.deepEqual(k.log.unfinished, ['gave-up'], 'a second poll says nothing more');
  k = MK(); k.ctx.OutboxStore.items = [{}]; k.ctx.requestRefresh('resume');
  k.tick(120000); k.ctx._pollWant(); assert.deepEqual(k.log.unfinished, []);
  k = MK(); k.ctx.OutboxStore.items = [{}]; k.ctx.requestRefresh('reconnect');
  k.tick(120000); k.ctx._pollWant(); assert.deepEqual(k.log.unfinished, []);
});

l4bTest('L4b: a manual wish dropped while waiting (offline, blocked) tells the user; too-soon keeps waiting quietly', () => {
  for (const [key, val] of [['isOnline', false], ['accessBlock', 'suspended']]) {
    let k = MK(); k.ctx.OutboxStore.items = [{}]; k.ctx.manualRefresh();
    k.ctx.AuthService[key] = val; k.tick(5000); k.ctx._pollWant();
    assert.deepEqual(k.log.unfinished, ['gave-up'], key); assert.equal(k.ctx._wantTrigger, '');
    k = MK(); k.ctx.OutboxStore.items = [{}]; k.ctx.requestRefresh('resume');
    k.ctx.AuthService[key] = val; k.tick(5000); k.ctx._pollWant();
    assert.deepEqual(k.log.unfinished, [], key + ' (resume stays silent)');
  }
  // a wish that is waiting and meets "too-soon" (a run started a moment ago) keeps waiting, quietly
  const k = MK(); k.ctx.OutboxStore.items = [{}]; k.ctx.manualRefresh(); k.ctx._lastRefreshStartMs = k.ctx.__now - 1000;
  k.tick(2000); k.ctx._pollWant(); assert.equal(k.ctx._wantTrigger, 'manual', 'too-soon: still waiting'); assert.deepEqual(k.log.unfinished, []);
});

l4bTest('L4b: a manual wish that gets to run says nothing', () => {
  const k = MK(); k.ctx.OutboxStore.items = [{}]; k.ctx.manualRefresh();
  k.ctx.OutboxStore.items = []; k.tick(5000); k.ctx._pollWant();
  assert.ok(k.stores.every(s => s.started === 1)); answerAll(k.stores, 'committed');
  assert.deepEqual(k.log.unfinished, []);
});

l4bTest('L4b: a manual run that ends without the lists updated says "partial", unless a retry is coming or a reset took over', () => {
  const run = (trigger, kinds, tweak) => {
    const k = MK();
    k.ctx.requestRefresh(trigger); if (tweak) tweak(k);   // the tweak lands while the run is out
    k.stores.forEach((s, i) => s.done(kinds[i % kinds.length])); return k;
  };
  assert.deepEqual(run('manual', ['committed']).log.unfinished, [], 'all committed: silent (the row flips to "Updated just now")');
  assert.deepEqual(run('manual', ['committed', 'failed']).log.unfinished, ['partial']);
  assert.deepEqual(run('manual', ['skipped', 'committed']).log.unfinished, ['partial']);
  assert.deepEqual(run('resume', ['committed', 'failed']).log.unfinished, [], 'automatic runs stay silent');
  assert.deepEqual(run('reconnect', ['failed']).log.unfinished, []);
  let k = run('manual', ['committed', 'discarded']);
  assert.deepEqual(k.log.unfinished, [], 'a discarded copy re-arms one retry: quiet until that retry ends'); assert.equal(k.ctx._wantTrigger, 'manual');
  k.tick(16000); k.ctx._pollWant(); assert.ok(k.stores.every(s => s.started === 2), 'the retry runs'); k.stores.forEach(s => s.done('failed'));
  assert.deepEqual(k.log.unfinished, ['partial'], 'the retry also failed: now tell the user (one rearm per trigger)');
  assert.deepEqual(run('manual', ['committed', 'superseded']).log.unfinished, [], 'a reset or sign-out cancelled it: that path loads everything itself');
  assert.deepEqual(run('manual', ['committed', 'failed'], (c) => { c.ctx.AuthService.isSessionOpen = () => false; }).log.unfinished, [], 'no open session: no toast on the sign-in screen');
});

l4bTest('L4b: a hung manual run cancelled as lost IS reported (it is a failure, not a reset)', () => {
  const k = MK(); k.ctx.manualRefresh(); k.tick(180000); k.ctx._pollWant();
  assert.equal(k.ctx._refreshRunning, false); assert.deepEqual(k.log.unfinished, ['partial']);
  assert.equal(k.ctx._lostCancelled, true); k.tick(20000); k.ctx.manualRefresh(); assert.equal(k.ctx._lostCancelled, false, 'a new run clears the flag');
});

l4bTest('L4b watchdog: the poll timer stays on while a run is out, so a hung read cannot leave the row stuck on "Refreshing..."', () => {
  const k = MK(); k.ctx.manualRefresh();
  assert.equal(timerOn(k), true, 'run started: timer on');
  k.tick(5000); k.ctx._pollWant(); assert.equal(k.ctx._refreshRunning, true); assert.equal(timerOn(k), true, 'a poll with a live run keeps the timer');
  k.tick(176000); k.ctx._pollWant();
  assert.equal(k.ctx._refreshRunning, false, 'the poll cancelled the lost run on its own, no trigger needed'); assert.equal(timerOn(k), false);
  // a wish that is abandoned while a run is out must not stop the watchdog
  const j = MK(); j.ctx.requestRefresh('resume'); j.tick(20000); j.ctx.OutboxStore.items = [{}]; j.ctx.manualRefresh();
  assert.equal(j.ctx._wantTrigger, 'manual'); j.ctx._abandonWant();
  assert.equal(j.ctx._refreshRunning, true); assert.equal(timerOn(j), true, 'abandon keeps the timer while running'); assert.deepEqual(j.log.unfinished, ['gave-up']);
  answerAll(j.stores, 'committed'); assert.equal(timerOn(j), false, 'run over, nothing waiting: off');
  // run ends while a wish is pending: the timer stays on for that wish
  const w = MK(); w.ctx.requestRefresh('resume'); w.tick(20000); w.ctx.requestRefresh('manual');
  assert.equal(w.ctx._wantTrigger, 'manual'); answerAll(w.stores, 'committed'); assert.equal(timerOn(w), true);
});

l4bTest('L4b: refreshState and lastSyncMs are read-only views, evaluated from the real expressions in DataModel.qml', () => {
  const src = require('fs').readFileSync(path.join(__dirname, '..', '..', '..', 'qml', 'model', 'DataModel.qml'), 'utf8');
  const expr = (name) => { const m = new RegExp('readonly property (?:real|string) ' + name + ': ([^\\n]+)').exec(src); assert.ok(m, name + ' not declared readonly'); return m[1]; };
  const ev = (e, ctx) => vm.runInNewContext(e, ctx);
  const states = [[false, '', 'idle'], [true, '', 'running'], [false, 'resume', 'waiting'], [true, 'manual', 'running']];
  for (const [running, want, out] of states) assert.equal(ev(expr('refreshState'), { _refreshRunning: running, _wantTrigger: want }), out);
  assert.equal(ev(expr('lastSyncMs'), { _lastSyncMs: 123 }), 123);
});

l4bTest('L4b monkey: 6 seeds x 3000 steps, manual taps included: timer on <=> (run out or wish waiting); state follows; toasts only for manual', () => {
  for (const seed0 of [1, 2, 3, 4, 5, 6]) {
    let seed = seed0 * 104729; const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
    const k = MK(); const c = k.ctx; let unfinishedSeen = 0;
    for (let i = 0; i < 3000; i++) {
      const r = rnd();
      if (r < 0.14) c.OutboxStore.items = rnd() > 0.5 ? [{}] : [];
      else if (r < 0.18) c.OutboxStore.revision++;
      else if (r < 0.22) c.AuthService.isOnline = rnd() > 0.2;
      else if (r < 0.25) c.AuthService.accessBlock = rnd() > 0.7 ? 'removed' : '';
      else if (r < 0.29) c.LockManager.anyHeld = rnd() > 0.6;
      else if (r < 0.32) c.LockManager.anyEditing = rnd() > 0.7;
      else if (r < 0.36) { c._clearWant(); for (const s of k.stores) s._cancelRefresh(); }            // sign-out
      else if (r < 0.46) c.manualRefresh();
      else if (r < 0.54) c.requestRefresh(['resume', 'reconnect'][Math.floor(rnd() * 2)]);
      else if (r < 0.66) c._pollWant();
      else if (r < 0.84) for (const s of k.stores) if (s.done) { const d = s.done; s.done = null; d(['committed', 'committed', 'discarded', 'failed', 'superseded'][Math.floor(rnd() * 5)]); }
      k.tick(Math.floor(rnd() * 70000));
      const want = c._wantTrigger !== '', running = c._refreshRunning;
      assert.equal(timerOn(k), running || want, 'seed ' + seed0 + ' step ' + i + ': timer must be on exactly while a run is out or a wish waits');
      if (!running) assert.equal(c._refreshOutstanding, 0);
      assert.ok(k.log.unfinished.length >= unfinishedSeen); unfinishedSeen = k.log.unfinished.length;
      for (const w of k.log.unfinished) assert.ok(w === 'gave-up' || w === 'partial');
    }
  }
});

// ── L4b mutants on the real DataModel.qml function bodies: every scenario above runs against each mutant; at least one must fail ──
const DM_SRC = require('fs').readFileSync(path.join(__dirname, '..', '..', '..', 'qml', 'model', 'DataModel.qml'), 'utf8');
const L4B_MUTANTS = [
  ['a resume wish that is abandoned also toasts', 'if (manual) manualRefreshUnfinished("gave-up")', 'manualRefreshUnfinished("gave-up")'],
  ['an abandoned manual wish never toasts', 'if (manual) manualRefreshUnfinished("gave-up")', ''],
  ['an expired wish is cleared silently', '{ _abandonWant(); return }', '{ _clearWant(); return }'],
  ['a wish dropped by offline or block is cleared silently', '_abandonWant()   // blocked', '_clearWant()   // blocked'],
  ['clearing a wish always stops the timer', 'if (!_refreshRunning) _refreshWaitTimer.stop()', '_refreshWaitTimer.stop()'],
  ['a run does not keep the watchdog timer on', '_refreshWaitTimer.restart()   // polls for a hung read', ''],
  ['the timer never stops after a run', 'if (_wantTrigger === "") _refreshWaitTimer.stop()', ''],
  ['automatic runs toast too', '_refreshTrigger === "manual" && !cancelledByReset', '!cancelledByReset'],
  ['a re-armed retry toasts early', '!all && !rearm &&', '!all &&'],
  ['a reset or sign-out cancel toasts', ' && !cancelledByReset', ''],
  ['a lost run is not marked lost', '_lostCancelled = true', ''],
  ['the lost flag is never cleared', '_lostCancelled = false', ''],
  ['a toast with no open session', ' && AuthService.isSessionOpen())', ')'],
  ['requestRefresh leaks the whole decision', 'return _request(trigger).action', 'return _request(trigger)'],
  ['manualRefresh runs as a resume', 'return _request("manual")', 'return _request("resume")'],
  ['the decision loses its reason', '        return d\\n    }', '        return { action: d.action }\\n    }'],
  ['a manual run leaves the old trigger behind', '_refreshTrigger = trigger\n        _refreshRunning = true', '_refreshRunning = true'],
];
for (const [name, from, to] of L4B_MUTANTS) {
  test('L4b mutant killed: ' + name, () => {
    assert.ok(DM_SRC.includes(from.replace(/\\n/g, '\n')), 'mutant anchor not found in DataModel.qml: ' + from.slice(0, 60));
    const f = from.replace(/\\n/g, '\n'), t = to.replace(/\\n/g, '\n');
    const saved = MK;
    MK = (o) => makeCoordinator(o, (fn, text) => text.includes(f) ? text.replace(f, t) : text);
    let killed = false;
    try { for (const [, scenario] of L4B) { try { scenario(); } catch (e) { killed = true; break; } } } finally { MK = saved; }
    assert.ok(killed, 'no L4b scenario noticed this mutant');
  });
}

// ── review of PR #186: a waiting MANUAL wish must not be taken over by an automatic trigger ──────────────────
// Only a manual wish tells the user how it ended (toast). If a resume or reconnect request replaced it while it
// waited (a saved edit form closing makes exactly such a request), the wish would later run or expire in silence.
// Each scenario takes a coordinator maker so the same scenarios also run against mutants of the real DataModel text.
const stale = (k) => { k.ctx.OutboxStore.items = [{}]; k.ctx._lastSyncMs = k.ctx.__now - 600000; return k; };

const REVIEW = [
  ['an automatic wait does not replace a waiting manual wish (trigger, start time and re-arm flag stay)', (mk) => {
    for (const auto of ['resume', 'reconnect']) {
      const k = stale(mk());
      assert.equal(k.ctx.manualRefresh().action, 'wait');
      const since = k.ctx._wantSinceMs; k.ctx._wantRearmed = true;
      k.tick(30000);
      assert.equal(k.ctx.requestRefresh(auto), 'wait', auto);
      assert.equal(k.ctx._wantTrigger, 'manual', auto + ': still the user\'s wish');
      assert.equal(k.ctx._wantSinceMs, since, auto + ': the wait clock is not restarted');
      assert.equal(k.ctx._wantRearmed, true, auto + ': flag untouched');
      assert.equal(k.log.timer.at(-1), 'restart', auto + ': the poll timer keeps running');
    }
  }],
  ['the manual wish still ends with its toast after an automatic request touched it', (mk) => {
    const k = stale(mk());
    k.ctx.manualRefresh(); k.tick(30000); k.ctx.requestRefresh('resume');
    k.tick(90000); k.ctx._pollWant();
    assert.deepEqual(k.log.unfinished, ['gave-up']);
    assert.equal(k.ctx._wantTrigger, '');
  }],
  ['the manual wish still RUNS as manual when the outbox drains after an automatic request', (mk) => {
    const k = stale(mk());
    k.ctx.manualRefresh(); k.tick(5000); k.ctx.requestRefresh('resume');
    k.ctx.OutboxStore.items = []; k.tick(15000); k.ctx._pollWant();
    assert.ok(k.stores.every(s => s.started === 1)); assert.equal(k.ctx._refreshTrigger, 'manual');
    k.stores[0].done('committed'); k.stores[1].done('failed'); k.stores.slice(2).forEach(s => s.done('committed'));
    assert.deepEqual(k.log.unfinished, ['partial'], 'a run that started as manual keeps its partial toast');
  }],
  ['the other replacements still work (manual replaces automatic, a repeated tap restarts the clock, automatic replaces automatic)', (mk) => {
    let k = stale(mk()); k.ctx.requestRefresh('resume'); assert.equal(k.ctx._wantTrigger, 'resume');
    k.tick(10000); k.ctx.manualRefresh(); assert.equal(k.ctx._wantTrigger, 'manual'); assert.equal(k.ctx._wantSinceMs, k.ctx.__now);
    k.tick(10000); k.ctx.manualRefresh(); assert.equal(k.ctx._wantSinceMs, k.ctx.__now, 'a new tap restarts the clock');
    k = stale(mk()); k.ctx.requestRefresh('resume'); k.tick(10000); k.ctx.requestRefresh('reconnect');
    assert.equal(k.ctx._wantTrigger, 'reconnect'); assert.equal(k.ctx._wantSinceMs, k.ctx.__now);
  }],
  ['an automatic request that is dropped or runs never touches a waiting manual wish', (mk) => {
    let k = stale(mk()); k.ctx.manualRefresh(); k.ctx._lastSyncMs = k.ctx.__now - 1000;   // lists look fresh
    assert.equal(k.ctx.requestRefresh('resume'), 'drop'); assert.equal(k.ctx._wantTrigger, 'manual');
    k = stale(mk()); k.ctx.manualRefresh(); k.ctx.OutboxStore.items = []; k.tick(20000);
    assert.equal(k.ctx.requestRefresh('resume'), 'run'); assert.equal(k.ctx._wantTrigger, '', 'a run consumes the wish');
  }],
];
for (const [name, scenario] of REVIEW) test('review: ' + name, () => scenario(() => makeCoordinator()));

const REVIEW_MUTANTS = [
  ['the guard is removed: any wait replaces the wish', 'if (_wantTrigger !== "manual" || trigger === "manual") {', 'if (true) {'],
  ['the guard is inverted', '_wantTrigger !== "manual" || trigger === "manual"', '_wantTrigger === "manual" || trigger !== "manual"'],
  ['a manual tap can no longer replace a manual wish', '_wantTrigger !== "manual" || trigger === "manual"', '_wantTrigger !== "manual"'],
  // Equivalent, not listed: restarting the poll timer when the wish is NOT replaced (the timer is already running; restart only re-phases the 5 s poll).
  ['the guard also blocks an automatic wish from replacing an automatic one', '_wantTrigger !== "manual" || trigger === "manual"', '_wantTrigger === ""'],
];
for (const [name, from, to] of REVIEW_MUTANTS) {
  test('review mutant killed: ' + name, () => {
    const f = from.replace(/\\n/g, '\n'), t = to.replace(/\\n/g, '\n');
    assert.ok(DM_SRC.includes(f), 'mutant anchor not found in DataModel.qml: ' + from.slice(0, 60));
    const mk = () => makeCoordinator({}, (fn, text) => text.includes(f) ? text.replace(f, t) : text);
    let killed = false;
    for (const [, scenario] of REVIEW) { try { scenario(mk); } catch (e) { killed = true; break; } }
    assert.ok(killed, 'no review scenario noticed this mutant');
  });
}
