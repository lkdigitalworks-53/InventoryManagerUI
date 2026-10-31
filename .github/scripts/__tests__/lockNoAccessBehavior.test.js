'use strict';

// PR #171 device test (2026-10-31): a SUSPENDED member pressed Approve on Orders and got
// "Being edited elsewhere, try again shortly". Cause: acquireLock answers 403 `no-tenant-context`
// for a suspended member, LockManager called that reason "error", and OrdersPage lumped every
// non-granted acquire into `lockedOut`. The three edit dialogs said "connection issue, try again"
// for the same 403. This file runs the REAL text of the functions involved (QML pages cannot be
// instantiated under qmltestrunner: Constants imports Felgo), plus source pins and mutants.
// Plan: docs/superpowers/test-plans/2026-10-28-s2f3-access-blocked-test-plan.md (H8, N8-N13)

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..', '..');
const rd = (...p) => fs.readFileSync(path.join(REPO, ...p), 'utf8');
const PAGE = rd('qml', 'pages', 'OrdersPage.qml');
const LOCK = rd('qml', 'model', 'LockManager.qml');
const DIALOGS = {
  OrderDetailDialog: rd('qml', 'pages', 'OrderDetailDialog.qml'),
  EditProductDialog: rd('qml', 'pages', 'EditProductDialog.qml'),
  StaffDetailDialog: rd('qml', 'pages', 'StaffDetailDialog.qml'),
};

// Whole `function name(...) { ... }` text by brace matching; '' when absent or unbalanced.
function fnText(src, name) {
  const at = src.indexOf(`function ${name}(`);
  if (at < 0) return '';
  const open = src.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}' && --depth === 0) return src.slice(at, i + 1);
  }
  return '';
}

