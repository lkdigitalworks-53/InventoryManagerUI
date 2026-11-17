'use strict';

// P1 S4b-2: the pure page controller qml/helper/StockRegisterFlow.js (state transitions, the request, what the
// page paints). The battery is ONE function that COLLECTS failures, so the same assertions run on the real file
// (must be empty) and on every hand mutant (must not be empty). It runs the real flow against the real
// StockRegisterModel.js and a scripted fake service. A copy of the main cases runs in the Qt JS engine in
// tests/tst_StockRegisterFlow.qml (CI only).
// Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md (S4b-2 addendum)
// Test plan: docs/superpowers/test-plans/2026-11-17-p1-s4b2-register-page-test-plan.md

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { load } = require(path.join('..', '..', '..', 'functions', 'test', 'testSupport', 'qmlHelpers.js'));

const REPO = path.resolve(__dirname, '..', '..', '..');
const FILE = path.join(REPO, 'qml/helper/StockRegisterFlow.js');
const SRC = fs.readFileSync(FILE, 'utf8');
const M = load('StockRegisterModel.js');
const plain = (v) => JSON.parse(JSON.stringify(v));

function loadSrc(src) {
  const ctx = { M };
  vm.runInNewContext(src.replace(/^\.pragma library\s*$/m, '').replace(/^\.import "[^"]+" as \w+\s*$/gm, ''), ctx, { filename: FILE });
  return ctx;
}

const OFF = 19800000;
const at = (y, m0, d, h, mi) => Date.UTC(y, m0, d, h || 0, mi || 0) - OFF;     // an IST wall-clock instant
const NOW = at(2026, 10, 12, 10, 0);                                          // 12 Nov 2026, 10:00 IST
const VIEW_KEYS = ['asOf', 'canCancel', 'canLoad', 'canRetry', 'caption', 'captionIsError', 'chipIndex', 'chips', 'custom', 'dayNote',
  'emptyText', 'errorText', 'hasData', 'hasWarning', 'loadLabel', 'loading', 'locked', 'periodNote', 'rows', 'running', 'showAll',
  'showToggle', 'staleNote', 'summaryText', 'toggleText', 'warnings'].sort();
const ROW_KEYS = ['closingText', 'currentText', 'deleted', 'id', 'inText', 'movementCount', 'moved', 'note', 'openingText', 'outText', 'reconciles', 'title'].sort();

// ---- fixtures ---------------------------------------------------------------------------------------------
function product(over) {
  return Object.assign({
    productId: 'p-abcdef123', name: 'Silk Saree', deleted: false, opening: 10,
    kinds: { sale: { in: 0, out: 3 }, receipt: { in: 5, out: 0 } },
    inTotal: 5, outTotal: 3, closing: 12, currentStock: 12, ledgerStock: 12, reconciles: true, movementCount: 4
  }, over);
}
function quiet(id) {
  return { productId: id, name: 'Quiet ' + id, deleted: false, opening: 0, kinds: {}, inTotal: 0, outTotal: 0, closing: 0, currentStock: 0, ledgerStock: 0, reconciles: true, movementCount: 0 };
}
function answer(win, products, extra) {
  return Object.assign({
    ok: true, window: { fromMs: win.fromMs, toMs: win.toMs }, readAt: at(2026, 10, 12, 9, 5), products,
    counts: { rowsInWindow: 5, skipped: { noProduct: 0, badKind: 0 } }
  }, extra);
}
const OK = (win, products, extra) => ({ ok: true, body: answer(win, products, extra), window: win });
const FAIL = (kind, retryable) => ({ ok: false, kind, message: M.message(kind), retryable: retryable !== false });

function fakeSvc() {
  const s = { calls: [], cancels: 0, clears: 0, cache: null, pending: null, sync: null };
  s.cached = (win) => (s.cache && M.windowKey(s.cache.window) === M.windowKey(win) ? s.cache : null);
  s.load = (win, cb) => {
    s.calls.push(win);
    if (s.hook) s.hook(win);
    if (s.sync) { cb(s.sync(win)); return false; }
    s.pending = cb;
    return true;
  };
  s.answer = (r) => { const cb = s.pending; s.pending = null; if (cb) cb(r); };
  s.cancel = () => { s.cancels++; if (s.pending) { const cb = s.pending; s.pending = null; cb(FAIL('cancelled')); } };
  s.clear = () => { s.clears++; s.cache = null; };
  return s;
}
function box(state) {
  const b = { state, log: [] };
  b.ctx = { get: () => b.state, set: (n) => { b.state = n; b.log.push(n.phase); } };
  return b;
}

// ---- the battery ---------------------------------------------------------------------------------------------
function battery(F) {
  const bad = [];
  const eq = (name, got, want) => { if (JSON.stringify(plain(got)) !== JSON.stringify(want)) bad.push(name + ': got ' + JSON.stringify(plain(got)) + ' want ' + JSON.stringify(want)); };
  const T = (name, got) => eq(name, got === true, true);
  const F0 = (name, got) => eq(name, got === false, true);
  const same = (name, a, b) => { if (a !== b) bad.push(name + ': not the same object'); };
  const monthWin = M.presetWindow('month', NOW);
  const lastWin = M.presetWindow('lastMonth', NOW);
  const shown = (svc, win, products) => { const r = OK(win, products || [product()]); svc.cache = { body: r.body, window: win }; return r; };

  // F1 initial and chips
  eq('F1 initial', F.initial(), { preset: 'month', customFrom: '', customTo: '', showAll: false, phase: 'idle', error: null, body: null, win: null, expandedId: '' });
  eq('F1 chip labels', F.chipLabels(), ['This month', 'Last month', 'This quarter', 'Last quarter', 'This FY', 'Last FY', 'Custom']);
  eq('F1 chipIndex', ['month', 'lastMonth', 'quarter', 'lastQuarter', 'fy', 'lastFy', 'custom', 'x', undefined].map(F.chipIndex), [0, 1, 2, 3, 4, 5, 6, 0, 0]);
  eq('F1 chips cover the model presets', F.CHIPS.map((c) => c.preset).filter((p) => p !== 'custom'), plain(M.PRESETS));

  // F2 selectChip
  {
    const svc = fakeSvc();
    for (let i = 0; i < 7; i++) eq('F2 chip ' + i, F.selectChip(F.initial(), i, NOW, svc).preset, F.CHIPS[i].preset);
    const s0 = F.initial();
    for (const j of [-1, 7, 1.5, '1', NaN, Infinity, null, undefined]) same('F2 junk index ' + String(j), F.selectChip(s0, j, NOW, svc), s0);
    const loading = Object.assign(F.initial(), { phase: 'loading' });
    same('F2 locked while loading', F.selectChip(loading, 2, NOW, svc), loading);
    const withData = Object.assign(F.initial(), { body: answer(monthWin, []), win: monthWin, phase: 'shown', expandedId: 'x', error: { kind: 'x' } });
    const next = F.selectChip(withData, 1, NOW, svc);
    eq('F2 change clears body win error expanded', [next.body, next.win, next.phase, next.error, next.expandedId], [null, null, 'idle', null, '']);
    eq('F2 showAll survives', F.selectChip(Object.assign(F.initial(), { showAll: true }), 1, NOW, svc).showAll, true);
  }

  // F3 cache attach
  {
    const svc = fakeSvc();
    const r = shown(svc, monthWin);
    const a = F.selectChip(F.selectChip(F.initial(), 1, NOW, svc), 0, NOW, svc);
    eq('F3 cache hit shows', [a.phase, a.body === r.body, M.windowKey(a.win)], ['shown', true, M.windowKey(monthWin)]);
    eq('F3 other window has no cache', [F.selectChip(F.initial(), 1, NOW, svc).phase, F.selectChip(F.initial(), 1, NOW, svc).body], ['idle', null]);
    eq('F3 no svc cached fn', F.selectChip(F.initial(), 0, NOW, {}).phase, 'idle');
    svc.cached = () => ({ body: null, window: monthWin });
    eq('F3 half cache ignored', F.selectChip(F.initial(), 0, NOW, svc).phase, 'idle');
    svc.cached = () => ({ body: answer(monthWin, []), window: null });
    eq('F3 cache without window ignored', [F.selectChip(F.initial(), 0, NOW, svc).phase, F.selectChip(F.initial(), 0, NOW, svc).win], ['idle', null]);
  }

  // F4 custom days
  {
    const svc = fakeSvc();
    let s = F.selectChip(F.initial(), 6, NOW, svc);
    eq('F4 blank is a hint', plain(F.windowFor(s, NOW)), { ok: false, message: F.CUSTOM_BLANK, blank: true });
    s = F.setCustom(s, '2026-11-01', '', NOW, svc);
    eq('F4 half blank', F.windowFor(s, NOW).blank, true);
    eq('F4 other half blank', F.windowFor(F.setCustom(s, '', '2026-11-01', NOW, svc), NOW).blank, true);
    s = F.setCustom(s, '2026-02-30', '2026-03-01', NOW, svc);
    eq('F4 impossible day', plain(F.windowFor(s, NOW)), { ok: false, message: M.customErrorText('bad-from'), blank: false });
    s = F.setCustom(s, '2026-03-05', '2026-03-01', NOW, svc);
    eq('F4 reversed', F.windowFor(s, NOW).message, M.customErrorText('reversed'));
    s = F.setCustom(s, ' 2026-03-01 ', '2026-03-31 ', NOW, svc);
    eq('F4 trimmed valid', plain(F.windowFor(s, NOW).win), plain(M.customWindow('2026-03-01', '2026-03-31')));
    same('F4 same text is the same state', F.setCustom(s, ' 2026-03-01 ', '2026-03-31 ', NOW, svc), s);
    eq('F4 junk text becomes empty', [F.setCustom(s, 5, null, NOW, svc).customFrom, F.setCustom(s, 5, null, NOW, svc).customTo], ['', '']);
    const loading = Object.assign({}, s, { phase: 'loading' });
    same('F4 locked while loading', F.setCustom(loading, '2026-04-01', '2026-04-02', NOW, svc), loading);
    const keep = Object.assign(F.initial(), { body: answer(monthWin, []), win: monthWin, phase: 'shown' });
    const typed = F.setCustom(keep, '2026-04-01', '2026-04-02', NOW, svc);
    eq('F4 days of a hidden Custom do not drop a shown register', [typed.phase, typed.body !== null, typed.customFrom], ['shown', true, '2026-04-01']);
    const cw = M.customWindow('2026-03-01', '2026-03-31');
    svc.cache = { body: answer(cw, []), window: cw };
    eq('F4 custom cache attaches', F.setCustom(F.selectChip(F.initial(), 6, NOW, svc), '2026-03-01', '2026-03-31', NOW, svc).phase, 'shown');
    eq('F4 custom edit drops the old body', F.setCustom(Object.assign(F.selectChip(F.initial(), 6, NOW, svc), { body: answer(cw, []), win: cw, phase: 'shown', customFrom: '2026-03-01', customTo: '2026-03-31' }), '2026-03-01', '2026-03-30', NOW, svc).body, null);
  }

  // F5 happy load: commit loading BEFORE the service call
  {
    const svc = fakeSvc(), b = box(F.initial());
    let phaseAtCall = '';
    svc.hook = () => { phaseAtCall = b.state.phase; };
    T('F5 load returns true', F.startLoad(b.ctx, NOW, svc, 'owner'));
    eq('F5 loading committed before the call', phaseAtCall, 'loading');
    eq('F5 sent the selected window', [svc.calls.length, M.windowKey(svc.calls[0])], [1, M.windowKey(monthWin)]);
    eq('F5 phase while waiting', b.state.phase, 'loading');
    svc.answer(OK(monthWin, [product()]));
    eq('F5 shown', [b.state.phase, b.state.error, M.windowKey(b.state.win), b.state.body.products.length, b.state.expandedId], ['shown', null, M.windowKey(monthWin), 1, '']);
    eq('F5 log', b.log, ['loading', 'shown']);
    // an answer settles the state it lands on: stale error and open row are dropped, the window is the one asked for
    const b3 = box(F.initial()), s3 = fakeSvc();
    F.startLoad(b3.ctx, NOW, s3, 'owner');
    b3.ctx.set(Object.assign({}, b3.state, { expandedId: 'p-abcdef123', error: { kind: 'x', message: 'm', retryable: true } }));
    s3.answer({ ok: true, body: answer(monthWin, [product()]) });
    eq('F5 answer clears the open row, the stale error, and takes the asked window', [b3.state.expandedId, b3.state.error, M.windowKey(b3.state.win)], ['', null, M.windowKey(monthWin)]);
    // a state the person changed while waiting (show all, expand) is not lost by the answer
    const b2 = box(F.initial()); const s2 = fakeSvc();
    F.startLoad(b2.ctx, NOW, s2, 'owner');
    b2.ctx.set(F.toggleShowAll(b2.state));
    s2.answer(OK(monthWin, [product()]));
    eq('F5 showAll set while waiting survives', b2.state.showAll, true);
  }

  // F6 a refusal that answers synchronously lands on top of loading
  {
    const svc = fakeSvc(), b = box(F.initial());
    svc.sync = () => FAIL('notSignedIn');
    F0('F6 returns the service answer', F.startLoad(b.ctx, NOW, svc, 'owner'));
    eq('F6 order and result', [b.log, b.state.phase, b.state.error.kind, b.state.error.retryable], [['loading', 'error'], 'error', 'notSignedIn', true]);
  }

  // F7 double tap
  {
    const svc = fakeSvc(), b = box(F.initial());
    F.startLoad(b.ctx, NOW, svc, 'owner');
    F0('F7 second tap refused', F.startLoad(b.ctx, NOW, svc, 'owner'));
    eq('F7 one request', svc.calls.length, 1);
  }

  // F8 refusals before any request
  {
    let svc = fakeSvc(), b = box(F.selectChip(F.initial(), 6, NOW, svc));
    F0('F8 blank custom', F.startLoad(b.ctx, NOW, svc, 'owner'));
    eq('F8 blank custom: no state change, no call', [b.log, svc.calls.length], [[], 0]);
    b = box(F.setCustom(F.selectChip(F.initial(), 6, NOW, svc), '2026-02-30', '2026-03-01', NOW, svc));
    F0('F8 invalid custom', F.startLoad(b.ctx, NOW, svc, 'owner'));
    eq('F8 invalid custom', [b.state.phase, b.state.error.kind, b.state.error.retryable, b.state.error.message, svc.calls.length], ['error', 'window', false, M.customErrorText('bad-from'), 0]);
    for (const role of ['staff', 'viewer', '', undefined, null, 5]) {
      b = box(F.initial());
      F0('F8 role ' + String(role), F.startLoad(b.ctx, NOW, svc, role));
      eq('F8 role ' + String(role), [b.state.phase, b.state.error.kind, b.state.error.retryable, svc.calls.length], ['error', 'role', false, 0]);
    }
    for (const role of ['owner', 'admin', 'manager']) { b = box(F.initial()); T('F8 allowed ' + role, F.startLoad(b.ctx, NOW, fakeSvc(), role)); }
    b = box(Object.assign(F.initial(), { preset: 'nope' }));
    F0('F8 bad preset', F.startLoad(b.ctx, NOW, svc, 'owner'));
    eq('F8 bad preset words', b.state.error.message, M.message('unknown'));
  }

  // F9 failures keep the last good figures
  for (const [kind, retryable] of [['offline', true], ['auth', true], ['tenant', true], ['timeout', true], ['server', true], ['tooLarge', false], ['role', false], ['window', false], ['badAnswer', true], ['unknown', true]]) {
    const svc = fakeSvc(); shown(svc, monthWin);
    const b = box(F.selectChip(F.initial(), 0, NOW, svc));
    F.startLoad(b.ctx, NOW, svc, 'owner');
    svc.answer(FAIL(kind, retryable));
    eq('F9 ' + kind, [b.state.phase, b.state.error.kind, b.state.error.retryable, b.state.error.message, b.state.body !== null], ['error', kind, retryable, M.message(kind), true]);
    const v = F.view(b.state, NOW, 'owner');
    eq('F9 ' + kind + ' view', [v.hasData, v.canRetry, v.errorText, v.staleNote === 'The figures below are from the earlier load, as of 12 Nov 2026, 9:05 am IST.', v.loadLabel], [true, retryable, M.message(kind), true, retryable ? 'Try again' : 'Reload']);
  }
  {
    const svc = fakeSvc(), b = box(F.initial());
    F.startLoad(b.ctx, NOW, svc, 'owner');
    svc.answer({ ok: false, kind: 'server' });
    eq('F9 missing message falls back', [b.state.error.message, b.state.error.retryable], [M.message('unknown'), true]);
    const b2 = box(F.initial()), s2 = fakeSvc();
    F.startLoad(b2.ctx, NOW, s2, 'owner');
    s2.answer({ ok: false, kind: 'server', message: 5, retryable: false });
    eq('F9 junk message and flag', [b2.state.error.message, b2.state.error.retryable], [M.message('unknown'), false]);
  }

  // F10 busy and cancelled are not errors
  for (const kind of ['busy', 'cancelled']) {
    for (const withBody of [false, true]) {
      const svc = fakeSvc(); if (withBody) shown(svc, monthWin);
      const b = box(F.selectChip(F.initial(), 0, NOW, svc));
      F.startLoad(b.ctx, NOW, svc, 'owner');
      svc.answer(FAIL(kind));
      eq('F10 ' + kind + ' ' + withBody, [b.state.phase, b.state.error], [withBody ? 'shown' : 'idle', null]);
    }
  }
  {
    const b = box(Object.assign(F.initial(), { phase: 'loading' }));
    F.applyResult(b.state, monthWin, null);
    eq('F10 junk result settles', F.applyResult(b.state, monthWin, null).phase, 'idle');
    eq('F10 junk result array settles', F.applyResult(b.state, monthWin, []).phase, 'idle');
  }

  // F11 cancel
  {
    const svc = fakeSvc(), b = box(F.initial());
    F.cancelLoad(b.ctx, svc);
    eq('F11 idle cancel is a no-op', svc.cancels, 0);
    F.startLoad(b.ctx, NOW, svc, 'owner');
    F.cancelLoad(b.ctx, svc);
    eq('F11 cancel while loading', [svc.cancels, b.state.phase, b.state.error], [1, 'idle', null]);
    eq('F11 can load again', F.startLoad(b.ctx, NOW, svc, 'owner'), true);
  }

  // F11b a tap handler that threw
  {
    const svc = fakeSvc(); shown(svc, monthWin);
    const loading = Object.assign(F.selectChip(F.initial(), 0, NOW, svc), { phase: 'loading' });
    const c = F.crashed(loading);
    eq('F11b crashed settles with words, keeps the figures', [c.phase, c.error.kind, c.error.message, c.error.retryable, c.body !== null], ['error', 'unknown', M.message('unknown'), true, true]);
    eq('F11b the view offers a retry', [F.view(c, NOW, 'owner').canRetry, F.view(c, NOW, 'owner').loadLabel, F.view(c, NOW, 'owner').loading], [true, 'Try again', false]);
  }

  // F12 reset
  {
    const svc = fakeSvc(), b = box(F.initial());
    F.startLoad(b.ctx, NOW, svc, 'owner');
    b.ctx.set(F.toggleShowAll(b.state));
    F.reset(b.ctx, svc, false);
    eq('F12 state is initial', b.state, F.initial());
    eq('F12 cancelled once, cache kept', [svc.cancels, svc.clears], [1, 0]);
    eq('F12 the cancelled answer was ignored', b.log[b.log.length - 1], 'idle');
    svc.cache = { body: {}, window: monthWin };
    F.reset(b.ctx, svc, true);
    eq('F12 clear on request', svc.clears, 1);
    F.reset(b.ctx, svc);
    eq('F12 clear only when true', svc.clears, 1);
    // late answer of a request that reset could not cancel (service already settled) is ignored too
    const b2 = box(F.initial()), s2 = fakeSvc();
    F.startLoad(b2.ctx, NOW, s2, 'owner');
    const cb = s2.pending; s2.pending = null;
    F.reset(b2.ctx, s2, true);
    cb(OK(monthWin, [product()]));
    eq('F12 late answer ignored', [b2.state.phase, b2.state.body], ['idle', null]);
  }

  // F13 stale callbacks
  {
    const s = F.initial();
    same('F13 success on idle ignored', F.applyResult(s, monthWin, OK(monthWin, [])), s);
    same('F13 failure on idle ignored', F.applyResult(s, monthWin, FAIL('server')), s);
  }

  // F14 an answer that does not match the window is not shown
  {
    const svc = fakeSvc(), b = box(F.initial());
    F.startLoad(b.ctx, NOW, svc, 'owner');
    svc.answer(OK(lastWin, [product()]));   // the service would refuse it; the flow must not trust that
    const r = OK(monthWin, [product()]); r.body.window = { fromMs: lastWin.fromMs, toMs: lastWin.toMs };
    const b2 = box(F.initial()), s2 = fakeSvc();
    F.startLoad(b2.ctx, NOW, s2, 'owner');
    s2.answer(r);
    eq('F14 window mismatch', [b2.state.phase, b2.state.error.kind, b2.state.body], ['error', 'badAnswer', null]);
    eq('F14 words', b2.state.error.message, M.message('badAnswer'));
  }

  // F15 view
  {
    const v0 = F.view(F.initial(), NOW, 'owner');
    eq('F15 keys', Object.keys(v0).sort(), VIEW_KEYS);
    eq('F15 idle', [v0.caption, v0.captionIsError, v0.canLoad, v0.loadLabel, v0.hasData, v0.canCancel, v0.locked, v0.loading, v0.rows.length, v0.errorText, v0.summaryText, v0.asOf, v0.showToggle], ['Nov 2026 \u00b7 1 Nov 2026 \u2013 30 Nov 2026 (IST)', false, true, 'Load register', false, false, false, false, 0, '', '', '', false]);
    const vl = F.view(Object.assign(F.initial(), { phase: 'loading' }), NOW, 'owner');
    eq('F15 loading', [vl.loading, vl.canLoad, vl.canCancel, vl.locked, vl.loadLabel], [true, false, true, true, 'Loading\u2026']);
    const vr = F.view(F.initial(), NOW, 'staff');
    eq('F15 role refused', [vr.canLoad, vr.errorText, vr.canRetry], [false, M.message('role'), false]);
    eq('F15 role junk', F.view(F.initial(), NOW, undefined).canLoad, false);
    const errSt = Object.assign(F.initial(), { phase: 'error', error: { kind: 'server', message: 'm', retryable: true } });
    eq('F15 retry needs the role', [F.view(errSt, NOW, 'owner').canRetry, F.view(errSt, NOW, 'staff').canRetry], [true, false]);
    const errLoading = Object.assign({}, errSt, { phase: 'loading' });
    eq('F15 an error is not shown while a request flies', [F.view(errLoading, NOW, 'owner').errorText, F.view(errLoading, NOW, 'owner').canRetry, F.view(errLoading, NOW, 'owner').loadLabel], ['', false, 'Loading\u2026']);
    const sc = F.selectChip(F.initial(), 6, NOW, fakeSvc());
    const vc = F.view(sc, NOW, 'owner');
    eq('F15 custom blank is not an error', [vc.custom, vc.caption, vc.captionIsError, vc.canLoad, vc.chipIndex], [true, F.CUSTOM_BLANK, false, false, 6]);
    const vbad = F.view(F.setCustom(sc, 'x', 'y', NOW, fakeSvc()), NOW, 'owner');
    eq('F15 custom bad is an error', [vbad.captionIsError, vbad.canLoad, vbad.caption], [true, false, M.customErrorText('bad-from')]);
    const vok = F.view(F.setCustom(sc, '2026-03-01', '2026-03-31', NOW, fakeSvc()), NOW, 'owner');
    eq('F15 custom ok caption', [vok.caption, vok.canLoad], ['1 Mar 2026 \u2013 31 Mar 2026 (IST)', true]);
    eq('F15 bad preset', [F.view(Object.assign(F.initial(), { preset: 'zz' }), NOW, 'owner').canLoad, F.view(Object.assign(F.initial(), { preset: 'zz' }), NOW, 'owner').captionIsError], [false, true]);

    // with data
    const products = [product(), product({ productId: 'p-2', name: 'Cotton', reconciles: false, ledgerStock: 9 }), quiet('q1'), quiet('q2'), { junk: 1 }];
    const body = answer(monthWin, products, { counts: { rowsInWindow: 5, skipped: { noProduct: 2, badKind: 0 } } });
    const st = Object.assign(F.initial(), { body, win: monthWin, phase: 'shown' });
    const v = F.view(st, NOW, 'owner');
    eq('F15 data flags', [v.hasData, v.loadLabel, v.canLoad, v.rows.length, v.hasWarning, v.showToggle, v.toggleText, v.asOf], [true, 'Reload', true, 2, true, true, 'Show products with no movement', 'As of 12 Nov 2026, 9:05 am IST']);
    eq('F15 summary', v.summaryText, '2 products shown, 2 with no movement hidden');
    eq('F15 warnings', v.warnings, ['2 stock ledger rows could not be read and are not in these figures.', '1 product in the answer could not be read and is not listed.', '1 product where the ledger and the stock figure disagree (marked below).']);
    eq('F15 row keys', Object.keys(v.rows[0]).sort(), ROW_KEYS);
    eq('F15 running (period not over)', v.running, true);
    const va = F.view(Object.assign({}, st, { showAll: true }), NOW, 'owner');
    eq('F15 show all', [va.rows.length, va.summaryText, va.toggleText, va.showToggle], [4, '4 products shown', 'Hide products with no movement', true]);
    eq('F15 singular', F.view(Object.assign({}, st, { body: answer(monthWin, [product(), quiet('q')], { counts: { skipped: { a: 1 } } }) }), NOW, 'owner').warnings, ['1 stock ledger row could not be read and is not in these figures.']);
    const ended = M.presetWindow('lastMonth', NOW);
    eq('F15 ended period is not running', F.view(Object.assign(F.initial(), { preset: 'lastMonth', body: answer(ended, [product()], { readAt: ended.toMs + 1000 }), win: ended, phase: 'shown' }), NOW, 'owner').running, false);
    eq('F15 no readAt: not running', F.view(Object.assign(F.initial(), { body: answer(monthWin, [product()], { readAt: 0 }), win: monthWin, phase: 'shown' }), NOW, 'owner').running, false);
    const noAt = Object.assign(F.initial(), { body: answer(monthWin, [product()], { readAt: 0 }), win: monthWin, phase: 'error', error: { kind: 'server', message: 'm', retryable: true } });
    eq('F15 stale note without a time', F.view(noAt, NOW, 'owner').staleNote, 'The figures below are from the earlier load.');
    // empty states
    const onlyQuiet = Object.assign(F.initial(), { body: answer(monthWin, [quiet('a'), quiet('b'), quiet('c')]), win: monthWin, phase: 'shown' });
    const ve = F.view(onlyQuiet, NOW, 'owner');
    eq('F15 empty with hidden', [ve.rows.length, ve.emptyText, ve.summaryText], [0, 'No product moved in this period. 3 products with no movement are hidden.', '0 products shown, 3 with no movement hidden']);
    eq('F15 empty with one hidden', F.view(Object.assign({}, onlyQuiet, { body: answer(monthWin, [quiet('a')]) }), NOW, 'owner').emptyText, 'No product moved in this period. 1 product with no movement is hidden.');
    eq('F15 no products at all', [F.view(Object.assign({}, onlyQuiet, { body: answer(monthWin, []) }), NOW, 'owner').emptyText, F.view(Object.assign({}, onlyQuiet, { body: answer(monthWin, []) }), NOW, 'owner').showToggle], ['There are no products to show.', false]);
    eq('F15 show all with nothing quiet', F.view(Object.assign({}, onlyQuiet, { showAll: true }), NOW, 'owner').emptyText, '');
    // data that belongs to another window is not shown (month turned while the page was open)
    const later = at(2026, 11, 2, 10, 0);
    const old = F.view(st, later, 'owner');
    eq('F15 month turned: old register hidden', [old.hasData, old.rows.length, old.loadLabel, old.asOf, old.canLoad], [false, 0, 'Load register', '', true]);
    // a body that fails the model's checks is not shown
    eq('F15 broken body hidden', F.view(Object.assign({}, st, { body: { ok: true, window: { fromMs: 1, toMs: 2 }, products: [] } }), NOW, 'owner').hasData, false);
    // loading with figures: stays visible while the reload runs
    const vlo = F.view(Object.assign({}, st, { phase: 'loading' }), NOW, 'owner');
    eq('F15 reload keeps figures', [vlo.hasData, vlo.rows.length, vlo.errorText, vlo.staleNote], [true, 2, '', '']);
    // error with no figures
    eq('F15 error without figures', [F.view(Object.assign(F.initial(), { phase: 'error', error: { kind: 'server', message: 'm', retryable: true } }), NOW, 'owner').staleNote, F.view(Object.assign(F.initial(), { phase: 'error', error: { kind: 'server', message: 'm', retryable: true } }), NOW, 'owner').errorText], ['', 'm']);
    // flat values only
    for (const k of Object.keys(v)) {
      const x = v[k];
      if (!(typeof x === 'string' || typeof x === 'number' || typeof x === 'boolean' || Array.isArray(x))) bad.push('F15 non-flat value ' + k);
    }
  }

  // F16 asOfText
  eq('F16 table', [at(2026, 10, 12, 0, 0), at(2026, 10, 12, 0, 59), at(2026, 10, 12, 11, 59), at(2026, 10, 12, 12, 0), at(2026, 10, 12, 23, 59), at(2026, 10, 12, 13, 5)].map(F.asOfText),
    ['12 Nov 2026, 12:00 am IST', '12 Nov 2026, 12:59 am IST', '12 Nov 2026, 11:59 am IST', '12 Nov 2026, 12:00 pm IST', '12 Nov 2026, 11:59 pm IST', '12 Nov 2026, 1:05 pm IST']);
  eq('F16 IST day boundary', [F.asOfText(Date.UTC(2026, 2, 31, 18, 29, 59, 999)), F.asOfText(Date.UTC(2026, 2, 31, 18, 30, 0, 0))], ['31 Mar 2026, 11:59 pm IST', '1 Apr 2026, 12:00 am IST']);
  eq('F16 junk', [0, -5, NaN, Infinity, '1', null, undefined, {}].map(F.asOfText), ['', '', '', '', '', '', '', '']);

  // F17 sameRows
  {
    const r = (o) => Object.assign({ id: 'a', title: 't', note: '', deleted: false, reconciles: true, moved: true, movementCount: 1, openingText: '1', inText: '2', outText: '3', closingText: '0', currentText: '0' }, o);
    T('F17 equal', F.sameRows([r(), r({ id: 'b' })], [r(), r({ id: 'b' })]));
    T('F17 both empty', F.sameRows([], []));
    F0('F17 length', F.sameRows([r()], []));
    F0('F17 longer b', F.sameRows([r()], [r(), r({ id: 'b' })]));
    F0('F17 longer a', F.sameRows([r(), r({ id: 'b' })], [r()]));
    F0('F17 order', F.sameRows([r(), r({ id: 'b' })], [r({ id: 'b' }), r()]));
    F0('F17 one cell text', F.sameRows([r()], [r({ closingText: '1' })]));
    F0('F17 one cell flag', F.sameRows([r()], [r({ reconciles: false })]));
    F0('F17 string vs number', F.sameRows([r({ movementCount: 1 })], [r({ movementCount: '1' })]));
    F0('F17 extra key', F.sameRows([r()], [Object.assign(r(), { extra: 1 })]));
    F0('F17 missing key', F.sameRows([Object.assign(r(), { extra: 1 })], [r()]));
    F0('F17 not arrays', F.sameRows(null, []));
    F0('F17 not arrays b', F.sameRows([], undefined));
    F0('F17 junk rows', F.sameRows([null], [null]));
    F0('F17 junk row vs row', F.sameRows([r()], [5]));
  }

  // F18 onOpen
  {
    const svc = fakeSvc();
    const st = Object.assign(F.initial(), { body: answer(monthWin, []), win: monthWin, phase: 'shown' });
    same('F18 same window keeps', F.onOpen(st, NOW, svc), st);
    const later = at(2026, 11, 2, 10, 0);
    const moved = F.onOpen(st, later, svc);
    eq('F18 month turned drops the old register', [moved.phase, moved.body, moved.win], ['idle', null, null]);
    const dec = M.presetWindow('month', later);
    svc.cache = { body: answer(dec, []), window: dec };
    eq('F18 and picks a cached one', F.onOpen(st, later, svc).phase, 'shown');
    const loading = Object.assign({}, st, { phase: 'loading' });
    same('F18 loading untouched', F.onOpen(loading, later, svc), loading);
    const blankCustom = F.selectChip(F.initial(), 6, NOW, svc);
    same('F18 invalid selection untouched', F.onOpen(blankCustom, NOW, svc), blankCustom);
    const errNoBody = Object.assign(F.initial(), { phase: 'error', error: { kind: 'server', message: 'm', retryable: true } });
    eq('F18 old error without figures is cleared', [F.onOpen(errNoBody, NOW, fakeSvc()).phase, F.onOpen(errNoBody, NOW, fakeSvc()).error], ['idle', null]);
    const errBody = Object.assign({}, st, { phase: 'error', error: { kind: 'server', message: 'm', retryable: true } });
    same('F18 error with figures stays', F.onOpen(errBody, NOW, svc), errBody);
  }

  // F19 detail and speech
  {
    const st = Object.assign(F.initial(), { body: answer(monthWin, [product()]), win: monthWin, phase: 'shown' });
    eq('F19 detail lines', F.detailFor(st, 'p-abcdef123'), [{ kind: 'receipt', label: 'Received', inText: '5', outText: '0' }, { kind: 'sale', label: 'Sold', inText: '0', outText: '3' }]);
    eq('F19 unknown id', F.detailFor(st, 'zz'), []);
    eq('F19 no body', F.detailFor(F.initial(), 'p'), []);
    const row = F.view(st, NOW, 'owner').rows[0];
    eq('F19 speech', F.rowSpeech(row), 'Silk Saree. Opening 10, in 5, out 3, closing 12.');
    eq('F19 speech with note', F.rowSpeech({ title: 'X', openingText: '1', inText: '2', outText: '3', closingText: '0', note: 'Deleted product' }), 'X. Opening 1, in 2, out 3, closing 0. Deleted product.');
    eq('F19 speech junk', [F.rowSpeech(null), F.rowSpeech(5)], ['', '']);
    eq('F19 no detail words', F.NO_DETAIL, 'No stock moved in this period.');
  }

  // F20 expand and show-all
  {
    const s = Object.assign(F.initial(), { expandedId: 'a' });
    eq('F20 expand other', F.toggleExpand(s, 'b').expandedId, 'b');
    eq('F20 collapse same', F.toggleExpand(s, 'a').expandedId, '');
    for (const j of ['', 5, null, undefined, {}]) same('F20 junk id ' + String(j), F.toggleExpand(s, j), s);
    eq('F20 show all flips and collapses', [F.toggleShowAll(s).showAll, F.toggleShowAll(s).expandedId, F.toggleShowAll(F.toggleShowAll(s)).showAll], [true, '', false]);
  }

  // F21 states are never edited in place
  {
    const svc = fakeSvc(); shown(svc, monthWin);
    const base = Object.assign(F.initial(), { body: answer(monthWin, [product()]), win: monthWin, phase: 'shown', expandedId: 'p-abcdef123' });
    const calls = [
      (s) => F.selectChip(s, 1, NOW, svc), (s) => F.setCustom(Object.assign({}, s, { preset: 'custom' }), '2026-03-01', '2026-03-02', NOW, svc),
      (s) => F.toggleShowAll(s), (s) => F.toggleExpand(s, 'x'), (s) => F.onOpen(s, at(2026, 11, 3), svc),
      (s) => F.applyResult(Object.assign({}, s, { phase: 'loading' }), monthWin, FAIL('server')), (s) => F.view(s, NOW, 'owner')
    ];
    calls.forEach((fn, i) => { const before = JSON.stringify(base); fn(base); if (JSON.stringify(base) !== before) bad.push('F21 call ' + i + ' edited its input'); });
  }

  // F22 monkey: random taps, answers, resets, clock moves; invariants after every step
  {
    let seed = 20261117;
    const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    const svc = fakeSvc(), b = box(F.initial());
    let now = NOW, sawLoading = 0, sawShown = 0, sawError = 0, sawHit = 0, sawCustom = 0;
    for (let i = 0; i < 4000; i++) {
      const a = Math.floor(rnd() * 11);
      if (a === 0) F.startLoad(b.ctx, now, svc, pick(['owner', 'owner', 'owner', 'admin', 'staff']));
      else if (a === 1) b.ctx.set(F.selectChip(b.state, Math.floor(rnd() * 9) - 1, now, svc));
      else if (a === 2) b.ctx.set(F.setCustom(b.state, pick(['2026-03-01', '2026-02-30', '', 'x', '2026-11-01']), pick(['2026-03-31', '2026-03-01', '', '2026-02-28']), now, svc));
      else if (a === 3) b.ctx.set(F.toggleShowAll(b.state));
      else if (a === 4) b.ctx.set(F.toggleExpand(b.state, pick(['p-abcdef123', 'q1', 'zz', ''])));
      else if (a === 5 && svc.pending) {
        const w = svc.calls[svc.calls.length - 1];
        svc.answer(pick([OK(w, [product(), quiet('q1')]), OK(w, []), FAIL('server'), FAIL('offline'), FAIL('busy'), FAIL('cancelled'), FAIL('role', false)]));
      } else if (a === 6) F.cancelLoad(b.ctx, svc);
      else if (a === 7) F.reset(b.ctx, svc, rnd() < 0.5);
      else if (a === 8) { now = pick([NOW, at(2026, 11, 2), at(2027, 3, 31, 23, 59), at(2027, 4, 1), NOW + 86400000 * Math.floor(rnd() * 400)]); b.ctx.set(F.onOpen(b.state, now, svc)); }
      else if (a === 9 && rnd() < 0.4) svc.cache = svc.calls.length ? { body: answer(svc.calls[svc.calls.length - 1], [product()]), window: svc.calls[svc.calls.length - 1] } : null;
      else if (a === 10) { const v = F.view(b.state, now, pick(['owner', 'staff'])); if (Object.keys(v).sort().join() !== VIEW_KEYS.join()) bad.push('F22 view keys at ' + i); }
      const s = b.state;
      if (s.phase === 'loading') sawLoading++;
      if (s.phase === 'shown') sawShown++;
      if (s.phase === 'error') sawError++;
      if (s.preset === 'custom') sawCustom++;
      // (1) body is null or the answer for exactly win
      if (s.body !== null) {
        if (!s.win || s.body.window.fromMs !== s.win.fromMs || s.body.window.toMs !== s.win.toMs) { bad.push('F22 body/win drift at ' + i); break; }
        if (s.preset !== 'custom') { const w = F.windowFor(s, now); if (w.ok && M.windowKey(w.win) !== M.windowKey(s.win) && s.phase !== 'loading') { /* an old month: view() hides it */ } }
      } else if (s.win !== null) { bad.push('F22 win without body at ' + i); break; }
      // (2) loading iff a request is pending
      if ((s.phase === 'loading') !== (svc.pending !== null)) { bad.push('F22 loading/pending mismatch at ' + i + ' phase ' + s.phase + ' pending ' + (svc.pending !== null)); break; }
      // (3) an error always carries words and a flag; a non-error never carries one
      if (s.phase === 'error' && !(s.error && typeof s.error.message === 'string' && typeof s.error.retryable === 'boolean')) { bad.push('F22 error shape at ' + i); break; }
      if (s.phase !== 'error' && s.error !== null) { bad.push('F22 stray error at ' + i); break; }
      // (4) the view never shows figures that belong to another window
      const v = F.view(s, now, 'owner');
      if (v.hasData) { const w = F.windowFor(s, now); if (!w.ok || M.windowKey(w.win) !== M.windowKey(s.win)) { bad.push('F22 view shows another window at ' + i); break; } }
      if (v.rows.length > 0 && !v.hasData) { bad.push('F22 rows without data at ' + i); break; }
    }
    if (!(sawLoading > 100 && sawShown > 100 && sawError > 50 && sawCustom > 100)) bad.push('F22 monkey did not reach every phase: ' + [sawLoading, sawShown, sawError, sawCustom]);
  }

  return bad;
}

// ---- real file ----------------------------------------------------------------------------------------------
test('SRF-01 the battery passes on the real file', () => {
  const bad = battery(loadSrc(SRC));
  assert.deepEqual(bad, [], bad.join('\n'));
});

test('SRF-02 pure: no clock, no local-time getter, no QML name', () => {
  const code = SRC.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
  for (const bannedText of ['Date.now', 'new Date()', 'getHours(', 'getDate(', 'getMonth(', 'getFullYear(', 'getMinutes(', 'toLocale', 'AuthStore', 'Qt.', 'console.', 'XMLHttpRequest', 'FirebaseService']) {
    assert.ok(!code.includes(bannedText), 'banned in the flow file: ' + bannedText);
  }
  assert.match(code, /new Date\(ms \+ M\.IST_OFFSET_MS\)/, 'the one Date is built from an IST-shifted instant');
  assert.equal((code.match(/new Date\(/g) || []).length, 1);
  assert.ok(/^\.pragma library\s*$/m.test(SRC));
});

test('SRF-03 the chips cover every model preset once, then Custom, and the row keys match the model', () => {
  const F = loadSrc(SRC);
  assert.deepEqual(plain(F.CHIPS.map((c) => c.preset)), plain(M.PRESETS).concat(['custom']));
  const w = M.presetWindow('month', NOW);
  const v = M.buildView(answer(w, [product()]), w, {});
  assert.deepEqual(Object.keys(v.rows[0]).sort(), ROW_KEYS);
});

// ---- hand mutants --------------------------------------------------------------------------------------------
const MUTANTS = [
  ['initial phase', 'phase: "idle", error: null,\n             body: null', 'phase: "shown", error: null,\n             body: null'],
  ['initial preset', 'return { preset: "month", customFrom', 'return { preset: "lastMonth", customFrom'],
  ['chip order', '{ preset: "month", label: "This month" },\n    { preset: "lastMonth", label: "Last month" }', '{ preset: "lastMonth", label: "Last month" },\n    { preset: "month", label: "This month" }'],
  ['chip index default', 'return 0\n}\n\n// ---- the selected window', 'return 1\n}\n\n// ---- the selected window'],
  ['custom blank not trimmed', 'var f = String(state.customFrom).trim(), t = String(state.customTo).trim()', 'var f = String(state.customFrom), t = String(state.customTo)'],
  ['custom blank only on from', 'if (f === "" || t === "") return', 'if (f === "") return'],
  ['custom blank only on to', 'if (f === "" || t === "") return', 'if (t === "") return'],
  ['blank flagged as error', 'message: CUSTOM_BLANK, blank: true', 'message: CUSTOM_BLANK, blank: false'],
  ['cache lookup dropped', 'var c = svc.cached(w.win)', 'var c = null'],
  ['cache needs no body', '!c || !c.body || !c.window', '!c || !c.window'],
  ['cache needs no window', '!c || !c.body || !c.window', '!c || !c.body'],
  ['cache phase', 'return _with(s, { body: c.body, win: c.window, phase: "shown" })', 'return _with(s, { body: c.body, win: c.window, phase: "idle" })'],
  ['chip lock dropped', 'function selectChip(state, index, nowMs, svc) {\n    if (state.phase === "loading") return state', 'function selectChip(state, index, nowMs, svc) {\n    if (false) return state'],
  ['chip index not integer', 'index !== Math.floor(index) || ', ''],
  ['chip index upper bound', 'index >= CHIPS.length', 'index > CHIPS.length'],
  ['chip index lower bound', 'index < 0 ||', 'index < -1 ||'],
  ['chip keeps body', 'return _attach(_cleared(state, { preset: CHIPS[index].preset }), nowMs, svc)', 'return _attach(_with(state, { preset: CHIPS[index].preset }), nowMs, svc)'],
  ['cleared keeps error', 'phase: "idle", error: null, body: null, win: null, expandedId: "" }, patch', 'phase: "idle", body: null, win: null, expandedId: "" }, patch'],
  ['cleared keeps expanded', 'body: null, win: null, expandedId: "" }, patch', 'body: null, win: null }, patch'],
  ['custom lock dropped', 'function setCustom(state, from, to, nowMs, svc) {\n    if (state.phase === "loading") return state', 'function setCustom(state, from, to, nowMs, svc) {\n    if (false) return state'],
  ['custom same text rebuilds', 'if (f === state.customFrom && t === state.customTo) return state', ''],
  ['custom same text from only', 'if (f === state.customFrom && t === state.customTo) return state', 'if (f === state.customFrom) return state'],
  ['custom junk kept', 'var f = typeof from === "string" ? from : "", t = typeof to === "string" ? to : ""', 'var f = from, t = to'],
  ['custom drops body for other chips', 'if (state.preset !== "custom") return _with(state, { customFrom: f, customTo: t })', 'if (false) return _with(state, { customFrom: f, customTo: t })'],
  ['custom edit keeps body', 'return _attach(_cleared(state, { customFrom: f, customTo: t }), nowMs, svc)', 'return _attach(_with(state, { customFrom: f, customTo: t }), nowMs, svc)'],
  ['show all keeps expanded', 'return _with(state, { showAll: !state.showAll, expandedId: "" })', 'return _with(state, { showAll: !state.showAll })'],
  ['show all stuck', 'showAll: !state.showAll, expandedId: ""', 'showAll: true, expandedId: ""'],
  ['expand never collapses', 'state.expandedId === id ? "" : id', 'id'],
  ['expand junk id', 'if (typeof id !== "string" || id === "") return state', ''],
  ['open ignores loading', 'function onOpen(state, nowMs, svc) {\n    if (state.phase === "loading") return state', 'function onOpen(state, nowMs, svc) {\n    if (false) return state'],
  ['open keeps another window', 'M.windowKey(state.win) === M.windowKey(w.win)) return state', 'true) return state'],
  ['open invalid selection', 'if (!w.ok) return state\n    if (state.body', 'if (state.body'],
  ['open keeps error', 'return _attach(_cleared(state), nowMs, svc)\n}\n\n// ---- the request', 'return _attach(_with(state, { phase: "idle", body: null, win: null, expandedId: "" }), nowMs, svc)\n}\n\n// ---- the request'],
  ['stale callback applied', 'function applyResult(state, win, r) {\n    if (state.phase !== "loading") return state', 'function applyResult(state, win, r) {\n    if (false) return state'],
  ['junk result not settled', 'if (!_isObj(r)) return _with(state, { phase: _settledPhase(state), error: null })', ''],
  ['answer not rechecked', 'if (!M.validateAnswer(r.body, win).ok) {', 'if (false) {'],
  ['answer keeps error', 'return _with(state, { phase: "shown", error: null, body: r.body, win: win, expandedId: "" })', 'return _with(state, { phase: "shown", body: r.body, win: win, expandedId: "" })'],
  ['answer keeps expanded', 'body: r.body, win: win, expandedId: "" })', 'body: r.body, win: win })'],
  ['busy is an error', 'if (r.kind === "busy" || r.kind === "cancelled")', 'if (r.kind === "cancelled")'],
  ['cancelled is an error', 'if (r.kind === "busy" || r.kind === "cancelled")', 'if (r.kind === "busy")'],
  ['settle drops figures', 'function _settledPhase(state) { return state.body ? "shown" : "idle" }', 'function _settledPhase(state) { return "idle" }'],
  ['error drops figures', 'return _with(state, {\n        phase: "error",', 'return _with(state, {\n        body: null, win: null,\n        phase: "error",'],
  ['error words fallback', 'typeof r.message === "string" && r.message !== "" ? r.message : M.message("unknown")', 'r.message'],
  ['retryable default', 'retryable: r.retryable !== false', 'retryable: r.retryable === true'],
  ['load lock dropped', 'var s = ctx.get()\n    if (s.phase === "loading") return false', 'var s = ctx.get()\n    if (false) return false'],
  ['blank custom errors', 'if (!w.blank) ctx.set(', 'if (true) ctx.set('],
  ['invalid custom silent', 'if (!w.blank) ctx.set(_with(s, { phase: "error", error: { kind: "window", message: w.message, retryable: false } }))', ''],
  ['invalid custom retryable', 'kind: "window", message: w.message, retryable: false', 'kind: "window", message: w.message, retryable: true'],
  ['role not checked', 'if (!M.canView(role)) {', 'if (false) {'],
  ['role retryable', 'kind: "role", message: M.message("role"), retryable: false', 'kind: "role", message: M.message("role"), retryable: true'],
  ['loading committed after the call', 'ctx.set(_with(s, { phase: "loading", error: null }))\n    return svc.load(w.win, function(result) { ctx.set(applyResult(ctx.get(), w.win, result)) })', 'var r0 = svc.load(w.win, function(result) { ctx.set(applyResult(ctx.get(), w.win, result)) })\n    ctx.set(_with(s, { phase: "loading", error: null }))\n    return r0'],
  ['loading keeps error', 'ctx.set(_with(s, { phase: "loading", error: null }))', 'ctx.set(_with(s, { phase: "loading" }))'],
  ['answer applied to the tap-time state', 'ctx.set(applyResult(ctx.get(), w.win, result))', 'ctx.set(applyResult(s, w.win, result))'],
  ['cancel when idle', 'if (ctx.get().phase === "loading") svc.cancel()', 'svc.cancel()'],
  ['crashed keeps loading', 'return _with(state, { phase: "error", error: { kind: "unknown", message: M.message("unknown"), retryable: true } })\n}\n\n// Stops waiting', 'return state\n}\n\n// Stops waiting'],
  ['crashed not retryable', 'error: { kind: "unknown", message: M.message("unknown"), retryable: true } })\n}\n\n// Stops', 'error: { kind: "unknown", message: M.message("unknown"), retryable: false } })\n}\n\n// Stops'],
  ['cancel never', 'if (ctx.get().phase === "loading") svc.cancel()', ''],
  ['reset never cancels', 'ctx.set(initial())\n    svc.cancel()\n', 'ctx.set(initial())\n'],
  ['reset always clears', 'if (clearCache === true) svc.clear()', 'svc.clear()'],
  ['reset never clears', 'if (clearCache === true) svc.clear()', ''],
  ['asOf noon', 'var hh = h % 12 === 0 ? 12 : h % 12', 'var hh = h % 12'],
  ['asOf am pm', '(h < 12 ? "am" : "pm")', '(h < 11 ? "am" : "pm")'],
  ['asOf pad', '(mi < 10 ? "0" + mi : mi)', 'mi'],
  ['asOf utc', 'new Date(ms + M.IST_OFFSET_MS)', 'new Date(ms)'],
  ['asOf junk', 'if (typeof ms !== "number" || !isFinite(ms) || ms <= 0) return ""', 'if (typeof ms !== "number") return ""'],
  ['asOf zero', 'ms <= 0) return ""', 'ms < 0) return ""'],
  ['singular', '(n === 1 ? one : many)', 'many'],
  ['warning verb', '(sum.skippedLedgerRows === 1 ? "is" : "are")', '"are"'],
  ['warning skipped dropped', 'if (sum.skippedLedgerRows > 0) {', 'if (false) {'],
  ['warning dropped dropped', 'if (sum.droppedBad > 0) {', 'if (false) {'],
  ['warning mismatch dropped', 'if (sum.mismatches > 0) {', 'if (false) {'],
  ['view data without window match', 'M.windowKey(state.win) === key)', 'true)'],
  ['view broken body shown', 'if (v && !v.ok) { v = null; data = false }', ''],
  ['view role ignored', 'canLoad: !loading && w.ok && allowed,', 'canLoad: !loading && w.ok,'],
  ['view loading ignored', 'canLoad: !loading && w.ok && allowed,', 'canLoad: w.ok && allowed,'],
  ['view window ignored', 'canLoad: !loading && w.ok && allowed,', 'canLoad: !loading && allowed,'],
  ['view retry role', 'var retry = !!(err && err.retryable === true && allowed)', 'var retry = !!(err && err.retryable === true)'],
  ['view retry not retryable', 'var retry = !!(err && err.retryable === true && allowed)', 'var retry = !!(err && allowed)'],
  ['view stale note without error', 'staleNote: data && err ?', 'staleNote: data ?'],
  ['view stale note without data', 'staleNote: data && err ?', 'staleNote: err ?'],
  ['view stale note without asOf', '(asOf !== "" ? ", as of " + asOf : "")', '", as of " + asOf'],
  ['view empty with hidden', 'emptyText = sum.hiddenQuiet > 0\n', 'emptyText = false\n'],
  ['view hidden count', 'if (sum.hiddenQuiet > 0) summaryText', 'if (false) summaryText'],
  ['view error while loading', 'var err = loading ? null : state.error', 'var err = state.error'],
  ['view role words', 'if (!allowed) errorText = M.message("role")', 'if (false) errorText = M.message("role")'],
  ['view label order', 'else if (retry) loadLabel = "Try again"\n    else if (data) loadLabel = "Reload"', 'else if (data) loadLabel = "Reload"\n    else if (retry) loadLabel = "Try again"'],
  ['view label loading', 'if (loading) loadLabel = "Loading\\u2026"\n    else if (retry)', 'if (false) loadLabel = "Loading\\u2026"\n    else if (retry)'],
  ['view empty only when no rows', 'if (rows.length === 0) {', 'if (true) {'],
  ['view toggle', 'showToggle: !!(sum && (sum.hiddenQuiet > 0 || state.showAll))', 'showToggle: !!(sum && sum.hiddenQuiet > 0)'],
  ['view toggle text', 'toggleText: state.showAll ? "Hide products with no movement" : "Show products with no movement"', 'toggleText: "Show products with no movement"'],
  ['view running', 'sum.readAt > 0 && state.win.toMs > sum.readAt', 'state.win.toMs > sum.readAt'],
  ['view running flipped', 'state.win.toMs > sum.readAt', 'state.win.toMs < sum.readAt'],
  ['view custom caption', 'state.preset === "custom" ? w.win.text : w.win.label', 'false ? w.win.text : w.win.label'],
  ['view caption error', 'captionIsError: !w.ok && !w.blank', 'captionIsError: !w.ok'],
  ['view chip index', 'chipIndex: chipIndex(state.preset),', 'chipIndex: 0,'],
  ['view locked', 'locked: loading,', 'locked: false,'],
  ['same rows length', 'a.length !== b.length) return false', 'false) return false'],
  ['same rows strict', 'if (x[k] !== y[k]) return false', 'if (x[k] != y[k]) return false'],
  ['same rows extra keys', 'if (kx !== ky) return false', ''],
  ['same rows junk', 'if (!_isObj(x) || !_isObj(y)) return false', ''],
  ['speech note', '(row.note !== "" ? " " + row.note + "." : "")', '""']
];

test('SRF-04 every hand mutant is a real change and the battery kills it', () => {
  const survivors = [], notFound = [];
  for (const [name, from, to] of MUTANTS) {
    const at0 = SRC.indexOf(from);
    if (at0 < 0) { notFound.push(name); continue; }
    if (SRC.indexOf(from, at0 + 1) >= 0) { notFound.push(name + ' (not unique)'); continue; }
    let bad;
    try { bad = battery(loadSrc(SRC.replace(from, () => to))); } catch (e) { bad = ['threw ' + e.message]; }
    if (bad.length === 0) survivors.push(name);
  }
  assert.deepEqual(notFound, [], 'broken mutants (the text does not occur once): ' + notFound.join(' | '));
  assert.deepEqual(survivors, [], 'surviving mutants: ' + survivors.join(' | '));
});
