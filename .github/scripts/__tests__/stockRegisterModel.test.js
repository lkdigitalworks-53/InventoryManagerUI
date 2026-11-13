'use strict';

// P1 S4b-1: the pure helper qml/helper/StockRegisterModel.js (periods in IST, request body, error wording,
// answer check, row building). The battery is one function that COLLECTS failures, so the same assertions run
// on the real file (must be empty) and on every hand mutant (must not be empty). A small copy of the contract
// runs in the Qt JS engine in tests/tst_StockRegisterModel.qml (CI only).
// Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md
// Test plan: docs/superpowers/test-plans/2026-11-12-p1-s4b1-register-client-engine-test-plan.md

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '..', '..', '..');
const FILE = path.join(REPO, 'qml/helper/StockRegisterModel.js');
const SRC = fs.readFileSync(FILE, 'utf8');
const server = require(path.join(REPO, 'functions/lib/stockRegisterMath.js'));
const movement = require(path.join(REPO, 'functions/lib/movementLogic.js'));

const NAMES = ['IST_OFFSET_MS', 'REGISTER_ROLES', 'KINDS', 'KIND_LABELS', 'PRESETS', 'MSG', 'canView', 'istMidnight', 'istParts',
  'rangeText', 'presetWindow', 'customWindow', 'customErrorText', 'windowKey', 'requestBody', 'classify', 'message',
  'validateAnswer', 'fmtQty', 'buildView', 'detailLines', 'detailFor'];

function loadSrc(src) {
  const ctx = vm.createContext({});
  vm.runInContext(src.replace(/^\.pragma library/m, '') + '\n;this.__x = {' + NAMES.map((n) => n + ':' + n).join(',') + '}', ctx, { filename: FILE });
  return ctx.__x;
}
const plain = (v) => JSON.parse(JSON.stringify(v));
const OFF = 19800000;
const ist = (y, m0, d) => Date.UTC(y, m0, d) - OFF;           // independent oracle: IST midnight
const at = (y, m0, d, h, mi, s, ms) => Date.UTC(y, m0, d, h || 0, mi || 0, s || 0, ms || 0) - OFF; // an IST wall-clock instant
const JUNK = [undefined, null, NaN, Infinity, -Infinity, '', 'x', '1', true, false, {}, [], () => 1];

// ---- fixtures: the shape computeStockRegister really answers ---------------------------------------------
function product(over) {
  const kinds = {};
  for (const k of movement.MOVEMENT_KINDS) kinds[k] = { in: 0, out: 0 };
  return Object.assign({
    productId: 'p-abcdef123', name: 'Silk Saree', deleted: false, opening: 10, kinds, inTotal: 5, outTotal: 3, closing: 12,
    currentStock: 12, ledgerStock: 12, reconciles: true, movementCount: 4
  }, over);
}
function answer(win, products, extra) {
  return Object.assign({
    ok: true, window: { fromMs: win.fromMs, toMs: win.toMs }, readAt: 1700000000000, kinds: movement.MOVEMENT_KINDS.slice(),
    products, counts: { products: products.length, rowsSeen: 9, rowsInWindow: 5, mismatches: 0, skipped: { noProduct: 0, badKind: 0, badQty: 0, badTime: 0 } }
  }, extra);
}
const ROW_KEYS = ['closingText', 'currentText', 'deleted', 'id', 'inText', 'movementCount', 'moved', 'note', 'openingText', 'outText', 'reconciles', 'title'].sort();

