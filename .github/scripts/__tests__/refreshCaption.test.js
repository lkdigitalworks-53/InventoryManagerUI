'use strict';

// L4b: unit tests for the pure helper qml/helper/RefreshCaption.js (what the refresh row says, whether it can be
// tapped, what a tap or an unfinished refresh tells the user). The same contract runs under qmltestrunner in
// tests/tst_RefreshCaption.qml (CI only); this file runs here. Hand mutants at the bottom prove the battery bites.
// Design: docs/superpowers/specs/2026-11-04-l4b-refresh-row-design.md (B-D3..B-D6).

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { load } = require(path.join('..', '..', '..', 'functions', 'test', 'testSupport', 'qmlHelpers.js'));

const REPO = path.resolve(__dirname, '..', '..', '..');
const SRC = fs.readFileSync(path.join(REPO, 'qml/helper/RefreshCaption.js'), 'utf8');
const POLICY = load('RefreshPolicy.js');

function loadSrc(src) {
  const ctx = vm.createContext({});
  vm.runInContext(src.replace(/^\.pragma library/m, '') +
    '\n;this.__x = { MIN_MS, HOUR_MS, DAY_MS, OFFLINE_TOAST, ageText, view, accessibleName, requestMessage, unfinishedMessage }', ctx);
  return ctx.__x;
}

const NOW = 1_700_000_000_000;
const JUNK = [undefined, null, NaN, Infinity, -Infinity, '', 'x', '1', true, false, {}, [], () => 1];
const plain = (v) => JSON.parse(JSON.stringify(v));

