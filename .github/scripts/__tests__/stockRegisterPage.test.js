'use strict';

// P1 S4b-2: the pure page glue qml/helper/StockRegisterPage.js (which window, may a tap send, what the page shows
// for an answer, wording). One battery that COLLECTS failures: the same assertions run on the real file (must be
// empty), on the real file under other time zones, and on every hand mutant (must not be empty). A small copy of
// the contract runs in the Qt JS engine in tests/tst_StockRegisterPage.qml (CI only).
// Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md section 8
// Test plan: docs/superpowers/test-plans/2026-11-20-p1-s4b2-register-page-test-plan.md

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { load } = require(path.join('..', '..', '..', 'functions', 'test', 'testSupport', 'qmlHelpers.js'));

const REPO = path.resolve(__dirname, '..', '..', '..');
const FILE = path.join(REPO, 'qml/helper/StockRegisterPage.js');
const SRC = fs.readFileSync(FILE, 'utf8');
const M = load('StockRegisterModel.js');
const plain = (v) => JSON.parse(JSON.stringify(v));
const OFF = 19800000;
const at = (y, m0, d, h, mi) => Date.UTC(y, m0, d, h || 0, mi || 0) - OFF;   // an IST wall-clock instant
const NOW = at(2026, 10, 20, 15, 42);                                          // 20 Nov 2026 15:42 IST
const LITERAL_KEYS = ['productId', 'title', 'note', 'reconciles', 'openingText', 'inText', 'outText', 'closingText', 'rowName'];