// ---- the battery -------------------------------------------------------------------------------------------
function battery(m) {
  const bad = [];
  const eq = (name, got, want) => { if (JSON.stringify(plain(got)) !== JSON.stringify(want)) bad.push(name + ': got ' + JSON.stringify(plain(got)) + ' want ' + JSON.stringify(want)); };
  const T = (name, got) => eq(name, got === true, true);
  const W = (p, now) => plain(m.presetWindow(p, now));

  // constants keep their meaning
  eq('offset', m.IST_OFFSET_MS, OFF);
  eq('roles', m.REGISTER_ROLES, ['owner', 'admin', 'manager']);
  eq('kinds', m.KINDS, movement.MOVEMENT_KINDS);
  eq('labels cover kinds', movement.MOVEMENT_KINDS.every((k) => typeof m.KIND_LABELS[k] === 'string' && m.KIND_LABELS[k] !== ''), true);
  eq('presets', m.PRESETS, ['month', 'lastMonth', 'quarter', 'lastQuarter', 'fy', 'lastFy']);

  // canView
  for (const r of ['owner', 'admin', 'manager']) eq('canView ' + r, m.canView(r), true);
  for (const r of ['staff', '', 'Owner', 'OWNER', ' owner', 'constructor', '__proto__', 'toString', null, undefined, 1, ['owner'], { 0: 'owner' }]) eq('!canView ' + String(r), m.canView(r), false);

  // presets: a mid-month day
  const NOV = at(2026, 10, 12, 10);
  eq('month', W('month', NOV), { ok: true, preset: 'month', label: 'Nov 2026', fromMs: ist(2026, 10, 1), toMs: ist(2026, 11, 1), text: '1 Nov 2026 \u2013 30 Nov 2026 (IST)' });
  eq('lastMonth', W('lastMonth', NOV), { ok: true, preset: 'lastMonth', label: 'Oct 2026', fromMs: ist(2026, 9, 1), toMs: ist(2026, 10, 1), text: '1 Oct 2026 \u2013 31 Oct 2026 (IST)' });
  eq('quarter', W('quarter', NOV), { ok: true, preset: 'quarter', label: 'Q3 FY 2026-27 (Oct\u2013Dec)', fromMs: ist(2026, 9, 1), toMs: ist(2027, 0, 1), text: '1 Oct 2026 \u2013 31 Dec 2026 (IST)' });
  eq('lastQuarter', W('lastQuarter', NOV), { ok: true, preset: 'lastQuarter', label: 'Q2 FY 2026-27 (Jul\u2013Sep)', fromMs: ist(2026, 6, 1), toMs: ist(2026, 9, 1), text: '1 Jul 2026 \u2013 30 Sep 2026 (IST)' });
  eq('fy', W('fy', NOV), { ok: true, preset: 'fy', label: 'FY 2026-27', fromMs: ist(2026, 3, 1), toMs: ist(2027, 3, 1), text: '1 Apr 2026 \u2013 31 Mar 2027 (IST)' });
  eq('lastFy', W('lastFy', NOV), { ok: true, preset: 'lastFy', label: 'FY 2025-26', fromMs: ist(2025, 3, 1), toMs: ist(2026, 3, 1), text: '1 Apr 2025 \u2013 31 Mar 2026 (IST)' });

  // the IST midnight is the boundary, not the UTC one: 18:30 UTC on 31 March is already 1 April in India
  const lastInstantMar = at(2026, 2, 31, 23, 59, 59, 999);
  eq('Mar 31 23:59:59.999 IST is March', W('month', lastInstantMar).label, 'Mar 2026');
  eq('...and FY 2025-26', W('fy', lastInstantMar).label, 'FY 2025-26');
  eq('...and Q4', W('quarter', lastInstantMar).label, 'Q4 FY 2025-26 (Jan\u2013Mar)');
  const firstInstantApr = at(2026, 3, 1, 0, 0, 0, 0);
  eq('Apr 1 00:00 IST is April', W('month', firstInstantApr).label, 'Apr 2026');
  eq('...FY 2026-27', W('fy', firstInstantApr).label, 'FY 2026-27');
  eq('...Q1', W('quarter', firstInstantApr).label, 'Q1 FY 2026-27 (Apr\u2013Jun)');
  eq('...lastQuarter is Q4 of the old FY', W('lastQuarter', firstInstantApr).label, 'Q4 FY 2025-26 (Jan\u2013Mar)');
  eq('...lastMonth is March', W('lastMonth', firstInstantApr).label, 'Mar 2026');
  // 18:29:59.999 UTC on 31 March is IST 23:59:59.999 on 31 March; 18:30:00.000 UTC is IST 1 April
  eq('UTC edge, before', W('month', Date.UTC(2026, 2, 31, 18, 29, 59, 999)).label, 'Mar 2026');
  eq('UTC edge, at', W('month', Date.UTC(2026, 2, 31, 18, 30, 0, 0)).label, 'Apr 2026');

  // year edge, leap February, century
  const JAN1 = at(2026, 0, 1, 0, 0, 0, 0);
  eq('Jan 1 month', W('month', JAN1).label, 'Jan 2026');
  eq('Jan 1 lastMonth', [W('lastMonth', JAN1).label, W('lastMonth', JAN1).text], ['Dec 2025', '1 Dec 2025 \u2013 31 Dec 2025 (IST)']);
  eq('Jan 1 quarter', W('quarter', JAN1).label, 'Q4 FY 2025-26 (Jan\u2013Mar)');
  eq('Jan 1 lastQuarter', W('lastQuarter', JAN1).label, 'Q3 FY 2025-26 (Oct\u2013Dec)');
  eq('Jan 1 fy', W('fy', JAN1).label, 'FY 2025-26');
  eq('leap Feb 2028', W('month', at(2028, 1, 10)).text, '1 Feb 2028 \u2013 29 Feb 2028 (IST)');
  eq('non-leap Feb 2026', W('month', at(2026, 1, 10)).text, '1 Feb 2026 \u2013 28 Feb 2026 (IST)');
  eq('FY label rolls the century', W('fy', at(2099, 5, 1)).label, 'FY 2099-00');
  eq('FY label 2009-10', W('fy', at(2009, 5, 1)).label, 'FY 2009-10');

  // chains: no gap and no overlap between neighbours
  for (const now of [NOV, JAN1, firstInstantApr, lastInstantMar, at(2027, 5, 15), at(2028, 1, 29, 23)]) {
    eq('month chain ' + now, W('lastMonth', now).toMs, W('month', now).fromMs);
    eq('quarter chain ' + now, W('lastQuarter', now).toMs, W('quarter', now).fromMs);
    eq('fy chain ' + now, W('lastFy', now).toMs, W('fy', now).fromMs);
  }

  // bad input
  for (const p of JUNK.concat(['', 'Month', 'week', 'constructor', '__proto__', 'toString', 'custom'])) eq('bad preset ' + String(p), plain(m.presetWindow(p, NOV)), { ok: false, error: 'bad-preset' });
  for (const n of JUNK.concat([ist(2000, 0, 1) - 1, ist(2101, 0, 1), 8.64e15])) if (typeof n !== 'number' || !(n >= ist(2000, 0, 1) && n < ist(2101, 0, 1))) eq('bad now ' + String(n), plain(m.presetWindow('month', n)), { ok: false, error: 'bad-now' });
  eq('now lower edge ok', m.presetWindow('month', ist(2000, 0, 1)).ok, true);
  eq('now upper edge ok', m.presetWindow('month', ist(2101, 0, 1) - 1).ok, true);

  // customWindow
  eq('custom ok', plain(m.customWindow('2026-04-01', '2026-04-30')), { ok: true, preset: 'custom', label: '1 Apr 2026 \u2013 30 Apr 2026', fromMs: ist(2026, 3, 1), toMs: ist(2026, 4, 1), text: '1 Apr 2026 \u2013 30 Apr 2026 (IST)' });
  eq('custom one day is 24 h', (() => { const w = m.customWindow('2026-04-01', '2026-04-01'); return w.toMs - w.fromMs; })(), 86400000);
  eq('custom leap day ok', m.customWindow('2028-02-29', '2028-02-29').ok, true);
  eq('custom end of year', m.customWindow('2026-12-31', '2026-12-31').toMs, ist(2027, 0, 1));
  eq('custom bounds ok', [m.customWindow('2000-01-01', '2100-12-31').ok], [true]);
  eq('custom 2026-02-29', plain(m.customWindow('2026-02-29', '2026-03-01')), { ok: false, error: 'bad-from' });
  eq('custom 2026-04-31 to', plain(m.customWindow('2026-04-01', '2026-04-31')), { ok: false, error: 'bad-to' });
  for (const s of ['2026-4-1', '2026/04/01', ' 2026-04-01', '2026-04-01 ', '2026-04-01T00:00', '2026-13-01', '2026-00-10', '2026-04-00', '20260401', '', 'x', 20260401, null, undefined, {}, []]) {
    eq('custom bad from ' + JSON.stringify(s), plain(m.customWindow(s, '2026-04-30')), { ok: false, error: 'bad-from' });
    eq('custom bad to ' + JSON.stringify(s), plain(m.customWindow('2026-04-01', s)), { ok: false, error: 'bad-to' });
  }
  eq('custom from checked first', plain(m.customWindow('x', 'y')), { ok: false, error: 'bad-from' });
  eq('custom 1999', plain(m.customWindow('1999-12-31', '2026-01-01')), { ok: false, error: 'out-of-range' });
  eq('custom 2101', plain(m.customWindow('2026-01-01', '2101-01-01')), { ok: false, error: 'out-of-range' });
  eq('custom reversed', plain(m.customWindow('2026-04-30', '2026-04-01')), { ok: false, error: 'reversed' });
  eq('custom end one day before start (equal ms)', plain(m.customWindow('2026-04-02', '2026-04-01')), { ok: false, error: 'reversed' });
  eq('custom text', [m.customErrorText('bad-from'), m.customErrorText('bad-to'), m.customErrorText('out-of-range'), m.customErrorText('reversed')],
    ['Enter the start date as a real day.', 'Enter the end date as a real day.', 'Pick days between 2000 and 2100.', 'The end date is before the start date.']);
  for (const c of ['constructor', '__proto__', 'x', null, undefined, 3]) eq('custom text fallback ' + String(c), m.customErrorText(c), m.MSG.window);

  // windowKey, requestBody
  const w1 = m.presetWindow('month', NOV);
  eq('key', m.windowKey(w1), w1.fromMs + ':' + w1.toMs);
  for (const j of JUNK.concat([{ fromMs: 1 }, { toMs: 1 }, { fromMs: '1', toMs: 2 }, { fromMs: NaN, toMs: 2 }])) eq('key junk ' + JSON.stringify(j), m.windowKey(j), '');
  eq('body', plain(m.requestBody(w1)), { from: w1.fromMs, to: w1.toMs });
  eq('body has numbers', typeof m.requestBody(w1).from === 'number' && typeof m.requestBody(w1).to === 'number', true);

  // rangeText
  eq('rangeText junk', [m.rangeText(1, 1), m.rangeText(2, 1), m.rangeText('a', 2), m.rangeText(NaN, 2), m.rangeText(1, undefined)], ['', '', '', '', '']);

  // classify
  const C = (s, b) => plain(m.classify(s, b));
  const kindOf = (s, b) => C(s, b).kind;
  for (const s of [0, NaN, undefined, null, '0', Infinity]) eq('classify no answer ' + String(s), C(s, null), { kind: 'offline', message: m.MSG.offline, retryable: true });
  eq('401', C(401, { error: 'invalid-token' }), { kind: 'auth', message: m.MSG.auth, retryable: true });
  eq('401 no body', kindOf(401, null), 'auth');
  eq('403 role', C(403, { error: 'role-not-allowed' }), { kind: 'role', message: m.MSG.role, retryable: false });
  eq('403 tenant', C(403, { error: 'no-tenant-context' }), { kind: 'tenant', message: m.MSG.tenant, retryable: true });
  eq('403 no body', kindOf(403, null), 'tenant');
  eq('400 window', C(400, { error: 'invalid-window' }), { kind: 'window', message: m.MSG.window, retryable: false });
  eq('400 other', kindOf(400, { error: 'x' }), 'unknown');
  eq('400 no body', kindOf(400, null), 'unknown');
  eq('413', C(413, { error: 'ledger-too-large' }), { kind: 'tooLarge', message: m.MSG.tooLarge, retryable: false });
  eq('504', C(504, { error: 'ledger-scan-timeout' }), { kind: 'timeout', message: m.MSG.timeout, retryable: true });
  for (const s of [500, 502, 503, 599]) eq('5xx ' + s, C(s, { error: 'compute-failed' }), { kind: 'server', message: m.MSG.server, retryable: true });
  for (const s of [404, 405, 418, 302, 100]) eq('other ' + s, kindOf(s, null), 'unknown');
  for (const b of JUNK) eq('classify junk body ' + JSON.stringify(b), kindOf(403, b), 'tenant');
  eq('classify proto error code', kindOf(403, { error: '__proto__' }), 'tenant');
  for (const k of Object.keys(m.MSG)) if (k !== 'busy' && k !== 'cancelled') eq('message non-empty ' + k, m.MSG[k] !== '', true);
  eq('message busy/cancelled empty', [m.message('busy'), m.message('cancelled')], ['', '']);
  eq('message unknown key', [m.message('nope'), m.message('constructor'), m.message(undefined)], [m.MSG.unknown, m.MSG.unknown, m.MSG.unknown]);

  // validateAnswer
  const win = m.presetWindow('month', NOV);
  const good = answer(win, [product()]);
  eq('valid', plain(m.validateAnswer(good, win)), { ok: true });
  eq('empty products ok', plain(m.validateAnswer(answer(win, []), win)), { ok: true });
  for (const b of JUNK) eq('invalid body ' + JSON.stringify(b), plain(m.validateAnswer(b, win)).ok, false);
  eq('ok false', plain(m.validateAnswer(Object.assign({}, good, { ok: false }), win)), { ok: false, reason: 'not-ok' });
  eq('ok "true"', plain(m.validateAnswer(Object.assign({}, good, { ok: 'true' }), win)).reason, 'not-ok');
  eq('window from moved 1 ms', plain(m.validateAnswer(Object.assign({}, good, { window: { fromMs: win.fromMs + 1, toMs: win.toMs } }), win)), { ok: false, reason: 'window-mismatch' });
  eq('window to moved 1 ms', plain(m.validateAnswer(Object.assign({}, good, { window: { fromMs: win.fromMs, toMs: win.toMs - 1 } }), win)).reason, 'window-mismatch');
  eq('window as strings', plain(m.validateAnswer(Object.assign({}, good, { window: { fromMs: String(win.fromMs), toMs: String(win.toMs) } }), win)).reason, 'window-mismatch');
  eq('no window', plain(m.validateAnswer(Object.assign({}, good, { window: undefined }), win)).reason, 'window-mismatch');
  eq('products not array', plain(m.validateAnswer(Object.assign({}, good, { products: {} }), win)), { ok: false, reason: 'no-products' });
  for (const w of JUNK.filter((x) => x === null || typeof x !== 'object' || Array.isArray(x))) eq('validate bad win ' + JSON.stringify(w), plain(m.validateAnswer(good, w)), { ok: false, reason: 'bad-window' });

  // fmtQty
  const Q = [[0, '0'], [-0, '0'], [1, '1'], [12, '12'], [999, '999'], [1000, '1,000'], [12345, '12,345'], [99999, '99,999'], [100000, '1,00,000'],
    [1234567, '12,34,567'], [123456789, '12,34,56,789'], [0.5, '0.5'], [0.25, '0.25'], [1.2345, '1.235'], [1.0004, '1'], [0.0004, '0'], [-0.0004, '0'],
    [-5, '-5'], [-1234567.5, '-12,34,567.5'], [2.5e-9, '0'], [10.1, '10.1'], [1e6, '10,00,000']];
  for (const [n, s] of Q) eq('fmtQty ' + String(n), m.fmtQty(n), s);
  for (const j of JUNK.filter((x) => typeof x !== 'number' || !isFinite(x))) eq('fmtQty junk ' + JSON.stringify(j), m.fmtQty(j), '\u2014');

  // buildView
  const V = (b, o) => plain(m.buildView(b, win, o));
  const p1 = product();
  let v = V(answer(win, [p1]));
  eq('view ok', [v.ok, v.reason], [true, '']);
  eq('row exact', v.rows[0], { id: 'p-abcdef123', title: 'Silk Saree', note: '', deleted: false, reconciles: true, moved: true, movementCount: 4, openingText: '10', inText: '5', outText: '3', closingText: '12', currentText: '12' });
  eq('row keys sorted', Object.keys(v.rows[0]).sort(), ROW_KEYS);
  eq('summary', v.summary, { shown: 1, hiddenQuiet: 0, droppedBad: 0, mismatches: 0, skippedLedgerRows: 0, rowsInWindow: 5, windowText: win.text, label: win.label, hasWarning: false, readAt: 1700000000000 });

  // every row has the same keys and primitive types, whatever the product looks like
  const odd = [product({ name: null }), product({ productId: 'q2', name: '   ', deleted: true, reconciles: false, ledgerStock: 4 }), product({ productId: 'q3', name: 'A', reconciles: false, ledgerStock: 7, currentStock: 9 }),
    product({ productId: 'q4', opening: 1234567.891, inTotal: 0, outTotal: 0, closing: 1234567.891, movementCount: 0 })];
  v = V(answer(win, odd), { showAll: true });
  eq('odd rows kept', v.rows.length, 4);
  for (const r of v.rows) {
    eq('odd keys ' + r.id, Object.keys(r).sort(), ROW_KEYS);
    eq('odd types ' + r.id, Object.keys(r).map((k) => typeof r[k]).every((t) => t === 'string' || t === 'number' || t === 'boolean'), true);
  }
  eq('title fallback', v.rows[0].title, 'Product p-abcd');
  eq('blank name falls back', v.rows[1].title, 'Product q2');
  eq('name trimmed', V(answer(win, [product({ name: '  Kurta ' })])).rows[0].title, 'Kurta');
  eq('deleted note', V(answer(win, [product({ deleted: true })])).rows[0].note, 'Deleted product');
  eq('deleted + hole note', v.rows[1].note, 'Deleted product, ledger shows 4 left');
  eq('mismatch note', v.rows[2].note, 'Ledger 7 vs stock 9');
  eq('indian grouping in a row', v.rows[3].openingText, '12,34,567.891');

  // quiet rows
  const quiet = product({ productId: 'z', opening: 0, inTotal: 0, outTotal: 0, closing: 0, currentStock: 0, ledgerStock: 0, movementCount: 0, reconciles: true });
  v = V(answer(win, [p1, quiet]));
  eq('quiet hidden', [v.rows.map((r) => r.id), v.summary.hiddenQuiet], [['p-abcdef123'], 1]);
  v = V(answer(win, [p1, quiet]), { showAll: true });
  eq('quiet shown with showAll', [v.rows.map((r) => r.id), v.summary.hiddenQuiet], [['p-abcdef123', 'z'], 0]);
  for (const o of [undefined, null, {}, { showAll: 1 }, { showAll: 'true' }, { showAll: false }, 5]) eq('showAll only for true ' + JSON.stringify(o), V(answer(win, [quiet]), o).rows.length, 0);
  for (const [name, over] of [['opening', { opening: 1 }], ['in', { inTotal: 1 }], ['out', { outTotal: 1 }], ['closing', { closing: 1 }], ['movements', { movementCount: 1 }], ['mismatch', { reconciles: false, currentStock: 3 }]]) {
    eq('not quiet: ' + name, V(answer(win, [Object.assign({}, quiet, over)])).rows.length, 1);
  }
  eq('quiet but deleted still quiet (hole-free)', V(answer(win, [Object.assign({}, quiet, { deleted: true })])).rows.length, 0);

  // server order is kept; bad products are dropped AND counted
  const ordered = [product({ productId: 'b', name: 'B' }), product({ productId: 'a', name: 'A' }), product({ productId: 'c', name: null, deleted: true })];
  eq('order kept', V(answer(win, ordered)).rows.map((r) => r.id), ['b', 'a', 'c']);
  const badOnes = [null, 7, 'x', [], {}, product({ productId: '' }), product({ productId: 5 }), product({ opening: '1' }), product({ closing: NaN }), product({ reconciles: 'yes' }),
    product({ deleted: 0 }), product({ movementCount: undefined }), product({ currentStock: null }), product({ ledgerStock: Infinity })];
  v = V(answer(win, [p1].concat(badOnes)));
  eq('bad products dropped', [v.rows.length, v.summary.droppedBad, v.summary.hasWarning], [1, badOnes.length, true]);

  // warnings
  v = V(answer(win, [p1], { counts: { rowsInWindow: 5, skipped: { noProduct: 1, badKind: 2, badQty: 0, badTime: 3, junk: 'x', numeric: '5', neg: 4 } } }));
  eq('skipped summed (numbers only)', [v.summary.skippedLedgerRows, v.summary.hasWarning], [10, true]);
  v = V(answer(win, [p1], { counts: undefined }));
  eq('no counts', [v.ok, v.summary.skippedLedgerRows, v.summary.rowsInWindow, v.summary.hasWarning], [true, 0, 0, false]);
  v = V(answer(win, [p1], { counts: { skipped: [1, 2] } }));
  eq('skipped as array ignored', v.summary.skippedLedgerRows, 0);
  v = V(answer(win, [product({ reconciles: false, ledgerStock: 1, currentStock: 2 })]));
  eq('mismatch warns', [v.summary.mismatches, v.summary.hasWarning], [1, true]);
  v = V(answer(win, [p1], { readAt: 'x' }));
  eq('readAt junk is 0', v.summary.readAt, 0);

  // refused answers give no rows
  eq('mismatched window refused', plain(m.buildView(Object.assign(answer(win, [p1]), { window: { fromMs: 1, toMs: 2 } }), win)), { ok: false, reason: 'window-mismatch', rows: [], summary: null });
  eq('junk body refused', plain(m.buildView(null, win)).rows, []);
  eq('does not modify its input', (() => { const b = answer(win, [p1]); const before = JSON.stringify(b); m.buildView(b, win, { showAll: true }); return JSON.stringify(b) === before; })(), true);

  // detail lines
  const k = {}; for (const kk of movement.MOVEMENT_KINDS) k[kk] = { in: 0, out: 0 };
  eq('detail none', plain(m.detailLines(product({ kinds: k }))), []);
  k.sale = { in: 0, out: 3 }; k.receipt = { in: 10, out: 0 }; k.adjustment = { in: 1.5, out: 2 };
  eq('detail order and zeros', plain(m.detailLines(product({ kinds: k }))), [
    { kind: 'receipt', label: 'Received', inText: '10', outText: '0' }, { kind: 'sale', label: 'Sold', inText: '0', outText: '3' },
    { kind: 'adjustment', label: 'Adjustment', inText: '1.5', outText: '2' }]);
  k.future_kind = { in: 0, out: 4 };
  eq('detail unknown kind last', plain(m.detailLines(product({ kinds: k }))).pop(), { kind: 'future_kind', label: 'future_kind', inText: '0', outText: '4' });
  eq('detail ignores junk entries', plain(m.detailLines({ kinds: { sale: 5, loss: null, gift: { in: 'x', out: 2 }, theft: [] } })), [{ kind: 'gift', label: 'Gift', inText: '0', outText: '2' }]);
  for (const j of JUNK) eq('detail junk ' + JSON.stringify(j), plain(m.detailLines(j)), []);
  eq('detailFor', plain(m.detailFor(answer(win, [product({ productId: 'a', kinds: k })]), 'a')).length, 4);
  eq('detailFor picks the right product', plain(m.detailFor(answer(win, [product({ productId: 'a', kinds: {} }), product({ productId: 'b', kinds: k })]), 'b')).length, 4);
  eq('detailFor unknown id', plain(m.detailFor(answer(win, [p1]), 'nope')), []);
  eq('detailFor junk', [plain(m.detailFor(null, 'a')), plain(m.detailFor({ products: 3 }, 'a'))], [[], []]);
  return bad;
}

