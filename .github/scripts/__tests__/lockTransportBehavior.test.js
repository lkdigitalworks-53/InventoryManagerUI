'use strict';

// D-E + F2 (PR #174 sweep, 2026-10-31). LockManager._post is the one raw XHR of the lock service. It had
//  (F2) no QTBUG-49896 snapshot (SKILLS Skill 45/76): QML can reset xhr.status to 0 at the 3->4 transition for
//       some non-2xx answers, so a real 403 `no-tenant-context` or 409 denial could reach the classifier as
//       status 0 = "no real answer" and the whole no-access / denied wording would never show on a device;
//  (D-E) no timeout: an acquire that never answers never calls back, so bulk Approve waited forever.
// This file runs the REAL text of _post / _captureBeforeStatusIsLost / _onRenewTick / _renewalLost against a
// scripted fake XMLHttpRequest, plus mutants. Plan: docs/superpowers/test-plans/2026-10-28-s2f3-access-blocked-test-plan.md (2e, N14, E15)

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..', '..');
const LOCK = fs.readFileSync(path.join(REPO, 'qml', 'model', 'LockManager.qml'), 'utf8');

function fnText(src, name) {
  const at = src.indexOf(`function ${name}(`);
  if (at < 0) return '';
  const open = src.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}' && --depth === 0) return src.slice(at, i + 1);
  }
  return '';
}

// QML resolves bare names against the component (root properties and sibling functions). `with(scope)` gives
// the extracted function text the same lookup, and assignments to existing scope keys (`_held = null`) land
// on the scope object, like they do on a QML property.
function build(src, names, scope) {
  const texts = names.map((n) => {
    const t = fnText(src, n);
    assert.ok(t, `${n} text found`);
    return t;
  });
  const body = `with(scope){ ${texts.join('\n')}\n return {${names.map((n) => `${n}:${n}`).join(',')}} }`;
  return new Function('scope', body)(scope);
}

class FakeXHR {
  constructor() { FakeXHR.last = this; this.readyState = 0; this.status = 0; this.responseText = ''; this.headers = {}; this.timeout = 0; }
  open(m, u) { this.method = m; this.url = u; }
  setRequestHeader(k, v) { this.headers[k] = v; }
  send(b) { this.sent = b; }
  emit(state, status, text) { this.readyState = state; this.status = status; this.responseText = text; if (this.onreadystatechange) this.onreadystatechange(); }
  fireTimeout() { if (this.ontimeout) this.ontimeout(); }
}
FakeXHR.UNSENT = 0; FakeXHR.HEADERS_RECEIVED = 2; FakeXHR.LOADING = 3; FakeXHR.DONE = 4;

function scopeFor() {
  return {
    XMLHttpRequest: FakeXHR,
    AuthStore: { idToken: 'tok-123' },
    FirebaseService: { environment: 'test-env' },
    requestTimeoutMs: 15000,
    console: { warn() {}, log() {} },
  };
}

// Runs one _post with a scripted XHR life; returns the callback calls.
function post(src, script, payload = { entity: 'order', entityId: 'o1' }) {
  const scope = scopeFor();
  const lm = build(src, ['_captureBeforeStatusIsLost', '_post'], scope);
  const calls = [];
  lm._post('https://x/acquireLock', payload, (status, body) => calls.push([status, body]));
  script(FakeXHR.last);
  return { calls, xhr: FakeXHR.last };
}

const classify = (() => {
  const t = fnText(LOCK, '_classifyAcquireResponse');
  return new Function(`${t}\n;return _classifyAcquireResponse`)();
})();

const NOACC_BODY = JSON.stringify({ ok: false, error: 'no-tenant-context' });
const DENY_BODY = JSON.stringify({ ok: false, holder: { name: 'Zed' } });

