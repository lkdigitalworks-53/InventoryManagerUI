'use strict';

// P1 S4b-1: qml/model/StockRegisterService.qml runs here as REAL text (load / cancel / cached / clear and the
// two XHR helpers) against a scripted fake XMLHttpRequest, fake stores and the real StockRegisterModel.js.
// Same technique as lockTransportBehavior.test.js. Hand mutants at the bottom prove the battery bites.
// Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md
// Test plan: docs/superpowers/test-plans/2026-11-12-p1-s4b1-register-client-engine-test-plan.md

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { load } = require(path.join('..', '..', '..', 'functions', 'test', 'testSupport', 'qmlHelpers.js'));

const REPO = path.resolve(__dirname, '..', '..', '..');
const SVC_PATH = path.join(REPO, 'qml/model/StockRegisterService.qml');
const SVC = fs.readFileSync(SVC_PATH, 'utf8');
const MODEL = load('StockRegisterModel.js');
const plain = (v) => JSON.parse(JSON.stringify(v));

function fnText(src, name) {
  const at = src.indexOf(`function ${name}(`);
  if (at < 0) return '';
  const open = src.indexOf('{', src.indexOf(')', at));
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}' && --depth === 0) return src.slice(at, i + 1);
  }
  return '';
}

const FN = ['cached', 'clear', '_answer', '_fail', '_captureBeforeStatusIsLost', 'load', 'cancel'];

// QML resolves bare names against the component; `with(scope)` gives the extracted text the same lookup and
// assignments to scope keys (`loading = true`) land on the scope, like a QML property.
function build(src, scope) {
  const texts = FN.map((n) => { const t = fnText(src, n); assert.ok(t, n + ' text found'); return t; });
  const body = `with(scope){ ${texts.join('\n')}\n return {${FN.map((n) => `${n}:${n}`).join(',')}} }`;
  const api = new Function('scope', body)(scope);
  for (const n of FN) scope[n] = api[n];   // sibling functions resolve through the scope, as in QML
  return api;
}

class FakeXHR {
  constructor() { FakeXHR.last = this; FakeXHR.count++; this.readyState = 0; this.status = 0; this.responseText = ''; this.headers = {}; this.timeout = 0; this.aborted = false; }
  open(m, u) { this.method = m; this.url = u; }
  setRequestHeader(k, v) { this.headers[k] = v; }
  send(b) { this.sent = b; }
  abort() { this.aborted = true; this.emit(4, 0, ''); }
  emit(state, status, text) { this.readyState = state; this.status = status; this.responseText = text; if (this.onreadystatechange) this.onreadystatechange(); }
  fireTimeout() { if (this.ontimeout) this.ontimeout(); }
}
FakeXHR.UNSENT = 0; FakeXHR.HEADERS_RECEIVED = 2; FakeXHR.LOADING = 3; FakeXHR.DONE = 4; FakeXHR.count = 0;

const NOW = Date.UTC(2026, 10, 12, 10);
const WIN = MODEL.presetWindow('month', NOW);

function scopeFor(over) {
  const s = {
    XMLHttpRequest: FakeXHR,
    StockRegisterModel: MODEL,
    AuthStore: { idToken: 'tok-1', tenantId: 't1', role: 'owner' },
    AuthService: { fresh: 0, refreshed: [], ensureFreshToken() { s.AuthService.fresh++; }, refreshIdToken(silent) { s.AuthService.refreshed.push(silent); } },
    FirebaseService: { environment: 'dev' },
    console: { warn() {}, log() {} },
    functionUrl: 'https://x/computeStockRegister',
    requestTimeoutMs: 125000,
    loading: false, lastBody: null, lastWindow: null, lastTenantId: '', lastRole: '',
    _xhr: null, _pendingCallback: null, _generation: 0
  };
  return Object.assign(s, over);
}
const good = (win) => JSON.stringify({ ok: true, window: { fromMs: win.fromMs, toMs: win.toMs }, readAt: 5, kinds: [], products: [], counts: {} });

// One scenario: returns { calls, scope, svc, xhr }.
function run(script, opts, src) {
  const scope = scopeFor(opts && opts.scope);
  const svc = build(src || SVC, scope);
  const calls = [];
  const sent = svc.load(opts && 'win' in opts ? opts.win : WIN, (r) => calls.push(plain(r)));
  const xhr = sent ? FakeXHR.last : null;
  if (script) script(xhr, scope, svc, calls);
  return { calls, scope, svc, xhr, sent };
}

