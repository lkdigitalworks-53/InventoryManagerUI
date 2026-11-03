'use strict';

// L4a: unit tests for the pure helper qml/helper/RefreshPolicy.js (when a non-blanking refresh may start, when
// its result may replace the lists, how long a waiting refresh lives). The same contract runs under
// qmltestrunner in tests/tst_RefreshPolicy.qml (CI only); this file runs here. Hand mutants at the bottom prove
// the battery bites. Design: docs/superpowers/specs/2026-11-02-l4a-resume-refresh-design.md (L4-D1..D8).

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '..', '..', '..');
const SRC = fs.readFileSync(path.join(REPO, 'qml/helper/RefreshPolicy.js'), 'utf8');

function load(src) {
  const ctx = vm.createContext({});
  vm.runInContext(src.replace(/^\.pragma library/m, '') +
    '\n;this.__x = { STALE_MS, SPACING_MS, WANT_TTL_MS, POLL_MS, RUN_TTL_MS, runLost, decide, swapOk, wantExpired, allCommitted, hardBlock, softBlock }', ctx);
  return ctx.__x;
}

const QUIET = () => ({ online: true, sessionOpen: true, accessBlock: '', checking: false, refreshing: false,
  storeBusy: false, outboxPending: 0, outboxRevision: 7, gatewayInFlight: 0, lockHeld: false, editOpen: false, photoPending: 0 });
const with_ = (o) => Object.assign(QUIET(), o);
const JUNK = [undefined, null, NaN, Infinity, -Infinity, '', 'x', '1', true, false, {}, [], () => 1, -1];
const NOW = 1_700_000_000_000;