const REAL = loadSrc(SRC);

test('SRM-01 the battery passes on the real file', () => {
  const bad = battery(REAL);
  assert.deepEqual(bad, [], bad.slice(0, 5).join('\n'));
});

test('SRM-02 periods do not depend on the phone time zone', () => {
  const was = process.env.TZ;
  try {
    const results = [];
    for (const tz of ['UTC', 'Asia/Kolkata', 'America/Los_Angeles', 'Pacific/Kiritimati', 'Australia/Lord_Howe']) {
      process.env.TZ = tz;
      const fresh = loadSrc(SRC);
      const row = [];
      for (const now of [at(2026, 10, 12, 10), at(2026, 2, 31, 23, 59), at(2026, 3, 1, 0, 1), at(2026, 0, 1)]) {
        for (const p of REAL.PRESETS) row.push(plain(fresh.presetWindow(p, now)));
      }
      row.push(plain(fresh.customWindow('2026-04-01', '2026-04-30')));
      results.push(JSON.stringify(row));
    }
    for (const r of results) assert.equal(r, results[0]);
  } finally {
    if (was === undefined) delete process.env.TZ; else process.env.TZ = was;
  }
});

test('SRM-03 monkey: 3000 random instants keep every period property', () => {
  let seed = 20261112;
  const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
  const lo = ist(2000, 0, 1), hi = ist(2101, 0, 1);
  const seen = { month28: 0, month29: 0, month30: 0, month31: 0, q: new Set(), fy365: 0, fy366: 0 };
  for (let i = 0; i < 3000; i++) {
    const now = Math.floor(lo + rnd() * (hi - lo));
    const w = {};
    for (const p of REAL.PRESETS) { w[p] = plain(REAL.presetWindow(p, now)); assert.equal(w[p].ok, true); }
    for (const p of REAL.PRESETS) {
      assert.ok(w[p].fromMs < w[p].toMs, p);
      assert.equal((w[p].fromMs + OFF) % 86400000, 0, p + ' starts at IST midnight');
      assert.equal((w[p].toMs + OFF) % 86400000, 0, p + ' ends at IST midnight');
    }
    for (const p of ['month', 'quarter', 'fy']) assert.ok(w[p].fromMs <= now && now < w[p].toMs, p + ' contains now');
    assert.equal(w.lastMonth.toMs, w.month.fromMs);
    assert.equal(w.lastQuarter.toMs, w.quarter.fromMs);
    assert.equal(w.lastFy.toMs, w.fy.fromMs);
    assert.ok(w.fy.fromMs <= w.quarter.fromMs && w.quarter.toMs <= w.fy.toMs, 'quarter inside FY');
    assert.ok(w.quarter.fromMs <= w.month.fromMs && w.month.toMs <= w.quarter.toMs, 'month inside quarter');
    const days = (x) => (x.toMs - x.fromMs) / 86400000;
    assert.ok(Number.isInteger(days(w.month)) && days(w.month) >= 28 && days(w.month) <= 31);
    assert.ok([90, 91, 92].includes(days(w.quarter)) || days(w.quarter) === 89 || days(w.quarter) === 90, 'quarter days ' + days(w.quarter));
    assert.ok(days(w.fy) === 365 || days(w.fy) === 366);
    seen['month' + days(w.month)]++; seen.q.add(w.quarter.label.slice(0, 2)); seen['fy' + days(w.fy)]++;
    assert.match(w.month.text, /^\d{1,2} [A-Z][a-z]{2} \d{4} \u2013 \d{1,2} [A-Z][a-z]{2} \d{4} \(IST\)$/);
    // a custom window built from the same days equals the month window
    const a = REAL.istParts(w.month.fromMs), b = REAL.istParts(w.month.toMs - 1);
    const pad = (n) => (n < 10 ? '0' : '') + n;
    const cw = plain(REAL.customWindow(a.y + '-' + pad(a.m + 1) + '-' + pad(a.d), b.y + '-' + pad(b.m + 1) + '-' + pad(b.d)));
    assert.equal(cw.fromMs, w.month.fromMs); assert.equal(cw.toMs, w.month.toMs);
  }
  // the monkey reached every outcome it claims to cover
  for (const k of ['month28', 'month29', 'month30', 'month31', 'fy365', 'fy366']) assert.ok(seen[k] > 0, k + ' reached');
  assert.equal(seen.q.size, 4, 'all four quarters reached');
});