// Every assertion collected, so a mutant can be asked "does the battery notice?".
function battery(src) {
  const bad = [];
  const eq = (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) bad.push(name + ': got ' + JSON.stringify(got) + ' want ' + JSON.stringify(want)); };
  const kinds = (calls) => calls.map((c) => c.kind || 'ok');
  const R = (script, o) => run(script, o, src);

  // request shape
  let r = R(null);
  eq('sent', r.sent, true);
  eq('method+url', [r.xhr.method, r.xhr.url], ['POST', 'https://x/computeStockRegister']);
  eq('auth header', r.xhr.headers.Authorization, 'Bearer tok-1');
  eq('content type', r.xhr.headers['Content-Type'], 'application/json');
  eq('timeout from property', r.xhr.timeout, 125000);
  eq('body', JSON.parse(r.xhr.sent), { from: WIN.fromMs, to: WIN.toMs, env: 'dev' });
  eq('token refreshed before send', r.scope.AuthService.fresh, 1);
  eq('loading while in flight', r.scope.loading, true);
  eq('no callback yet', r.calls, []);

  // success
  r = R((x) => x.emit(4, 200, good(WIN)));
  eq('success calls once', kinds(r.calls), ['ok']);
  eq('success result', [r.calls[0].ok, r.calls[0].window.fromMs, r.calls[0].body.readAt], [true, WIN.fromMs, 5]);
  eq('loading cleared', r.scope.loading, false);
  eq('stored', [r.scope.lastWindow.fromMs, r.scope.lastTenantId, r.scope.lastRole, r.scope.lastBody.ok], [WIN.fromMs, 't1', 'owner', true]);
  eq('no stale xhr', [r.scope._xhr, r.scope._pendingCallback], [null, null]);

  // QTBUG-49896: DONE reports 0 but a real status was seen earlier
  r = R((x) => { x.emit(2, 403, '{"error":"role-not-allowed"}'); x.emit(3, 403, '{"error":"role-not-allowed"}'); x.emit(4, 0, ''); });
  eq('lost status is recovered', kinds(r.calls), ['role']);
  r = R((x) => { x.emit(2, 200, good(WIN)); x.emit(4, 0, ''); });
  eq('lost 200 is recovered', kinds(r.calls), ['ok']);
  r = R((x) => { x.emit(2, 403, '{"error":"role-not-allowed"}'); x.emit(3, 0, ''); x.emit(4, 0, ''); });
  eq('a later status 0 does not erase the real one', kinds(r.calls), ['role']);
  r = R((x) => { x.emit(4, 0, ''); });
  eq('a real no-answer is offline', kinds(r.calls), ['offline']);
  r = R((x) => { x.fireTimeout(); });
  eq('timeout alone answers offline and frees the screen', [kinds(r.calls), r.scope.loading], [['offline'], false]);
  r = R((x) => { x.emit(1, 0, ''); x.emit(2, 0, ''); x.emit(4, 0, ''); });
  eq('status 0 at every stage is offline', kinds(r.calls), ['offline']);

  // failures
  const FAIL = [[401, '{"error":"invalid-token"}', 'auth'], [403, '{"error":"role-not-allowed"}', 'role'], [403, '{"error":"no-tenant-context"}', 'tenant'],
    [400, '{"error":"invalid-window"}', 'window'], [413, '{"error":"ledger-too-large"}', 'tooLarge'], [504, '{"error":"ledger-scan-timeout"}', 'timeout'],
    [500, '{"error":"compute-failed"}', 'server'], [502, 'not json', 'server'], [404, '', 'unknown'], [405, '{"error":"method-not-allowed"}', 'unknown']];
  for (const [status, text, kind] of FAIL) {
    r = R((x) => x.emit(4, status, text));
    eq('fail ' + status, [kinds(r.calls), r.calls[0].ok, r.calls[0].message === MODEL.message(kind) || kind === 'x'], [[kind], false, true]);
    eq('fail ' + status + ' stores nothing', [r.scope.lastBody, r.scope.loading], [null, false]);
  }
  r = R((x) => x.emit(4, 401, '{}'));
  eq('401 asks the silent door again (once before send, once after)', [r.scope.AuthService.fresh, r.scope.AuthService.refreshed], [2, []]);
  r = R((x) => x.emit(4, 500, '{}'));
  eq('500 does not refresh', r.scope.AuthService.fresh, 1);
  r = R((x) => x.emit(4, 403, '{}'));
  eq('403 does not refresh', r.scope.AuthService.fresh, 1);
  r = R((x) => x.emit(4, 403, '{"error":"role-not-allowed"}'));
  eq('role is not retryable', r.calls[0].retryable, false);

  // timeout, late DONE after timeout, double DONE: exactly one answer
  r = R((x) => { x.fireTimeout(); x.emit(4, 0, ''); });
  eq('timeout then DONE answers once', kinds(r.calls), ['offline']);
  r = R((x) => { x.emit(4, 200, good(WIN)); x.emit(4, 200, good(WIN)); x.fireTimeout(); });
  eq('double DONE answers once', kinds(r.calls), ['ok']);
  r = R((x) => { x.emit(4, 200, good(WIN)); x.fireTimeout(); });
  eq('timeout after success is ignored', [kinds(r.calls), r.scope.lastBody !== null], [['ok'], true]);

  // a 200 that must not be shown
  r = R((x) => x.emit(4, 200, JSON.stringify({ ok: true, window: { fromMs: WIN.fromMs + 1, toMs: WIN.toMs }, products: [] })));
  eq('moved window refused', [kinds(r.calls), r.scope.lastBody], [['badAnswer'], null]);
  r = R((x) => x.emit(4, 200, '<html>'));
  eq('200 not json refused', [kinds(r.calls), r.scope.lastBody], [['badAnswer'], null]);
  r = R((x) => x.emit(4, 200, JSON.stringify({ ok: true, window: { fromMs: WIN.fromMs, toMs: WIN.toMs }, products: 'x' })));
  eq('200 without products refused', kinds(r.calls), ['badAnswer']);
  r = R((x) => x.emit(4, 204, ''));
  eq('204 refused', kinds(r.calls), ['badAnswer']);
  r = R((x) => x.emit(4, 300, good(WIN)));
  eq('3xx is a failure', kinds(r.calls), ['unknown']);

  // refusals before any request
  const refuse = (name, o, want, retryable) => {
    const n0 = FakeXHR.count;
    const x = R(null, o);
    eq(name, [x.sent, kinds(x.calls), FakeXHR.count - n0, x.scope.loading], [false, [want], 0, false]);
    if (retryable !== undefined) eq(name + ' retryable', x.calls[0].retryable, retryable);
  };
  refuse('no token', { scope: { AuthStore: { idToken: '', tenantId: 't1', role: 'owner' } } }, 'notSignedIn');
  refuse('undefined token', { scope: { AuthStore: { idToken: undefined, tenantId: 't1', role: 'owner' } } }, 'notSignedIn');
  for (const role of ['staff', '', 'Owner', undefined, 'constructor']) {
    refuse('role ' + role + ' refused locally', { scope: { AuthStore: { idToken: 'tok', tenantId: 't1', role } } }, 'role', false);
  }
  for (const role of ['owner', 'admin', 'manager']) {
    r = R(null, { scope: { AuthStore: { idToken: 'tok', tenantId: 't1', role } } });
    eq('role ' + role + ' sends', r.sent, true);
  }
  for (const w of [null, undefined, {}, { ok: false, fromMs: 1, toMs: 2 }, { ok: true }, { ok: true, fromMs: '1', toMs: 2 }, 5, 'x']) {
    refuse('bad window ' + JSON.stringify(w), { win: w }, 'window');
  }

  // single flight: a second load while one flies is refused as "busy" and sends nothing
  {
    const scope = scopeFor();
    const svc = build(src, scope);
    const calls = [];
    svc.load(WIN, (c) => calls.push(plain(c)));
    const n = FakeXHR.count;
    const second = svc.load(WIN, (c) => calls.push(plain(c)));
    eq('second load refused', [second, FakeXHR.count - n, kinds(calls)], [false, 0, ['busy']]);
    eq('busy has no words and is not an error', [calls[0].message, calls[0].ok], ['', false]);
    eq('first still flying', scope.loading, true);
    FakeXHR.last.emit(4, 200, good(WIN));
    eq('first answers once', kinds(calls), ['busy', 'ok']);
    const third = svc.load(WIN, () => {});
    eq('a load after the answer is allowed', third, true);
  }

  // a null callback never throws
  r = R(null);
  let threw = false;
  try { const scope = scopeFor(); const svc = build(src, scope); svc.load(WIN, null); FakeXHR.last.emit(4, 500, '{}'); svc.load(null, null); } catch (e) { threw = true; }
  eq('null callback is safe', threw, false);

  // cancel
  {
    const scope = scopeFor();
    const svc = build(src, scope);
    const calls = [];
    svc.cancel();
    eq('cancel when idle does nothing', [scope.loading, calls.length, scope._generation], [false, 0, 0]);
    svc.load(WIN, (c) => calls.push(plain(c)));
    const x = FakeXHR.last;
    svc.cancel();
    eq('cancel answers once', kinds(calls), ['cancelled']);
    eq('cancel aborts and frees', [x.aborted, scope.loading, scope._xhr, scope._pendingCallback], [true, false, null, null]);
    eq('cancelled has no words', calls[0].message, '');
    x.emit(4, 200, good(WIN));            // a late answer for the cancelled request
    eq('late answer is ignored', [kinds(calls), scope.lastBody], [['cancelled'], null]);
    svc.cancel();
    eq('second cancel does nothing', kinds(calls), ['cancelled']);
    // a new load right after a cancel is not confused by the old request's late answer
    const calls2 = [];
    svc.load(WIN, (c) => calls2.push(plain(c)));
    const y = FakeXHR.last;
    x.emit(4, 500, '{}'); x.fireTimeout();
    eq('old request cannot answer the new one', [kinds(calls2), scope.loading], [[], true]);
    y.emit(4, 200, good(WIN));
    eq('new request answers', kinds(calls2), ['ok']);
  }

  // workspace or role change while the ledger is being read
  for (const [what, change] of [['tenant', (s) => { s.AuthStore.tenantId = 't2'; }], ['role', (s) => { s.AuthStore.role = 'admin'; }], ['sign-out', (s) => { s.AuthStore.tenantId = ''; }]]) {
    r = R((x, s) => { change(s); x.emit(4, 200, good(WIN)); });
    eq(what + ' change drops the answer', [kinds(r.calls), r.scope.lastBody, r.scope.loading], [['cancelled'], null, false]);
    r = R((x, s) => { change(s); x.emit(4, 500, '{}'); });
    eq(what + ' change drops a failure too', kinds(r.calls), ['cancelled']);
  }

  // cached(): the last good answer, for exactly that window, workspace and role
  {
    const scope = scopeFor();
    const svc = build(src, scope);
    eq('cache empty', svc.cached(WIN), null);
    scope.lastRole = 'owner'; scope.lastTenantId = 't1'; scope.lastWindow = WIN; scope.lastBody = null;
    eq('cache with no body is empty', svc.cached(WIN), null);
    scope.lastBody = { ok: true }; scope.lastWindow = null;
    eq('cache with no window is empty', svc.cached(WIN), null);
    scope.lastRole = ''; scope.lastTenantId = ''; scope.lastBody = null;
    svc.load(WIN, () => {});
    FakeXHR.last.emit(4, 200, good(WIN));
    const c = svc.cached(WIN);
    eq('cache hit', [c !== null, c && c.window.fromMs, c && c.body.readAt], [true, WIN.fromMs, 5]);
    eq('cache is per window', svc.cached(MODEL.presetWindow('lastMonth', NOW)), null);
    eq('cache window junk', [svc.cached(null), svc.cached({})], [null, null]);
    scope.AuthStore.tenantId = 't2';
    eq('cache is per workspace', svc.cached(WIN), null);
    scope.AuthStore.tenantId = 't1'; scope.AuthStore.role = 'staff';
    eq('cache is per role and refuses staff', svc.cached(WIN), null);
    scope.AuthStore.role = 'admin';
    eq('cache refuses another role', svc.cached(WIN), null);
    scope.AuthStore.role = 'owner';
    eq('cache back for the same person', svc.cached(WIN) !== null, true);
    svc.clear();
    eq('clear empties', [svc.cached(WIN), scope.lastBody, scope.lastWindow, scope.lastTenantId, scope.lastRole], [null, null, null, '', '']);
    // a failed load keeps the previous good answer (the page can still show it as stale)
    svc.load(WIN, () => {}); FakeXHR.last.emit(4, 200, good(WIN));
    svc.load(WIN, () => {}); FakeXHR.last.emit(4, 500, '{}');
    eq('failure keeps the last good answer', svc.cached(WIN) !== null, true);
  }
  return bad;
}

