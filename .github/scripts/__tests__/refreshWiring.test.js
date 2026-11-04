'use strict';

// L4a wiring pins: source-level rules that keep the non-blanking refresh safe as the code changes. Each rule is
// a function over the source texts, run against the real files and against hand mutants. No Qt needed.
// Design: docs/superpowers/specs/2026-11-02-l4a-resume-refresh-design.md.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..', '..');
const rd = (p) => fs.readFileSync(path.join(REPO, p), 'utf8');
const STORE_FILES = {
  OrdersStore: 'qml/model/OrdersStore.qml', InventoryStore: 'qml/model/InventoryStore.qml', StockBatchStore: 'qml/model/StockBatchStore.qml',
  SupplierStore: 'qml/model/SupplierStore.qml', StaffStore: 'qml/model/StaffStore.qml', TransactionStore: 'qml/model/TransactionStore.qml',
};
const LISTS = { OrdersStore: 'orders', InventoryStore: 'products', StockBatchStore: 'batches', SupplierStore: 'suppliers', StaffStore: 'staff', TransactionStore: 'entries' };

function body(src, name) {
  const at = src.indexOf('function ' + name + '(');
  if (at < 0) return null;
  const open = src.indexOf('{', src.indexOf(')', at));
  let depth = 0, i = open;
  for (; i < src.length; i++) { if (src[i] === '{') depth++; else if (src[i] === '}' && --depth === 0) break; }
  return src.substring(open + 1, i);
}

function snapshot() {
  const o = {};
  for (const [k, p] of Object.entries(STORE_FILES)) o[k] = rd(p);
  o.dm = rd('qml/model/DataModel.qml'); o.main = rd('qml/Main.qml'); o.lock = rd('qml/model/LockManager.qml');
  o.auth = rd('qml/model/AuthService.qml'); o.policy = rd('qml/helper/RefreshPolicy.js');
  o.sheet = rd('qml/components/BottomSheet.qml');
  o.pages = {}; for (const e of fs.readdirSync(path.join(REPO, 'qml/pages'))) if (/\.qml$/.test(e)) o.pages[e] = rd('qml/pages/' + e);
  return o;
}