test('SRM-04 monkey: random answers never throw and every row is flat', () => {
  let seed = 7;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const win = REAL.presetWindow('fy', at(2026, 10, 12));
  let shown = 0, dropped = 0, quiet = 0;
  for (let i = 0; i < 1500; i++) {
    const products = [];
    for (let j = 0; j < Math.floor(rnd() * 8); j++) {
      const p = product({ productId: pick(['a', 'b', 'c', '', 5, null]) + j, name: pick(['N', '', null, '  x  ', 7, undefined]), deleted: pick([true, false, 1]),
        opening: pick([0, 1, -1, 1e7, 0.123456, NaN, '2']), inTotal: pick([0, 3, 2.5]), outTotal: pick([0, 1]), closing: pick([0, 4, -2]),
        currentStock: pick([0, 4]), ledgerStock: pick([0, 4, 1e-12]), reconciles: pick([true, false, 'x']), movementCount: pick([0, 0, 3, undefined]) });
      const q = product({ productId: 'q' + j, opening: 0, inTotal: 0, outTotal: 0, closing: 0, currentStock: 0, ledgerStock: 0, movementCount: 0, reconciles: true });
      products.push(pick([p, p, p, q, q, null, 3, {}]));
    }
    const v = plain(REAL.buildView(answer(win, products), win, { showAll: rnd() < 0.5 }));
    assert.equal(v.ok, true);
    for (const r of v.rows) {
      assert.deepEqual(Object.keys(r).sort(), ROW_KEYS);
      for (const k of Object.keys(r)) assert.ok(['string', 'number', 'boolean'].includes(typeof r[k]), k);
      for (const k of ['openingText', 'inText', 'outText', 'closingText', 'currentText']) assert.ok(!/NaN|undefined|Infinity|-0$/.test(r[k]), k + ' ' + r[k]);
    }
    assert.equal(v.rows.length + v.summary.droppedBad + v.summary.hiddenQuiet, products.length);
    shown += v.rows.length; dropped += v.summary.droppedBad; quiet += v.summary.hiddenQuiet;
  }
  assert.ok(shown > 0 && dropped > 0 && quiet > 0, 'all three outcomes reached: ' + [shown, dropped, quiet]);
});