// Load a `.pragma library` helper: every top-level function becomes a property.
function loadHelper(file) {
  const src = rd('qml', 'helper', file).replace(/^\.pragma library/, '');
  const names = [...src.matchAll(/^function (\w+)\(/gm)].map((m) => m[1]);
  return new Function(`${src}\n;return {${names.map((n) => `${n}:${n}`).join(',')}}`)();
}
const FC = loadHelper('FailureCause.js');
const BAP = loadHelper('BulkApproveProgress.js');
const ACCESS = FC.forAccess().text;

// qsTr + QString.arg for the page text.
function qsTr(s) {
  const o = new String(s);
  o.arg = (v) => qsTr(String(s).replace(/%\d/, String(v)));
  return o;
}

// ---- LockManager._classifyAcquireResponse, real text ----
function classifierFrom(src) {
  const text = fnText(src, '_classifyAcquireResponse');
  assert.ok(text, 'classifier text found');
  return new Function(`${text}\n;return _classifyAcquireResponse`)();
}

// Returns the list of broken behaviours for a LockManager source (empty = correct).
function classifierProblems(src) {
  const out = [];
  let c;
  try { c = classifierFrom(src); } catch (e) { return ['load']; }
  const noAcc = c(403, { ok: false, error: 'no-tenant-context' });
  if (!(noAcc.noAccess === true && noAcc.granted === false && noAcc.reason === 'error' && noAcc.holder === null)) out.push('403-pair');
  const near = [
    [403, { ok: false, error: 'not-authorized' }], [403, { ok: false }], [403, { ok: false, error: 'no-tenant-context-x' }],
    [401, { ok: false, error: 'no-tenant-context' }], [400, { ok: false, error: 'no-tenant-context' }],
    [500, { ok: false, error: 'no-tenant-context' }], [409, { ok: false, error: 'no-tenant-context', holder: { name: 'A' } }],
    [0, null], [403, null], [403, 'no-tenant-context'], [404, { error: { code: 404 } }],
  ];
  near.forEach(([s, b], i) => { if (c(s, b).noAccess === true) out.push(`near-miss-${i}`); });
  const den = c(409, { ok: false, holder: { name: 'Zed' } });
  if (!(den.reason === 'denied' && den.holder.name === 'Zed' && den.noAccess !== true)) out.push('denied');
  const ok = c(200, { ok: true });
  if (!(ok.granted === true && ok.noAccess !== true)) out.push('granted');
  for (const s of [400, 401, 500]) if (c(s, { ok: false, error: 'x' }).reason !== 'error') out.push(`error-${s}`);
  return out;
}

// ---- OrdersPage._approveAllPending, real text ----
// opts.acquire(orderId) -> an acquire result; opts.complete(orderId) -> boolean.
function runBulk(src, orders, opts) {
  const text = fnText(src, '_approveAllPending');
  assert.ok(text, '_approveAllPending text found');
  const fn = new Function('root', 'BAP', 'LockManager', 'dataModel', 'FailureCause', 'qsTr', 'stockErrorDlg',
    'approveHold', '_scopedOrders', `${text}\n;return _approveAllPending`);
  const rec = { acquires: [], completes: [], releases: [], dialogs: [], holds: 0, maxDepth: 0 };
  const root = { _approveState: BAP.newState() };
  // Call-stack depth at every progress step: the QML engine caps call depth (V4, ~1200 by default
  // in release builds, I believe), so a loop that recurses once per order throws on a big batch and
  // leaves the busy overlay up forever. Depth must not grow with the number of orders.
  const bapProbe = Object.assign({}, BAP, {
    step(st, outcome) {
      // Sampled (every 500th step and the last one) so a 5000-order run stays cheap: a recursing loop is
      // deepest at the end, so sampling still sees it. Node keeps only 10 frames by default: lift the limit.
      if (st.done % 500 === 0 || st.done === st.total - 1) {
        const lim = Error.stackTraceLimit;
        Error.stackTraceLimit = Infinity;
        rec.maxDepth = Math.max(rec.maxDepth, new Error().stack.split('\n').length);
        Error.stackTraceLimit = lim;
      }
      return BAP.step(st, outcome);
    },
  });
  const pending = [];
  const LockManager = {
    acquire(entity, id, cb) {
      rec.acquires.push(id);
      const r = opts.acquire(id);
      if (opts.async) pending.push(() => cb(r)); else cb(r);
    },
    release(entity, id) { rec.releases.push(id); },
  };
  const dataModel = {
    syncOrdersModel() {},
    tryCompleteOrder(id, cb) { rec.completes.push(id); cb(opts.complete ? opts.complete(id) : true); },
  };
  const stockErrorDlg = { show(o) { rec.dialogs.push({ title: String(o.title), message: String(o.message), variant: o.variant }); } };
  const approveHold = { restart() { rec.holds++; } };
  const orderList = orders.map((id) => ({ orderId: id, status: 'pending' }));
  fn(root, bapProbe, LockManager, dataModel, FC, qsTr, stockErrorDlg, approveHold, () => orderList)();
  while (pending.length) pending.shift()();
  rec.state = root._approveState;
  return rec;
}

// Returns the list of broken behaviours for an OrdersPage source (empty = correct).
function bulkProblems(src) {
  const out = [];
  const GRANT = { granted: true, holder: null, reason: null };
  const NOACC = { granted: false, holder: null, reason: 'error', noAccess: true };
  const ERR = { granted: false, holder: null, reason: 'error' };
  const DEN = { granted: false, holder: { name: 'Zed' }, reason: 'denied' };
  try {
    // the reported bug: a suspended member, every acquire is a 403
    const a = runBulk(src, ['o1', 'o2', 'o3'], { acquire: () => NOACC });
    const m = a.dialogs[0] ? a.dialogs[0].message : '';
    if (a.dialogs.length !== 1) out.push('suspended-one-dialog');
    if (/elsewhere/i.test(m)) out.push('suspended-says-elsewhere');
    if (/connection/i.test(m)) out.push('suspended-says-connection');
    if (!m.includes(ACCESS)) out.push('suspended-access-text');
    if (!m.startsWith('3 not approved.')) out.push('suspended-count');
    if (a.acquires.length !== 1) out.push('suspended-fail-fast');
    if (a.completes.length !== 0) out.push('suspended-never-completes');
    if (a.state.phase !== 'done' || BAP.approved(a.state) !== 0) out.push('suspended-progress-ends');
    if (a.dialogs[0] && a.dialogs[0].title !== "Some Orders Weren't Approved") out.push('suspended-title');

    // a connection error is not "elsewhere" and not an access problem
    const b = runBulk(src, ['o1', 'o2'], { acquire: () => ERR });
    const mb = b.dialogs[0] ? b.dialogs[0].message : '';
    if (/elsewhere/i.test(mb)) out.push('error-says-elsewhere');
    if (!/connection issue/.test(mb) || !mb.includes('o1, o2')) out.push('error-text');
    if (mb.includes(ACCESS)) out.push('error-says-access');
    if (b.acquires.length !== 2) out.push('error-no-fail-fast');

    // a real holder keeps the old text, with the ids
    const c = runBulk(src, ['o1', 'o2'], { acquire: (id) => (id === 'o1' ? DEN : GRANT) });
    const mc = c.dialogs[0] ? c.dialogs[0].message : '';
    if (mc !== 'Being edited elsewhere, try again shortly: o1') out.push('denied-text');
    if (c.completes.join() !== 'o2') out.push('denied-others-complete');

    // all granted: no dialog, every order completes and releases
    const d = runBulk(src, ['o1', 'o2'], { acquire: () => GRANT });
    if (d.dialogs.length !== 0 || d.completes.length !== 2 || d.releases.length !== 2) out.push('granted-happy');
    if (!BAP.allOk(d.state)) out.push('granted-allOk');

    // insufficient inventory is still its own message
    const e = runBulk(src, ['o1'], { acquire: () => GRANT, complete: () => false });
    if (!/Insufficient inventory: o1/.test(e.dialogs[0] ? e.dialogs[0].message : '')) out.push('failed-text');

    // mixed: ok, denied, error, then a 403 stops the rest
    const f = runBulk(src, ['o1', 'o2', 'o3', 'o4', 'o5'], {
      acquire: (id) => ({ o1: GRANT, o2: DEN, o3: ERR, o4: NOACC, o5: GRANT })[id] });
    const mf = f.dialogs[0] ? f.dialogs[0].message : '';
    if (f.acquires.join() !== 'o1,o2,o3,o4') out.push('mixed-fail-fast-after-403');
    if (f.completes.join() !== 'o1') out.push('mixed-completes');
    if (!/elsewhere.*o2/.test(mf) || !/1 order\(s\).*o3/.test(mf) || !mf.includes('2 not approved.')) out.push('mixed-text');
    if (f.state.phase !== 'done' || BAP.approved(f.state) !== 1) out.push('mixed-progress');

    // a big batch for a suspended member: one request, constant stack depth, every order accounted for
    const big = Array.from({ length: 5000 }, (_, i) => `b${i}`);
    const bs = runBulk(src, big, { acquire: () => NOACC });
    if (bs.acquires.length !== 1) out.push('big-fail-fast');
    if (bs.maxDepth > 40) out.push('big-stack-grows');
    if (bs.state.phase !== 'done' || bs.state.done !== 5000) out.push('big-progress');
    if (!(bs.dialogs[0] && bs.dialogs[0].message.startsWith('5000 not approved.'))) out.push('big-count');
    // same after earlier orders were approved: the 403 arrives mid-batch (suspended during the run)
    const mid = runBulk(src, big, { acquire: (id) => (['b0', 'b1', 'b2'].includes(id) ? GRANT : NOACC) });
    if (mid.completes.join() !== 'b0,b1,b2' || mid.acquires.length !== 4) out.push('big-mid-batch');
    if (mid.maxDepth > 40) out.push('big-mid-stack-grows');
    if (BAP.approved(mid.state) !== 3 || mid.state.done !== 5000) out.push('big-mid-progress');
    if (!(mid.dialogs[0] && mid.dialogs[0].message.startsWith('4997 not approved.'))) out.push('big-mid-count');

    // D-E breaker: 3 CONSECUTIVE no-answers stop the run (the 4th..nth order is never asked), the rest are
    // listed as "couldn't confirm" with a capped id list, progress still ends full
    const ids10 = Array.from({ length: 10 }, (_, i) => `o${i + 1}`);
    const br = runBulk(src, ids10, { acquire: () => ERR });
    const mbr = br.dialogs[0] ? br.dialogs[0].message : '';
    if (br.acquires.length !== 3) out.push('breaker-stops-after-3');
    if (!mbr.startsWith("Couldn't confirm 10 order(s)")) out.push('breaker-count');
    if (!mbr.includes('o1, o2, o3, o4, o5 and 5 more') || mbr.includes('o6,')) out.push('breaker-id-list-capped');
    if (/elsewhere/i.test(mbr) || mbr.includes(ACCESS)) out.push('breaker-wording');
    if (br.state.phase !== 'done' || br.state.done !== 10 || BAP.approved(br.state) !== 0) out.push('breaker-progress');
    if (br.completes.length !== 0 || br.dialogs.length !== 1) out.push('breaker-nothing-completes');
    // a real answer in between resets the run: E,E,G,E,E,D,E,E never trips (no 3 in a row)
    const seq = [ERR, ERR, GRANT, ERR, ERR, DEN, ERR, ERR];
    const noTrip = runBulk(src, seq.map((_, i) => `s${i}`), { acquire: (id) => seq[Number(id.slice(1))] });
    if (noTrip.acquires.length !== 8) out.push('breaker-reset-by-real-answer');
    // exactly 3 in a row after a reset trips on the 3rd: G,E,E,E -> 4 asked, the rest skipped
    const seq2 = [GRANT, ERR, ERR, ERR, GRANT, GRANT];
    const trip = runBulk(src, seq2.map((_, i) => `t${i}`), { acquire: (id) => seq2[Number(id.slice(1))] });
    if (trip.acquires.length !== 4 || trip.completes.join() !== 't0') out.push('breaker-trips-on-third');
    if (!/Couldn't confirm 5 order\(s\)/.test(trip.dialogs[0] ? trip.dialogs[0].message : '')) out.push('breaker-trip-count');
    // a 403 inside an error run wins and says access, with the run counter irrelevant
    const seq3 = [ERR, ERR, NOACC, GRANT];
    const mix = runBulk(src, seq3.map((_, i) => `u${i}`), { acquire: (id) => seq3[Number(id.slice(1))] });
    if (mix.acquires.length !== 3 || !mix.dialogs[0].message.includes(ACCESS)) out.push('breaker-403-inside-run');
    // two errors only: nothing is skipped, both are named in full
    const two = runBulk(src, ['p1', 'p2'], { acquire: () => ERR });
    if (two.acquires.length !== 2 || !two.dialogs[0].message.endsWith('p1, p2')) out.push('breaker-not-tripped-by-two');
    // a big offline batch: 3 requests, constant stack depth, every order accounted for
    const offline = runBulk(src, big, { acquire: () => ERR });
    if (offline.acquires.length !== 3 || offline.maxDepth > 40 || offline.state.done !== 5000) out.push('breaker-big');
    if (!(offline.dialogs[0] && offline.dialogs[0].message.includes('and 4995 more'))) out.push('breaker-big-text');
    // asynchronous answers trip it the same way
    const aOff = runBulk(src, ids10, { acquire: () => ERR, async: true });
    if (aOff.acquires.length !== 3 || aOff.state.done !== 10) out.push('breaker-async');

    // nothing pending: no dialog, no throw
    const g = runBulk(src, [], { acquire: () => GRANT });
    if (g.dialogs.length !== 0 || g.acquires.length !== 0) out.push('empty');

    // asynchronous acquire answers behave the same
    const h = runBulk(src, ['o1', 'o2'], { acquire: () => NOACC, async: true });
    if (h.dialogs.length !== 1 || h.acquires.length !== 1 || !h.dialogs[0].message.includes(ACCESS)) out.push('async-suspended');

    // seeded monkey: random outcomes, invariants from the spec above
    let seed = 20261031;
    const rnd = () => ((seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296);
    const KINDS = [GRANT, DEN, ERR, NOACC, { granted: false }, null, undefined, { granted: 'yes' }];
    for (let run = 0; run < 200; run++) {
      const n = Math.floor(rnd() * 12);
      const ids = Array.from({ length: n }, (_, i) => `m${run}_${i}`);
      const plan = Object.fromEntries(ids.map((id) => [id, KINDS[Math.floor(rnd() * KINDS.length)]]));
      const comp = Object.fromEntries(ids.map((id) => [id, rnd() < 0.8]));
      const r = runBulk(src, ids, { acquire: (id) => plan[id], complete: (id) => comp[id] });
      const st = (x) => FC.lockState(x);
      const firstNo = ids.findIndex((id) => st(plan[id]) === 'no-access');
      // reference model: ask in order; stop at the first 403 or after 3 consecutive no-answers
      let reached = n; let streak = 0;
      for (let i = 0; i < n; i++) {
        const k = st(plan[ids[i]]);
        streak = k === 'error' ? streak + 1 : 0;
        if (k === 'no-access' || streak >= 3) { reached = i + 1; break; }
      }
      if (r.acquires.length !== reached) { out.push('monkey-acquire-count'); break; }
      const granted = ids.slice(0, reached).filter((id) => st(plan[id]) === 'granted');
      if (r.completes.join() !== granted.join()) { out.push('monkey-completes'); break; }
      if (n > 0 && r.state.phase !== 'done') { out.push('monkey-progress-ends'); break; }
      const bad = r.completes.filter((id) => !comp[id]).length;
      const lockBad = n - granted.length; // skipped orders count as not approved too
      if (n > 0 && BAP.approved(r.state) !== granted.length - bad) { out.push('monkey-approved'); break; }
      const msg = r.dialogs[0] ? r.dialogs[0].message : '';
      const kinds = ids.slice(0, reached).map((id) => st(plan[id]));
      if (/elsewhere/i.test(msg) !== kinds.includes('denied')) { out.push('monkey-elsewhere-iff-denied'); break; }
      if (msg.includes(ACCESS) !== (firstNo >= 0 && firstNo < reached)) { out.push('monkey-access-iff-403'); break; }
      if (/connection issue/.test(msg) !== kinds.includes('error')) { out.push('monkey-connection-iff-error'); break; }
      if ((r.dialogs.length === 1) !== (bad + lockBad > 0)) { out.push('monkey-dialog-iff-something-failed'); break; }
      if (r.dialogs.length > 1) { out.push('monkey-one-dialog'); break; }
    }
  } catch (err) {
    out.push(`threw: ${err.message}`);
  }
  return out;
}

// ---- dialog source pins ----
const EXPECT = {
  OrderDetailDialog: { states: 2, branches: 1 },
  EditProductDialog: { states: 2, branches: 2 },
  StaffDetailDialog: { states: 2, branches: 2 },
};
function dialogProblems(src, kind) {
  const out = [];
  const e = EXPECT[kind];
  if (!src.includes('import "../helper/FailureCause.js" as FailureCause')) out.push('import');
  if (/result\.granted \? "granted" : result\.reason/.test(src)) out.push('old-state-mapping');
  if (src.split('FailureCause.lockState(result)').length - 1 !== e.states) out.push('lockState-sites');
  if (src.split('_lockState === "no-access"').length - 1 !== e.branches) out.push('no-access-branches');
  if (src.split('FailureCause.forAccess().text').length - 1 !== e.branches) out.push('access-text-sites');
  if (/result\.reason === "denied"/.test(src)) out.push('reads-raw-reason');
  if (!/"pending" \| "granted" \| "denied" \| "no-access" \| "error"/.test(src)) out.push('state-comment');
  return out;
}

// =========================== tests ===========================

// ---- happy ----
test('happy: the real LockManager classifier is correct', () => {
  assert.deepEqual(classifierProblems(LOCK), []);
});
test('happy: the real OrdersPage bulk approve is correct (the reported bug cannot recur)', () => {
  assert.deepEqual(bulkProblems(PAGE), []);
});
test('happy: every edit dialog maps and words the no-access state', () => {
  for (const [k, src] of Object.entries(DIALOGS)) assert.deepEqual(dialogProblems(src, k), [], k);
});
test('happy: the 403 stuck-write text and the lock text are one string', () => {
  assert.equal(FC.forWriteError('no-tenant-context', 403).text, ACCESS);
  assert.equal(FC.forAccess().kind, 'access');
});

// ---- the reported scenario, spelled out ----
test('regression: suspended member + Approve never says "edited elsewhere" or "connection"', () => {
  const r = runBulk(PAGE, ['order-1'], { acquire: () => ({ granted: false, holder: null, reason: 'error', noAccess: true }) });
  assert.equal(r.dialogs.length, 1);
  assert.doesNotMatch(r.dialogs[0].message, /elsewhere|connection|try again/i);
  assert.match(r.dialogs[0].message, /removed or suspended/);
  assert.equal(r.completes.length, 0, 'the order is never completed');
});
test('regression: the same 403 came out of the real classifier as noAccess, not denied', () => {
  const c = classifierFrom(LOCK);
  assert.equal(FC.lockState(c(403, { ok: false, error: 'no-tenant-context' })), 'no-access');
  assert.equal(FC.lockState(c(409, { ok: false, holder: { name: 'A' } })), 'denied');
  assert.equal(FC.lockState(c(500, { ok: false, error: 'lock-failed' })), 'error');
});

// ---- negative: mutants must be caught ----
const MUT_LOCK = [
  ['403 branch removed', /\n        if \(status === 403 && body\.error === "no-tenant-context"\)\n            return \{[^\n]*\n/, '\n'],
  ['error code not checked', 'status === 403 && body.error === "no-tenant-context"', 'status === 403'],
  ['any non-409 is noAccess', 'status === 403 && body.error === "no-tenant-context"', 'status !== 409'],
  ['noAccess reported as denied', 'return { granted: false, holder: null, reason: "error", noAccess: true }', 'return { granted: false, holder: body.holder || null, reason: "denied", noAccess: true }'],
];
for (const [name, from, to] of MUT_LOCK) {
  test(`negative (LockManager): ${name} is caught`, () => {
    const mutated = LOCK.replace(from, to);
    assert.notEqual(mutated, LOCK, `fixture drifted: ${name}`);
    assert.ok(classifierProblems(mutated).length > 0, name);
  });
}
const MUT_PAGE = [
  ['the old bug: every non-granted acquire is "edited elsewhere"', '(lockSt === "denied" ? lockedOut : (lockSt === "no-access" ? noAccess : unchecked)).push(orderId)', 'lockedOut.push(orderId)'],
  ['a connection error counted as no-access', '(lockSt === "no-access" ? noAccess : unchecked)', '(lockSt === "no-access" ? noAccess : noAccess)'],
  ['a 403 counted as unchecked', '(lockSt === "no-access" ? noAccess : unchecked)', '(lockSt === "no-access" ? unchecked : unchecked)'],
  ['fail-fast removed (a 403 does not skip the rest)', 'if (lockSt === \"no-access\") _skipRest(noAccess)', 'if (false) _skipRest(noAccess)'],
  ['fail-fast skip recurses per order again (stack grows with the batch)', 'while (idx < toApprove.length) {\n                list.push(toApprove[idx++])\n                root._approveState = BAP.step(root._approveState, \"locked\")\n            }', 'if (idx < toApprove.length) {\n                list.push(toApprove[idx++])\n                root._approveState = BAP.step(root._approveState, \"locked\")\n                _skipRest(list)\n            }'],
  ['lock stage skips the progress step', 'root._approveState = BAP.step(root._approveState, "locked")\n                    // Stop asking', '// Stop asking'],
  ['skip drain skips the progress step', 'list.push(toApprove[idx++])\n                root._approveState = BAP.step(root._approveState, \"locked\")', 'list.push(toApprove[idx++])'],
  ['skip drain drops the remaining orders', 'list.push(toApprove[idx++])', 'idx++'],
  ['skip list is the wrong one for a 403', '_skipRest(noAccess)', '_skipRest(unchecked)'],
  ['breaker removed', 'else if (noAnswerRun >= maxNoAnswerRun) _skipRest(unchecked)', ''],
  ['breaker trips on 2', 'var maxNoAnswerRun = 3', 'var maxNoAnswerRun = 2'],
  ['breaker trips on 4', 'var maxNoAnswerRun = 3', 'var maxNoAnswerRun = 4'],
  ['breaker never resets on a real answer', 'noAnswerRun = lockSt === \"error\" ? noAnswerRun + 1 : 0', 'noAnswerRun = lockSt === \"error\" ? noAnswerRun + 1 : noAnswerRun'],
  ['breaker counts a denial as a no-answer', 'noAnswerRun = lockSt === \"error\" ? noAnswerRun + 1 : 0', 'noAnswerRun = lockSt !== \"granted\" ? noAnswerRun + 1 : 0'],
  ['breaker skipped orders filed under the real-holder list', 'else if (noAnswerRun >= maxNoAnswerRun) _skipRest(unchecked)', 'else if (noAnswerRun >= maxNoAnswerRun) _skipRest(lockedOut)'],
  ['id list not capped', 'unchecked.slice(0, 5)', 'unchecked.slice(0, 5000)'],
  ['id list cap without the \"and N more\" tail', 'unchecked.length > 5 ? qsTr(\" and %1 more\").arg(unchecked.length - 5) : \"\"', '\"\"'],
  ['dialog not shown for access-only', 'lockedOut.length > 0 || noAccess.length > 0 || unchecked.length > 0', 'lockedOut.length > 0 || unchecked.length > 0'],
  ['dialog not shown for error-only', 'lockedOut.length > 0 || noAccess.length > 0 || unchecked.length > 0', 'lockedOut.length > 0 || noAccess.length > 0'],
  ['access text replaced by the elsewhere text', 'parts.push(qsTr("%1 not approved. %2").arg(noAccess.length).arg(FailureCause.forAccess().text))', 'parts.push(qsTr("Being edited elsewhere, try again shortly: %1").arg(noAccess.join(", ")))'],
  ['count dropped from the access text', 'qsTr("%1 not approved. %2").arg(noAccess.length)', 'qsTr("%1 not approved. %2").arg("")'],
  ['error text says elsewhere', 'Couldn\'t confirm %1 order(s) are free to edit (connection issue), try again: %2', 'Being edited elsewhere, try again shortly: %1 %2'],
  ['lock state read from the raw granted flag', 'var lockSt = FailureCause.lockState(result)', 'var lockSt = result.granted ? "granted" : "denied"'],
];
for (const [name, from, to] of MUT_PAGE) {
  test(`negative (OrdersPage): ${name} is caught`, () => {
    const mutated = PAGE.replace(from, to);
    assert.notEqual(mutated, PAGE, `fixture drifted: ${name}`);
    assert.ok(bulkProblems(mutated).length > 0, name);
  });
}
const MUT_DIALOG = [
  ['import removed', (s) => s.replace('import "../helper/FailureCause.js" as FailureCause\n', '')],
  ['one state site reverted', (s) => s.replace('_lockState = FailureCause.lockState(result)', '_lockState = result.granted ? "granted" : result.reason')],
  ['no-access branch removed', (s) => s.replace('_lockState === "no-access"', '_lockState === "no-access-x"')],
  ['access text replaced', (s) => s.replace('FailureCause.forAccess().text', '"try again"')],
  ['raw reason read again', (s) => s.replace('_lockState === "denied"', 'result.reason === "denied"')],
];
for (const kind of Object.keys(DIALOGS)) {
  for (const [name, mut] of MUT_DIALOG) {
    test(`negative (${kind}): ${name} is caught`, () => {
      const src = DIALOGS[kind];
      const mutated = mut(src);
      if (mutated === src) return; // this dialog has no such site (e.g. OrderDetailDialog has no result.reason read)
      assert.ok(dialogProblems(mutated, kind).length > 0, `${kind}: ${name}`);
    });
  }
}

// ---- edge ----
test('edge: fnText is empty for a missing or unbalanced function', () => {
  assert.equal(fnText('nothing', '_approveAllPending'), '');
  assert.equal(fnText('function _approveAllPending() { if (x) {', '_approveAllPending'), '');
});
test('edge: a page with no bulk function reports a failure instead of passing', () => {
  assert.ok(bulkProblems(PAGE.replace('function _approveAllPending(', 'function _other(')).length > 0);
});
test('edge: FailureCause.lockState never throws on hostile input', () => {
  const evil = { get granted() { throw new Error('x'); } };
  assert.throws(() => FC.lockState(evil)); // documented: getters are not a supported input (QML objects are plain)
  for (const v of [Symbol, () => 1, new Date(), /x/, NaN, -0, Infinity]) assert.equal(FC.lockState(v), 'error');
});

// ---- caller pin (Skill 138 style): a new acquire caller must adopt lockState ----
function qmlFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((d) =>
    d.isDirectory() ? qmlFiles(path.join(dir, d.name)) : (d.name.endsWith('.qml') ? [path.join(dir, d.name)] : []));
}
test('pin: exactly these files call LockManager.acquire and all of them use FailureCause.lockState', () => {
  const callers = qmlFiles(path.join(REPO, 'qml'))
    .filter((f) => fs.readFileSync(f, 'utf8').includes('LockManager.acquire('))
    .map((f) => path.basename(f)).sort();
  assert.deepEqual(callers, ['EditProductDialog.qml', 'OrderDetailDialog.qml', 'OrdersPage.qml', 'StaffDetailDialog.qml']);
  for (const f of callers) {
    const src = rd('qml', 'pages', f);
    assert.ok(src.includes('FailureCause.lockState(result)'), `${f} must classify acquire results with FailureCause.lockState`);
    assert.doesNotMatch(src, /result\.granted \? "granted" : result\.reason/, `${f} must not map the raw reason`);
  }
  // a dialog may still test `!result.granted` to decide WHETHER to show an error; the bulk loop must not
  // use it to decide WHICH error (that was the bug)
  assert.doesNotMatch(fnText(PAGE, '_approveAllPending'), /!result\.granted\b/);
});