function loadSrc(src) {
  const ctx = { Model: M };
  vm.runInNewContext(src.replace(/^\.pragma library\s*$/m, '').replace(/^\.import "[^"]+" as \w+\s*$/gm, ''), ctx, { filename: FILE });
  return ctx;
}

function product(over) {
  const p = { productId: 'p-abcdef123', name: 'Silk Saree', deleted: false, opening: 10, kinds: { sale: { in: 0, out: 3 } },
    inTotal: 0, outTotal: 3, closing: 7, currentStock: 7, ledgerStock: 7, reconciles: true, movementCount: 4 };
  return Object.assign(p, over || {});
}
function answer(win, products, counts) {
  return { ok: true, window: { fromMs: win.fromMs, toMs: win.toMs }, readAt: NOW, products, counts: counts || { rowsInWindow: 4, skipped: {} } };
}
const QUIET = () => product({ productId: 'q-1', name: 'Idle', opening: 0, inTotal: 0, outTotal: 0, closing: 0, currentStock: 0, ledgerStock: 0, movementCount: 0, kinds: {} });

// The battery. P = the helper under test. Returns the list of failed check names.
function battery(P) {
  const bad = [];
  const ok = (name, cond) => { if (!cond) bad.push(name); };
  const eq = (name, a, b) => { try { assert.deepEqual(plain(a), plain(b)); } catch (e) { bad.push(name); } };
  const safe = (name, fn) => { try { fn(); } catch (e) { bad.push(name + ' threw ' + e.message); } };

  // chips
  eq('chip labels', P.chipLabels(), ['This month', 'Last month', 'This quarter', 'Last quarter', 'This FY', 'Last FY', 'Custom']);
  ok('chip count = presets + custom', P.chipLabels().length === M.PRESETS.length + 1 && P.CUSTOM_INDEX === M.PRESETS.length);
  const labels = P.chipLabels(); labels.push('x'); ok('chip labels are a copy', P.chipLabels().length === 7);
  eq('row keys literal', P.ROW_KEYS, LITERAL_KEYS);

  // resolveWindow
  for (let i = 0; i < 6; i++) eq('preset chip ' + i, P.resolveWindow(i, '', '', NOW), { ok: true, win: M.presetWindow(M.PRESETS[i], NOW) });
  eq('custom ok', P.resolveWindow(6, '2026-04-01', '2026-04-30', 0), { ok: true, win: M.customWindow('2026-04-01', '2026-04-30') });
  eq('custom trimmed', P.resolveWindow(6, '  2026-04-01 ', '\t2026-04-30\n', 0), { ok: true, win: M.customWindow('2026-04-01', '2026-04-30') });
  eq('custom bad from', P.resolveWindow(6, 'x', '2026-04-30', 0), { ok: false, text: M.customErrorText('bad-from') });
  eq('custom bad to', P.resolveWindow(6, '2026-04-01', '', 0), { ok: false, text: M.customErrorText('bad-to') });
  eq('custom out of range', P.resolveWindow(6, '1999-12-31', '2026-01-01', 0), { ok: false, text: M.customErrorText('out-of-range') });
  eq('custom reversed', P.resolveWindow(6, '2026-05-01', '2026-04-01', 0), { ok: false, text: M.customErrorText('reversed') });
  eq('custom junk texts', P.resolveWindow(6, null, 5, 0), { ok: false, text: M.customErrorText('bad-from') });
  eq('custom ignores now', P.resolveWindow(6, '2026-04-01', '2026-04-01', NaN).ok, true);
  for (const j of [-1, 7, 1.5, '0', NaN, null, undefined, Infinity, {}]) eq('bad chip ' + String(j), P.resolveWindow(j, '', '', NOW), { ok: false, text: M.message('window') });
  eq('preset bad now', P.resolveWindow(0, '', '', NaN), { ok: false, text: M.message('window') });
  eq('preset ignores typed text', P.resolveWindow(0, 'junk', 'junk', NOW).ok, true);

  // tapDecision
  const good = P.resolveWindow(0, '', '', NOW);
  const base = { loading: false, online: true, role: 'owner', resolved: good };
  for (const r of ['owner', 'admin', 'manager']) eq('go for ' + r, P.tapDecision(Object.assign({}, base, { role: r })), { go: true, kind: '', text: '' });
  for (const r of ['staff', 'viewer', 'Owner', '', null, undefined, 5]) eq('no go role ' + String(r), P.tapDecision(Object.assign({}, base, { role: r })), { go: false, kind: 'role', text: M.message('role') });
  for (const o of [false, undefined, null, 'true', 1]) eq('no go offline ' + String(o), P.tapDecision(Object.assign({}, base, { online: o })), { go: false, kind: 'offline', text: M.message('offline') });
  eq('busy wins over everything', P.tapDecision({ loading: true, online: false, role: 'staff', resolved: { ok: false, text: 'x' } }), { go: false, kind: 'busy', text: '' });
  for (const l of [false, undefined, 'true', 1]) ok('loading must be exactly true ' + String(l), P.tapDecision(Object.assign({}, base, { loading: l })).go === true);
  eq('bad window wins over role and network', P.tapDecision({ loading: false, online: false, role: 'staff', resolved: { ok: false, text: 'Fix the dates.' } }), { go: false, kind: 'window', text: 'Fix the dates.' });
  eq('bad window without text', P.tapDecision({ loading: false, online: true, role: 'owner', resolved: { ok: false } }), { go: false, kind: 'window', text: M.message('window') });
  eq('resolved ok flag must be true', P.tapDecision({ loading: false, online: true, role: 'owner', resolved: { ok: 'yes', win: {} } }).kind, 'window');
  for (const j of [null, undefined, 5, 'x', []]) eq('junk ctx ' + String(j), P.tapDecision(j).kind, 'window');
  eq('no resolved', P.tapDecision({ loading: false, online: true, role: 'owner' }).kind, 'window');

  // states
  const win = M.presetWindow('month', NOW);
  eq('initial state', P.initialState(), { status: 'idle', rows: [], summary: null, body: null, win: null, text: '', retryable: true });
  const body = answer(win, [product(), QUIET()]);
  const s1 = P.stateFromResult({ ok: true, body, window: win }, win, false);
  ok('ok status', s1 && s1.status === 'ok' && s1.text === '' && s1.retryable === true);
  ok('ok keeps body', s1 && s1.body === body);
  eq('ok keeps the window', s1.win, win);
  ok('quiet hidden by default', s1 && s1.rows.length === 1 && s1.summary.hiddenQuiet === 1 && s1.summary.shown === 1);
  eq('row keys in order', s1.rows[0] && Object.keys(plain(s1.rows[0])), LITERAL_KEYS);
  const types = { productId: 'string', title: 'string', note: 'string', reconciles: 'boolean', openingText: 'string', inText: 'string', outText: 'string', closingText: 'string', rowName: 'string' };
  ok('row types', s1.rows[0] && LITERAL_KEYS.every((k) => typeof s1.rows[0][k] === types[k]));
  const s2 = P.stateFromResult({ ok: true, body, window: win }, win, true);
  ok('showAll keeps quiet rows', s2.rows.length === 2 && s2.summary.hiddenQuiet === 0);
  ok('showAll must be exactly true', P.stateFromResult({ ok: true, body }, win, 'yes').rows.length === 1);
  const wrong = answer(M.presetWindow('lastMonth', NOW), [product()]);
  eq('window mismatch is an error', P.stateFromResult({ ok: true, body: wrong }, win, false), { status: 'error', rows: [], summary: null, body: null, win: null, text: M.message('badAnswer'), retryable: true });
  eq('no body is an error', P.stateFromResult({ ok: true }, win, false).status, 'error');
  eq('offline', P.stateFromResult({ ok: false, kind: 'offline', message: 'No answer.', retryable: true }, win, false), { status: 'error', rows: [], summary: null, body: null, win: null, text: 'No answer.', retryable: true });
  eq('role is not retryable', P.stateFromResult({ ok: false, kind: 'role', message: 'Nope.', retryable: false }, win, false).retryable, false);
  eq('retryable missing means retry', P.stateFromResult({ ok: false, kind: 'server', message: 'x' }, win, false).retryable, true);
  eq('message missing falls back', P.stateFromResult({ ok: false, kind: 'timeout', retryable: true }, win, false).text, M.message('timeout'));
  eq('message empty falls back', P.stateFromResult({ ok: false, kind: 'server', message: '', retryable: true }, win, false).text, M.message('server'));
  eq('busy leaves the page alone', P.stateFromResult({ ok: false, kind: 'busy', message: '', retryable: true }, win, false), null);
  eq('cancelled leaves the page alone', P.stateFromResult({ ok: false, kind: 'cancelled', message: '', retryable: true }, win, false), null);
  for (const j of [null, undefined, 5, 'x']) eq('junk result ' + String(j), P.stateFromResult(j, win, false).text, M.message('unknown'));
  eq('cache miss is idle', P.stateFromCache(null, win, false), P.initialState());
  eq('cache without body is idle', P.stateFromCache({ window: win }, win, false), P.initialState());
  eq('cache hit equals fresh', P.stateFromCache({ body, window: win }, win, false), s1);
  eq('cache of another window is refused', P.stateFromCache({ body: wrong, window: win }, win, false).status, 'error');
  eq('from body null', P.stateFromBody(null, win, true), P.initialState());
  eq('from body switch', P.stateFromBody(body, win, true).rows.length, 2);

  // rows
  const lr = P.toListRow({ id: 'p9', title: 'T', note: '', deleted: false, reconciles: true, moved: true, movementCount: 2, openingText: '1', inText: '2', outText: '3', closingText: '0', currentText: '0' });
  ok('no id key, no unused keys', !('id' in lr) && !('moved' in lr) && !('deleted' in lr) && !('movementCount' in lr) && !('currentText' in lr));
  eq('row name plain', lr.rowName, 'T. Opening 1, in 2, out 3, closing 0.');
  eq('row name with note', P.toListRow({ id: 'p9', title: 'T', note: 'Ledger 5 vs stock 4', deleted: false, reconciles: false, movementCount: 2, openingText: '1', inText: '2', outText: '3', closingText: '0', currentText: '0' }).rowName, 'T. Opening 1, in 2, out 3, closing 0. Ledger 5 vs stock 4.');
  eq('reconciles kept', P.toListRow({ id: 'p9', title: 'T', note: 'n', reconciles: false, openingText: '0', inText: '0', outText: '0', closingText: '0' }).reconciles, false);
  eq('reconciles is a strict boolean', P.toListRow({ id: 'p9', title: 'T', note: '', reconciles: 'yes', openingText: '0', inText: '0', outText: '0', closingText: '0' }).reconciles, false);
  eq('productId from id', lr.productId, 'p9');

  // refusals
  eq('refusal offline retries', P.stateFromRefusal({ go: false, kind: 'offline', text: 'Off.' }), { status: 'error', rows: [], summary: null, body: null, win: null, text: 'Off.', retryable: true });
  eq('refusal role does not retry', P.stateFromRefusal({ go: false, kind: 'role', text: 'No.' }).retryable, false);
  eq('refusal window does not retry', P.stateFromRefusal({ go: false, kind: 'window', text: 'Bad.' }).retryable, false);
  eq('refusal busy is silent', P.stateFromRefusal({ go: false, kind: 'busy', text: '' }), null);
  eq('refusal go is not a refusal', P.stateFromRefusal({ go: true, kind: '', text: '' }), null);
  for (const j of [null, undefined, 5, 'x']) eq('refusal junk ' + String(j), P.stateFromRefusal(j), null);
  eq('refusal text missing', P.stateFromRefusal({ go: false, kind: 'window' }).text, M.message('unknown'));

  // inline error, caption, detail
  const badCustom = P.resolveWindow(6, 'x', '', 0);
  eq('no inline error when valid', P.inlineError(0, '', '', good), '');
  eq('custom blank is quiet', P.inlineError(6, '', '', badCustom), '');
  eq('custom blank spaces is quiet', P.inlineError(6, '  ', '\t', badCustom), '');
  eq('custom one field shows', P.inlineError(6, 'x', '', badCustom), M.customErrorText('bad-from'));
  eq('custom other field shows', P.inlineError(6, '', '2026-01-01', P.resolveWindow(6, '', '2026-01-01', 0)), M.customErrorText('bad-from'));
  eq('preset error always shows', P.inlineError(0, '', '', { ok: false, text: 'Clock.' }), 'Clock.');
  eq('error without text', P.inlineError(0, '', '', { ok: false }), M.message('window'));
  eq('error without resolved', P.inlineError(0, '', '', null), M.message('window'));
  eq('caption of the answer wins', P.captionText({ text: 'A' }, good), 'A');
  eq('caption of the chips', P.captionText(null, good), good.win.text);
  eq('caption empty text falls to chips', P.captionText({ text: '' }, good), good.win.text);
  eq('caption nothing', P.captionText(null, badCustom), '');
  eq('caption junk', P.captionText(5, null), '');
  eq('detail only when open', P.detailRows(body, 'p-abcdef123', 'p-abcdef123').length, 1);
  eq('detail closed row', P.detailRows(body, '', 'p-abcdef123'), []);
  eq('detail other row open', P.detailRows(body, 'zzz', 'p-abcdef123'), []);
  eq('detail unknown product', P.detailRows(body, 'nope', 'nope'), []);
  eq('detail junk body', P.detailRows(null, 'a', 'a'), []);
  ok('texts are plain words', P.IDLE_TEXT.length > 20 && P.LOADING_TEXT.indexOf('two minutes') > 0 && P.DETAIL_EMPTY.length > 10);
  ok('loading text agrees with the service timeout', /two minutes/.test(P.LOADING_TEXT));

  // small wording and labels
  eq('label idle', P.loadLabel('idle', true), 'Load register');
  eq('label loading', P.loadLabel('loading', true), 'Load register');
  eq('label ok', P.loadLabel('ok', true), 'Reload register');
  eq('label error retry', P.loadLabel('error', true), 'Try again');
  eq('label error no retry', P.loadLabel('error', false), 'Load register');
  eq('label error junk retryable', P.loadLabel('error', 'yes'), 'Load register');
  eq('toggle open', P.nextExpanded('', 'a'), 'a');
  eq('toggle close', P.nextExpanded('a', 'a'), '');
  eq('toggle switch', P.nextExpanded('a', 'b'), 'b');
  eq('summary one', P.summaryText({ shown: 1, hiddenQuiet: 0 }), '1 product shown');
  eq('summary many hidden', P.summaryText({ shown: 12, hiddenQuiet: 3 }), '12 products shown, 3 with no stock history hidden');
  eq('summary zero', P.summaryText({ shown: 0, hiddenQuiet: 0 }), '0 products shown');
  eq('summary one hidden', P.summaryText({ shown: 2, hiddenQuiet: 1 }), '2 products shown, 1 with no stock history hidden');
  for (const j of [null, undefined, 5, 'x']) eq('summary junk ' + String(j), P.summaryText(j), '');
  eq('no warnings', P.warningLines({ mismatches: 0, skippedLedgerRows: 0, droppedBad: 0 }), []);
  eq('warn mismatch', P.warningLines({ mismatches: 1, skippedLedgerRows: 0, droppedBad: 0 }), ['1 product where the ledger and the stock count disagree.']);
  eq('warn skipped', P.warningLines({ mismatches: 0, skippedLedgerRows: 2, droppedBad: 0 }), ['2 ledger rows could not be read and are not in these numbers.']);
  eq('warn dropped', P.warningLines({ mismatches: 0, skippedLedgerRows: 0, droppedBad: 1 }), ['1 product row from the server were unreadable and are not shown.']);
  eq('warn all in order', P.warningLines({ mismatches: 2, skippedLedgerRows: 1, droppedBad: 3 }).length, 3);
  for (const j of [null, undefined, 5]) eq('warn junk ' + String(j), P.warningLines(j), []);
  eq('empty with hidden', P.emptyText({ hiddenQuiet: 4 }), 'Nothing to show for this period. 4 products have no stock history; use "Show all products" to list them.');
  eq('empty with one hidden', P.emptyText({ hiddenQuiet: 1 }), 'Nothing to show for this period. 1 product has no stock history; use "Show all products" to list them.');
  eq('empty none', P.emptyText({ hiddenQuiet: 0 }), 'No products in this workspace yet.');
  eq('empty junk', P.emptyText(null), '');

  // warning flag agrees with the model's own flag
  for (const [mm, sk, dr] of [[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1], [2, 3, 4]]) {
    const prods = []; for (let i = 0; i < mm; i++) prods.push(product({ productId: 'm' + i, reconciles: false }));
    for (let i = 0; i < dr; i++) prods.push({ productId: '' });
    const v = M.buildView(answer(win, prods, { rowsInWindow: 1, skipped: { noProduct: sk } }), win, {});
    ok('warning agrees ' + [mm, sk, dr], v.summary.hasWarning === (P.warningLines(v.summary).length > 0));
  }

  // as-of text
  eq('as of afternoon', P.asOfText(NOW), 'as of 20 Nov 2026, 3:42 pm (IST)');
  eq('as of just after midnight', P.asOfText(at(2026, 10, 20, 0, 5)), 'as of 20 Nov 2026, 12:05 am (IST)');
  eq('as of noon', P.asOfText(at(2026, 10, 20, 12, 0)), 'as of 20 Nov 2026, 12:00 pm (IST)');
  eq('as of 1 am', P.asOfText(at(2026, 0, 5, 1, 9)), 'as of 5 Jan 2026, 1:09 am (IST)');
  eq('as of 11 59 pm', P.asOfText(at(2026, 11, 31, 23, 59)), 'as of 31 Dec 2026, 11:59 pm (IST)');
  eq('as of is IST not UTC', P.asOfText(Date.UTC(2026, 10, 19, 19, 0)), 'as of 20 Nov 2026, 12:30 am (IST)');
  eq('as of one ms', P.asOfText(1).startsWith('as of 1 Jan 1970'), true);
  for (const j of [0, -5, NaN, Infinity, null, undefined, '5', {}]) eq('as of junk ' + String(j), P.asOfText(j), '');
  // Review #209 F-E: a finite readAt past the Date range (8.64e15 ms; the IST offset is added first) is an Invalid Date.
  // It must give no line, never "as of NaN undefined NaN, NaN:NaN pm (IST)".
  const DATE_MAX = 8.64e15;
  eq('as of at the Date limit', P.asOfText(DATE_MAX), '');
  eq('as of far past the Date range', P.asOfText(1e20), '');
  eq('as of Number.MAX_VALUE', P.asOfText(Number.MAX_VALUE), '');
  eq('as of last instant that still fits is real text', P.asOfText(DATE_MAX - 19800000 - 1).startsWith('as of ') && !P.asOfText(DATE_MAX - 19800000 - 1).includes('NaN'), true);
  eq('summary as of past the Date range', P.summaryAsOf({ readAt: 1e20 }), '');
  eq('summary as of', P.summaryAsOf({ readAt: NOW }), 'as of 20 Nov 2026, 3:42 pm (IST)');
  eq('summary as of missing read time', P.summaryAsOf({ readAt: 0 }), '');
  for (const j of [null, undefined, 5, 'x']) eq('summary as of junk ' + String(j), P.summaryAsOf(j), '');

  // seeded monkey: nothing throws, shapes hold
  let seed = 12345; const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const junk = [undefined, null, NaN, '', 'x', 7, -1, true, {}, [], { ok: true }, { ok: false }, { ok: false, kind: 'busy' }, { ok: true, body: {} }];
  for (let i = 0; i < 600; i++) {
    const a = pick(junk), b = pick(junk), c = pick([...junk, 0, 3, 6]);
    safe('monkey resolve', () => { const r = P.resolveWindow(c, a, b, pick([NOW, NaN, 0, 'x'])); if (typeof r.ok !== 'boolean') throw new Error('shape'); });
    safe('monkey tap', () => { const r = P.tapDecision({ loading: pick([true, false, a]), online: pick([true, false, b]), role: pick(['owner', 'staff', a]), resolved: pick([good, a, { ok: false, text: 'z' }]) }); if (typeof r.go !== 'boolean') throw new Error('shape'); });
    safe('monkey result', () => { const r = P.stateFromResult(a, pick([win, a]), pick([true, false, b])); if (r !== null && ['ok', 'error'].indexOf(r.status) < 0) throw new Error('shape'); });
    safe('monkey cache', () => { P.stateFromCache(a, pick([win, b]), true); P.stateFromBody(a, pick([win, b]), false); });
    safe('monkey text', () => { P.summaryText(a); P.warningLines(b); P.emptyText(a); P.asOfText(c); P.loadLabel(a, b); P.nextExpanded(a, b); });
  }
  return bad;
}

test('SRP-01 the battery is clean on the real file', () => {
  assert.deepEqual(battery(loadSrc(SRC)), []);
});

test('SRP-02 the battery is clean under other time zones (no local-time getter)', () => {
  const was = process.env.TZ;
  try {
    for (const tz of ['Pacific/Auckland', 'America/Los_Angeles', 'Asia/Kolkata', 'UTC']) {
      process.env.TZ = tz;
      assert.deepEqual(battery(loadSrc(SRC)), [], tz);
    }
  } finally { if (was === undefined) delete process.env.TZ; else process.env.TZ = was; }
});

test('SRP-03 the file reads no local time and no clock', () => {
  const code = SRC.replace(/\/\/.*$/gm, '');
  for (const bad of [/\.getFullYear\(/, /\.getMonth\(/, /\.getDate\(/, /\.getHours\(/, /\.getMinutes\(/, /\.getDay\(/, /getTimezoneOffset/, /toLocale/, /Date\.now\(/, /new Date\(\)/, /Qt\./, /AuthStore|StockRegisterService|Constants/]) {
    assert.ok(!bad.test(code), String(bad));
  }
});

test('SRP-04 the file is a pragma library that imports only the model', () => {
  assert.match(SRC, /^\.pragma library\s*$/m);
  assert.deepEqual(SRC.match(/^\.import .*$/gm), ['.import "StockRegisterModel.js" as Model']);
});

// ---- hand mutants -------------------------------------------------------------------------------------------------
const MUTANTS = [
  ['custom index moved', 'var CUSTOM_INDEX = 6', 'var CUSTOM_INDEX = 5'],
  ['chip label changed', '"This FY"', '"FY"'],
  ['row key renamed', '"reconciles", "openingText"', '"reconciles", "opening"'],
  ['chip above custom accepted', 'chipIndex > CUSTOM_INDEX)', 'chipIndex > CUSTOM_INDEX + 1)'],
  ['non-int chip accepted', '!_isInt(chipIndex) || ', ''],
  ['bad preset passes', 'return p.ok ? { ok: true, win: p } : { ok: false, text: Model.message("window") }', 'return { ok: true, win: p }'],
  ['bad custom passes', 'return c.ok ? { ok: true, win: c } :', 'return true ? { ok: true, win: c } :'],
  ['from text not trimmed', 'Model.customWindow(_trim(fromText),', 'Model.customWindow(fromText,'],
  ['to text not trimmed', '_trim(toText))', 'toText)'],
  ['custom error text lost', 'Model.customErrorText(c.error)', 'Model.message("window")'],
  ['busy not checked', 'if (c.loading === true) return', 'if (false) return'],
  ['busy loose', 'c.loading === true', 'c.loading'],
  ['busy kind wrong', 'kind: "busy", text: "" }\n    if', 'kind: "window", text: "" }\n    if'],
  ['bad window passes', 'if (!c.resolved || c.resolved.ok !== true) {', 'if (false) {'],
  ['resolved flag loose', 'c.resolved.ok !== true', 'c.resolved.ok === false'],
  ['role not checked', 'if (!Model.canView(c.role))', 'if (false)'],
  ['offline not checked', 'if (c.online !== true)', 'if (false)'],
  ['offline loose', 'if (c.online !== true)', 'if (c.online === false)'],
  ['badAnswer not checked', 'if (!v.ok) return', 'if (false) return'],
  ['showAll loose', '{ showAll: showAll === true }', '{ showAll: !!showAll }'],
  ['cancel replaces page', 'result.kind === "busy" || result.kind === "cancelled"', 'result.kind === "busy"'],
  ['busy replaces page', 'result.kind === "busy" || result.kind === "cancelled"', 'result.kind === "cancelled"'],
  ['retry flag strict', 'result.retryable !== false', 'result.retryable === true'],
  ['message fallback gone', ': Model.message(result.kind)', ': ""'],
  ['empty message kept', 'result.message !== "" ?', 'true ?'],
  ['cache body not checked', '|| !cached.body)', '|| false)'],
  ['from body null builds', 'return body ? _ok(body, win, showAll) : initialState()', 'return _ok(body, win, showAll)'],
  ['productId wrong', 'productId: r.id,', 'productId: r.title,'],
  ['reconciles dropped', 'reconciles: r.reconciles === true,', 'reconciles: true,'],
  ['reconciles loose', 'reconciles: r.reconciles === true,', 'reconciles: !!r.reconciles,'],
  ['as of Invalid Date guard gone', 'if (isNaN(d.getTime())) return ""', ''],
  ['as of summary unguarded', 'return summary && typeof summary === "object" ? asOfText(summary.readAt) : ""', 'return asOfText(summary.readAt)'],
  ['note not in name', 'r.note !== "" ? name', 'false ? name'],
  ['note always in name', 'r.note !== "" ? name', 'true ? name'],
  ['label ok wrong', 'if (status === "ok") return "Reload register"', 'if (status === "idle") return "Reload register"'],
  ['label retry loose', 'retryable === true) return "Try again"', 'true) return "Try again"'],
  ['toggle never closes', 'return current === productId ? "" : productId', 'return productId'],
  ['plural broken', 'n === 1 ? one : many', 'many'],
  ['hidden always shown', 'if (summary.hiddenQuiet > 0) t +=', 'if (true) t +='],
  ['mismatch always warned', 'summary.mismatches > 0', 'summary.mismatches >= 0'],
  ['skipped always warned', 'summary.skippedLedgerRows > 0', 'summary.skippedLedgerRows >= 0'],
  ['dropped always warned', 'summary.droppedBad > 0', 'summary.droppedBad >= 0'],
  ['dropped never warned', 'if (summary.droppedBad > 0)', 'if (false)'],
  ['empty text blind', 'if (summary.hiddenQuiet > 0) return "Nothing', 'if (true) return "Nothing'],
  ['as of offset gone', 'readAtMs + Model.IST_OFFSET_MS', 'readAtMs'],
  ['as of local date', 'd.getUTCDate() + " "', 'd.getDate() + " "'],
  ['as of local hour', 'var h = d.getUTCHours()', 'var h = d.getHours()'],
  ['as of midnight not 12', 'h % 12 === 0 ? 12 : h % 12', 'h === 0 ? 12 : h % 12'],
  ['as of noon not 12', 'h % 12 === 0 ? 12 : h % 12', 'h === 12 ? 0 : h % 12'],
  ['as of pm boundary', 'h < 12 ? "am"', 'h < 13 ? "am"'],
  ['as of minute pad', 'm < 10 ? "0" + m : m', 'm < 9 ? "0" + m : m'],
  ['as of zero accepted', 'readAtMs <= 0', 'readAtMs < 0'],
  ['refusal busy loud', 'd.kind === "busy") return null', 'false) return null'],
  ['refusal go loud', 'd.go === true ||', ''],
  ['refusal always retry', 'd.kind === "offline")', 'true)'],
  ['refusal never retry', 'd.kind === "offline")', 'false)'],
  ['inline error shown while typing blank', 'if (chipIndex === CUSTOM_INDEX && _trim(fromText) === "" && _trim(toText) === "") return ""', ''],
  ['inline error needs both blank', '_trim(fromText) === "" && _trim(toText) === ""', '_trim(fromText) === "" || _trim(toText) === ""'],
  ['inline error hidden when valid', 'if (resolved && resolved.ok === true) return ""', ''],
  ['inline error only custom blank', 'chipIndex === CUSTOM_INDEX && _trim', 'true && _trim'],
  ['caption ignores the answer', 'if (shownWin && typeof shownWin.text === "string" && shownWin.text !== "") return shownWin.text', ''],
  ['caption empty answer text used', 'shownWin.text !== "")', 'true)'],
  ['caption ignores the chips', 'resolved && resolved.ok === true && resolved.win ? resolved.win.text : ""', '""'],
  ['detail always open', 'return expandedId === productId ? Model.detailFor(body, productId) : []', 'return Model.detailFor(body, productId)'],
  ['ok state forgets the window', 'body: body, win: win, text', 'body: body, win: null, text']
];

test('SRP-05 every mutant text is really in the file (a missing one is a broken mutant, not a kill)', () => {
  const missing = MUTANTS.filter(([, from]) => !SRC.includes(from)).map(([n]) => n);
  assert.deepEqual(missing, []);
});

for (const [name, from, to] of MUTANTS) {
  test('SRP-M ' + name + ' is killed', () => {
    assert.ok(SRC.includes(from), 'mutant text present');
    // Under a zone that is NOT UTC, so a local-time getter and a UTC getter disagree (the sandbox runs in UTC).
    const was = process.env.TZ;
    let failures;
    try { process.env.TZ = 'Pacific/Auckland'; failures = battery(loadSrc(SRC.replace(from, to))); }
    catch (e) { failures = ['the battery threw: ' + e.message]; }   // a throw is a kill too
    finally { if (was === undefined) delete process.env.TZ; else process.env.TZ = was; }
    assert.ok(failures.length > 0, 'mutant survived: ' + name);
  });
}