test('SRM-05 contract: the real server answer builds a view and reconciles with it', () => {
  const win = REAL.presetWindow('month', at(2026, 10, 12));
  const T = (y, m, d, h) => at(y, m, d, h || 12);
  const rows = [
    { productId: 'p1', kind: 'receipt', qty: 20, serverTimestamp: T(2026, 9, 20), productName: 'Silk Saree' },     // before: opening
    { productId: 'p1', kind: 'sale', qty: -4, serverTimestamp: T(2026, 10, 3), productName: 'Silk Saree' },
    { productId: 'p1', kind: 'loss', qty: -1, serverTimestamp: T(2026, 10, 9) },
    { productId: 'p1', kind: 'receipt', qty: 2, serverTimestamp: at(2026, 10, 1, 0, 0, 0, 0) },                   // exactly at from: in window
    { productId: 'p1', kind: 'sale', qty: -1, serverTimestamp: at(2026, 11, 1, 0, 0, 0, 0) },                      // exactly at to: NOT in window
    { productId: 'p2', kind: 'receipt', qty: 5, serverTimestamp: T(2026, 10, 2), productName: 'Gone' },
    { productId: 'p3', kind: 'sale', qty: 3, serverTimestamp: T(2026, 10, 2) },                                     // against direction: skipped
    { productId: 'p4', kind: 'weird', qty: 1, serverTimestamp: T(2026, 10, 2) }
  ];
  const inv = [{ productId: 'p1', name: 'Silk Saree', stock: 16 }, { productId: 'p9', name: 'Never moved', stock: 6 }, { productId: 'p8', name: 'Empty', stock: 0 }];
  const reg = server.buildRegister(rows, inv, { fromMs: win.fromMs, toMs: win.toMs });
  const body = Object.assign({ ok: true, window: { fromMs: win.fromMs, toMs: win.toMs }, readAt: 1 }, JSON.parse(JSON.stringify(reg)));
  const v = plain(REAL.buildView(body, win));
  assert.equal(v.ok, true);
  const byId = Object.fromEntries(v.rows.map((r) => [r.id, r]));
  assert.deepEqual([byId.p1.openingText, byId.p1.inText, byId.p1.outText, byId.p1.closingText], ['20', '2', '5', '17']);
  // the ledger total (16) includes the row exactly at `to` that the period leaves out, so it equals the stock doc
  assert.deepEqual([byId.p1.reconciles, byId.p1.note], [true, '']);
  assert.equal(byId.p2.note, 'Deleted product, ledger shows 5 left');
  assert.equal(byId.p2.title, 'Gone');
  assert.equal(byId.p9.note, 'Ledger 0 vs stock 6');             // stock with no ledger row at all is exposed
  assert.equal(byId.p8, undefined);                              // empty and never moved: quiet, hidden
  assert.equal(v.summary.skippedLedgerRows, 2);
  assert.equal(v.summary.hasWarning, true);
  assert.deepEqual(plain(REAL.detailFor(body, 'p1')).map((d) => d.kind), ['receipt', 'sale', 'loss']);
  // adjacent periods chain through the client windows: closing of last month = opening of this month
  const prev = REAL.presetWindow('lastMonth', at(2026, 10, 12));
  const regPrev = JSON.parse(JSON.stringify(server.buildRegister(rows, inv, { fromMs: prev.fromMs, toMs: prev.toMs })));
  const p1prev = regPrev.products.find((p) => p.productId === 'p1');
  const p1now = reg.products.find((p) => p.productId === 'p1');
  assert.equal(p1prev.closing, p1now.opening);
});