// Every assertion of the contract, collected (not thrown) so a mutant can be asked "does the battery notice?".
function battery(m) {
  const bad = [];
  const eq = (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) bad.push(name + ': got ' + JSON.stringify(got) + ' want ' + JSON.stringify(want)); };
  const act = (t, snap, now, sync, start) => m.decide(t, snap, now, sync, start).action;
  const why = (t, snap, now, sync, start) => m.decide(t, snap, now, sync, start).reason;

  // constants keep their meaning
  eq('STALE', m.STALE_MS, 300000); eq('SPACING', m.SPACING_MS, 15000); eq('TTL', m.WANT_TTL_MS, 120000); eq('POLL', m.POLL_MS, 5000); eq('RUN_TTL', m.RUN_TTL_MS, 180000);
  eq('run fresh', m.runLost(NOW, NOW + 179999), false); eq('run edge', m.runLost(NOW, NOW + 180000), true);
  eq('run backwards', m.runLost(NOW, NOW - 1), true);
  for (const j of JUNK) if (typeof j !== 'number' || !isFinite(j)) { eq('run junk start', m.runLost(j, NOW), true); eq('run junk now', m.runLost(NOW, j), true); }

  // a quiet, stale session runs, for every trigger
  for (const t of ['resume', 'reconnect', 'manual']) eq('run ' + t, act(t, QUIET(), NOW, NOW - 400000, 0), 'run');
  eq('never synced runs', act('resume', QUIET(), NOW, 0, 0), 'run');
  eq('unknown sync runs', act('resume', QUIET(), NOW, undefined, undefined), 'run');
  eq('unreadable clock runs', act('resume', QUIET(), NaN, NOW, NOW), 'run');

  // bad triggers
  for (const t of [undefined, null, '', 'x', 'RESUME', 1, {}]) eq('bad trigger', act(t, QUIET(), NOW, 0, 0), 'drop');

  // staleness: resume/reconnect drop when fresh, manual never does
  eq('fresh resume', why('resume', QUIET(), NOW, NOW - 299999, 0), 'fresh');
  eq('stale edge resume', act('resume', QUIET(), NOW, NOW - 300000, 0), 'run');
  eq('fresh reconnect', act('reconnect', QUIET(), NOW, NOW - 1000, 0), 'drop');
  eq('fresh manual runs', act('manual', QUIET(), NOW, NOW - 1000, 0), 'run');
  eq('clock backwards counts as stale', act('resume', QUIET(), NOW, NOW + 5000, 0), 'run');

  // spacing: any trigger, manual included
  eq('too-soon', why('manual', QUIET(), NOW, 0, NOW - 14999), 'too-soon');
  eq('spacing edge', act('manual', QUIET(), NOW, 0, NOW - 15000), 'run');
  eq('spacing backwards clock', act('manual', QUIET(), NOW, 0, NOW + 9000), 'run');

  // hard blockers drop, whatever else is going on
  eq('offline', why('resume', with_({ online: false }), NOW, 0, 0), 'offline');
  eq('no session', why('resume', with_({ sessionOpen: false }), NOW, 0, 0), 'no-session');
  for (const b of ['removed', 'suspended', 'role', 'unverified', 'moved']) eq('block ' + b, why('manual', with_({ accessBlock: b }), NOW, 0, 0), 'blocked');
  eq('hard beats soft', act('resume', with_({ online: false, outboxPending: 3 }), NOW, 0, 0), 'drop');
  eq('null snap', why('resume', null, NOW, 0, 0), 'no-state');
  eq('string snap', act('resume', 'x', NOW, 0, 0), 'drop');

  // soft blockers wait, one reason each, in the documented order
  const soft = [['checking', { checking: true }], ['refreshing', { refreshing: true }], ['store-loading', { storeBusy: true }],
    ['outbox', { outboxPending: 1 }], ['in-flight', { gatewayInFlight: 2 }], ['lock', { lockHeld: true }], ['edit-dialog', { editOpen: true }], ['photos', { photoPending: 1 }]];
  for (const [r, o] of soft) { eq('wait ' + r, why('resume', with_(o), NOW, 0, 0), r); eq('wait act ' + r, act('manual', with_(o), NOW, 0, 0), 'wait'); }
  eq('order checking first', why('resume', with_({ checking: true, outboxPending: 5, lockHeld: true }), NOW, 0, 0), 'checking');
  eq('order lock before edit-dialog', why('resume', with_({ lockHeld: true, editOpen: true }), NOW, 0, 0), 'lock');
  eq('order edit-dialog before photos', why('resume', with_({ editOpen: true, photoPending: 3 }), NOW, 0, 0), 'edit-dialog');
  eq('edit dialog alone waits for every trigger', ['resume', 'reconnect', 'manual'].map(x => act(x, with_({ editOpen: true }), NOW, 0, 0)).join(), 'wait,wait,wait');
  eq('order outbox before lock', why('resume', with_({ outboxPending: 5, lockHeld: true }), NOW, 0, 0), 'outbox');
  // fresh/too-soon drop BEFORE a soft wait (nothing to wait for)
  eq('fresh beats wait', act('resume', with_({ outboxPending: 2 }), NOW, NOW - 1000, 0), 'drop');
  eq('too-soon beats wait', why('manual', with_({ outboxPending: 2 }), NOW, 0, NOW - 100), 'too-soon');

  // junk in any snapshot field never runs (fails closed), never throws
  for (const k of ['online', 'sessionOpen']) for (const j of JUNK) if (j !== true) eq('junk ' + k, act('resume', with_({ [k]: j }), NOW, 0, 0), 'drop');
  for (const k of ['checking', 'refreshing', 'storeBusy', 'lockHeld', 'editOpen']) for (const j of JUNK) if (j !== false) eq('junk ' + k, act('resume', with_({ [k]: j }), NOW, 0, 0), 'wait');
  for (const k of ['outboxPending', 'gatewayInFlight', 'photoPending']) for (const j of JUNK) if (j !== 0) eq('junk ' + k, act('resume', with_({ [k]: j }), NOW, 0, 0), 'wait');
  for (const j of JUNK) if (j !== '') eq('junk accessBlock', act('resume', with_({ accessBlock: j }), NOW, 0, 0), 'drop');

  // swapOk
  eq('swap quiet', m.swapOk(7, QUIET()), true);
  eq('swap revision moved', m.swapOk(7, with_({ outboxRevision: 8 })), false);
  eq('swap revision moved down', m.swapOk(7, with_({ outboxRevision: 6 })), false);
  eq('swap outbox', m.swapOk(7, with_({ outboxPending: 1 })), false);
  eq('swap in-flight', m.swapOk(7, with_({ gatewayInFlight: 1 })), false);
  eq('swap lock', m.swapOk(7, with_({ lockHeld: true })), false);
  eq('swap edit dialog', m.swapOk(7, with_({ editOpen: true })), false);
  for (const j of JUNK) if (j !== false) eq('swap junk editOpen', m.swapOk(7, with_({ editOpen: j })), false);
  eq('swap photos', m.swapOk(7, with_({ photoPending: 1 })), false);
  eq('swap offline', m.swapOk(7, with_({ online: false })), false);
  eq('swap blocked', m.swapOk(7, with_({ accessBlock: 'removed' })), false);
  eq('swap no session', m.swapOk(7, with_({ sessionOpen: false })), false);
  eq('swap does not mind checking', m.swapOk(7, with_({ checking: true })), true);
  for (const j of JUNK) if (j !== 7) eq('swap junk startRevision', m.swapOk(j, QUIET()), false);
  for (const j of JUNK) if (j !== 7) eq('swap junk outboxRevision', m.swapOk(7, with_({ outboxRevision: j })), false);
  for (const j of JUNK) if (typeof j !== 'number' || !isFinite(j)) eq('swap junk equal revisions', m.swapOk(j, with_({ outboxRevision: j })), false);
  eq('swap null snap', m.swapOk(7, null), false);
  eq('swap undefined snap', m.swapOk(7, undefined), false);

  // wantExpired
  eq('want fresh', m.wantExpired(NOW, NOW + 119999), false);
  eq('want edge', m.wantExpired(NOW, NOW + 120000), true);
  eq('want backwards', m.wantExpired(NOW, NOW - 1), true);
  for (const j of JUNK) if (typeof j !== 'number' || !isFinite(j)) { eq('want junk since', m.wantExpired(j, NOW), true); eq('want junk now', m.wantExpired(NOW, j), true); }

  // allCommitted
  eq('all ok', m.allCommitted(['committed', 'committed']), true);
  eq('one discarded', m.allCommitted(['committed', 'discarded']), false);
  for (const k of ['failed', 'superseded', 'skipped', '', undefined, null]) eq('not ' + k, m.allCommitted(['committed', k]), false);
  for (const j of [undefined, null, [], 'committed', {}, 3]) eq('allCommitted junk', m.allCommitted(j), false);
  return bad;
}