test('SRS-01 the service battery passes on the real file', () => {
  const bad = battery(SVC);
  assert.deepEqual(bad, [], bad.slice(0, 6).join('\n'));
});

test('SRS-02 monkey: random answer orders never double-answer, leak a flag or throw', () => {
  let seed = 99;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const outcomes = new Set();
  for (let i = 0; i < 2000; i++) {
    const scope = scopeFor();
    const svc = build(SVC, scope);
    const log = [];
    const flights = [];
    let callSeq = 0;
    for (let step = 0; step < 8; step++) {
      const a = rnd();
      if (a < 0.35) {
        const id = callSeq++;
        const sent = svc.load(WIN, (r) => log.push([id, r.kind || 'ok']));
        if (sent) flights.push({ id, x: FakeXHR.last });
      } else if (a < 0.5) svc.cancel();
      else if (flights.length) {
        const f = flights[Math.floor(rnd() * flights.length)];
        const b = rnd();
        if (b < 0.3) f.x.emit(4, 200, good(WIN));
        else if (b < 0.45) f.x.emit(4, [401, 403, 413, 500, 504, 0][Math.floor(rnd() * 6)], '{}');
        else if (b < 0.6) f.x.fireTimeout();
        else if (b < 0.7) { scope.AuthStore.tenantId = rnd() < 0.5 ? 't1' : 't9'; }
        else f.x.emit(rnd() < 0.5 ? 2 : 3, 200, good(WIN));
      }
    }
    // finish: answer or cancel whatever still flies
    svc.cancel();
    const perCall = {};
    for (const [id, kind] of log) { perCall[id] = (perCall[id] || 0) + 1; outcomes.add(kind); }
    for (const id of Object.keys(perCall)) assert.equal(perCall[id], 1, 'flight ' + id + ' answered ' + perCall[id] + ' times: ' + JSON.stringify(log));
    assert.equal(scope.loading, false);
    assert.equal(scope._xhr, null);
    for (const f of flights) assert.ok(perCall[f.id] === 1 || log.some(([id]) => id === f.id), 'every sent request is answered');
  }
  for (const k of ['ok', 'cancelled', 'busy', 'offline', 'auth', 'role', 'timeout', 'tooLarge', 'tenant', 'server']) if (!outcomes.has(k)) assert.ok(['role', 'tenant'].includes(k), k + ' reached');
  assert.ok(outcomes.has('ok') && outcomes.has('cancelled') && outcomes.has('busy') && outcomes.has('offline'), 'monkey reached: ' + [...outcomes]);
});

