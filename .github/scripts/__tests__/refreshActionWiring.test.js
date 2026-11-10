'use strict';

// L4b (reshaped after the PR #186 device test, 2026-11-10): wiring tests over the source TEXT of the refresh button, the
// five pages, Main.qml and DataModel.qml (no Qt). They pin what behaviour tests cannot see: which pages carry the
// button, that all five wire it identically inside the header actions, that the button reads nothing but its props,
// that only a tap on it ever shows the caption, that only the two intended places emit the "unfinished" signal. A
// drift guard in the same style as refreshWiring.test.js. Hand mutants at the bottom prove each rule bites.
// Design: docs/superpowers/specs/2026-11-04-l4b-refresh-row-design.md (+ addendum 2026-11-10).

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..', '..');
const rd = (rel) => fs.readFileSync(path.join(REPO, rel), 'utf8');
const WITH_ACTION = ['Inventory', 'Orders', 'Staff', 'Dashboard', 'Sales'];
const WITHOUT_ACTION = ['Activity', 'Profile', 'Login', 'AccessBlocked', 'TenantSetup'];

function snapshot() {
  const f = { btn: rd('qml/components/RefreshAction.qml'), main: rd('qml/Main.qml'), dm: rd('qml/model/DataModel.qml') };
  for (const p of [...WITH_ACTION, ...WITHOUT_ACTION]) f['page:' + p] = rd('qml/pages/' + p + 'Page.qml');
  return f;
}

// The wiring block, as it must appear in every page, indentation taken from the page itself.
const BLOCK = /\n( *)RefreshAction \{\n\1    lastSyncMs: app\.refreshLastSyncMs\n\1    refreshState: app\.refreshState\n\1    online: app\.isOnline\n\1    onRefreshRequested: app\.requestManualRefresh\(\)\n\1\},\n/;
const strip = (s) => s.replace(/\/\/.*$/gm, '');
const count = (s, needle) => s.split(needle).length - 1;

