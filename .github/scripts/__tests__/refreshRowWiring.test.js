'use strict';

// L4b: wiring tests over the source TEXT of the refresh row, the five pages, Main.qml and DataModel.qml (no Qt).
// They pin what behaviour tests cannot see: which pages carry the row, that all five wire it identically, that the
// row reads nothing but its props, that only the two intended places emit the "unfinished" signal. A drift guard in the
// same style as refreshWiring.test.js. Hand mutants at the bottom prove each rule bites.
// Design: docs/superpowers/specs/2026-11-04-l4b-refresh-row-design.md (B-D1..B-D9).

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..', '..');
const rd = (rel) => fs.readFileSync(path.join(REPO, rel), 'utf8');
const WITH_ROW = ['Inventory', 'Orders', 'Staff', 'Dashboard', 'Sales'];
const WITHOUT_ROW = ['Activity', 'Profile', 'Login', 'AccessBlocked', 'TenantSetup'];

function snapshot() {
  const f = { row: rd('qml/components/RefreshRow.qml'), main: rd('qml/Main.qml'), dm: rd('qml/model/DataModel.qml') };
  for (const p of [...WITH_ROW, ...WITHOUT_ROW]) f['page:' + p] = rd('qml/pages/' + p + 'Page.qml');
  return f;
}

const ROW_BLOCK = /\n( {12}RefreshRow \{\n(?: {16}[^\n]*\n)+ {12}\}\n)/;
const strip = (s) => s.replace(/\/\/.*$/gm, '');
const count = (s, needle) => s.split(needle).length - 1;