// ---- guards ---------------------------------------------------------------------------------------------------

test('SRM-06 guards: role list, kind list and labels equal the server; no local-time getters; pure file', () => {
  assert.deepEqual(plain(REAL.REGISTER_ROLES), server.REGISTER_ROLES);
  assert.deepEqual(plain(REAL.KINDS), movement.MOVEMENT_KINDS);
  assert.deepEqual(Object.keys(REAL.KIND_LABELS).sort(), movement.MOVEMENT_KINDS.slice().sort());
  const code = SRC.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
  assert.doesNotMatch(code, /\.get(FullYear|Month|Date|Day|Hours|Minutes|Seconds|TimezoneOffset)\s*\(/, 'local-time getter');
  assert.doesNotMatch(code, /new Date\(\s*[^)]*,/, 'local-time Date constructor');
  assert.doesNotMatch(code, /\bDate\.now\s*\(|new Date\(\s*\)/, 'reads the clock: the caller passes now');
  assert.doesNotMatch(code, /^\s*(import|\.import)\s/m, 'a pure helper imports nothing');
  assert.match(SRC, /^\.pragma library/m);
});

// ---- hand mutants: every one must be noticed by the battery ----------------------------------------------------
const MUTANTS = [
  ['offset zero', 'var IST_OFFSET_MS = 19800000', 'var IST_OFFSET_MS = 0'],
  ['offset 5h', 'var IST_OFFSET_MS = 19800000', 'var IST_OFFSET_MS = 18000000'],
  ['role added', 'var REGISTER_ROLES = ["owner", "admin", "manager"]', 'var REGISTER_ROLES = ["owner", "admin", "manager", "staff"]'],
  ['role dropped', 'var REGISTER_ROLES = ["owner", "admin", "manager"]', 'var REGISTER_ROLES = ["owner", "admin"]'],
  ['canView loose compare', 'return REGISTER_ROLES.indexOf(role) >= 0', 'return REGISTER_ROLES.some(function (r) { return r == role })'],
  ['FY starts in March', 'p.m >= 3 ? p.y : p.y - 1', 'p.m >= 2 ? p.y : p.y - 1'],
  ['FY starts in January', 'p.m >= 3 ? p.y : p.y - 1', 'p.y'],
  ['quarter off by one month', 'var qStartMonth = 3 + 3 * q', 'var qStartMonth = 2 + 3 * q'],
  ['quarter index', '((p.m - 3 + 12) % 12) / 3', '((p.m - 2 + 12) % 12) / 3'],
  ['last month same as month', 'var mo = preset === "month" ? p.m : p.m - 1', 'var mo = p.m'],
  ['month end inclusive', 'istMidnight(p.y, mo + 1, 1))', 'istMidnight(p.y, mo + 1, 1) + 1)'],
  ['last quarter same as quarter', 'var sm = preset === "quarter" ? qStartMonth : qStartMonth - 3', 'var sm = qStartMonth'],
  ['quarter FY label for Jan-Mar', 'var fyOfQ = sm < 3 ? fyYear - 1 : fyYear', 'var fyOfQ = fyYear'],
  ['last FY same as FY', 'var y = preset === "fy" ? fyYear : fyYear - 1', 'var y = fyYear'],
  ['FY label two digits', 'return "FY " + fyYear + "-" + _pad2((fyYear + 1) % 100)', 'return "FY " + fyYear + "-" + (fyYear + 1)'],
  ['preset check dropped', 'if (typeof preset !== "string" || PRESETS.indexOf(preset) < 0) return { ok: false, error: "bad-preset" }', ''],
  ['now range dropped', 'nowMs < istMidnight(MIN_YEAR, 0, 1) || nowMs >= istMidnight(MAX_YEAR + 1, 0, 1)', 'false'],
  ['now lower edge', 'nowMs < istMidnight(MIN_YEAR, 0, 1)', 'nowMs <= istMidnight(MIN_YEAR, 0, 1)'],
  ['now upper edge', 'nowMs >= istMidnight(MAX_YEAR + 1, 0, 1)', 'nowMs > istMidnight(MAX_YEAR + 1, 0, 1)'],
  ['day-in-month dropped', 'if (d < 1 || d > _daysInMonth(y, mo)) return null', 'if (d < 1 || d > 31) return null'],
  ['custom end exclusive', 'var toMs = istMidnight(t.y, t.m - 1, t.d + 1)', 'var toMs = istMidnight(t.y, t.m - 1, t.d)'],
  ['custom reversed allowed', 'if (toMs <= fromMs) return { ok: false, error: "reversed" }', ''],
  ['custom reversed equal allowed', 'if (toMs <= fromMs)', 'if (toMs < fromMs)'],
  ['custom year min', 'if (y < MIN_YEAR || y > MAX_YEAR) return { range: true }', 'if (y > MAX_YEAR) return { range: true }'],
  ['custom year max', 'if (y < MIN_YEAR || y > MAX_YEAR) return { range: true }', 'if (y < MIN_YEAR) return { range: true }'],
  ['custom bad-to first', 'if (f === null) return { ok: false, error: "bad-from" }\n    if (t === null) return { ok: false, error: "bad-to" }', 'if (t === null) return { ok: false, error: "bad-to" }\n    if (f === null) return { ok: false, error: "bad-from" }'],
  ['custom regex loose', '/^(\\d{4})-(\\d{2})-(\\d{2})$/', '/(\\d{4})-(\\d{1,2})-(\\d{1,2})/'],
  ['custom error lookup unsafe', 'return (typeof code === "string" && _has(CUSTOM_ERROR_TEXT, code)) ? CUSTOM_ERROR_TEXT[code] : MSG.window', 'return CUSTOM_ERROR_TEXT[code] || MSG.window'],
  ['window key accepts strings', 'return _isObj(win) && _isNum(win.fromMs) && _isNum(win.toMs) ?', 'return _isObj(win) ?'],
  ['body sends dates', 'return { from: win.fromMs, to: win.toMs }', 'return { from: new Date(win.fromMs).toISOString(), to: new Date(win.toMs).toISOString() }'],
  ['status 0 is not offline', 'if (!_isNum(status) || status === 0)', 'if (!_isNum(status))'],
  ['401 not auth', 'if (status === 401) return { kind: "auth"', 'if (status === 4010) return { kind: "auth"'],
  ['role retryable', 'kind: "role", message: MSG.role, retryable: false', 'kind: "role", message: MSG.role, retryable: true'],
  ['403 any is role', 'if (code === "role-not-allowed") return', 'if (true) return'],
  ['window error any 400', 'if (status === 400 && code === "invalid-window")', 'if (status === 400)'],
  ['413 retryable', 'kind: "tooLarge", message: MSG.tooLarge, retryable: false', 'kind: "tooLarge", message: MSG.tooLarge, retryable: true'],
  ['504 is plain server', 'if (status === 504) return', 'if (status === 5040) return'],
  ['5xx boundary', 'if (status >= 500) return', 'if (status > 500) return'],
  ['message lookup unsafe', 'return _has(MSG, key) ? MSG[key] : MSG.unknown', 'return MSG[key] || MSG.unknown'],
  ['echoed window not checked', 'if (!_isObj(body.window) || body.window.fromMs !== win.fromMs || body.window.toMs !== win.toMs) {', 'if (false) {'],
  ['only from checked', 'body.window.fromMs !== win.fromMs || body.window.toMs !== win.toMs', 'body.window.fromMs !== win.fromMs'],
  ['only to checked', 'body.window.fromMs !== win.fromMs || body.window.toMs !== win.toMs', 'body.window.toMs !== win.toMs'],
  ['loose window compare', 'body.window.fromMs !== win.fromMs || body.window.toMs !== win.toMs', 'body.window.fromMs != win.fromMs || body.window.toMs != win.toMs'],
  ['ok truthy', 'if (!_isObj(body) || body.ok !== true)', 'if (!_isObj(body) || !body.ok)'],
  ['products not checked', 'if (!Array.isArray(body.products)) return { ok: false, reason: "no-products" }', ''],
  ['win not checked', 'if (!_isObj(win)) return { ok: false, reason: "bad-window" }', ''],
  ['qty -0 shown', 'if (r === 0) return "0"', ''],
  ['qty no grouping', 'ip = head.replace(/\\B(?=(\\d{2})+(?!\\d))/g, ",") + "," + tail', 'ip = head + tail'],
  ['qty western grouping', 'head.replace(/\\B(?=(\\d{2})+(?!\\d))/g, ",")', 'head.replace(/\\B(?=(\\d{3})+(?!\\d))/g, ",")'],
  ['qty 2 decimals', 'r.toFixed(3)', 'r.toFixed(2)'],
  ['qty keeps zeros', '.replace(/\\.?0+$/, "")', ''],
  ['qty sign lost', 'return (n < 0 ? "-" : "") + ip', 'return ip'],
  ['qty junk shown as number', 'if (!_isNum(n)) return "\\u2014"', 'if (typeof n !== "number") return "\\u2014"'],
  ['title not trimmed', 'var nm = typeof p.name === "string" ? p.name.trim() : ""', 'var nm = typeof p.name === "string" ? p.name : ""'],
  ['deleted note lost', 'return p.reconciles === true ? "Deleted product"', 'return p.reconciles === false ? "Deleted product"'],
  ['mismatch note lost', 'if (p.reconciles !== true) return "Ledger "', 'if (false) return "Ledger "'],
  ['quiet ignores mismatch', 'p.closing === 0 &&\n           p.reconciles === true', 'p.closing === 0'],
  ['quiet ignores movement', 'return p.movementCount === 0 && p.opening === 0', 'return p.opening === 0'],
  ['quiet ignores opening', 'p.movementCount === 0 && p.opening === 0 &&', 'p.movementCount === 0 &&'],
  ['quiet ignores out', 'p.inTotal === 0 && p.outTotal === 0 &&', 'p.inTotal === 0 &&'],
  ['showAll truthy', 'opts.showAll === true', 'opts.showAll'],
  ['showAll ignored', 'if (!showAll && _isQuiet(p))', 'if (_isQuiet(p))'],
  ['bad product kept', 'if (!_validProduct(p)) { dropped++; continue }', ''],
  ['dropped not counted', 'if (!_validProduct(p)) { dropped++; continue }', 'if (!_validProduct(p)) { continue }'],
  ['quiet not counted', 'if (!showAll && _isQuiet(p)) { quiet++; continue }', 'if (!showAll && _isQuiet(p)) { continue }'],
  ['validProduct loose id', 'typeof p.productId === "string" && p.productId !== "" &&', 'typeof p.productId === "string" &&'],
  ['validProduct loose reconciles', 'typeof p.reconciles === "boolean" &&', ''],
  ['validProduct loose deleted', 'typeof p.deleted === "boolean"', 'true'],
  ['skipped not summed', 'if (_has(sk, k) && _isNum(sk[k])) skipped += sk[k]', ''],
  ['skipped non-number summed', 'if (_has(sk, k) && _isNum(sk[k])) skipped += sk[k]', 'if (_has(sk, k)) skipped += Number(sk[k]) || 0'],
  ['warning ignores skipped', 'hasWarning: skipped > 0 || dropped > 0 || mismatches > 0', 'hasWarning: dropped > 0 || mismatches > 0'],
  ['warning ignores dropped', 'hasWarning: skipped > 0 || dropped > 0 || mismatches > 0', 'hasWarning: skipped > 0 || mismatches > 0'],
  ['warning ignores mismatch', 'hasWarning: skipped > 0 || dropped > 0 || mismatches > 0', 'hasWarning: skipped > 0 || dropped > 0'],
  ['row not flat', 'moved: p.movementCount > 0,', 'moved: p.movementCount > 0, extra: [],'],
  ['row key missing', 'currentText: fmtQty(p.currentStock)', ''],
  ['rows resorted', 'rows.push({', 'rows.unshift({'],
  ['detail zero kept', 'if (i === 0 && o === 0) return', ''],
  ['detail order lost', 'for (var a = 0; a < KINDS.length; a++) if (_has(product.kinds, KINDS[a])) add(KINDS[a])', 'for (var k0 in product.kinds) if (_has(product.kinds, k0)) add(k0)'],
  ['detail unknown dropped', 'for (var k in product.kinds) if (_has(product.kinds, k) && KINDS.indexOf(k) < 0) add(k)', ''],
  ['detail junk number', 'var i = _isNum(e.in) ? e.in : 0', 'var i = e.in'],
  ['detailFor wrong id', 'if (_isObj(p) && p.productId === productId) return detailLines(p)', 'if (_isObj(p)) return detailLines(p)']
];

test('SRM-07 every hand mutant is noticed by the battery', () => {
  const survivors = [], broken = [];
  for (const [name, from, to] of MUTANTS) {
    if (!SRC.includes(from)) { broken.push(name); continue; }          // a mutant that changes nothing proves nothing
    if (SRC.split(from).length - 1 !== 1) { broken.push(name + ' (ambiguous)'); continue; }
    let mutated;
    try { mutated = loadSrc(SRC.replace(from, to)); } catch (e) { continue; }   // does not even load: killed
    let bad;
    try { bad = battery(mutated); } catch (e) { continue; }                      // throws: killed
    if (bad.length === 0) survivors.push(name);
  }
  assert.deepEqual(broken, [], 'mutants whose text is not in the file (not kills): ' + broken.join(', '));
  assert.deepEqual(survivors, [], 'survivors: ' + survivors.join(', '));
});