// Every assertion of the contract, collected (not thrown) so a mutant can be asked "does the battery notice?".
function battery(m) {
  const bad = [];
  const eq = (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) bad.push(name + ': got ' + JSON.stringify(got) + ' want ' + JSON.stringify(want)); };
  const age = (ms) => m.ageText(NOW - ms, NOW);
  const v = (o) => plain(m.view(Object.assign({ online: true, state: 'idle', lastSyncMs: NOW - 4 * 60000, nowMs: NOW }, o)));

  // constants keep their meaning
  eq('MIN', m.MIN_MS, 60000); eq('HOUR', m.HOUR_MS, 3600000); eq('DAY', m.DAY_MS, 86400000);
  eq('offline sentence is the one Main.qml already uses', m.OFFLINE_TOAST, 'You are offline. Connect to the internet and try again');

  // ageText: boundaries on both sides of every unit
  eq('0 s', age(0), 'just now'); eq('59.999 s', age(59999), 'just now'); eq('60 s', age(60000), '1 min ago');
  eq('1 min 59 s', age(119999), '1 min ago'); eq('2 min', age(120000), '2 min ago'); eq('59 min 59 s', age(3599999), '59 min ago');
  eq('60 min', age(3600000), '1 h ago'); eq('23 h 59 min', age(86399999), '23 h ago'); eq('24 h', age(86400000), '1 d ago');
  eq('3 d', age(3 * 86400000 + 5), '3 d ago'); eq('400 d', age(400 * 86400000), '400 d ago');
  eq('clock went backwards: never the future', m.ageText(NOW + 5000, NOW), 'just now');
  eq('far in the future still just now', m.ageText(NOW + 9e12, NOW), 'just now');
  eq('never synced (0)', m.ageText(0, NOW), ''); eq('negative sync time', m.ageText(-5, NOW), '');
  for (const j of JUNK) { eq('junk lastSync', m.ageText(j, NOW), ''); eq('junk now', m.ageText(NOW - 1000, j), ''); }

  // view: precedence offline > running > waiting > idle
  eq('idle', v({}), { text: 'Updated 4 min ago', busy: false, enabled: true });
  eq('idle never synced', v({ lastSyncMs: 0 }), { text: 'Tap to refresh', busy: false, enabled: true });
  eq('idle just now', v({ lastSyncMs: NOW - 5000 }), { text: 'Updated just now', busy: false, enabled: true });
  eq('running', v({ state: 'running' }), { text: 'Refreshing…', busy: true, enabled: false });
  eq('waiting', v({ state: 'waiting' }), { text: 'Waiting to refresh…', busy: true, enabled: false });
  eq('offline idle', v({ online: false }), { text: 'Offline · Updated 4 min ago', busy: false, enabled: false });
  eq('offline never synced', v({ online: false, lastSyncMs: 0 }), { text: 'Offline', busy: false, enabled: false });
  eq('offline beats running', v({ online: false, state: 'running' }), { text: 'Offline · Updated 4 min ago', busy: false, enabled: false });
  eq('offline beats waiting', v({ online: false, state: 'waiting' }), { text: 'Offline · Updated 4 min ago', busy: false, enabled: false });
  for (const j of JUNK) if (j !== true) eq('junk online is offline', v({ online: j }).enabled, false);
  for (const j of JUNK) if (j !== 'idle' && j !== 'running' && j !== 'waiting') eq('junk state is disabled', v({ state: j }), { text: 'Refresh', busy: false, enabled: false });
  for (const j of [null, undefined, 5, 'x', true]) eq('junk snap', plain(m.view(j)), { text: 'Refresh', busy: false, enabled: false });
  eq('junk lastSync only loses the age', v({ lastSyncMs: 'x' }), { text: 'Tap to refresh', busy: false, enabled: true });

  // accessibleName
  eq('a11y tappable', m.accessibleName(v({})), 'Updated 4 min ago. Tap to refresh.');
  eq('a11y busy', m.accessibleName(v({ state: 'running' })), 'Refreshing…');
  eq('a11y offline', m.accessibleName(v({ online: false })), 'Offline · Updated 4 min ago');
  for (const j of [null, undefined, 5, 'x', {}, { text: 5 }]) eq('a11y junk', m.accessibleName(j), 'Refresh');
  eq('a11y enabled must be literally true', m.accessibleName({ text: 'T', enabled: 'yes' }), 'T');

  // requestMessage
  eq('run is silent', m.requestMessage({ action: 'run', reason: '' }), '');
  eq('wait outbox', m.requestMessage({ action: 'wait', reason: 'outbox' }), 'Sending your changes first. The refresh follows.');
  eq('wait in-flight', m.requestMessage({ action: 'wait', reason: 'in-flight' }), 'Sending your changes first. The refresh follows.');
  eq('wait photos', m.requestMessage({ action: 'wait', reason: 'photos' }), 'Sending your changes first. The refresh follows.');
  eq('wait lock', m.requestMessage({ action: 'wait', reason: 'lock' }), 'Finish editing first. The refresh follows.');
  eq('wait edit-dialog', m.requestMessage({ action: 'wait', reason: 'edit-dialog' }), 'Finish editing first. The refresh follows.');
  eq('wait refreshing', m.requestMessage({ action: 'wait', reason: 'refreshing' }), 'Already refreshing.');
  for (const r of ['checking', 'store-loading', 'zzz', '', undefined]) eq('wait generic ' + r, m.requestMessage({ action: 'wait', reason: r }), 'Busy for a moment. Refreshing as soon as it is free.');
  eq('drop offline', m.requestMessage({ action: 'drop', reason: 'offline' }), 'You are offline. Connect to the internet and try again');
  eq('drop too-soon', m.requestMessage({ action: 'drop', reason: 'too-soon' }), 'Just refreshed. Try again in a few seconds.');
  for (const r of ['blocked', 'no-session', 'no-state', 'fresh', 'bad-trigger', 'zzz', '', undefined]) eq('drop generic ' + r, m.requestMessage({ action: 'drop', reason: r }), "Can't refresh right now.");
  for (const j of [null, undefined, 5, 'x', {}, { action: 'zzz' }, { action: 5 }]) eq('junk decision', m.requestMessage(j), '');

  // unfinishedMessage
  eq('gave up', m.unfinishedMessage('gave-up'), "Couldn't refresh. Tap the refresh row to try again.");
  eq('partial', m.unfinishedMessage('partial'), 'Some lists could not be updated. Tap the refresh row to try again.');
  for (const j of [...JUNK, 'zzz', 'committed']) eq('unfinished junk', m.unfinishedMessage(j), '');

  // review of PR #186: stuck writes (second argument) change what a wait on the outbox, and a gave-up wish, say
  const STUCK_WAIT = 'Some changes are not syncing, so the refresh waits. Open the sync message at the top to fix or discard them.';
  const STUCK_GAVE_UP = "Couldn't refresh: some changes are not syncing. Fix or discard them, then tap the refresh row.";
  eq('stuck + outbox wait', m.requestMessage({ action: 'wait', reason: 'outbox' }, 1), STUCK_WAIT);
  eq('stuck many + outbox wait', m.requestMessage({ action: 'wait', reason: 'outbox' }, 12), STUCK_WAIT);
  for (const z of [0, -1, undefined, null, NaN, Infinity, '2', true, {}])
    eq('no usable stuck count keeps the old wait ' + String(z), m.requestMessage({ action: 'wait', reason: 'outbox' }, z), 'Sending your changes first. The refresh follows.');
  eq('stuck does not change in-flight', m.requestMessage({ action: 'wait', reason: 'in-flight' }, 3), 'Sending your changes first. The refresh follows.');
  eq('stuck does not change photos', m.requestMessage({ action: 'wait', reason: 'photos' }, 3), 'Sending your changes first. The refresh follows.');
  eq('stuck does not change edit-dialog', m.requestMessage({ action: 'wait', reason: 'edit-dialog' }, 3), 'Finish editing first. The refresh follows.');
  eq('stuck does not change a drop', m.requestMessage({ action: 'drop', reason: 'too-soon' }, 3), 'Just refreshed. Try again in a few seconds.');
  eq('stuck does not make a run talk', m.requestMessage({ action: 'run', reason: '' }, 3), '');
  eq('stuck + gave-up', m.unfinishedMessage('gave-up', 2), STUCK_GAVE_UP);
  for (const z of [0, -1, undefined, null, NaN, '2']) eq('no usable stuck count keeps gave-up ' + String(z), m.unfinishedMessage('gave-up', z), "Couldn't refresh. Tap the refresh row to try again.");
  eq('stuck does not change partial', m.unfinishedMessage('partial', 5), 'Some lists could not be updated. Tap the refresh row to try again.');
  eq('stuck + junk why stays silent', m.unfinishedMessage('zzz', 5), '');

  // Contract with RefreshPolicy: every answer the real policy can give a manual refresh has the right message kind.
  const QUIET = { online: true, sessionOpen: true, accessBlock: '', checking: false, refreshing: false, storeBusy: false,
    outboxPending: 0, outboxRevision: 7, gatewayInFlight: 0, lockHeld: false, editOpen: false, photoPending: 0 };
  const variants = [{}, { online: false }, { sessionOpen: false }, { accessBlock: 'removed' }, { checking: true }, { refreshing: true }, { storeBusy: true },
    { outboxPending: 2 }, { gatewayInFlight: 1 }, { lockHeld: true }, { editOpen: true }, { photoPending: 1 }];
  for (const o of variants) for (const last of [0, NOW - 100, NOW - 1e6]) {
    const d = POLICY.decide('manual', Object.assign({}, QUIET, o), NOW, NOW - 1e6, last);
    const msg = m.requestMessage(plain(d));
    if (d.action === 'run') eq('policy run is silent ' + JSON.stringify(o), msg, '');
    else eq('policy ' + d.action + '/' + d.reason + ' has a message', msg.length > 0, true);
  }

  // View invariants over a seeded monkey: never throws, text is always a string, tappable means idle + online.
  let seed = 12345; const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  for (let i = 0; i < 4000; i++) {
    const snap = { online: pick([true, false, true, 1, null]), state: pick(['idle', 'waiting', 'running', 'idle', 'x', undefined]),
      lastSyncMs: pick([0, NOW - 1, NOW - rnd() * 9e9, NOW + 5000, 'x', NaN, undefined]), nowMs: pick([NOW, NOW, NOW + rnd() * 9e9, undefined]) };
    let out; try { out = plain(m.view(snap)); } catch (e) { bad.push('monkey threw ' + e.message); break; }
    if (typeof out.text !== 'string' || out.text.length === 0) bad.push('monkey: empty text ' + JSON.stringify(snap));
    if (out.enabled && (out.busy || snap.online !== true || snap.state !== 'idle')) bad.push('monkey: tappable when it must not be ' + JSON.stringify(snap));
    if (out.busy && snap.online === true && snap.state !== 'running' && snap.state !== 'waiting') bad.push('monkey: busy without a run or a wait ' + JSON.stringify(snap));
  }
  return bad;
}