// Returns the list of broken behaviours for a LockManager source (empty = correct).
function transportProblems(src) {
  const out = [];
  try {
    // plain 200
    let r = post(src, (x) => { x.emit(2, 200, ''); x.emit(3, 200, '{"ok":true}'); x.emit(4, 200, '{"ok":true}'); });
    if (r.calls.length !== 1 || r.calls[0][0] !== 200 || r.calls[0][1].ok !== true) out.push('ok-200');

    // request shape: method, url, headers, timeout, merged envelope
    r = post(src, () => {}, { entity: 'order', entityId: 'o9', requestId: 'r1' });
    const sent = JSON.parse(r.xhr.sent || '{}');
    if (r.xhr.method !== 'POST' || r.xhr.url !== 'https://x/acquireLock') out.push('shape-method-url');
    if (r.xhr.headers.Authorization !== 'Bearer tok-123' || r.xhr.headers['Content-Type'] !== 'application/json') out.push('shape-headers');
    if (sent.env !== 'test-env' || sent.entity !== 'order' || sent.entityId !== 'o9' || sent.requestId !== 'r1') out.push('shape-envelope');
    if (r.xhr.timeout !== 15000) out.push('timeout-set');
    if (r.calls.length !== 0) out.push('no-callback-before-answer');

    // F2: the status is lost at DONE (QTBUG-49896) -> recovered from the snapshot, body too
    r = post(src, (x) => { x.emit(2, 403, ''); x.emit(3, 403, NOACC_BODY); x.emit(4, 0, ''); });
    if (r.calls.length !== 1 || r.calls[0][0] !== 403 || !r.calls[0][1] || r.calls[0][1].error !== 'no-tenant-context') out.push('lost-403-recovered');
    else if (classify(...r.calls[0]).noAccess !== true) out.push('lost-403-classified');
    r = post(src, (x) => { x.emit(2, 409, ''); x.emit(3, 409, DENY_BODY); x.emit(4, 0, ''); });
    if (r.calls.length !== 1 || r.calls[0][0] !== 409 || !r.calls[0][1]) out.push('lost-409-recovered');
    else if (classify(...r.calls[0]).reason !== 'denied') out.push('lost-409-classified');
    // snapshot taken at HEADERS_RECEIVED only (no LOADING): status recovered, body empty -> still not a real answer
    r = post(src, (x) => { x.emit(2, 403, ''); x.emit(4, 0, ''); });
    if (r.calls[0][0] !== 403 || r.calls[0][1] !== null || classify(...r.calls[0]).noAccess === true) out.push('headers-only');
    // a later state with status 0 never wipes the snapshot
    r = post(src, (x) => { x.emit(2, 403, ''); x.emit(3, 403, NOACC_BODY); x.emit(3, 0, ''); x.emit(4, 0, ''); });
    if (r.calls[0][0] !== 403 || !r.calls[0][1]) out.push('snapshot-kept');
    // a real status at DONE wins over an older snapshot
    r = post(src, (x) => { x.emit(2, 200, ''); x.emit(3, 200, '{"ok":true}'); x.emit(4, 409, DENY_BODY); });
    if (r.calls[0][0] !== 409) out.push('done-status-wins');

    // a genuine network failure never saw headers: status 0, no body
    r = post(src, (x) => { x.emit(4, 0, ''); });
    if (r.calls.length !== 1 || r.calls[0][0] !== 0 || r.calls[0][1] !== null) out.push('network-failure');

    // D-E: timeout answers once as "no answer", a late DONE does not answer a second time
    r = post(src, (x) => { x.fireTimeout(); });
    if (r.calls.length !== 1 || r.calls[0][0] !== 0 || r.calls[0][1] !== null) out.push('timeout-answers');
    r = post(src, (x) => { x.fireTimeout(); x.emit(4, 200, '{"ok":true}'); });
    if (r.calls.length !== 1) out.push('late-done-after-timeout');
    r = post(src, (x) => { x.emit(4, 0, ''); x.fireTimeout(); });
    if (r.calls.length !== 1) out.push('timeout-after-done');
    r = post(src, (x) => { x.emit(4, 200, '{"ok":true}'); x.emit(4, 200, '{"ok":true}'); });
    if (r.calls.length !== 1) out.push('double-done');

    // malformed / empty bodies never throw and read as no body
    for (const txt of ['', '<html>502</html>', '{', 'null']) {
      r = post(src, (x) => { x.emit(4, 502, txt); });
      if (r.calls.length !== 1 || r.calls[0][1] !== null) out.push(`bad-body-${txt.length}`);
    }
    // no callback given: no throw
    const lm = build(src, ['_captureBeforeStatusIsLost', '_post'], scopeFor());
    lm._post('u', {}, undefined);
    FakeXHR.last.emit(4, 200, '{"ok":true}');
    FakeXHR.last.fireTimeout();
  } catch (err) {
    out.push(`threw: ${err.message}`);
  }
  return out;
}

