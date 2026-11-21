'use strict';

// P1 S4b-2: wiring of qml/pages/StockRegisterPage.qml, the Profile row and the Main overlay.
// A Felgo page cannot load under qmltestrunner, so (Skill 155 rule 6, Skill 156 rule 4) the page's REAL function
// bodies run here in a vm against the real helpers, a scripted fake service and a fake ListModel; the rest is
// pinned by source scans. What no Node test can prove (painting, scroll, the Back key) is on the device list of
// the test plan.
// Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md section 8
// Test plan: docs/superpowers/test-plans/2026-11-20-p1-s4b2-register-page-test-plan.md

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { load, extractFunction } = require(path.join('..', '..', '..', 'functions', 'test', 'testSupport', 'qmlHelpers.js'));

const REPO = path.resolve(__dirname, '..', '..', '..');
const rd = (rel) => fs.readFileSync(path.join(REPO, rel), 'utf8');
const PAGE = rd('qml/pages/StockRegisterPage.qml');
const ROW = rd('qml/components/StockRegisterRow.qml');
const MAIN = rd('qml/Main.qml');
const PROFILE = rd('qml/pages/ProfilePage.qml');
const GLUE_SRC = rd('qml/helper/StockRegisterPage.js');
const Glue = load('StockRegisterPage.js');
const Model = load('StockRegisterModel.js');
const plain = (v) => JSON.parse(JSON.stringify(v));
const OFF = 19800000;
const at = (y, m0, d, h, mi) => Date.UTC(y, m0, d, h || 0, mi || 0) - OFF;
const NOW = at(2026, 10, 20, 15, 42);
const noComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');

// ---- static pins -------------------------------------------------------------------------------------------------

test('SRW-01 the page imports the helper by name and nothing else it does not use', () => {
  assert.match(PAGE, /^import "\.\.\/helper\/StockRegisterPage\.js" as Glue$/m);
  // Skill 156 rule 1: every capitalised helper namespace used is imported (the tree guard also scans this file).
  assert.match(ROW, /^import "\.\.\/helper\/StockRegisterPage\.js" as Glue$/m);
  assert.ok(!/\bStockRegisterModel\./.test(noComments(PAGE)) && !/\bStockRegisterModel\./.test(noComments(ROW)), 'the page decides through Glue; the engine stays behind it');
});

test('SRW-02 every Glue name the page uses is exported by the helper', () => {
  const used = [...new Set([...noComments(PAGE + ROW).matchAll(/\bGlue\.(\w+)/g)].map((m) => m[1]))].sort();
  assert.ok(used.length >= 15, 'found ' + used.length);
  for (const n of used) assert.ok(n in Glue, n + ' is not exported by StockRegisterPage.js');
});

test('SRW-03 the row component declares exactly the ListModel roles, in order, and no reserved word; the page delegate adds only what the row lets it', () => {
  const names = [...ROW.matchAll(/required property (?:string|bool|int|real|var) (\w+)/g)].map((m) => m[1]);
  // The first nine are the row's roles; later ones belong to the small nested delegates (modelData).
  assert.deepEqual(names.slice(0, Glue.ROW_KEYS.length), plain(Glue.ROW_KEYS));
  assert.ok(!Glue.ROW_KEYS.includes('id') && !Glue.ROW_KEYS.includes('enabled'));
  assert.deepEqual(names.slice(Glue.ROW_KEYS.length), ['modelData', 'modelData']);
  assert.match(PAGE, /delegate: StockRegisterRow \{[^}]*open: root\.expandedId === productId[^}]*detail: Glue\.detailRows\(root\._body, root\.expandedId, productId\)[^}]*onToggled: function\(id\) \{ root\._toggleRow\(id\) \}/s);
  assert.ok(!/required property/.test(noComments(PAGE).replace(/required property string modelData/g, '')), 'no role is declared twice');
  assert.match(ROW, /signal toggled\(string productId\)/);
  assert.equal((noComments(ROW).match(/row\.toggled\(row\.productId\)/g) || []).length, 2, 'tap and the accessibility press action');
});