// Returns the list of broken rules (empty = all hold).
function check(f) {
  const bad = []; const add = (m) => bad.push(m);
  for (const p of WITH_ACTION) {
    const src = f['page:' + p];
    if (count(src, 'RefreshAction {') !== 1) { add(p + ': RefreshAction must appear exactly once'); continue; }
    if (!BLOCK.test(src)) { add(p + ': RefreshAction is not wired like the other pages'); continue; }
    // first entry of the GlassHeader actions list
    if (!/GlassHeader \{[\s\S]*?\n( *)actions: \[\n\1    RefreshAction \{/.test(src)) add(p + ': RefreshAction must be the first entry of the GlassHeader actions');
    if (src.includes('RefreshRow')) add(p + ': the old RefreshRow must be gone');
  }
  for (const p of WITHOUT_ACTION) if (f['page:' + p].includes('RefreshAction')) add(p + ': must not carry a RefreshAction (its data is not part of the refresh)');
  for (const p of [...WITH_ACTION, ...WITHOUT_ACTION]) {
    const code = strip(f['page:' + p]);
    if (/manualRefresh|requestRefresh|refreshFromFirebase|RefreshPolicy|_lastSyncMs/.test(code.replace(/app\.requestManualRefresh/g, ''))) add(p + ': a page must reach the refresh only through app.requestManualRefresh()');
  }

  // the button: props + one signal, nothing else from the app
  const b = strip(f.btn);
  for (const t of ['property real lastSyncMs', 'property bool online', 'property string refreshState', 'signal refreshRequested()'])
    if (!b.includes(t)) add('RefreshAction lacks: ' + t);
  if (/OrdersStore|InventoryStore|StaffStore|DataModel|AuthService|AuthStore|Gateway|OutboxStore|LockManager|app\./.test(b)) add('RefreshAction must read nothing but its props');
  if (!b.includes('import "../helper/RefreshCaption.js" as RefreshCaption')) add('RefreshAction must import RefreshCaption.js');
  if (!/RefreshCaption\.view\(\{[^}]*online: root\.online[^}]*state: root\.refreshState[^}]*lastSyncMs: root\.lastSyncMs[^}]*nowMs: root\._now/.test(b.replace(/\n\s*/g, ' '))) add('RefreshAction must build its view from the four inputs');
  if (!/Accessible\.role: Accessible\.Button/.test(b) || !/Accessible\.name: RefreshCaption\.accessibleName\(root\._view\)/.test(b)) add('RefreshAction lacks its accessible role and name');
  if (!/Accessible\.onPressAction: if \(!root\._view\.busy\) root\._tap\(\)/.test(b)) add('the accessible press must honour busy');
  if (!/IconActionButton \{[\s\S]*?variant: "ghost"[\s\S]*?enabled: !root\._view\.busy[\s\S]*?onClicked: root\._tap\(\)/.test(b)) add('the button must be a ghost IconActionButton, tappable unless busy (offline taps are answered by the toast)');
  if (!/implicitWidth: dp\(38\)/.test(b) || !/implicitHeight: dp\(38\)/.test(b)) add('the button must be the same 38 dp as the other header actions');
  // the caption only ever follows a tap
  if ((b.match(/(?:root\.)?_armed = true/g) || []).length !== 1 || !/function _tap\(\) \{\s*_tick\(\)\s*_armed = true\s*root\.refreshRequested\(\)\s*\}/.test(b)) add('only _tap() may arm the caption, and it must also read the clock and emit the request');
  if (!/on_ArmedChanged: if \(_armed\) pill\.open\(\); else pill\.close\(\)/.test(b)) add('the caption popup must follow _armed');
  if (!/Timer \{\s*interval: 3500\s*running: root\._armed && !root\._view\.busy\s*onTriggered: root\._armed = false/.test(b)) add('the caption must stay while busy and hide 3.5 s after the refresh settles');
  if (/repeat: true/.test(b)) add('no repeating timer: nothing may tick while no caption is shown');
  if (!/closePolicy: QQC\.Popup\.NoAutoClose/.test(b) || !/modal: false/.test(b) || !/focus: false/.test(b)) add('the caption popup must be non-modal, take no focus and never close itself');
  if (!/text: root\._view\.text/.test(b)) add('the caption must show the helper text');
  if (!/QQC\.BusyIndicator \{[^}]*running: root\._view\.busy/.test(b.replace(/\n\s*/g, ' '))) add('the spinner must run only while the view is busy');

  // Main.qml glue
  const main = strip(f.main);
  if (!main.includes('import "helper/RefreshCaption.js" as RefreshCaption')) add('Main.qml must import RefreshCaption.js');
  if (!/readonly property real refreshLastSyncMs: dataModel\.lastSyncMs/.test(main)) add('Main.qml: refreshLastSyncMs');
  if (!/readonly property string refreshState: dataModel\.refreshState/.test(main)) add('Main.qml: refreshState');
  if (!/function requestManualRefresh\(\) \{\s*var msg = RefreshCaption\.requestMessage\(dataModel\.manualRefresh\(\), app\.syncStuckCount\)\s*if \(msg\.length > 0\) Toast\.show\(msg\)\s*\}/.test(main)) add('Main.qml: requestManualRefresh must toast requestMessage(manualRefresh(), app.syncStuckCount)');
  if (!/Connections \{\s*target: dataModel\s*function onManualRefreshUnfinished\(why\) \{\s*var msg = RefreshCaption\.unfinishedMessage\(why, app\.syncStuckCount\)\s*if \(msg\.length > 0\) Toast\.show\(msg\)/.test(main)) add('Main.qml: the unfinished signal must become a toast');
  if (count(main, 'manualRefresh()') !== 1) add('Main.qml: manualRefresh() must have exactly one caller');

  // DataModel
  const dm = strip(f.dm);
  if (!/signal manualRefreshUnfinished\(string why\)/.test(dm)) add('DataModel: signal manualRefreshUnfinished');
  if (!/readonly property real lastSyncMs: _lastSyncMs/.test(dm)) add('DataModel: lastSyncMs must be a read-only view of _lastSyncMs');
  if (!/readonly property string refreshState: _refreshRunning \? "running" : \(_wantTrigger !== "" \? "waiting" : "idle"\)/.test(dm)) add('DataModel: refreshState expression');
  if (count(dm, 'manualRefreshUnfinished(') !== 3) add('DataModel: manualRefreshUnfinished is declared once and emitted exactly twice (gave-up, partial)');
  if (!/function _abandonWant\(\) \{\s*var manual = _wantTrigger === "manual"\s*_clearWant\(\)\s*if \(manual\) manualRefreshUnfinished\("gave-up"\)\s*\}/.test(dm)) add('DataModel: _abandonWant');
  if (count(dm, '_abandonWant()') !== 3) add('DataModel: _abandonWant is defined once and called from the two ends of a wish only (expiry, drop)');
  if (!/function requestRefresh\(trigger\) \{ return _request\(trigger\)\.action \}/.test(dm)) add('DataModel: requestRefresh must keep returning the bare action');
  if (!/function manualRefresh\(\) \{ return _request\("manual"\) \}/.test(dm)) add('DataModel: manualRefresh');
  if (count(dm, 'refreshFromFirebase(') !== 1) add('DataModel: refreshFromFirebase must still have exactly one caller (_startRefresh)');
  return bad;
}

test('refresh button wiring: every rule holds on the real files', () => { assert.deepEqual(check(snapshot()), []); });

test('refresh button wiring: the pages with the button are exactly the five whose data the refresh covers', () => {
  const dir = fs.readdirSync(path.join(REPO, 'qml/pages')).filter((n) => n.endsWith('.qml'));
  const carrying = dir.filter((n) => rd('qml/pages/' + n).includes('RefreshAction')).map((n) => n.replace('Page.qml', '')).sort();
  assert.deepEqual(carrying, [...WITH_ACTION].sort());
});

test('refresh button wiring: the old always-visible row is gone from the whole tree', () => {
  assert.equal(fs.existsSync(path.join(REPO, 'qml/components/RefreshRow.qml')), false);
  for (const n of fs.readdirSync(path.join(REPO, 'qml/pages')).filter((x) => x.endsWith('.qml')))
    assert.equal(rd('qml/pages/' + n).includes('RefreshRow'), false, n);
});

// ── hand mutants: each must make some rule fail ──────────────────────────────────────────────────────────────
const MUT = [
  ['a page loses the button', (f) => { f['page:Orders'] = f['page:Orders'].replace(BLOCK, '\n'); }],
  ['a page wires lastSyncMs differently', (f) => { f['page:Staff'] = f['page:Staff'].replace('lastSyncMs: app.refreshLastSyncMs', 'lastSyncMs: 0'); }],
  ['a page skips the online input', (f) => { f['page:Sales'] = f['page:Sales'].replace(/ *online: app\.isOnline\n/, ''); }],
  ['a page calls DataModel directly', (f) => { f['page:Inventory'] = f['page:Inventory'].replace('app.requestManualRefresh()', 'dataModel.manualRefresh()'); }],
  ['the Activity page gains the button', (f) => { f['page:Activity'] = f['page:Activity'].replace('ColumnLayout {', 'RefreshAction {}\n ColumnLayout {'); }],
  ['the button is no longer first in the header actions', (f) => { f['page:Dashboard'] = f['page:Dashboard'].replace(BLOCK, '\n').replace(/(\n *)(IconActionButton \{)/, '$1$2'.replace('$2', 'IconActionButton {') ).replace('actions: [\n', 'actions: [\n            IconActionButton { variant: "glass"; iconName: "x" },\n'); }],
  ['the page keeps a RefreshRow', (f) => { f['page:Orders'] = f['page:Orders'] + '\n// RefreshRow {}\nRefreshRow {}\n'; }],
  ['the button reads a store', (f) => { f.btn = f.btn.replace('property real _now: Date.now()', 'property real _now: Date.now() + OrdersStore.revision'); }],
  ['the button reads app', (f) => { f.btn = f.btn.replace('property bool online: true', 'property bool online: app.isOnline'); }],
  ['the button bypasses the helper', (f) => { f.btn = f.btn.replace('RefreshCaption.view({', 'Object({'); }],
  ['the button is not a button', (f) => { f.btn = f.btn.replace('Accessible.role: Accessible.Button', 'Accessible.role: Accessible.StaticText'); }],
  ['a busy button can be pressed by a screen reader', (f) => { f.btn = f.btn.replace('if (!root._view.busy) root._tap()', 'root._tap()'); }],
  ['the tap target ignores busy', (f) => { f.btn = f.btn.replace('enabled: !root._view.busy\n        opacity', 'opacity'); }],
  ['the button is gated on the view (offline taps swallowed)', (f) => { f.btn = f.btn.replace('enabled: !root._view.busy\n        opacity', 'enabled: root._view.enabled\n        opacity'); }],
  ['the button is too small', (f) => { f.btn = f.btn.replace('implicitWidth: dp(38)', 'implicitWidth: dp(24)'); }],
  ['the button is not ghost', (f) => { f.btn = f.btn.replace('variant: "ghost"', 'variant: "glass"'); }],
  ['a second place arms the caption', (f) => { f.btn = f.btn.replace('onVisibleChanged: if (visible) _tick()', 'onVisibleChanged: if (visible) { _tick(); root._armed = true }'); }],
  ['the tap forgets to arm', (f) => { f.btn = f.btn.replace('        _armed = true\n', ''); }],
  ['the tap does not emit', (f) => { f.btn = f.btn.replace('        root.refreshRequested()\n    }', '    }'); }],
  ['the popup ignores _armed', (f) => { f.btn = f.btn.replace('on_ArmedChanged: if (_armed) pill.open(); else pill.close()', 'on_ArmedChanged: pill.open()'); }],
  ['the caption hides while busy', (f) => { f.btn = f.btn.replace('running: root._armed && !root._view.busy', 'running: root._armed'); }],
  ['the caption never hides', (f) => { f.btn = f.btn.replace('running: root._armed && !root._view.busy', 'running: false'); }],
  ['the caption timer repeats', (f) => { f.btn = f.btn.replace('interval: 3500', 'interval: 3500\n        repeat: true'); }],
  ['the caption closes on an outside press', (f) => { f.btn = f.btn.replace('closePolicy: QQC.Popup.NoAutoClose', 'closePolicy: QQC.Popup.CloseOnPressOutside'); }],
  ['the caption is modal', (f) => { f.btn = f.btn.replace('modal: false', 'modal: true'); }],
  ['the caption takes focus', (f) => { f.btn = f.btn.replace('focus: false', 'focus: true'); }],
  ['the caption shows something else', (f) => { f.btn = f.btn.replace('text: root._view.text', 'text: "x"'); }],
  ['the spinner runs always', (f) => { f.btn = f.btn.replace('running: root._view.busy\n        visible', 'running: true\n        visible'); }],
  ['Main drops the toast on a refusal', (f) => { f.main = f.main.replace('if (msg.length > 0) Toast.show(msg)\n    }', '}'); }],
  ['Main forgets the stuck count on a refusal toast (review #186)', (f) => { f.main = f.main.replace('manualRefresh(), app.syncStuckCount)', 'manualRefresh())'); }],
  ['Main forgets the stuck count on the unfinished toast (review #186)', (f) => { f.main = f.main.replace('unfinishedMessage(why, app.syncStuckCount)', 'unfinishedMessage(why)'); }],
  ['Main stops listening for the unfinished signal', (f) => { f.main = f.main.replace('function onManualRefreshUnfinished(why)', 'function onSomethingElse(why)'); }],
  ['Main has a second manual caller', (f) => { f.main = f.main.replace('function openStuckWrites()', 'function again() { dataModel.manualRefresh() }\n    function openStuckWrites()'); }],
  ['DataModel emits from a third place', (f) => { f.dm = f.dm.replace('function _clearWant() {', 'function _clearWant() {\n        manualRefreshUnfinished("partial")'); }],
  ['DataModel makes lastSyncMs writable', (f) => { f.dm = f.dm.replace('readonly property real lastSyncMs', 'property real lastSyncMs'); }],
  ['DataModel refreshState ignores the wish', (f) => { f.dm = f.dm.replace('(_wantTrigger !== "" ? "waiting" : "idle")', '"idle"'); }],
  ['requestRefresh returns the object', (f) => { f.dm = f.dm.replace('return _request(trigger).action }', 'return _request(trigger) }'); }],
  ['a second caller of the stores appears', (f) => { f.dm = f.dm.replace('function _clearWant() {', 'function _again() { StaffStore.refreshFromFirebase(null, null) }\n    function _clearWant() {'); }],
];
for (const [name, fn] of MUT) test('refresh button wiring mutant killed: ' + name, () => {
  const f = snapshot(); const before = JSON.stringify(f); fn(f);
  assert.notEqual(JSON.stringify(f), before, 'mutation did not change anything (stale anchor)');
  assert.ok(check(f).length > 0, 'no rule noticed this mutant');
});