// ---- renewal: a no-answer keeps the hold, a real refusal drops it ----
function renew(src, answer, opts = {}) {
  const scope = {
    ...scopeFor(),
    _held: opts.held === undefined ? { entity: 'order', entityId: 'o1', requestId: 'r1' } : opts.held,
    acquireLockUrl: 'https://x/acquireLock',
    _classifyAcquireResponse: classify,
    stops: 0, posts: 0,
    _renewTimerInstance() { return { stop: () => { scope.stops++; } }; },
    _post(url, payload, cb) { scope.posts++; if (opts.during) opts.during(scope); cb(answer[0], answer[1]); },
  };
  const lm = build(src, ['_renewalLost', '_onRenewTick'], scope);
  const before = scope._held;
  lm._onRenewTick();
  return { scope, before };
}

function renewalProblems(src) {
  const out = [];
  try {
    let r = renew(src, [200, { ok: true }]);
    if (r.scope._held !== r.before || r.scope.stops !== 0) out.push('ok-keeps');
    r = renew(src, [0, null]);
    if (r.scope._held !== r.before || r.scope.stops !== 0) out.push('no-answer-keeps');
    for (const [name, ans] of [['409', [409, { ok: false, holder: { name: 'A' } }]], ['403', [403, { ok: false, error: 'no-tenant-context' }]],
      ['500', [500, { ok: false, error: 'lock-failed' }]]]) {
      r = renew(src, ans);
      if (r.scope._held !== null || r.scope.stops !== 1) out.push(`refusal-drops-${name}`);
    }
    // an answer we cannot read (HTML error page, empty or partial body after a timeout, JSON without `ok`) is a
    // no-answer too: keep the hold, the next heartbeat asks again
    for (const [name, ans] of [['502-html', [502, null]], ['200-empty', [200, null]], ['200-no-ok', [200, {}]], ['500-ok-not-bool', [500, { ok: 'no' }]]]) {
      r = renew(src, ans);
      if (r.scope._held !== r.before || r.scope.stops !== 0) out.push(`unreadable-keeps-${name}`);
    }
    // nothing held: stop the timer, send nothing
    r = renew(src, [200, { ok: true }], { held: null });
    if (r.scope.posts !== 0 || r.scope.stops !== 1) out.push('nothing-held');
    // another lock was taken while the old renewal was in flight: a failing old renewal must not drop the new one
    const fresh = { entity: 'order', entityId: 'o2', requestId: 'r2' };
    r = renew(src, [409, { ok: false, holder: null }], { during: (s) => { s._held = fresh; } });
    if (r.scope._held !== fresh) out.push('new-lock-not-dropped');
    // the unit rule itself
    const lost = build(src, ['_renewalLost'], { })._renewalLost;
    const real = { ok: false };
    if (lost(0, real, { granted: false }) !== false || lost(409, real, { granted: false }) !== true || lost(200, { ok: true }, { granted: true }) !== false
      || lost(403, real, { granted: false }) !== true || lost(0, { ok: true }, { granted: true }) !== false
      || lost(502, null, { granted: false }) !== false || lost(500, undefined, { granted: false }) !== false
      || lost(500, [], { granted: false }) !== false || lost(500, 'x', { granted: false }) !== false) out.push('renewalLost-rule');
  } catch (err) {
    out.push(`threw: ${err.message}`);
  }
  return out;
}