test('contract battery passes on the real helper', () => {
  assert.deepEqual(battery(load(SRC)), []);
});

test('never throws on any input', () => {
  const m = load(SRC);
  for (const a of JUNK) for (const b of JUNK) {
    assert.doesNotThrow(() => { m.decide(a, b, a, b, a); m.swapOk(a, b); m.wantExpired(a, b); m.allCommitted(a); m.hardBlock(a); });
  }
});

// Seeded monkey: random snapshots; compare with an independent model of the documented rules.
test('monkey: 20000 random decisions agree with an independent model', () => {
  const m = load(SRC);
  let seed = 12345;
  const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  let runs = 0, waits = 0, drops = 0;
  for (let i = 0; i < 20000; i++) {
    const snap = { online: rnd() > 0.1, sessionOpen: rnd() > 0.1, accessBlock: rnd() > 0.9 ? 'removed' : '', checking: rnd() > 0.85,
      refreshing: rnd() > 0.9, storeBusy: rnd() > 0.9, outboxPending: rnd() > 0.7 ? 2 : 0, outboxRevision: 3,
      gatewayInFlight: rnd() > 0.9 ? 1 : 0, lockHeld: rnd() > 0.9, editOpen: rnd() > 0.9, photoPending: rnd() > 0.9 ? 1 : 0 };
    const trig = pick(['resume', 'reconnect', 'manual']);
    const sync = pick([0, NOW - 1000, NOW - 299999, NOW - 300000, NOW - 900000]);
    const start = pick([0, NOW - 1000, NOW - 14999, NOW - 15000, NOW - 99999]);
    let want;
    if (!snap.online) want = 'drop'; else if (!snap.sessionOpen) want = 'drop'; else if (snap.accessBlock) want = 'drop';
    else if (trig !== 'manual' && sync > 0 && NOW - sync < 300000) want = 'drop';
    else if (start > 0 && NOW - start < 15000) want = 'drop';
    else if (snap.checking || snap.refreshing || snap.storeBusy || snap.outboxPending > 0 || snap.gatewayInFlight > 0 || snap.lockHeld || snap.editOpen || snap.photoPending > 0) want = 'wait';
    else want = 'run';
    const got = m.decide(trig, snap, NOW, sync, start).action;
    assert.equal(got, want, JSON.stringify({ trig, snap, sync, start }));
    if (got === 'run') runs++; else if (got === 'wait') waits++; else drops++;
    // a run implies the swap gate is open for the same snapshot at the same revision
    if (got === 'run') assert.equal(m.swapOk(3, snap), true);
  }
  assert.ok(runs > 500 && waits > 500 && drops > 500, `coverage runs=${runs} waits=${waits} drops=${drops}`);
});