// ---- wiring and dormancy ------------------------------------------------------------------------------------------

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === 'node_modules' || e.name === '.git' || e.name === '3rdparty') continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out); else out.push(p);
  }
  return out;
}

test('SRS-03 wiring: singleton registered, URL = deployed handler, timeout above the server budget, no timer, imports resolve', () => {
  assert.match(fs.readFileSync(path.join(REPO, 'qml/model/qmldir'), 'utf8'), /^singleton StockRegisterService 1\.0 StockRegisterService\.qml$/m);
  assert.match(SVC, /^pragma Singleton/m);
  assert.match(SVC, /import "\.\.\/helper\/StockRegisterModel\.js" as StockRegisterModel/);
  assert.ok(fs.existsSync(path.join(REPO, 'qml/helper/StockRegisterModel.js')));
  // same project and region as the other endpoints, and the handler's real name
  const url = /property string functionUrl: "([^"]+)"/.exec(SVC)[1];
  const lock = fs.readFileSync(path.join(REPO, 'qml/model/AnalysisService.qml'), 'utf8');
  const base = (u) => u.replace(/\/[A-Za-z]+$/, '');
  assert.equal(base(url), base(/property string functionUrl: "([^"]+)"/.exec(lock)[1]));
  assert.match(url, /\/computeStockRegister$/);
  const index = fs.readFileSync(path.join(REPO, 'functions/index.js'), 'utf8');
  assert.match(index, /exports\.computeStockRegister = functions\.onRequest\(/);
  // client timeout above the server's function timeout (a shorter one aborts a still-valid, still-billed scan)
  const clientMs = Number(/readonly property int requestTimeoutMs: (\d+)/.exec(SVC)[1]);
  const fnSeconds = Number(/exports\.computeStockRegister = functions\.onRequest\(\s*\{[^}]*timeoutSeconds: (\d+)/.exec(index)[1]);
  assert.ok(clientMs > fnSeconds * 1000, `client ${clientMs} ms must exceed server ${fnSeconds} s`);
  assert.ok(clientMs <= 180000, 'a hung request must not spin for minutes');
  // on demand only: no timer, no resume hook, no auto-refresh in the service
  assert.doesNotMatch(SVC.replace(/\/\/.*$/gm, ''), /Timer|createQmlObject|onResume|Qt\.application|setInterval|setTimeout/);
  // the request carries the environment, as every other endpoint does
  assert.match(SVC, /envelope\.env = FirebaseService\.environment/);
});