test('RefreshCaption: the whole contract holds on the real file', () => {
  const bad = battery(loadSrc(SRC));
  assert.deepEqual(bad, []);
});

test('RefreshCaption: the helper is a pure library (no QML, no clock reads, no stores)', () => {
  assert.match(SRC, /^\.pragma library/m);
  const code = SRC.replace(/\/\/.*$/gm, '');   // comments may name the stores; code may not use them
  assert.doesNotMatch(code, /Date\.now|new Date|qsTr|Toast\.|DataModel|AuthService|\.import /);
});

// ── hand mutants: each must be killed by the battery ──────────────────────────────────────────────────────
const MUTANTS = [
  ['minute boundary <= instead of <', 'if (age < MIN_MS) return "just now"', 'if (age <= MIN_MS) return "just now"'],
  ['hour boundary <= instead of <', 'if (age < HOUR_MS) return Math.floor', 'if (age <= HOUR_MS) return Math.floor'],
  ['day boundary <= instead of <', 'if (age < DAY_MS) return Math.floor', 'if (age <= DAY_MS) return Math.floor'],
  ['round instead of floor (minutes)', 'Math.floor(age / MIN_MS)', 'Math.round(age / MIN_MS)'],
  ['hours use the minute unit', 'Math.floor(age / HOUR_MS) + " h ago"', 'Math.floor(age / MIN_MS) + " h ago"'],
  ['backwards clock shows a negative', 'if (age < MIN_MS) return "just now"', 'if (age >= 0 && age < MIN_MS) return "just now"'],
  ['never synced reads as an age', 'lastSyncMs <= 0) return ""', 'lastSyncMs < 0) return ""'],
  ['junk now accepted', '!isNum(nowMs) || lastSyncMs <= 0', 'lastSyncMs <= 0'],
  ['offline text drops the age', '"Offline · Updated " + age', '"Offline"'],
  ['offline checked after running', 'if (snap.online !== true) return { text: age.length > 0 ? "Offline · Updated " + age : "Offline", busy: false, enabled: false }\n    if (snap.state === "running") return { text: "Refreshing…", busy: true, enabled: false }',
   'if (snap.state === "running") return { text: "Refreshing…", busy: true, enabled: false }\n    if (snap.online !== true) return { text: age.length > 0 ? "Offline · Updated " + age : "Offline", busy: false, enabled: false }'],
  ['online must be literally true', 'snap.online !== true', 'snap.online === false'],
  ['running is tappable', '{ text: "Refreshing…", busy: true, enabled: false }', '{ text: "Refreshing…", busy: true, enabled: true }'],
  ['waiting is tappable', '{ text: "Waiting to refresh…", busy: true, enabled: false }', '{ text: "Waiting to refresh…", busy: true, enabled: true }'],
  ['waiting is not busy', '{ text: "Waiting to refresh…", busy: true', '{ text: "Waiting to refresh…", busy: false'],
  ['unknown state is tappable', 'if (snap.state !== "idle") return { text: "Refresh", busy: false, enabled: false }', 'if (snap.state !== "idle") return { text: "Refresh", busy: false, enabled: true }'],
  ['idle never-synced text', '"Tap to refresh", busy: false, enabled: true }', '"Updated", busy: false, enabled: true }'],
  ['junk snap throws', 'if (snap === null || typeof snap !== "object") return', 'if (snap === undefined) return'],
  ['a11y drops the action', 'v.text + ". Tap to refresh."', 'v.text'],
  ['a11y enabled truthy', 'v.enabled === true ?', 'v.enabled ?'],
  ['a11y junk text', 'typeof v.text !== "string"', 'v.text === undefined'],
  ['run toasts', 'if (d.action === "run") return ""', 'if (d.action === "run") return "Refreshing"'],
  ['outbox gets the generic wait text', 'd.reason === "outbox" || ', ''],
  ['photos get the generic wait text', ' || d.reason === "photos")', ')'],
  ['lock gets the generic wait text', 'if (d.reason === "lock" || d.reason === "edit-dialog")', 'if (d.reason === "edit-dialog")'],
  ['edit-dialog gets the generic wait text', 'if (d.reason === "lock" || d.reason === "edit-dialog")', 'if (d.reason === "lock")'],
  ['refreshing gets the generic wait text', 'if (d.reason === "refreshing") return "Already refreshing."', ''],
  ['offline drop says too-soon', 'if (d.reason === "offline") return OFFLINE_TOAST', 'if (d.reason === "offline") return "Just refreshed. Try again in a few seconds."'],
  ['too-soon drop is silent', 'if (d.reason === "too-soon") return "Just refreshed. Try again in a few seconds."', 'if (d.reason === "too-soon") return ""'],
  ['unknown drop is silent', 'return "Can\'t refresh right now."', 'return ""'],
  ['unknown action says something', '    return ""\n}\n\n// A manual refresh that ended', '    return "Can\'t refresh right now."\n}\n\n// A manual refresh that ended'],
  ['gave-up message swapped', 'if (why === "gave-up") return "Couldn\'t refresh.', 'if (why === "gave-up") return "Some lists could not be updated.'],
  ['partial message dropped', 'if (why === "partial") return', 'if (why === "partial-x") return'],
  ['stuck wait ignores the count', 'if (d.reason === "outbox" && hasStuck(stuckCount)) return STUCK_WAIT', 'if (false) return STUCK_WAIT'],
  ['stuck wait fires for any reason', 'd.reason === "outbox" && hasStuck(stuckCount)', 'hasStuck(stuckCount)'],
  ['stuck count of 0 counts as stuck', 'return isNum(n) && n > 0', 'return isNum(n) && n >= 0'],
  ['string count counts as stuck', 'return isNum(n) && n > 0', 'return n > 0'],
  ['gave-up ignores the count', 'if (why === "gave-up" && hasStuck(stuckCount)) return STUCK_GAVE_UP', 'if (false) return STUCK_GAVE_UP'],
  ['partial wrongly stuck-aware', 'if (why === "partial") return', 'if (why === "partial" && hasStuck(stuckCount)) return STUCK_GAVE_UP\n    if (why === "partial") return'],
  ['unknown reason says something', 'return ""\n}\n', 'return "Couldn\'t refresh."\n}\n'],
];
for (const [name, from, to] of MUTANTS) {
  test('mutant killed: ' + name, () => {
    assert.ok(SRC.includes(from), 'mutant anchor not found in RefreshCaption.js: ' + from.slice(0, 50));
    let failed;
    try { failed = battery(loadSrc(SRC.replace(from, to))); } catch (e) { failed = ['threw: ' + e.message]; }
    assert.ok(failed.length > 0, 'the battery did not notice this mutant');
  });
}