// Returns the list of violated rules (empty = wiring is as designed).
function check(f) {
  const v = [];
  for (const k of Object.keys(STORE_FILES)) {
    const s = f[k]; const list = LISTS[k];
    const page = body(s, '_refreshPage'), commit = body(s, '_commitRefresh'), start = body(s, 'refreshFromFirebase');
    const fin = body(s, '_finishRefresh'), cancel = body(s, '_cancelRefresh');
    if (!page || !commit || !start || !fin || !cancel) { v.push(k + ': refresh functions missing'); continue; }
    if (!/property bool refreshing: false/.test(s)) v.push(k + ': refreshing property');
    if (!/property int _refreshSeq: 0/.test(s)) v.push(k + ': _refreshSeq property');
    // the paging function never touches live state: no list, no hasMore, no cursor, no loadingMore, no revision
    if (new RegExp('(^|[^_\\w.])' + list + '\\s*=[^=]').test(page)) v.push(k + ': _refreshPage assigns the live list');
    if (page.includes('revision')) v.push(k + ': _refreshPage touches revision');
    if (/(^|[^.\w])loadingMore\s*=[^=]/.test(page)) v.push(k + ': _refreshPage assigns loadingMore');
    // review F1: a load that started during the refresh blocks the swap (READ only), and the check sits before the guard
    if (!/if \(loadingMore \|\| _resetPending\) \{ _finishRefresh\(\"discarded\"\); return \}/.test(page) || page.indexOf('loadingMore ||') > page.indexOf('allowed')) v.push(k + ': no busy check before the guard');
    for (const bad of ['hasMore', '_cursor']) if (new RegExp('(^|[^.\\w])' + bad + '\\s*=[^=]').test(page)) v.push(k + ': _refreshPage assigns ' + bad);
    if (!/if \(seq !== _refreshSeq\) return\s*\n\s*if \(!ok/.test(page)) v.push(k + ': stale answer is not ignored first');
    if (!/typeof guard === "function"\) \? guard\(\) === true : false/.test(page) || !/catch \(e\) \{ allowed = false \}/.test(page)) v.push(k + ': guard not strict/try-wrapped');
    if (!/_finishRefresh\("failed"\)/.test(page) || !/_finishRefresh\("discarded"\)/.test(page) || !/_finishRefresh\("committed"\)/.test(page)) v.push(k + ': missing outcome');
    if (page.indexOf('_commitRefresh(') < page.indexOf('allowed')) v.push(k + ': commits before the guard');
    // the live list is assigned only in commit
    if (!new RegExp('(^|\\s)' + list + ' = ').test(commit)) v.push(k + ': commit does not assign the list');
    if (!/hasMore = false/.test(commit)) v.push(k + ': commit leaves hasMore');
    // start: refuses while busy; bumps seq; stores done
    if (!/refreshing \|\| loadingMore \|\| _resetPending\) return false/.test(start)) v.push(k + ': start does not refuse while busy');
    if (!/\+\+_refreshSeq/.test(start)) v.push(k + ': start does not bump the sequence');
    // cancel: only when running, bumps seq BEFORE answering
    if (!/if \(!refreshing\) return/.test(cancel) || cancel.indexOf('_refreshSeq++') < 0 || cancel.indexOf('_refreshSeq++') > cancel.indexOf('_finishRefresh')) v.push(k + ': cancel order');
    if (!/_refreshDone = null/.test(fin) || fin.indexOf('_refreshDone = null') < 0 || fin.indexOf('_refreshDone = null') > fin.indexOf('d(kind)')) v.push(k + ': done not cleared before it is called');
    // a reset and a clear both cancel a running refresh first
    for (const fn of ['_resetAndFetch', 'clear']) {
      const b = body(s, fn);
      if (!b || b.replace(/\s/g, '').indexOf('_cancelRefresh()') !== 0) v.push(k + ': ' + fn + ' does not cancel first');
    }
    // exactly one place starts a refresh and it is not a UI file (checked below)
  }
  if (!/if \(_retryTimer\) _retryTimer\.stop\(\)/.test(body(f.TransactionStore, '_commitRefresh') || '')) v.push('TransactionStore: commit does not stop the retry timer');
  // coordinator
  const dm = f.dm;
  const snapBody = body(dm, '_refreshSnapshot') || '';
  const policyKeys = [...new Set([...f.policy.matchAll(/snap\.(\w+)/g)].map(m => m[1]))].sort();
  const dmKeys = [...new Set([...snapBody.matchAll(/^\s+(\w+):/gm)].map(m => m[1]))].sort();
  if (JSON.stringify(policyKeys) !== JSON.stringify(dmKeys)) v.push('snapshot keys differ: policy ' + policyKeys + ' vs DataModel ' + dmKeys);
  for (const [key, src] of [['outboxPending', 'OutboxStore.items.length'], ['outboxRevision', 'OutboxStore.revision'], ['gatewayInFlight', 'Gateway.inFlight'],
    ['lockHeld', 'LockManager.anyHeld'], ['editOpen', 'LockManager.anyEditing'], ['photoPending', 'PhotoQueue.pendingCount'], ['sessionOpen', 'AuthService.isSessionOpen()'], ['accessBlock', 'AuthService.accessBlock']])
    if (!new RegExp(key + ':\\s*' + src.replace(/[().]/g, '\\$&')).test(snapBody)) v.push('snapshot ' + key + ' not read from ' + src);
  if (!/checking: AuthService\.checking === true \|\| AuthService\.tokenNeedsRefresh\(\)/.test(snapBody)) v.push('snapshot: token expiry not part of checking');
  if (!/_cancelLostRun\(now\)/.test(body(dm, '_request') || '') || !/_cancelLostRun\(now\)/.test(body(dm, '_pollWant') || '')) v.push('watchdog not run by both entry points');
  if (!/RefreshPolicy\.runLost\(_lastRefreshStartMs, now\)\) return/.test(body(dm, '_cancelLostRun') || '') || !/_cancelRefresh\(\)/.test(body(dm, '_cancelLostRun') || '')) v.push('watchdog body');
  const list = body(dm, '_refreshStoreList') || '';
  for (const k of Object.keys(STORE_FILES)) if (!list.includes(k)) v.push('coordinator list lacks ' + k);
  const start = body(dm, '_startRefresh') || '';
  if (!/var rev = OutboxStore\.revision/.test(start)) v.push('start: revision not captured');
  if (start.indexOf('_refreshOutstanding = stores.length') < 0 || start.indexOf('_refreshOutstanding = stores.length') > start.indexOf('refreshFromFirebase')) v.push('start: outstanding not counted up front');
  if (!/RefreshPolicy\.swapOk\(rev, _refreshSnapshot\(\)\)/.test(start)) v.push('start: guard is not swapOk on a fresh snapshot');
  if (!/if \(all\) _lastSyncMs = Date\.now\(\)/.test(body(dm, '_onStoreRefreshed') || '')) v.push('lists marked current without all committed');
  if (!/onTenantContextReady/.test(dm) || !/onSignedOut/.test(dm) || !/onIsOnlineChanged/.test(dm)) v.push('coordinator connections missing');
  if (!/function onSignedOut\(\) \{\s*dataModel\._clearWant\(\)\s*dataModel\._lastSyncMs = 0/.test(dm)) v.push('sign-out does not reset the coordinator');
  // triggers: the resume hook asks, nothing else starts a refresh
  if (!/Qt\.application\.state === Qt\.ApplicationActive\) \{[\s\S]*?AuthService\.onAppResumed\(\)[\s\S]*?dataModel\.requestRefresh\("resume"\)/.test(f.main)) v.push('Main: resume hook');
  if (!/readonly property bool anyHeld: _held !== null/.test(f.lock)) v.push('LockManager.anyHeld');
  if (!/function isSessionOpen\(\) \{ return _sessionOpen\(\) \}/.test(f.auth) || !/function tokenNeedsRefresh\(\) \{ return _tokenExpiring\(\) \}/.test(f.auth)) v.push('AuthService readers');
  // edit forms hold the refresh (L4-D10): counter, base sheet hook, the nine opt-in forms and nobody else, sign-out reset, close trigger
  if (!/readonly property bool anyEditing: editHolds > 0/.test(f.lock) || !/function holdForEdit\(\) \{ editHolds\+\+ \}/.test(f.lock) || !/function releaseEdit\(\) \{ if \(editHolds > 0\) editHolds-- \}/.test(f.lock) || !/function resetEditHolds\(\) \{ editHolds = 0 \}/.test(f.lock)) v.push('LockManager edit-hold counter');
  const sh = f.sheet;
  if (!/property bool holdsRefresh: false/.test(sh) || !/if \(on === _holding\) return/.test(sh)) v.push('BottomSheet: holdsRefresh / idempotent hold');
  if (!/aboutToShow\.connect\(function\(\) \{ root\._setHold\(root\.holdsRefresh\) \}\)/.test(sh) || !/closed\.connect\(function\(\) \{ root\._setHold\(false\) \}\)/.test(sh)) v.push('BottomSheet: hold not taken on show / released on close');
  if (!/Component\.onDestruction: _setHold\(false\)/.test(sh)) v.push('BottomSheet: no release on destruction');
  if (!/LockManager\.holdForEdit\(\)/.test(sh) || !/LockManager\.releaseEdit\(\)/.test(sh)) v.push('BottomSheet: does not call the counter');
  const FORMS = ['AddProductDialog', 'EditProductDialog', 'NewOrderDialog', 'OrderDetailDialog', 'RestockDialog', 'AddStaffDialog', 'StaffDetailDialog', 'ImportPreviewDialog', 'ConfirmReturnSheet'].map(n => n + '.qml');
  for (const n of Object.keys(f.pages)) {
    const has = /^\s*holdsRefresh:\s*true/m.test(f.pages[n]);
    if (FORMS.includes(n) && !has) v.push(n + ': edit form does not hold the refresh');
    if (!FORMS.includes(n) && has) v.push(n + ': holds the refresh but is not on the edit-form list');
  }
  for (const n of FORMS) if (!(n in f.pages)) v.push(n + ': listed form is missing');
  if (!/function _onEditHoldsChanged\(\) \{ if \(LockManager\.editHolds === 0\) requestRefresh\("resume"\) \}/.test(dm) || !/target: LockManager\s*function onEditHoldsChanged\(\) \{ dataModel\._onEditHoldsChanged\(\) \}/.test(dm)) v.push('DataModel: close trigger');
  if (!/dataModel\._lastSyncMs = 0\s*LockManager\.resetEditHolds\(\)/.test(dm)) v.push('DataModel: sign-out does not reset the edit holds');
  // purity of the helper
  if (/\bQt\b|^import |Date\.now|Math\.random/m.test(f.policy.replace(/\/\/.*$/gm, ''))) v.push('RefreshPolicy is not pure');
  return v;
}

function allQmlCallers() {
  const out = [];
  const walk = (d) => { for (const e of fs.readdirSync(path.join(REPO, d), { withFileTypes: true })) {
    const p = d + '/' + e.name; if (e.isDirectory()) walk(p); else if (/\.qml$/.test(e.name)) out.push(p); } };
  walk('qml');
  return out.filter(p => /\.refreshFromFirebase\(/.test(rd(p)) && !/qml\/model\/DataModel\.qml$/.test(p));
}

test('the real files satisfy every wiring rule', () => { assert.deepEqual(check(snapshot()), []); });

test('only DataModel starts a refresh (no page or other store calls refreshFromFirebase)', () => { assert.deepEqual(allQmlCallers(), []); });

const rep = (key, from, to) => ['mutate ' + key + ': ' + from.slice(0, 40), (f) => { assert.ok(f[key].includes(from), 'anchor: ' + from); f[key] = f[key].replace(from, to); }];
const MUT = [
  rep('OrdersStore', 'if (seq !== _refreshSeq) return\n', ''),
  rep('InventoryStore', 'allowed = (typeof guard === "function") ? guard() === true : false', 'allowed = true'),
  rep('SupplierStore', '_commitRefresh(next, result.nextCursor)\n            _finishRefresh("committed")', '_finishRefresh("committed")'),
  rep('StaffStore', 'if (refreshing || loadingMore || _resetPending) return false', 'if (refreshing) return false'),
  rep('TransactionStore', '        _refreshSeq++\n        _finishRefresh("superseded")', '        _finishRefresh("superseded")'),
  rep('StockBatchStore', '_refreshDone = null\n        if (typeof d', 'if (typeof d'),
  rep('OrdersStore', 'startAfter: cursor }, function(ok, result) {\n            if (seq', 'startAfter: cursor }, function(ok, result) {\n            loadingMore = false\n            if (seq'),
  rep('InventoryStore', '    function clear() {\n        _cancelRefresh()\n', '    function clear() {\n'),
  rep('SupplierStore', '    function _resetAndFetch() {\n        _cancelRefresh()\n', '    function _resetAndFetch() {\n'),
  rep('dm', 'checking: AuthService.checking === true || AuthService.tokenNeedsRefresh()', 'checking: AuthService.checking === true'),
  rep('dm', 'lockHeld: LockManager.anyHeld,', 'lockHeld: false,'),
  rep('dm', 'photoPending: PhotoQueue.pendingCount', 'photoPending: 0'),
  rep('dm', 'if (all) _lastSyncMs = Date.now()', '_lastSyncMs = Date.now()'),
  rep('dm', 'var rev = OutboxStore.revision', 'var rev = 0'),
  rep('dm', 'dataModel._clearWant()\n            dataModel._lastSyncMs = 0', 'dataModel._clearWant()'),
  rep('dm', 'return [OrdersStore, InventoryStore, StockBatchStore, SupplierStore, StaffStore, TransactionStore]', 'return [OrdersStore, InventoryStore, StockBatchStore, SupplierStore, StaffStore]'),
  rep('dm', '        _cancelLostRun(now)\n        var d = RefreshPolicy.decide(trigger', '        var d = RefreshPolicy.decide(trigger'),
  rep('dm', 'for (var i = 0; i < stores.length; ++i) stores[i]._cancelRefresh()', 'void 0'),
  rep('main', 'dataModel.requestRefresh("resume")', 'void 0'),
  rep('lock', 'readonly property bool anyHeld: _held !== null', 'readonly property bool anyHeld: false && _held !== null'),
  rep('auth', 'function tokenNeedsRefresh() { return _tokenExpiring() }', 'function tokenNeedsRefresh() { return false }'),
  rep('policy', 'var STALE_MS = 300000', 'var STALE_MS = 300000\nvar t = Date.now()'),
  rep('dm', 'editOpen: LockManager.anyEditing,', 'editOpen: false,'),
  rep('dm', '            LockManager.resetEditHolds()\n', ''),
  rep('dm', 'if (LockManager.editHolds === 0) requestRefresh("resume")', 'requestRefresh("resume")'),
  rep('dm', 'function onEditHoldsChanged() { dataModel._onEditHoldsChanged() }', 'function onEditHoldsChanged() { }'),
  rep('lock', 'function releaseEdit() { if (editHolds > 0) editHolds-- }', 'function releaseEdit() { editHolds-- }'),
  rep('lock', 'readonly property bool anyEditing: editHolds > 0', 'readonly property bool anyEditing: false'),
  rep('sheet', 'closed.connect(function() { root._setHold(false) })', 'void 0'),
  rep('sheet', 'aboutToShow.connect(function() { root._setHold(root.holdsRefresh) })', 'void 0'),
  rep('sheet', '    Component.onDestruction: _setHold(false)', ''),
  rep('sheet', 'if (on === _holding) return', 'if (false) return'),
  rep('OrdersStore', 'if (loadingMore || _resetPending) { _finishRefresh("discarded"); return }', ''),
  rep('TransactionStore', 'if (loadingMore || _resetPending) { _finishRefresh("discarded"); return }', ''),
  rep('StaffStore', 'if (loadingMore || _resetPending) { _finishRefresh("discarded"); return }', 'if (loadingMore) { _finishRefresh("discarded"); return }'),
  rep('InventoryStore', '            if (loadingMore || _resetPending) { _finishRefresh("discarded"); return }\n            var allowed = false\n', '            var allowed = false\n'),
  rep('TransactionStore', 'if (_retryTimer) _retryTimer.stop()   // the list is complete now', 'void 0   // the list is complete now'),
];
for (const [name, fn] of MUT) test('wiring mutant killed: ' + name, () => { const f = snapshot(); fn(f); assert.ok(check(f).length > 0, 'not noticed'); });

test('wiring mutant killed: an edit form loses its holdsRefresh opt-in', () => {
  for (const n of ['AddProductDialog.qml', 'EditProductDialog.qml', 'NewOrderDialog.qml', 'OrderDetailDialog.qml', 'RestockDialog.qml', 'AddStaffDialog.qml', 'StaffDetailDialog.qml', 'ImportPreviewDialog.qml', 'ConfirmReturnSheet.qml']) {
    const f = snapshot(); assert.ok(/holdsRefresh: true/.test(f.pages[n]), 'anchor ' + n);
    f.pages[n] = f.pages[n].replace(/holdsRefresh: true/, 'holdsRefresh: false'); assert.ok(check(f).length > 0, n);
  }
});

test('wiring mutant killed: a read-only sheet starts holding the refresh', () => {
  for (const n of ['FilterSheet.qml', 'ExportSheet.qml', 'NotificationsSheet.qml', 'SignOutSheet.qml', 'StuckWritesSheet.qml', 'StaffActionSheet.qml', 'AnalysisFilterSheet.qml']) {
    const f = snapshot(); assert.ok(n in f.pages, 'anchor ' + n);
    f.pages[n] = f.pages[n] + '\n    holdsRefresh: true\n'; assert.ok(check(f).length > 0, n);
  }
});