test('SRS-04 dormant: nothing but the service itself and tests names the service (S4b-2 will add the page)', () => {
  const users = walk(REPO, []).filter((f) => /\.(qml|js)$/.test(f) && !f.includes(`${path.sep}functions${path.sep}`) && !f.includes(`${path.sep}.github${path.sep}`) && !f.includes(`${path.sep}test${path.sep}`))
    .filter((f) => f !== SVC_PATH && !f.endsWith(path.join('helper', 'StockRegisterModel.js')))
    .filter((f) => /StockRegisterService|StockRegisterModel/.test(fs.readFileSync(f, 'utf8')))
    .map((f) => path.relative(REPO, f))
    .filter((f) => !f.startsWith('tests' + path.sep) && f !== path.join('qml', 'model', 'qmldir'));
  assert.deepEqual(users, [], 'unexpected users: ' + users.join(', '));
});

// ---- hand mutants -------------------------------------------------------------------------------------------------
const MUTANTS = [
  ['no busy guard', 'if (loading) {', 'if (false) {'],
  ['busy sends', 'return false\n        }\n        if (!win', 'return true\n        }\n        if (!win'],
  ['window not checked', 'if (!win || win.ok !== true || StockRegisterModel.windowKey(win) === "") {', 'if (false) {'],
  ['window ok flag ignored', 'if (!win || win.ok !== true ||', 'if (!win ||'],
  ['window key ignored', ' || StockRegisterModel.windowKey(win) === "") {', ') {'],
  ['token not checked', 'if (!AuthStore.idToken || AuthStore.idToken.length === 0) {', 'if (false) {'],
  ['role not checked', 'if (!StockRegisterModel.canView(AuthStore.role)) {\n            _fail(callback, "role")', 'if (false) {\n            _fail(callback, "role")'],
  ['token not refreshed', 'AuthService.ensureFreshToken()\n\n        var gen', '\n\n        var gen'],
  ['gen read after the bump', 'var gen = _generation   // only', 'var gen = _generation + 1   // only'],
  ['cancelled not ignored', 'if (gen !== _generation) return', ''],
  ['tenant change not checked', 'if (tenantAtSend !== AuthStore.tenantId || roleAtSend !== AuthStore.role) {', 'if (false) {'],
  ['role change not checked', ' || roleAtSend !== AuthStore.role) {', ') {'],
  ['tenant change only', 'tenantAtSend !== AuthStore.tenantId ||', ''],
  ['settled latch dropped', 'if (settled) return\n            settled = true', 'settled = true'],
  ['loading stuck on success', '            loading = false\n\n            // The person left', '\n            // The person left'],
  ['xhr not released', '            _xhr = null\n            _pendingCallback = null\n            loading = false\n\n', '            loading = false\n\n'],
  ['answer not validated', 'var check = StockRegisterModel.validateAnswer(body, win)\n                if (!check.ok) {', 'var check = { ok: true }\n                if (!check.ok) {'],
  ['bad answer stored', '_fail(callback, "badAnswer")\n                    return', '_fail(callback, "badAnswer")'],
  ['window not stored', '                lastWindow = win\n', ''],
  ['tenant not stored', '                lastTenantId = tenantAtSend\n', ''],
  ['role not stored', '                lastRole = roleAtSend\n', ''],
  ['2xx range', 'if (status >= 200 && status < 300) {', 'if (status >= 200) {'],
  ['2xx range low', 'if (status >= 200 && status < 300) {', 'if (status < 300) {'],
  ['no 401 refresh', 'if (c.kind === "auth" && typeof AuthService', 'if (false && typeof AuthService'],
  ['wrong door', '                AuthService.ensureFreshToken()\n            _answer', '                AuthService.refreshIdToken(true)\n            _answer'],
  ['refresh on every failure', 'if (c.kind === "auth" && typeof AuthService', 'if (typeof AuthService'],
  ['classify bypassed', 'var c = StockRegisterModel.classify(status, body)', 'var c = { kind: "server", message: "x", retryable: true }'],
  ['status snapshot dropped', '            _captureBeforeStatusIsLost(xhr, snap)\n', ''],
  ['snapshot ignores 0 check', 'if (xhr.status !== 0) {', 'if (true) {'],
  ['snapshot stage', 'if (xhr.readyState === XMLHttpRequest.HEADERS_RECEIVED || xhr.readyState === XMLHttpRequest.LOADING) {', 'if (xhr.readyState === XMLHttpRequest.DONE) {'],
  ['lost status not used', 'settle(lost ? snap.status : xhr.status, lost ? snap.responseText : xhr.responseText)', 'settle(xhr.status, xhr.responseText)'],
  ['timeout not wired', 'xhr.ontimeout = function() { settle(0, "") }', ''],
  ['timeout answers as success', 'xhr.ontimeout = function() { settle(0, "") }', 'xhr.ontimeout = function() { settle(200, "{}") }'],
  ['timeout not set', 'xhr.timeout = requestTimeoutMs', ''],
  ['token header dropped', 'xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)', ''],
  ['env dropped', 'envelope.env = FirebaseService.environment', ''],
  ['body dates', 'var envelope = StockRegisterModel.requestBody(win)', 'var envelope = { from: new Date(win.fromMs).toISOString(), to: new Date(win.toMs).toISOString() }'],
  ['sent flag false', '        xhr.send(JSON.stringify(envelope))\n        return true', '        xhr.send(JSON.stringify(envelope))\n        return false'],
  ['cancel answers nothing', '_fail(cb, "cancelled")', ''],
  ['cancel does not abort', 'try { if (xhr) xhr.abort() } catch (e) { }', ''],
  ['cancel keeps loading', '        _pendingCallback = null\n        loading = false\n        try', '        _pendingCallback = null\n        try'],
  ['cancel keeps generation', '        _generation++\n        _xhr = null', '        _xhr = null'],
  ['cancel when idle', 'if (!loading) return\n        var cb', 'var cb'],
  ['cached ignores window', 'if (StockRegisterModel.windowKey(win) !== StockRegisterModel.windowKey(lastWindow)) return null', ''],
  ['cached ignores tenant', 'if (lastTenantId !== AuthStore.tenantId || lastRole !== AuthStore.role) return null', 'if (lastRole !== AuthStore.role) return null'],
  ['cached ignores role', 'if (lastTenantId !== AuthStore.tenantId || lastRole !== AuthStore.role) return null', 'if (lastTenantId !== AuthStore.tenantId) return null'],
  ['cached empty check', 'if (!lastBody || !lastWindow) return null', ''],
  ['clear leaves body', '        lastBody = null\n        lastWindow = null\n        lastTenantId = ""', '        lastWindow = null\n        lastTenantId = ""'],
  ['clear leaves tenant', '        lastTenantId = ""\n        lastRole = ""', '        lastRole = ""'],
  ['failure clears the good answer', 'var c = StockRegisterModel.classify(status, body)', 'lastBody = null\n            var c = StockRegisterModel.classify(status, body)'],
  ['role retryable', 'retryable: kind !== "role"', 'retryable: true'],
  ['busy has words', '_answer(callback, { ok: false, kind: "busy", message: "", retryable: true })', '_answer(callback, { ok: false, kind: "busy", message: "Busy", retryable: true })']
];

test('SRS-05 every hand mutant is noticed by the battery', () => {
  const survivors = [], broken = [];
  for (const [name, from, to] of MUTANTS) {
    const n = SVC.split(from).length - 1;
    if (n !== 1) { broken.push(`${name} (${n} matches)`); continue; }     // a mutant that changes nothing proves nothing
    let bad;
    try { bad = battery(SVC.replace(from, to)); } catch (e) { continue; }   // throws: killed
    if (bad.length === 0) survivors.push(name);
  }
  assert.deepEqual(broken, [], 'mutants not matching exactly once: ' + broken.join(', '));
  assert.deepEqual(survivors, [], 'survivors: ' + survivors.join(', '));
});