test('SRW-04 on demand only: one load call, in the tap function; no timer, no auto-load hook', () => {
  const code = noComments(PAGE);
  assert.equal((code.match(/StockRegisterService\.load\(/g) || []).length, 1);
  assert.ok(extractFunction('pages/StockRegisterPage.qml', '_loadTapped').includes('StockRegisterService.load('));
  for (const bad of [/\bTimer\b/, /Component\.onCompleted/, /onVisibleChanged/, /onOpened/, /aboutToShow/, /Qt\.callLater/, /\bsetInterval\b/, /\bsetTimeout\b/]) {
    assert.ok(!bad.test(code), String(bad));
  }
  assert.match(code, /PrimaryButton \{[^}]*onClicked: root\._loadTapped\(\)/s);
  assert.match(code, /enabled: !root\._busy && root\._resolved\.ok/);
});

test('SRW-05 the single latch is the service flag: the page keeps no second busy flag', () => {
  assert.match(PAGE, /readonly property bool _busy: StockRegisterService\.loading/);
  assert.ok(!/property bool (?:_?loading|_?tapLatch|_?inFlight)/.test(PAGE));
});

test('SRW-06 chips and the custom fields are off while a load runs (the answer belongs to the period sent)', () => {
  assert.match(PAGE, /ChipScroller \{[^}]*enabled: !root\._busy/s);
  assert.match(PAGE, /visible: root\.chipIndex === Glue\.CUSTOM_INDEX\s*\n\s*enabled: !root\._busy/);
});

test('SRW-07 the page resets on a workspace or role change, cancelling before it clears', () => {
  assert.match(PAGE, /target: AuthStore\s*\n\s*function onTenantIdChanged\(\) \{ root\._resetAll\(\) \}\s*\n\s*function onRoleChanged\(\) \{ root\._resetAll\(\) \}/);
  const body = extractFunction('pages/StockRegisterPage.qml', '_resetAll');
  assert.ok(body.indexOf('StockRegisterService.cancel()') < body.indexOf('StockRegisterService.clear()'));
});

test('SRW-08 a custom field edit goes through one function and cannot loop on a reset', () => {
  assert.equal((PAGE.match(/onTextChanged: \{ if \(root\.(?:from|to)Text !== text\)/g) || []).length, 2);
});

test('SRW-09 Profile: a role-gated row emits the signal; Main closes Profile then opens the overlay', () => {
  assert.match(PROFILE, /signal stockRegisterRequested\(\)/);
  assert.match(PROFILE, /import "\.\.\/helper\/StockRegisterModel\.js" as StockRegisterModel/);
  assert.match(PROFILE, /SettingsRow \{ iconName: "report"; label: "Stock register"; onClicked: root\.stockRegisterRequested\(\); visible: StockRegisterModel\.canView\(AuthStore\.role\) \}/);
  assert.match(MAIN, /onStockRegisterRequested: \{\s*close\(\)\s*stockRegisterOverlay\.open\(\)\s*\}/);
});

test('SRW-10 Main: every way out and every way a role can lose the page is covered', () => {
  assert.match(MAIN, /import "helper\/StockRegisterModel\.js" as StockRegisterModel/);
  assert.match(MAIN, /if \(stockRegisterOverlay\.visible\) stockRegisterOverlay\.close\(\)\s*\n\s*if \(activityPageOverlay\.visible\) activityPageOverlay\.close\(\)/);   // workspace change
  assert.match(MAIN, /if \(stockRegisterOverlay\.visible\) \{ stockRegisterOverlay\.close\(\); return \}/);                                                            // Back
  assert.match(MAIN, /if \(!StockRegisterModel\.canView\(role\)\) stockRegisterOverlay\.close\(\)/);                                                                    // role lost
  assert.match(MAIN, /&& !stockRegisterOverlay\.visible/);                                                                                                              // tabbar hidden
  assert.match(MAIN, /id: stockRegisterOverlay[\s\S]*?target: navigation\s*\n\s*function onCurrentIndexChanged\(\) \{ stockRegisterOverlay\.close\(\) \}/);           // tab change
  assert.match(MAIN, /StockBatchStore\.clear\(\)\s*\n[^\n]*\n\s*StockRegisterService\.clear\(\)/);                                                                      // sign-out
  assert.match(MAIN, /id: stockRegisterOverlay\s*\n\s*anchors\.fill: parent\s*\n\s*z: 200/);
  assert.match(MAIN, /isOnline: app\.isOnline/);
});

test('SRW-11 Back order: the register closes after Profile and staff, before Activity (same family, one list)', () => {
  const back = extractFunction('Main.qml', '_handleBack');
  const i = (s) => back.indexOf(s);
  assert.ok(i('profilePage.visible') < i('staffPageOverlay.visible') && i('staffPageOverlay.visible') < i('stockRegisterOverlay.visible') && i('stockRegisterOverlay.visible') < i('activityPageOverlay.visible'));
});

test('SRW-12 not a fifth tab: the navigation still has four items', () => {
  assert.equal((MAIN.match(/NavigationItem \{/g) || []).length, 4);
});

test('SRW-13 dormancy REPLACED by the real callers (Skill 155 rule 8): exactly these files name the service and the model', () => {
  const walk = (d, out) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    if (['node_modules', '.git', 'docs', 'functions', 'test', 'tests', '.github'].includes(e.name)) continue;
    const p = path.join(d, e.name); if (e.isDirectory()) walk(p, out); else if (/\.(qml|js)$/.test(e.name)) out.push(p); } return out; };
  const files = walk(REPO, []).map((f) => path.relative(REPO, f));
  const naming = (re) => files.filter((f) => re.test(noComments(rd(f)))).sort();
  assert.deepEqual(naming(/StockRegisterService/).filter((f) => f !== 'qml/model/StockRegisterService.qml' && f !== 'qml/model/qmldir'), ['qml/Main.qml', 'qml/pages/StockRegisterPage.qml']);
  assert.deepEqual(naming(/StockRegisterModel/).filter((f) => f !== 'qml/helper/StockRegisterModel.js' && f !== 'qml/model/StockRegisterService.qml'), ['qml/Main.qml', 'qml/helper/StockRegisterPage.js', 'qml/pages/ProfilePage.qml']);
  assert.deepEqual(naming(/StockRegisterPage/), ['qml/Main.qml', 'qml/components/StockRegisterRow.qml', 'qml/pages/StockRegisterPage.qml']);
});

// ---- the page's real function bodies in a sandbox ----------------------------------------------------------------

const FN = ['_applyState', '_refreshNow', '_periodChanged', '_chipPicked', '_showAllToggled', '_toggleRow', '_loadTapped', '_answered', '_cancelTapped', '_resetAll'];

function makeSvc() {
  const s = { loading: false, calls: [], attempts: 0, cancels: 0, clears: 0, order: [], cache: {}, throwOnLoad: false, pending: null };
  s.cached = (win) => s.cache[Model.windowKey(win)] || null;
  s.load = (win, cb) => {
    s.attempts++;
    if (s.throwOnLoad) throw new Error('boom');
    if (s.loading) { cb({ ok: false, kind: 'busy', message: '', retryable: true }); return false; }
    s.calls.push({ win, cb }); s.loading = true; s.pending = { win, cb }; return true;
  };
  s.answer = (result) => { const p = s.pending; s.pending = null; s.loading = false; if (result.ok) s.cache[Model.windowKey(p.win)] = { body: result.body, window: p.win }; p.cb(result); };
  s.cancel = () => { s.cancels++; s.order.push('cancel'); if (s.loading) { const p = s.pending; s.pending = null; s.loading = false; p.cb({ ok: false, kind: 'cancelled', message: '', retryable: true }); } };
  s.clear = () => { s.clears++; s.order.push('clear'); s.cache = {}; };
  return s;
}

function makePage(src, over) {
  const svc = makeSvc();
  const regModel = { rows: [], clear() { this.rows = []; }, append(r) { this.rows.push(r); }, get count() { return this.rows.length; } };
  const scope = Object.assign({
    Glue, StockRegisterService: svc, AuthStore: { role: 'owner', tenantId: 't1' }, regModel, console: { warn() {} }, Date: { now: () => NOW },
    chipIndex: 0, fromText: '', toText: '', showAll: false, expandedId: '', status: 'idle', errorText: '', errorRetryable: true,
    summary: null, shownWin: null, _body: null, _warnings: [], _nowMs: NOW, isOnline: true
  }, over || {});
  scope.root = scope;
  const texts = FN.map((n) => extractFunction('pages/StockRegisterPage.qml', n));
  const code = src === undefined ? texts.join('\n') : src;
  const api = new Function('scope', `with(scope){ ${code}\n return {${FN.map((n) => `${n}:${n}`).join(',')}} }`)(scope);
  for (const n of FN) scope[n] = api[n];
  return { page: scope, svc, regModel };
}

function product(over) { return Object.assign({ productId: 'p-abcdef123', name: 'Silk Saree', deleted: false, opening: 10, kinds: { sale: { in: 0, out: 3 }, receipt: { in: 5, out: 0 } },
  inTotal: 5, outTotal: 3, closing: 12, currentStock: 12, ledgerStock: 12, reconciles: true, movementCount: 4 }, over || {}); }
const QUIET = () => product({ productId: 'q-1', name: 'Idle', opening: 0, inTotal: 0, outTotal: 0, closing: 0, currentStock: 0, ledgerStock: 0, movementCount: 0, kinds: {} });
const body = (win, products, counts) => ({ ok: true, window: { fromMs: win.fromMs, toMs: win.toMs }, readAt: NOW, products, counts: counts || { rowsInWindow: 3, skipped: {} } });
const okResult = (win, products, counts) => ({ ok: true, body: body(win, products, counts), window: win });
const monthWin = Model.presetWindow('month', NOW);

test('SRW-20 the function bodies were found and use only names the sandbox provides', () => {
  const allowed = new Set(['Glue', 'StockRegisterService', 'AuthStore', 'regModel', 'console', 'Date', 'root', 'Math']);
  for (const n of FN) {
    const t = extractFunction('pages/StockRegisterPage.qml', n).replace(/"[^"]*"/g, '""');   // names inside strings do not count
    for (const m of t.matchAll(/\b(Glue|StockRegister\w+|AuthStore|Model|Toast|Constants|AuthService|Qt)\b/g)) assert.ok(allowed.has(m[1]) || m[1] === 'StockRegisterService', n + ' uses ' + m[1]);
  }
});

test('SRW-21 a tap sends exactly the window resolved at the tap and shows the answer', () => {
  const { page, svc, regModel } = makePage();
  page._loadTapped();
  assert.equal(svc.calls.length, 1);
  assert.deepEqual(plain(svc.calls[0].win), plain(monthWin));
  assert.equal(page.status, 'idle', 'nothing is shown until the answer comes');
  svc.answer(okResult(monthWin, [product(), QUIET()]));
  assert.equal(page.status, 'ok');
  assert.equal(regModel.count, 1);
  assert.equal(regModel.rows[0].productId, 'p-abcdef123');
  assert.deepEqual(Object.keys(plain(regModel.rows[0])), plain(Glue.ROW_KEYS));
  assert.equal(page.summary.hiddenQuiet, 1);
  assert.deepEqual(plain(page.shownWin), plain(monthWin));
  assert.equal(page._warnings.length, 0);
});

test('SRW-22 refusals are shown in words and send nothing', () => {
  let t = makePage(undefined, { isOnline: false });
  t.page._loadTapped();
  assert.equal(t.svc.calls.length, 0);
  assert.equal(t.page.status, 'error');
  assert.equal(t.page.errorRetryable, true);
  assert.equal(t.page.errorText, Model.message('offline'));

  t = makePage(undefined, { AuthStore: { role: 'staff', tenantId: 't1' } });
  t.page._loadTapped();
  assert.equal(t.svc.calls.length, 0);
  assert.equal(t.page.errorText, Model.message('role'));
  assert.equal(t.page.errorRetryable, false);

  t = makePage(undefined, { chipIndex: 6, fromText: '2026-05-01', toText: '2026-04-01' });
  t.page._loadTapped();
  assert.equal(t.svc.calls.length, 0);
  assert.equal(t.page.errorText, Model.customErrorText('reversed'));
  assert.equal(t.page.errorRetryable, false);
});

test('SRW-23 a second tap while a load runs is silent and sends nothing', () => {
  const { page, svc } = makePage();
  page._loadTapped();
  page._loadTapped();
  page._loadTapped();
  assert.equal(svc.calls.length, 1);
  assert.equal(svc.attempts, 1, 'the page does not even ask the service again');
  assert.equal(page.status, 'idle');
  assert.equal(page.errorText, '');
});

test('SRW-24 cancel returns to the view before the tap; an old answer is not wiped by it', () => {
  const { page, svc, regModel } = makePage();
  page._loadTapped(); svc.answer(okResult(monthWin, [product()]));
  assert.equal(regModel.count, 1);
  page._loadTapped();
  page._cancelTapped();
  assert.equal(svc.cancels, 1);
  assert.equal(page.status, 'ok');
  assert.equal(regModel.count, 1);
});

test('SRW-25 an error replaces the old numbers (no stale rows behind an error)', () => {
  const { page, svc, regModel } = makePage();
  page._loadTapped(); svc.answer(okResult(monthWin, [product()]));
  page._loadTapped(); svc.answer({ ok: false, kind: 'timeout', message: Model.message('timeout'), retryable: true });
  assert.equal(page.status, 'error');
  assert.equal(regModel.count, 0);
  assert.equal(page.summary, null);
  assert.equal(page.errorText, Model.message('timeout'));
  assert.equal(Glue.loadLabel(page.status, page.errorRetryable), 'Try again');
});

test('SRW-26 a wrong-window answer is refused, not shown', () => {
  const { page, svc, regModel } = makePage();
  page._loadTapped();
  svc.answer({ ok: true, body: body(Model.presetWindow('lastMonth', NOW), [product()]), window: monthWin });
  assert.equal(page.status, 'error');
  assert.equal(page.errorText, Model.message('badAnswer'));
  assert.equal(regModel.count, 0);
});

test('SRW-27 a load that throws leaves the page usable', () => {
  const { page, svc } = makePage();
  svc.throwOnLoad = true;
  assert.doesNotThrow(() => page._loadTapped());
  assert.equal(page.status, 'error');
  assert.equal(page.errorText, Model.message('unknown'));
  svc.throwOnLoad = false;
  page._loadTapped();
  assert.equal(svc.calls.length, 1);
});

test('SRW-28 chips: a remembered answer shows with no request; no answer shows nothing; custom edits re-resolve', () => {
  const { page, svc, regModel } = makePage();
  page._loadTapped(); svc.answer(okResult(monthWin, [product()]));
  page._chipPicked(1);
  assert.equal(page.status, 'idle'); assert.equal(regModel.count, 0); assert.equal(svc.calls.length, 1);
  page._chipPicked(0);
  assert.equal(page.status, 'ok'); assert.equal(regModel.count, 1); assert.equal(svc.calls.length, 1, 'no new request');
  page._chipPicked(6);
  assert.equal(page.status, 'idle');
  page.fromText = '2026-10-01'; page.toText = '2026-10-31'; page._periodChanged();
  assert.equal(page.status, 'idle', 'a custom range with no remembered answer shows nothing');
  page.fromText = '2026-11-01'; page.toText = '2026-11-30'; page._periodChanged();
  assert.equal(page.status, 'ok', 'a custom range equal to a remembered window shows that answer (same window key)');
  assert.equal(svc.calls.length, 1);
  page._chipPicked(0);
  assert.equal(page.status, 'ok');
});

test('SRW-29 show-all re-reads the same answer: no request, rows change, nothing else does', () => {
  const { page, svc, regModel } = makePage();
  page._loadTapped(); svc.answer(okResult(monthWin, [product(), QUIET()]));
  assert.equal(regModel.count, 1);
  page._showAllToggled(true);
  assert.equal(page.showAll, true); assert.equal(regModel.count, 2); assert.equal(page.summary.hiddenQuiet, 0); assert.equal(svc.calls.length, 1);
  page._showAllToggled(false);
  assert.equal(regModel.count, 1);
});

test('SRW-30 show-all before any answer does nothing and does not throw', () => {
  const { page, regModel } = makePage();
  assert.doesNotThrow(() => page._showAllToggled(true));
  assert.equal(page.status, 'idle'); assert.equal(regModel.count, 0);
});

test('SRW-31 a row opens and closes; one at a time; a new answer closes it', () => {
  const { page, svc } = makePage();
  page._loadTapped(); svc.answer(okResult(monthWin, [product(), product({ productId: 'p-2' })]));
  page._toggleRow('p-abcdef123'); assert.equal(page.expandedId, 'p-abcdef123');
  page._toggleRow('p-2'); assert.equal(page.expandedId, 'p-2');
  page._toggleRow('p-2'); assert.equal(page.expandedId, '');
  page._toggleRow('p-2'); page._showAllToggled(true); assert.equal(page.expandedId, '');
});

test('SRW-32 reset: cancel, then clear, state back to the start, the running answer is dropped', () => {
  const { page, svc, regModel } = makePage();
  page._loadTapped(); svc.answer(okResult(monthWin, [product()]));
  page._chipPicked(6); page.fromText = 'x'; page.showAll = true;
  page._loadTapped();   // refused (bad custom): state error
  page.chipIndex = 0; page._loadTapped();   // a request in flight
  assert.equal(svc.loading, true);
  page._resetAll();
  assert.deepEqual(svc.order.slice(-2), ['cancel', 'clear']);
  assert.equal(svc.loading, false);
  assert.equal(page.chipIndex, 0); assert.equal(page.fromText, ''); assert.equal(page.toText, ''); assert.equal(page.showAll, false);
  assert.equal(page.status, 'idle'); assert.equal(regModel.count, 0); assert.equal(page.summary, null); assert.equal(page.errorText, '');
  assert.deepEqual(plain(svc.cache), {});
});

test('SRW-33 warnings reach the page when the ledger has rows the report could not read', () => {
  const { page, svc } = makePage();
  page._loadTapped();
  svc.answer(okResult(monthWin, [product({ reconciles: false, ledgerStock: 11 })], { rowsInWindow: 3, skipped: { noProduct: 2 } }));
  assert.equal(page._warnings.length, 2);
});

test('SRW-34 an empty answer says why', () => {
  const { page, svc, regModel } = makePage();
  page._loadTapped(); svc.answer(okResult(monthWin, [QUIET()]));
  assert.equal(page.status, 'ok'); assert.equal(regModel.count, 0);
  assert.match(Glue.emptyText(page.summary), /Show all products/);
});

test('SRW-35 monkey: 400 random taps never break the invariants', () => {
  let seed = 7; const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const { page, svc, regModel } = makePage();
  let started = 0;
  for (let i = 0; i < 400; i++) {
    const act = pick(['load', 'load', 'answerOk', 'answerErr', 'cancel', 'chip', 'showAll', 'row', 'reset', 'offline', 'role', 'custom']);
    const before = svc.calls.length;
    if (act === 'load') { page._loadTapped(); if (svc.calls.length > before) started++; }
    else if (act === 'answerOk' && svc.loading) svc.answer(okResult(svc.pending.win, [product(), QUIET()], { rowsInWindow: 1, skipped: {} }));
    else if (act === 'answerErr' && svc.loading) svc.answer({ ok: false, kind: pick(['offline', 'timeout', 'role', 'busy', 'cancelled']), message: 'm', retryable: rnd() < 0.5 });
    else if (act === 'cancel') page._cancelTapped();
    else if (act === 'chip' && !svc.loading) page._chipPicked(pick([0, 1, 2, 3, 4, 5, 6]));
    else if (act === 'showAll') page._showAllToggled(rnd() < 0.5);
    else if (act === 'row') page._toggleRow(pick(['p-abcdef123', 'q-1', '']));
    else if (act === 'reset') page._resetAll();
    else if (act === 'offline') page.isOnline = rnd() < 0.7;
    else if (act === 'role') page.AuthStore = undefined, page.AuthStore = { role: pick(['owner', 'staff', 'manager']) };
    else if (act === 'custom' && !svc.loading) { page.fromText = pick(['', '2026-04-01', 'x']); page.toText = pick(['', '2026-04-30', '2026-03-01']); }
    assert.ok(['idle', 'ok', 'error'].includes(page.status), 'status ' + page.status);
    assert.ok(svc.calls.length - before <= 1, 'one request per action');
    assert.equal(regModel.count > 0 ? page.status : 'ok-or-less', regModel.count > 0 ? 'ok' : 'ok-or-less', 'rows only with an ok answer');
    if (page.status === 'error') assert.ok(page.errorText.length > 0 && regModel.count === 0 && page.summary === null);
    if (page.status === 'ok') assert.ok(page.summary !== null && page.shownWin !== null);
    assert.ok(!(svc.loading && svc.pending === null));
  }
  assert.ok(started > 5);
});

// ---- hand mutants of the page glue (the page text, run through the same sandbox) ---------------------------------

function pageBattery(mutate) {
  const bad = [];
  const texts = FN.map((n) => mutate(extractFunction('pages/StockRegisterPage.qml', n)));
  const run = (name, fn) => { try { fn(); } catch (e) { bad.push(name); } };
  const mk = (over) => makePage(texts.join('\n'), over);
  run('send once', () => { const t = mk(); t.page._loadTapped(); t.page._loadTapped(); assert.equal(t.svc.calls.length, 1); assert.equal(t.svc.attempts, 1); });
  run('window at tap', () => { const t = mk(); t.page._loadTapped(); assert.deepEqual(plain(t.svc.calls[0].win), plain(monthWin)); });
  run('clock read at the tap', () => { const t = mk({ _nowMs: at(2026, 9, 5, 12) }); t.page._loadTapped(); assert.deepEqual(plain(t.svc.calls[0].win), plain(monthWin)); });
  run('answer honours show all', () => { const t = mk({ showAll: true }); t.page._loadTapped(); t.svc.answer(okResult(monthWin, [product(), QUIET()])); assert.equal(t.regModel.count, 2); });
  run('offline refused', () => { const t = mk({ isOnline: false }); t.page._loadTapped(); assert.equal(t.svc.calls.length, 0); assert.equal(t.page.errorText, Model.message('offline')); });
  run('role refused', () => { const t = mk({ AuthStore: { role: 'staff' } }); t.page._loadTapped(); assert.equal(t.svc.calls.length, 0); assert.equal(t.page.errorRetryable, false); });
  run('bad custom refused', () => { const t = mk({ chipIndex: 6, fromText: 'x' }); t.page._loadTapped(); assert.equal(t.svc.calls.length, 0); assert.equal(t.page.status, 'error'); });
  run('answer applied', () => { const t = mk(); t.page._loadTapped(); t.svc.answer(okResult(monthWin, [product(), QUIET()])); assert.equal(t.page.status, 'ok'); assert.equal(t.regModel.count, 1); assert.equal(t.page.summary.hiddenQuiet, 1); assert.deepEqual(plain(t.page.shownWin), plain(monthWin)); });
  run('cancel keeps view', () => { const t = mk(); t.page._loadTapped(); t.svc.answer(okResult(monthWin, [product()])); t.page._loadTapped(); t.page._cancelTapped(); assert.equal(t.svc.cancels, 1); assert.equal(t.svc.loading, false); assert.equal(t.page.status, 'ok'); assert.equal(t.regModel.count, 1); });
  run('error clears rows', () => { const t = mk(); t.page._loadTapped(); t.svc.answer(okResult(monthWin, [product()])); t.page._loadTapped(); t.svc.answer({ ok: false, kind: 'server', message: 'm', retryable: true }); assert.equal(t.regModel.count, 0); assert.equal(t.page.summary, null); assert.equal(t.page.status, 'error'); });
  run('throw handled', () => { const t = mk(); t.svc.throwOnLoad = true; t.page._loadTapped(); assert.equal(t.page.status, 'error'); });
  run('chip cache', () => { const t = mk(); t.page._loadTapped(); t.svc.answer(okResult(monthWin, [product()])); t.page._chipPicked(1); assert.equal(t.page.status, 'idle'); assert.equal(t.regModel.count, 0); t.page._chipPicked(0); assert.equal(t.page.status, 'ok'); assert.equal(t.svc.calls.length, 1); });
  run('chip sets index', () => { const t = mk(); t.page._chipPicked(3); assert.equal(t.page.chipIndex, 3); });
  run('invalid custom is idle', () => { const t = mk(); t.page._loadTapped(); t.svc.answer(okResult(monthWin, [product()])); t.page._chipPicked(6); assert.equal(t.page.status, 'idle'); assert.equal(t.regModel.count, 0); });
  run('show all', () => { const t = mk(); t.page._loadTapped(); t.svc.answer(okResult(monthWin, [product(), QUIET()])); t.page._showAllToggled(true); assert.equal(t.regModel.count, 2); assert.equal(t.page.showAll, true); assert.equal(t.svc.calls.length, 1); });
  run('row toggle', () => { const t = mk(); t.page._toggleRow('a'); assert.equal(t.page.expandedId, 'a'); t.page._toggleRow('a'); assert.equal(t.page.expandedId, ''); });
  run('new state closes row', () => { const t = mk(); t.page._loadTapped(); t.svc.answer(okResult(monthWin, [product()])); t.page._toggleRow('p-abcdef123'); t.page._showAllToggled(true); assert.equal(t.page.expandedId, ''); });
  run('reset', () => { const t = mk(); t.page._loadTapped(); t.svc.answer(okResult(monthWin, [product()])); t.page.chipIndex = 2; t.page.showAll = true; t.page.fromText = 'x'; t.page.toText = 'y'; t.page._loadTapped(); t.page._resetAll(); assert.deepEqual(t.svc.order, ['cancel', 'clear']); assert.equal(t.svc.loading, false); assert.equal(t.page.status, 'idle'); assert.equal(t.regModel.count, 0); assert.equal(t.page.summary, null); assert.equal(t.page.chipIndex, 0); assert.equal(t.page.showAll, false); assert.equal(t.page.fromText, ''); assert.equal(t.page.toText, ''); });
  run('reset drops a shown answer', () => { const t = mk(); t.page._loadTapped(); t.svc.answer(okResult(monthWin, [product()])); t.page._resetAll(); assert.equal(t.page.status, 'idle'); assert.equal(t.regModel.count, 0); assert.equal(t.page.shownWin, null); });
  run('warnings', () => { const t = mk(); t.page._loadTapped(); t.svc.answer(okResult(monthWin, [product({ reconciles: false })])); assert.equal(t.page._warnings.length, 1); });
  return bad;
}

test('SRW-40 the page battery is clean on the real text', () => { assert.deepEqual(pageBattery((t) => t), []); });

const PAGE_MUTANTS = [
  ['tap sends without the decision', 'if (!d.go) {', 'if (false) {'],
  ['refusal not shown', 'if (refusal !== null) _applyState(refusal)', ''],
  ['window not resolved at the tap', 'var resolved = Glue.resolveWindow(chipIndex, fromText, toText, _nowMs)', 'var resolved = Glue.resolveWindow(0, "", "", _nowMs)'],
  ['clock not refreshed at the tap', '_refreshNow()\n        var resolved', 'var resolved'],
  ['loading flag not passed', 'loading: StockRegisterService.loading', 'loading: false'],
  ['online not passed', 'online: isOnline', 'online: true'],
  ['role not passed', 'role: AuthStore.role', 'role: "owner"'],
  ['wrong window sent', 'var win = resolved.win', 'var win = Glue.resolveWindow(0, "", "", 1e12).win || resolved.win'],
  ['throw not caught', 'try {\n            StockRegisterService.load', '{\n            StockRegisterService.load'],
  ['null answer applied', 'if (st !== null) _applyState(st)', '_applyState(st || Glue.initialState())'],
  ['answer ignores show all', 'Glue.stateFromResult(result, win, showAll)', 'Glue.stateFromResult(result, win, false)'],
  ['cache ignored', 'Glue.stateFromCache(StockRegisterService.cached(r.win), r.win, showAll)', 'Glue.initialState()'],
  ['invalid period keeps rows', 'else _applyState(Glue.initialState())', ''],
  ['chip index not set', 'chipIndex = index', ''],
  ['show all not stored', 'showAll = checked', ''],
  ['show all requests again', '_applyState(Glue.stateFromBody(_body, shownWin, showAll))', '_loadTapped()'],
  ['row never closes', 'expandedId = Glue.nextExpanded(expandedId, productId)', 'expandedId = productId'],
  ['row stays open on new state', '        expandedId = ""\n        regModel.clear()', '        regModel.clear()'],
  ['model not cleared', 'regModel.clear()\n        for', 'for'],
  ['warnings not set', '_warnings = Glue.warningLines(st.summary)', ''],
  ['summary not set', 'summary = st.summary', ''],
  ['window not set', 'shownWin = st.win', ''],
  ['body not set', '_body = st.body', ''],
  ['error text not set', 'errorText = st.text', ''],
  ['retry flag not set', 'errorRetryable = st.retryable', ''],
  ['reset clears before cancel', 'StockRegisterService.cancel()\n        StockRegisterService.clear()', 'StockRegisterService.clear()\n        StockRegisterService.cancel()'],
  ['reset forgets cancel', 'StockRegisterService.cancel()\n        StockRegisterService.clear()', 'StockRegisterService.clear()'],
  ['reset forgets clear', 'StockRegisterService.clear()\n        chipIndex = 0', 'chipIndex = 0'],
  ['reset keeps showAll', '        showAll = false\n        _refreshNow()', '        _refreshNow()'],
  ['reset keeps texts', '        fromText = ""\n        toText = ""\n', ''],
  ['reset keeps state', '_applyState(Glue.initialState())\n    }\n\n    Connections', '    }\n\n    Connections'],
  ['cancel does nothing', 'function _cancelTapped() { StockRegisterService.cancel() }', 'function _cancelTapped() { }']
];

test('SRW-41 every page mutant text is really in the function bodies it targets', () => {
  const all = FN.map((n) => extractFunction('pages/StockRegisterPage.qml', n)).join('\n') + '\n    Connections';
  const missing = PAGE_MUTANTS.filter(([, from]) => !all.includes(from) && !PAGE.includes(from)).map(([n]) => n);
  assert.deepEqual(missing, []);
});

for (const [name, from, to] of PAGE_MUTANTS) {
  test('SRW-M ' + name + ' is killed', () => {
    // The mutants are applied to the page text, then the same function bodies are extracted from it.
    const mutated = PAGE.replace(from, to);
    assert.notEqual(mutated, PAGE, 'mutant text present in the page');
    const texts = FN.map((n) => { const at = mutated.indexOf('function ' + n + '('); const open = mutated.indexOf('{', mutated.indexOf(')', at)); let d = 0, i = open; for (; i < mutated.length; i++) { if (mutated[i] === '{') d++; else if (mutated[i] === '}' && --d === 0) break; } return mutated.substring(at, i + 1); });
    const bad = (() => { try { return pageBatteryFromTexts(texts); } catch (e) { return ['threw ' + e.message]; } })();
    assert.ok(bad.length > 0, 'mutant survived: ' + name);
  });
}

function pageBatteryFromTexts(texts) {
  // Re-run the same battery with the already-extracted (mutated) function texts.
  let i = 0; const mutate = () => texts[i++];
  return pageBattery(mutate);
}