// Returns the list of broken rules (empty = all hold).
function check(f) {
  const bad = []; const add = (m) => bad.push(m);
  const blocks = {};
  for (const p of WITH_ROW) {
    const src = f['page:' + p]; const m = ROW_BLOCK.exec(src);
    if (!m) { add(p + ': no RefreshRow block'); continue; }
    blocks[p] = m[1];
    if (count(src, 'RefreshRow {') !== 1) add(p + ': RefreshRow must appear exactly once');
    // first child of the content column: right after the stack header, before anything else
    const head = /AppScrollView \{[\s\S]*?ColumnLayout \{\n {12}id: stack\n {12}width: root\.width\n {12}spacing: dp\(Constants\.space\d\)\n\n$/.exec(src.slice(0, m.index + 1));
    if (!head) add(p + ': RefreshRow is not the first child of the AppScrollView content column');
    // the sibling after the row gives up its own top margin (the stack spacing is the gap)
    const after = src.slice(m.index + m[0].length, m.index + m[0].length + 900);
    const first = /\n( {16}Layout\.topMargin[^\n]*)\n/.exec(after);
    const nextItemEnd = after.search(/\n {12}\}\n/);
    if (first && (nextItemEnd < 0 || first.index < nextItemEnd)) add(p + ': the item after the row still has its own top margin');
  }
  const uniq = new Set(Object.values(blocks));
  if (uniq.size > 1) add('the five pages do not wire RefreshRow identically');
  const b = Object.values(blocks)[0] || '';
  for (const line of ['lastSyncMs: app.refreshLastSyncMs', 'refreshState: app.refreshState', 'online: app.isOnline', 'onRefreshRequested: app.requestManualRefresh()', 'Layout.fillWidth: true'])
    if (!b.includes(line)) add('RefreshRow wiring lacks: ' + line);
  for (const p of WITHOUT_ROW) if (f['page:' + p].includes('RefreshRow')) add(p + ': must not carry a RefreshRow (its data is not part of the refresh)');
  for (const p of [...WITH_ROW, ...WITHOUT_ROW]) {
    const code = strip(f['page:' + p]);
    if (/manualRefresh|requestRefresh|refreshFromFirebase|RefreshPolicy|_lastSyncMs/.test(code.replace(/app\.requestManualRefresh/g, ''))) add(p + ': a page must reach the refresh only through app.requestManualRefresh()');
  }

  // the row: props + one signal, nothing else from the app, no animation of its own
  const row = strip(f.row);
  for (const t of ['property real lastSyncMs', 'property bool online', 'property string refreshState', 'signal refreshRequested()'])
    if (!row.includes(t)) add('RefreshRow lacks: ' + t);
  if (/OrdersStore|InventoryStore|StaffStore|DataModel|AuthService|AuthStore|Gateway|OutboxStore|LockManager|app\./.test(row)) add('RefreshRow must read nothing but its props');
  if (!row.includes('import "../helper/RefreshCaption.js" as RefreshCaption')) add('RefreshRow must import RefreshCaption.js');
  if (!/RefreshCaption\.view\(\{[^}]*online: root\.online[^}]*state: root\.refreshState[^}]*lastSyncMs: root\.lastSyncMs[^}]*nowMs: root\._now/.test(row.replace(/\n\s*/g, ' '))) add('RefreshRow must build its view from the four inputs');
  if (!/Accessible\.role: Accessible\.Button/.test(row) || !/Accessible\.name: RefreshCaption\.accessibleName\(root\._view\)/.test(row)) add('RefreshRow lacks its accessible role and name');
  if (!/Accessible\.onPressAction: if \(root\._view\.enabled\) root\.refreshRequested\(\)/.test(row)) add('the accessible press must honour enabled');
  if (!/MouseArea \{\s*anchors\.fill: parent\s*enabled: root\._view\.enabled\s*onClicked: root\.refreshRequested\(\)/.test(row)) add('the whole row must be the tap target, enabled only when the view says so');
  if (!/implicitHeight: dp\(48\)/.test(row)) add('the row must be 48 dp high');
  if (!/elide: Text\.ElideRight[\s\S]*Layout\.maximumWidth: Math\.max\(0, root\.width/.test(row)) add('the text must have a width cap, or elide never fires inside the RowLayout (review of #186)');
  if (!/Timer \{\s*interval: 30000\s*repeat: true\s*running: root\.visible\s*onTriggered: root\._tick\(\)/.test(row)) add('the age timer must tick every 30 s and only while visible');
  if (!/onLastSyncMsChanged: _tick\(\)/.test(row) || !/onVisibleChanged: if \(visible\) _tick\(\)/.test(row) || !/onRefreshStateChanged: _tick\(\)/.test(row)) add('the age must refresh on sync, state change and becoming visible');
  if (/Animation|Animator|Behavior on|SequentialAnimation/.test(row)) add('no animation of its own (reduced motion): only the BusyIndicator moves, and only while busy');
  if (!/QQC\.BusyIndicator \{[^}]*running: root\._view\.busy/.test(row.replace(/\n\s*/g, ' '))) add('the spinner must run only while the view is busy');

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

test('refresh row wiring: every rule holds on the real files', () => { assert.deepEqual(check(snapshot()), []); });

test('refresh row wiring: the pages with the row are exactly the five whose data the refresh covers', () => {
  const dir = fs.readdirSync(path.join(REPO, 'qml/pages')).filter((n) => n.endsWith('.qml'));
  const carrying = dir.filter((n) => rd('qml/pages/' + n).includes('RefreshRow')).map((n) => n.replace('Page.qml', '')).sort();
  assert.deepEqual(carrying, [...WITH_ROW].sort());
});

// ── hand mutants: each must make some rule fail ──────────────────────────────────────────────────────────────
const MUT = [
  ['a page loses the row', (f) => { f['page:Orders'] = f['page:Orders'].replace(ROW_BLOCK, '\n'); }],
  ['a page wires lastSyncMs differently', (f) => { f['page:Staff'] = f['page:Staff'].replace('lastSyncMs: app.refreshLastSyncMs', 'lastSyncMs: 0'); }],
  ['a page skips the online input', (f) => { f['page:Sales'] = f['page:Sales'].replace('                online: app.isOnline\n', ''); }],
  ['a page calls DataModel directly', (f) => { f['page:Inventory'] = f['page:Inventory'].replace('app.requestManualRefresh()', 'dataModel.manualRefresh()'); }],
  ['the Activity page gains the row', (f) => { f['page:Activity'] = f['page:Activity'].replace('ColumnLayout {', 'RefreshRow {}\n ColumnLayout {'); }],
  ['the row moves below the first item', (f) => { f['page:Dashboard'] = f['page:Dashboard'].replace(ROW_BLOCK, '\n').replace('// ── KPI grid (2×2) ──', '// ── KPI grid (2×2) ──' + '\n            RefreshRow {\n                Layout.fillWidth: true\n                Layout.topMargin: dp(Constants.space2)\n                lastSyncMs: app.refreshLastSyncMs\n                refreshState: app.refreshState\n                online: app.isOnline\n                onRefreshRequested: app.requestManualRefresh()\n            }'); }],
  ['the item after the row keeps its top margin', (f) => { f['page:Orders'] = f['page:Orders'].replace('                Layout.fillWidth: true\n                Layout.leftMargin: dp(Constants.space4)', '                Layout.topMargin: dp(Constants.space3)\n                Layout.fillWidth: true\n                Layout.leftMargin: dp(Constants.space4)'); }],
  ['the row reads a store', (f) => { f.row = f.row.replace('property real _now: Date.now()', 'property real _now: Date.now() + OrdersStore.revision'); }],
  ['the row reads app', (f) => { f.row = f.row.replace('property bool online: true', 'property bool online: app.isOnline'); }],
  ['the row bypasses the helper', (f) => { f.row = f.row.replace('RefreshCaption.view({', 'Object({'); }],
  ['the row is not a button', (f) => { f.row = f.row.replace('Accessible.role: Accessible.Button', 'Accessible.role: Accessible.StaticText'); }],
  ['a disabled row can be pressed by a screen reader', (f) => { f.row = f.row.replace('if (root._view.enabled) root.refreshRequested()', 'root.refreshRequested()'); }],
  ['the tap target ignores the view', (f) => { f.row = f.row.replace('enabled: root._view.enabled\n        onClicked', 'onClicked'); }],
  ['the row is too small', (f) => { f.row = f.row.replace('implicitHeight: dp(48)', 'implicitHeight: dp(32)'); }],
  ['the timer runs while hidden', (f) => { f.row = f.row.replace('running: root.visible', 'running: true'); }],
  ['the timer is slower', (f) => { f.row = f.row.replace('interval: 30000', 'interval: 300000'); }],
  ['the row gains an animation', (f) => { f.row = f.row.replace('Timer {', 'NumberAnimation on opacity { from: 0; to: 1 }\n    Timer {'); }],
  ['the spinner runs always', (f) => { f.row = f.row.replace('running: root._view.busy', 'running: true'); }],
  ['Main drops the toast on a refusal', (f) => { f.main = f.main.replace('if (msg.length > 0) Toast.show(msg)\n    }', '}'); }],
  ['RefreshRow text loses its width cap (review #186)', (f) => { f.row = f.row.replace('Layout.maximumWidth: Math.max(0, root.width', 'Layout.minimumWidth: Math.max(0, root.width'); }],
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
for (const [name, fn] of MUT) test('refresh row wiring mutant killed: ' + name, () => {
  const f = snapshot(); const before = JSON.stringify(f); fn(f);
  assert.notEqual(JSON.stringify(f), before, 'mutation did not change anything (stale anchor)');
  assert.ok(check(f).length > 0, 'no rule noticed this mutant');
});