// ── hand mutants: each must be killed by the battery ──────────────────────────────────────────────────────
const MUTANTS = [
  ['stale 300000 -> 30000', 'var STALE_MS = 300000', 'var STALE_MS = 30000'],
  ['spacing dropped to 0', 'var SPACING_MS = 15000', 'var SPACING_MS = 0'],
  ['run ttl doubled', 'var RUN_TTL_MS = 180000', 'var RUN_TTL_MS = 360000'],
  ['run edge off-by-one', 'age >= RUN_TTL_MS', 'age > RUN_TTL_MS'],
  ['run backwards kept', 'return age < 0 || age >= RUN_TTL_MS', 'return age >= RUN_TTL_MS'],
  ['run bad clock kept', 'if (!isNum(startMs) || !isNum(nowMs)) return true', 'if (!isNum(startMs) || !isNum(nowMs)) return false'],
  ['ttl doubled', 'var WANT_TTL_MS = 120000', 'var WANT_TTL_MS = 240000'],
  ['poll 5000 -> 500', 'var POLL_MS = 5000', 'var POLL_MS = 500'],
  ['trigger list loses manual', 'var TRIGGERS = ["resume", "reconnect", "manual"]', 'var TRIGGERS = ["resume", "reconnect"]'],
  ['offline not hard', 'if (snap.online !== true) return "offline"', 'if (false) return "offline"'],
  ['no-session not hard', 'if (snap.sessionOpen !== true) return "no-session"', 'if (false) return "no-session"'],
  ['block not hard', 'snap.accessBlock.length > 0) return "blocked"', 'snap.accessBlock.length > 9) return "blocked"'],
  ['junk accessBlock allowed', 'typeof snap.accessBlock !== "string" || ', ''],
  ['null snap allowed', 'if (snap === null || typeof snap !== "object") return "no-state"', ''],
  ['checking ignored', 'if (snap.checking !== false) return "checking"', ''],
  ['refreshing ignored', 'if (snap.refreshing !== false) return "refreshing"', ''],
  ['storeBusy ignored', 'if (snap.storeBusy !== false) return "store-loading"', ''],
  ['outbox ignored', 'if (!(snap.outboxPending === 0)) return "outbox"', ''],
  ['outbox truthy test (junk passes)', 'if (!(snap.outboxPending === 0)) return "outbox"', 'if (snap.outboxPending > 0) return "outbox"'],
  ['inflight ignored', 'if (!(snap.gatewayInFlight === 0)) return "in-flight"', ''],
  ['lock ignored', 'if (snap.lockHeld !== false) return "lock"', ''],
  ['photos ignored', 'if (!(snap.photoPending === 0)) return "photos"', ''],
  ['manual obeys staleness', 'if (trigger !== "manual" && isNum(nowMs)', 'if (isNum(nowMs)'],
  ['staleness off-by-one', 'age < STALE_MS', 'age <= STALE_MS'],
  ['backwards clock = fresh', 'if (age >= 0 && age < STALE_MS)', 'if (age < STALE_MS)'],
  ['spacing off-by-one', 'gap < SPACING_MS', 'gap <= SPACING_MS'],
  ['spacing backwards wedges', 'if (gap >= 0 && gap < SPACING_MS)', 'if (gap < SPACING_MS)'],
  ['wait before drop(fresh)', 'if (trigger !== "manual" && isNum(nowMs) && isNum(lastSyncMs) && lastSyncMs > 0) {', 'if (softBlock(snap).length > 0) return { action: "wait", reason: softBlock(snap) }\n    if (trigger !== "manual" && isNum(nowMs) && isNum(lastSyncMs) && lastSyncMs > 0) {'],
  ['swap ignores revision', 'snap.outboxRevision !== startRevision) return false', 'false) return false'],
  ['swap accepts junk revision', '!isNum(startRevision) || !isNum(snap.outboxRevision) || ', ''],
  ['swap ignores outbox', 'if (!(snap.outboxPending === 0) || !(snap.gatewayInFlight === 0)) return false', 'if (!(snap.gatewayInFlight === 0)) return false'],
  ['swap ignores lock', 'if (snap.lockHeld !== false || snap.editOpen !== false || !(snap.photoPending === 0)) return false', 'if (snap.editOpen !== false || !(snap.photoPending === 0)) return false'],
  ['swap ignores edit dialog', 'if (snap.lockHeld !== false || snap.editOpen !== false || !(snap.photoPending === 0)) return false', 'if (snap.lockHeld !== false || !(snap.photoPending === 0)) return false'],
  ['edit dialog ignored', 'if (snap.editOpen !== false) return "edit-dialog"', ''],
  ['edit dialog truthy test (junk passes)', 'if (snap.editOpen !== false) return "edit-dialog"', 'if (snap.editOpen === true) return "edit-dialog"'],
  ['swap ignores block', 'if (hardBlock(snap).length > 0) return false', ''],
  ['want never expires on bad clock', 'if (!isNum(wantSinceMs) || !isNum(nowMs)) return true', 'if (!isNum(wantSinceMs) || !isNum(nowMs)) return false'],
  ['want backwards kept', 'return age < 0 || age >= WANT_TTL_MS', 'return age >= WANT_TTL_MS'],
  ['allCommitted accepts discarded', 'if (results[i] !== "committed") return false', 'if (results[i] === "failed") return false'],
  ['allCommitted accepts empty', 'if (!Array.isArray(results) || results.length === 0) return false', 'if (!Array.isArray(results)) return false'],
];

for (const [name, from, to] of MUTANTS) {
  test('mutant killed: ' + name, () => {
    assert.ok(SRC.includes(from), 'mutation anchor missing: ' + from);
    let failed;
    try { failed = battery(load(SRC.replace(from, to))); } catch (e) { failed = ['threw: ' + e.message]; }   // a mutant that throws is noticed too
    assert.ok(failed.length > 0, 'the battery did not notice: ' + name);
  });
}