// =========================== tests ===========================
test('happy: the real _post is correct (shape, timeout, lost status recovered, single answer)', () => {
  assert.deepEqual(transportProblems(LOCK), []);
});
test('happy: the real renewal keeps the hold on a no-answer and drops it on a real refusal', () => {
  assert.deepEqual(renewalProblems(LOCK), []);
});
test('regression F2: a 403 whose status was lost at DONE still reads as no-access', () => {
  const r = post(LOCK, (x) => { x.emit(2, 403, ''); x.emit(3, 403, NOACC_BODY); x.emit(4, 0, ''); });
  assert.equal(classify(...r.calls[0]).noAccess, true);
});
test('regression D-E: an acquire that never answers is answered by the timeout, once', () => {
  const r = post(LOCK, (x) => x.fireTimeout());
  assert.deepEqual(r.calls, [[0, null]]);
  assert.equal(classify(...r.calls[0]).reason, 'error');
  assert.equal(classify(...r.calls[0]).noAccess, undefined);
});

const MUT = [
  ['snapshot call removed (F2)', 'transport', '        xhr.onreadystatechange = function() {\n            _captureBeforeStatusIsLost(xhr, snap)\n', '        xhr.onreadystatechange = function() {\n'],
  ['snapshot only used when status is 0 is dropped: DONE status always used', 'transport', 'var lost = xhr.status === 0', 'var lost = false'],
  ['snapshot overwrites with status 0', 'transport', 'if (xhr.status !== 0) {', 'if (true) {'],
  ['timeout never set (D-E)', 'transport', 'xhr.timeout = requestTimeoutMs', 'xhr.timeout = 0'],
  ['timeout set to a different value', 'transport', 'xhr.timeout = requestTimeoutMs', 'xhr.timeout = 1'],
  ['ontimeout handler removed', 'transport', 'xhr.ontimeout = function() { _settle(0, "") }', ''],
  ['settled guard removed (double answer)', 'transport', 'if (settled) return\n            settled = true', 'settled = true'],
  ['body parse not guarded', 'transport', 'try { body = JSON.parse(text) } catch (e) { body = null }', 'body = JSON.parse(text)'],
  ['callback called without a null check', 'transport', 'if (callback) callback(status, body)', 'callback(status, body)'],
  ['auth header dropped', 'transport', 'xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)', ''],
  ['renewal drops the hold on a no-answer (old behaviour once timeouts exist)', 'renewal', 'return !classified.granted && status !== 0 && body !== null && typeof body === "object" && typeof body.ok === "boolean"', 'return !classified.granted'],
  ['renewal drops the hold on an unreadable answer', 'renewal', ' && body !== null && typeof body === "object" && typeof body.ok === "boolean"', ''],
  ['renewal readable check ignores the ok flag', 'renewal', ' && typeof body.ok === "boolean"', ''],
  ['renewal never drops the hold', 'renewal', 'return !classified.granted && status !== 0 && body', 'return false && body'],
  ['renewal rule not used', 'renewal', 'if (_renewalLost(status, body, classified)) {', 'if (!classified.granted) {'],
];
for (const [name, kind, from, to] of MUT) {
  test(`negative (LockManager): ${name} is caught`, () => {
    const mutated = LOCK.replace(from, to);
    assert.notEqual(mutated, LOCK, `fixture drifted: ${name}`);
    const probs = kind === 'transport' ? transportProblems(mutated) : renewalProblems(mutated);
    assert.ok(probs.length > 0, name);
  });
}

// ---- edge ----
test('edge: the snapshot helper only takes a non-zero status at states 2 and 3', () => {
  const f = build(LOCK, ['_captureBeforeStatusIsLost'], scopeFor())._captureBeforeStatusIsLost;
  const s = { status: 0, responseText: '' };
  f({ readyState: 1, status: 403, responseText: 'x' }, s); assert.equal(s.status, 0);
  f({ readyState: 4, status: 403, responseText: 'x' }, s); assert.equal(s.status, 0);
  f({ readyState: 2, status: 0, responseText: 'x' }, s); assert.equal(s.status, 0);
  f({ readyState: 3, status: 409, responseText: 'b' }, s); assert.deepEqual(s, { status: 409, responseText: 'b' });
});
test('edge: a page of LockManager with no _post reports a failure instead of passing', () => {
  assert.ok(transportProblems(LOCK.replace('function _post(', 'function _other(')).length > 0);
});
test('edge: the timeout is a named readonly property, 15 s', () => {
  assert.match(LOCK, /readonly property int requestTimeoutMs: 15000/);
});
