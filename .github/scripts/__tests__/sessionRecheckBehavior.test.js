'use strict';

// L3 slice A behaviour pins. AuthService cannot be instantiated under qmltestrunner (Felgo, no App context), so this
// file RUNS the real function text of AuthService.qml (the silent re-check path, the triggers, the token refresh)
// in a vm sandbox against a fake clock, a fake network and stubs for AuthStore / FirebaseService, with the real
// qml/helper/AccessState.js and qml/helper/SessionRecheck.js. Same method as accessBlockBehavior.test.js (S2f-3):
// the sandbox resolves bare names through a Proxy exactly as QML resolves them against the root object, so
// nothing here re-implements the logic under test. Not covered (needs a device): the property bindings, what
// the screen draws, and the real Qt.application.state transitions. See the test plan.
// Design: docs/superpowers/specs/2026-10-31-l3-session-lifecycle-design.md (L3-D1c, D2a, D5b).

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '..', '..', '..');
const AUTH_SRC = fs.readFileSync(path.join(REPO, 'qml/model/AuthService.qml'), 'utf8');
const lib = (f) => fs.readFileSync(path.join(REPO, 'qml/helper', f), 'utf8').replace(/^\.pragma library/m, '');
const ACCESS_SRC = lib('AccessState.js');
const RECHECK_SRC = lib('SessionRecheck.js');

const FNS = ['_loadUserProfile', '_verifyMembership', '_applyAccess', 'recheckAccess', 'signOut', '_recheckOrLoad',
  '_sessionOpen', 'requestRecheck', 'onAppResumed', '_tokenExpiring', 'refreshIdToken', 'ensureFreshToken', 'loadTenantMembers', '_ensureTenantName'];
const ROLES = ['owner', 'admin', 'manager', 'staff'];
const MEMBER_DOC = /^tenants\/[^/]+\/members\/[^/]+$/;
const ROSTER = /^tenants\/[^/]+\/members$/;
const T0 = 1_700_000_000_000;

function fnText(src, name) {
  const clean = src.split('\n').map((l) => l.replace(/\/\/.*$/, '')).join('\n');
  const at = clean.indexOf(`function ${name}(`);
  if (at < 0) throw new Error(`function ${name} not found`);
  const open = clean.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < clean.length; i++) {
    if (clean[i] === '{') depth++;
    if (clean[i] === '}' && --depth === 0) return clean.slice(at, i + 1);
  }
  throw new Error(`function ${name} not closed`);
}

function loadLib(src, names) {
  const ctx = vm.createContext({});
  vm.runInContext(src + `\n;this.__x = { ${names} }`, ctx);
  return ctx.__x;
}

// One copy of AuthService (the mutants pass a broken copy) wired to a fake world. init.store / init.state
// override the defaults, which describe an owner whose session is already open on this phone.
function makeHarness(authSrc, init = {}) {
  const calls = { applyTenantContext: [], tenantContextReady: [], roleChanged: [], onboardingRequired: 0, get: [], post: 0, signedOut: 0, authFailed: [], tokenRefreshed: 0, applyAuth: [] };
  const writes = [];
  const pending = [];
  const clock = { t: T0 };
  const state = {
    accessBlock: '', accessTenantName: '', _profileSeq: 0, profileResolved: true, onboardingNeeded: false, checking: false, _contextSynced: true,
    _lastRecheckMs: 0, _lastResumeMs: 0, isOnline: true, tenantMembers: [], membersBusy: false, busy: false, tenantCreateBusy: false,
    apiKey: 'k', tokenBaseUrl: 'https://t', ...(init.state || {}),
  };
  const AuthStore = {
    uid: 'u1', isAuthenticated: true, tenantId: 't1', tenantName: 'Al Shop', role: 'owner', email: 'u@x.in', displayName: 'U', photoUrl: '',
    refreshToken: 'rt', idToken: 'tok', expiresAtEpochSec: Math.floor(T0 / 1000) + 3600, ...(init.store || {}),
    applyTenantContext(c) { calls.applyTenantContext.push(c); this.tenantId = c.tenantId || ''; this.tenantName = c.tenantName || ''; this.role = c.role || ''; },
    applyAuth(a) {
      calls.applyAuth.push(a);
      if (a && a.idToken) { this.idToken = a.idToken; this.isAuthenticated = true; }
      if (a && a.uid) this.uid = a.uid;
      if (a && a.refreshToken) this.refreshToken = a.refreshToken;
      if (a && a.expiresAtEpochSec) this.expiresAtEpochSec = a.expiresAtEpochSec;
    },
    updateProfile() {}, saveSession() {},
    clear() { this.uid = ''; this.isAuthenticated = false; this.tenantId = ''; this.tenantName = ''; this.role = ''; this.idToken = ''; this.refreshToken = ''; },
  };
  const FirebaseService = {
    get(p, cb) { calls.get.push(p); pending.push({ p, cb, seq: own._profileSeq, silent: own.checking }); },
    toArray: (d) => d,
  };
  const noop = new Proxy(function () {}, { get: (t, k) => (k === Symbol.toPrimitive ? () => '' : noop), apply: () => noop });
  const own = {
    ...state, AuthStore, FirebaseService, AccessState: loadLib(ACCESS_SRC, 'classify, outcome, copy, isValidRole, STATE_MOVED'),
    SessionRecheck: loadLib(RECHECK_SRC, 'canStart, changeKind, AUTO_SPACING_MS, STALE_MS'),
    Date: { now: () => clock.t },
    _nowEpochSec: () => Math.floor(clock.t / 1000),
    _parseErrorReason: () => 'refresh failed',
    _postJson(url, body, cb) { calls.post++; pending.push({ p: 'POST token', cb, seq: own._profileSeq, silent: false, rt: body.refresh_token }); },
    tenantContextReady(t, r) { calls.tenantContextReady.push({ t, r, blockAtEmit: scope.accessBlock }); },
    roleChanged(r) { calls.roleChanged.push(r); },
    onboardingRequired() { calls.onboardingRequired++; },
    tenantMembersLoaded() {}, memberOperationFailed() {}, signedOut() { calls.signedOut++; },
    authFailed(m) { calls.authFailed.push(m); }, tokenRefreshed() { calls.tokenRefreshed++; },
  };
  const scope = new Proxy(own, {
    has: () => true,
    get(t, k) {
      if (k === Symbol.unscopables) return undefined;
      if (k in t) return t[k];
      if (typeof k === 'string' && k in globalThis) return globalThis[k];
      return noop;
    },
    set(t, k, v) { writes.push([k, v]); t[k] = v; return true; },
  });
  const fnSrc = FNS.map((n) => `${n}: ${fnText(authSrc, n).replace(`function ${n}(`, 'function(')}`).join(',\n');
  Object.assign(own, new Function('scope', `with (scope) { return { ${fnSrc} } }`)(scope));

  const h = {
    calls, scope, AuthStore, own, clock, pending, writes,
    tick(ms) { clock.t += ms; },
    answerAt(i, ok, data, status) { const [{ cb }] = pending.splice(i, 1); cb(ok, data, status); },
    answer(prefix, ok, data, status) {
      const i = pending.findIndex((x) => (prefix instanceof RegExp ? prefix.test(x.p) : x.p.startsWith(prefix)));
      assert.ok(i >= 0, `no pending read for ${prefix} (have: ${pending.map((x) => x.p)})`);
      h.answerAt(i, ok, data, status);
    },
    pendingCount: () => pending.length,
    users(tenantId, tenantName = 'Al Shop') { h.answer('users/', true, { tenantId, tenantName, role: 'owner' }, 200); },
    usersFails(status = 500) { h.answer('users/', false, null, status); },
    usersGone() { h.answer('users/', false, null, 404); },
    usersNoTenant() { h.answer('users/', true, {}, 200); },
    member(doc) { h.answer(MEMBER_DOC, true, doc, 200); },
    memberGone() { h.answer(MEMBER_DOC, false, null, 404); },
    memberFails(status = 500) { h.answer(MEMBER_DOC, false, null, status); },
    roster() { h.answer(ROSTER, true, [], 200); },
    mark: () => writes.length,
    falseWrites: (since = 0) => writes.slice(since).filter((w) => w[0] === 'profileResolved' && w[1] === false).length,
    usersReads: () => calls.get.filter((x) => x.startsWith('users/')).length,
    rosterReads: () => calls.get.filter((x) => ROSTER.test(x)).length,
  };
  return h;
}

const active = (role) => ({ status: 'active', role });
const nothingApplied = (h) => {
  assert.equal(h.calls.tenantContextReady.length, 0, 'no tenantContextReady');
  assert.equal(h.calls.applyTenantContext.length, 0, 'no applyTenantContext');
  assert.equal(h.calls.roleChanged.length, 0, 'no role toast');
  assert.equal(h.rosterReads(), 0, 'no roster reload');
  assert.equal(h.calls.onboardingRequired, 0, 'no onboarding');
};
// A silent check, answered end to end with the given member answer.
function silentWith(h, userTenant, memberAnswer) {
  assert.equal(h.scope.requestRecheck(), true, 'the check starts');
  h.users(userTenant);
  memberAnswer(h);
}

// ---------------------------------------------------------------------------------------------------------
const SCENARIOS = {
  'D1c: a healthy silent check changes nothing (no cover, no resync, no roster reload, checking only while out)'(h) {
    const m = h.mark();
    assert.equal(h.scope.requestRecheck(), true);
    assert.equal(h.scope.checking, true);
    assert.equal(h.scope.profileResolved, true);
    h.users('t1');
    assert.equal(h.scope.checking, true, 'still waiting for the member doc');
    h.member(active('owner'));
    assert.equal(h.scope.checking, false);
    assert.equal(h.falseWrites(m), 0, 'profileResolved was never flipped, so the sign-in form never shows');
    nothingApplied(h);
    assert.deepEqual(h.calls.get, ['users/u1', 'tenants/t1/members/u1']);
    assert.equal(h.pendingCount(), 0);
  },

  'D5b: every one of the 12 role changes emits tenantContextReady once and toasts once'(h, make) {
    for (const from of ROLES) for (const to of ROLES.filter((r) => r !== from)) {
      const x = make({ store: { role: from } });
      const m = x.mark();
      silentWith(x, 't1', (y) => y.member(active(to)));
      assert.equal(x.AuthStore.role, to, `${from} -> ${to}`);
      assert.deepEqual(x.calls.tenantContextReady.map((c) => c.r), [to], `${from} -> ${to}`);
      assert.deepEqual(x.calls.roleChanged, [to], `${from} -> ${to}`);
      assert.equal(x.rosterReads(), 1, 'a changed role reloads the roster once');
      assert.equal(x.falseWrites(m), 0, 'no sign-in cover');
      assert.equal(x.scope.checking, false);
    }
  },

  'Q2: another workspace shows the "moved" screen and switches NOTHING (no resync, no roster, no toast, no cover, no new tenant or role)'(h) {
    const m = h.mark();
    assert.equal(h.scope.requestRecheck(), true);
    h.users('t2', 'Beta Traders');
    h.member(active('staff'));
    assert.equal(h.scope.accessBlock, 'moved');
    assert.equal(h.scope.accessTenantName, 'Beta Traders', 'the screen names the NEW workspace');
    assert.equal(h.AuthStore.tenantId, 't1', 'stores keep the workspace the open forms belong to');
    assert.equal(h.AuthStore.role, 'owner');
    assert.equal(h.AuthStore.tenantName, 'Al Shop');
    nothingApplied(h);
    assert.equal(h.falseWrites(m), 0, 'no sign-in cover');
    assert.equal(h.scope.checking, false);
    assert.equal(h.scope.profileResolved, true);
    assert.equal(h.scope._contextSynced, true, 'the stores are still synced for the old workspace');
    assert.equal(h.pendingCount(), 0);
  },

  'Q2: the moved screen never names the old shop when the users doc carries no workspace name'(h) {
    assert.equal(h.scope.requestRecheck(), true);
    h.users('t2', '');
    h.member(active('owner'));
    assert.equal(h.scope.accessBlock, 'moved');
    assert.equal(h.scope.accessTenantName, '', 'empty, so the screen says "a different shop"');
    assert.notEqual(h.scope.accessTenantName, 'Al Shop');
  },

  'Q2: a role change together with a workspace change is a workspace change (moved, no toast)'(h) {
    silentWith(h, 't2', (y) => y.member(active('staff')));
    assert.equal(h.scope.accessBlock, 'moved');
    assert.deepEqual(h.calls.roleChanged, []);
  },

  'Q2: every role in the old workspace and every role in the new one ends on the moved screen'(h, make) {
    for (const from of ROLES) for (const to of ROLES) {
      const x = make({ store: { role: from } });
      silentWith(x, 't2', (y) => y.member(active(to)));
      assert.equal(x.scope.accessBlock, 'moved', `${from} -> ${to}`);
      assert.equal(x.AuthStore.role, from, `${from} -> ${to}: the held role is not rewritten`);
      nothingApplied(x);
    }
  },

  'Q2: Continue (a full load) opens the new workspace once: stores sync once, the screen clears, no role toast'(h) {
    silentWith(h, 't2', (y) => y.member(active('staff')));
    assert.equal(h.scope.accessBlock, 'moved');
    h.scope.recheckAccess();
    assert.equal(h.scope.accessBlock, 'moved', 'the screen stays up while the full load is out');
    h.users('t2', 'Beta Traders');
    h.member(active('staff'));
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.AuthStore.tenantId, 't2');
    assert.equal(h.AuthStore.role, 'staff');
    assert.equal(h.AuthStore.tenantName, 'Beta Traders');
    assert.deepEqual(h.calls.tenantContextReady.map((c) => [c.t, c.r]), [['t2', 'staff']]);
    assert.equal(h.calls.tenantContextReady[0].blockAtEmit, '', 'the screen is already down when the stores sync');
    assert.deepEqual(h.calls.roleChanged, []);
    assert.equal(h.rosterReads(), 1);
  },

  'Q2: Continue that cannot read keeps the moved screen exactly as it was (and the name it shows), a flaky network never switches silently'(h) {
    assert.equal(h.scope.requestRecheck(), true);
    h.users('t2', 'Beta Traders');
    h.member(active('staff'));
    assert.equal(h.scope.accessTenantName, 'Beta Traders');
    for (const status of [0, 401, 403, 500, 503]) {
      h.scope.recheckAccess();
      h.users('t2', '');
      h.memberFails(status);
      assert.equal(h.scope.accessBlock, 'moved', `member status ${status}`);
      assert.equal(h.AuthStore.tenantId, 't1');
      assert.equal(h.scope.accessTenantName, 'Beta Traders', 'neither the old shop nor an empty name replaces it');
    }
    h.scope.recheckAccess();
    h.usersFails(500);
    assert.equal(h.scope.accessBlock, 'moved', 'an unreadable users doc keeps it too');
    assert.equal(h.scope.accessTenantName, 'Beta Traders');
    assert.equal(h.AuthStore.tenantId, 't1');
    assert.equal(h.calls.tenantContextReady.length, 0);
  },

  'Q2: Continue offline does nothing (the moved screen stays, no read goes out)'(h) {
    silentWith(h, 't2', (y) => y.member(active('staff')));
    h.scope.isOnline = false;
    h.scope.recheckAccess();
    assert.equal(h.scope.accessBlock, 'moved');
    assert.equal(h.pendingCount(), 0);
  },

  'Q2: while moved, the next silent check that lets the member in opens like a fresh sign-in (once), the screen clears'(h) {
    silentWith(h, 't2', (y) => y.member(active('staff')));
    h.tick(61000);
    silentWith(h, 't2', (y) => y.member(active('staff')));
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.AuthStore.tenantId, 't2');
    assert.deepEqual(h.calls.tenantContextReady.map((c) => [c.t, c.r]), [['t2', 'staff']]);
    assert.deepEqual(h.calls.roleChanged, []);
  },

  'Q2: while moved, the server moves the account back: the silent check still opens the old workspace like a fresh sign-in'(h) {
    silentWith(h, 't2', (y) => y.member(active('owner')));
    h.tick(61000);
    silentWith(h, 't1', (y) => y.member(active('owner')));
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.AuthStore.tenantId, 't1');
    assert.equal(h.calls.tenantContextReady.length, 1, 'unblock resyncs once even though nothing changed');
  },

  'Q2: while moved, a refusal in the new workspace replaces the screen and names that workspace, never the old shop'(h, make) {
    const answers = { suspended: (y) => y.member({ status: 'suspended', role: 'staff' }), removed: (y) => y.memberGone(), role: (y) => y.member({ status: 'active', role: 'viewer' }) };
    for (const [reason, answer] of Object.entries(answers)) {
      const x = make({});
      silentWith(x, 't2', (y) => y.member(active('staff')));
      x.tick(61000);
      assert.equal(x.scope.requestRecheck(), true);
      x.users('t2', '');
      answer(x);
      assert.equal(x.scope.accessBlock, reason);
      assert.equal(x.scope.accessTenantName, '', `${reason}: the new workspace has no name here, so none is shown (not "Al Shop")`);
    }
  },

  'Q2: the moved answer is a decision, so it keeps the 60 s window (a storm of resumes cannot re-run it)'(h) {
    silentWith(h, 't2', (y) => y.member(active('staff')));
    assert.equal(h.scope.requestRecheck(), false, 'inside the window');
    h.tick(59999);
    assert.equal(h.scope.requestRecheck(), false);
    h.tick(1);
    assert.equal(h.scope.requestRecheck(), true);
  },

  'Q2: only an open, synced session can be moved: at the first resolve the other workspace just opens (nothing is open to protect)'(h, make) {
    const x = make({ state: { _contextSynced: false } });
    silentWith(x, 't2', (y) => y.member(active('staff')));
    assert.equal(x.scope.accessBlock, '');
    assert.equal(x.AuthStore.tenantId, 't2');
    assert.deepEqual(x.calls.tenantContextReady.map((c) => [c.t, c.r]), [['t2', 'staff']]);
    assert.deepEqual(x.calls.roleChanged, []);
  },

  'Q2: a refusal for another workspace is a plain refusal (no moved screen), and the name is the new workspace'(h) {
    silentWith(h, 't2', (y) => y.member({ status: 'suspended', role: 'staff' }));
    assert.equal(h.scope.accessBlock, 'suspended');
    assert.equal(h.scope.accessTenantName, 'Al Shop', 'the users doc named it');
    assert.equal(h.AuthStore.tenantId, 't1');
  },

  'Q2: a workspace named by nobody never inherits the old name on a refusal for another workspace'(h) {
    assert.equal(h.scope.requestRecheck(), true);
    h.users('t2', '');
    h.member({ status: 'suspended', role: 'staff' });
    assert.equal(h.scope.accessBlock, 'suspended');
    assert.equal(h.scope.accessTenantName, '');
  },

  'Q2: a refusal for the SAME workspace with no name on the users doc still names the shop this device holds'(h) {
    assert.equal(h.scope.requestRecheck(), true);
    h.users('t1', '');
    h.member({ status: 'suspended', role: 'owner' });
    assert.equal(h.scope.accessBlock, 'suspended');
    assert.equal(h.scope.accessTenantName, 'Al Shop');
  },

  'Q2: sign-out while the moved screen is up clears it (the next account starts clean)'(h) {
    silentWith(h, 't2', (y) => y.member(active('staff')));
    h.scope.signOut();
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.scope._contextSynced, false);
  },

  'refused silent check (suspended / removed / invalid role) shows the access screen without touching the cover or the app state'(h, make) {
    const answers = { suspended: (y) => y.member({ status: 'suspended', role: 'owner' }), removed: (y) => y.memberGone(), role: (y) => y.member({ status: 'active', role: 'viewer' }) };
    for (const [reason, answer] of Object.entries(answers)) {
      const x = make({});
      const m = x.mark();
      silentWith(x, 't1', answer);
      assert.equal(x.scope.accessBlock, reason);
      assert.equal(x.scope.accessTenantName, 'Al Shop');
      assert.equal(x.falseWrites(m), 0, reason);
      assert.equal(x.AuthStore.role, 'owner', 'the held role is not rewritten by a refusal');
      assert.equal(x.calls.tenantContextReady.length, 0, reason);
      assert.equal(x.calls.applyTenantContext.length, 0, reason);
      assert.equal(x.scope.checking, false, reason);
    }
  },

  'an unreadable member answer never blocks or changes a verified member (0, 401, 403, 500, 503)'(h, make) {
    for (const status of [0, 401, 403, 500, 503]) {
      const x = make({});
      silentWith(x, 't1', (y) => y.memberFails(status));
      assert.equal(x.scope.accessBlock, '', `status ${status}`);
      nothingApplied(x);
      assert.equal(x.scope.checking, false);
      assert.equal(x.scope.profileResolved, true);
    }
  },

  'Q1: an unreadable member answer for a DIFFERENT workspace is ignored by a silent check (no block, nothing applied) and frees the 60 s window'(h, make) {
    for (const status of [0, 401, 403, 500, 503]) {
      const x = make({});
      const m = x.mark();
      silentWith(x, 't2', (y) => y.memberFails(status));
      assert.equal(x.scope.accessBlock, '', `status ${status}`);
      assert.equal(x.AuthStore.tenantId, 't1', 'the device still holds the verified workspace');
      assert.equal(x.AuthStore.role, 'owner');
      nothingApplied(x);
      assert.equal(x.falseWrites(m), 0);
      assert.equal(x.scope.checking, false);
      assert.equal(x.scope.requestRecheck(), true, 'an answer that decided nothing does not use up the window');
    }
  },

  'Q1: a junk member body for a different workspace is ignored too (string, array, null, empty object)'(h, make) {
    for (const body of ['junk', [], null, 5]) {
      const x = make({});
      silentWith(x, 't2', (y) => y.answer(MEMBER_DOC, true, body, 200));
      assert.equal(x.scope.accessBlock, '', JSON.stringify(body));
      nothingApplied(x);
    }
  },

  'Q1: the ignore is only for unreadable answers: a refusal for a different workspace still shows the screen'(h, make) {
    const answers = { suspended: (y) => y.member({ status: 'suspended', role: 'staff' }), removed: (y) => y.memberGone(), role: (y) => y.member({ status: 'active', role: 'viewer' }) };
    for (const [reason, answer] of Object.entries(answers)) {
      const x = make({});
      silentWith(x, 't2', answer);
      assert.equal(x.scope.accessBlock, reason);
    }
  },

  'Q1: before the first sync an unreadable answer for another workspace is ignored too and does not mark the stores synced; the next verified one opens it once'(h, make) {
    const x = make({ state: { _contextSynced: false } });
    silentWith(x, 't2', (y) => y.memberFails(500));
    assert.equal(x.scope.accessBlock, '');
    nothingApplied(x);
    assert.equal(x.scope._contextSynced, false);
    x.tick(1000);
    silentWith(x, 't2', (y) => y.member(active('staff')));
    assert.equal(x.AuthStore.tenantId, 't2');
    assert.deepEqual(x.calls.tenantContextReady.map((c) => [c.t, c.r]), [['t2', 'staff']]);
    assert.equal(x.scope._contextSynced, true);
  },

  'Q1: a FULL load (Try again, sign-in) still blocks "unverified" when nothing was verified for the workspace it found'(h) {
    h.scope.recheckAccess();
    h.users('t2');
    h.memberFails(500);
    assert.equal(h.scope.accessBlock, 'unverified');
    assert.equal(h.AuthStore.tenantId, 't1');
  },

  'Q1: an unverified screen that is already showing is kept by a silent check that cannot read (never cleared, never changed)'(h) {
    const x = h;
    x.scope.recheckAccess();
    x.users('t2');
    x.memberFails(500);
    assert.equal(x.scope.accessBlock, 'unverified');
    x.tick(61000);
    const m = x.mark();
    silentWith(x, 't2', (y) => y.memberFails(500));
    assert.equal(x.scope.accessBlock, 'unverified');
    assert.equal(x.writes.slice(m).filter((w) => w[0] === 'accessBlock' && w[1] === '').length, 0, 'never written to ""');
  },

  'an unreadable users doc never blocks or changes a verified member'(h, make) {
    for (const status of [0, 401, 500, 503]) {
      const x = make({});
      assert.equal(x.scope.requestRecheck(), true);
      x.usersFails(status);
      assert.equal(x.scope.accessBlock, '', `status ${status}`);
      nothingApplied(x);
      assert.equal(x.scope.checking, false);
      assert.equal(x.pendingCount(), 0, 'no member read follows an unreadable users doc');
    }
  },

  'E2: a users doc that vanishes while the app is open never offers "Create your workspace"'(h) {
    const m = h.mark();
    assert.equal(h.scope.requestRecheck(), true);
    h.usersGone();
    assert.equal(h.scope.onboardingNeeded, false);
    assert.equal(h.scope.profileResolved, true);
    assert.equal(h.scope.checking, false);
    assert.equal(h.falseWrites(m), 0);
    nothingApplied(h);
  },

  'a users doc without a workspace never offers onboarding to an open session'(h) {
    assert.equal(h.scope.requestRecheck(), true);
    h.usersNoTenant();
    assert.equal(h.scope.onboardingNeeded, false);
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.scope.checking, false);
    nothingApplied(h);
  },

  'a junk member body (string, array, null) is unreadable, not a refusal'(h, make) {
    for (const body of ['x', [], null, 7]) {
      const x = make({});
      assert.equal(x.scope.requestRecheck(), true);
      x.users('t1');
      x.answer(MEMBER_DOC, true, body, 200);
      assert.equal(x.scope.accessBlock, '');
      nothingApplied(x);
    }
  },

  'blocked then reinstated: a silent check opens the app like a fresh sign-in (once)'(h, make) {
    const x = make({ state: { accessBlock: 'suspended', accessTenantName: 'Al Shop' }, store: { role: 'staff' } });
    const m = x.mark();
    silentWith(x, 't1', (y) => y.member(active('staff')));
    assert.equal(x.scope.accessBlock, '');
    assert.deepEqual(x.calls.tenantContextReady.map((c) => c.r), ['staff'], 'unblocking resyncs even though tenant and role are unchanged');
    assert.equal(x.falseWrites(m), 0);
    assert.deepEqual(x.calls.roleChanged, [], 'no role toast for an unblock');
  },

  'blocked and still suspended: the screen is never cleared, even for an instant'(h, make) {
    const x = make({ state: { accessBlock: 'suspended', accessTenantName: 'Al Shop' } });
    const m = x.mark();
    silentWith(x, 't1', (y) => y.member({ status: 'suspended', role: 'owner' }));
    assert.equal(x.scope.accessBlock, 'suspended');
    assert.equal(x.writes.slice(m).filter((w) => w[0] === 'accessBlock' && w[1] === '').length, 0, 'never written to ""');
    assert.equal(x.falseWrites(m), 0);
    nothingApplied(x);
  },

  'blocked: the reason follows the latest definitive answer (suspended -> removed)'(h, make) {
    const x = make({ state: { accessBlock: 'suspended', accessTenantName: 'Al Shop' } });
    silentWith(x, 't1', (y) => y.memberGone());
    assert.equal(x.scope.accessBlock, 'removed');
  },

  'blocked and the check could not read: the block stays exactly as it was (a flaky network never lets a suspended member back in)'(h, make) {
    for (const reason of ['suspended', 'removed', 'role', 'unverified']) {
      const x = make({ state: { accessBlock: reason, accessTenantName: 'Al Shop' } });
      silentWith(x, 't1', (y) => y.memberFails(500));
      assert.equal(x.scope.accessBlock, reason);
      nothingApplied(x);
    }
  },

  'offline: nothing is asked, nothing changes'(h) {
    h.scope.isOnline = false;
    assert.equal(h.scope.requestRecheck(), false);
    h.scope.onAppResumed();
    assert.equal(h.calls.get.length, 0);
    assert.equal(h.calls.post, 0);
    assert.equal(h.scope.checking, false);
  },

  'a session that is not open is never re-checked silently (profile loading, onboarding, no workspace, signed out)'(h, make) {
    const cases = [{ state: { profileResolved: false } }, { state: { onboardingNeeded: true } }, { store: { tenantId: '' } }, { store: { isAuthenticated: false } }];
    for (const c of cases) {
      const x = make(c);
      assert.equal(x.scope.requestRecheck(), false, JSON.stringify(c));
      assert.equal(x.calls.get.length, 0, JSON.stringify(c));
      assert.equal(x.scope.checking, false);
    }
  },

  'D2a throttle: one in flight, 60 s apart, a dropped trigger is not queued'(h) {
    assert.equal(h.scope.requestRecheck(), true);
    assert.equal(h.scope.requestRecheck(), false, 'second while the first is out');
    h.users('t1'); h.member(active('owner'));
    assert.equal(h.scope.requestRecheck(), false, 'answered but inside the window');
    h.tick(59999);
    assert.equal(h.scope.requestRecheck(), false, '1 ms short');
    h.tick(1);
    assert.equal(h.scope.requestRecheck(), true, 'exactly 60 s runs');
    assert.equal(h.usersReads(), 2, 'the dropped triggers did not queue a check behind them');
    h.users('t1'); h.member(active('owner'));
    assert.equal(h.pendingCount(), 0);
    assert.equal(h.usersReads(), 2);
  },

  'a check that never answers is replaced after 120 s and the lost one cannot apply late (no read has a timeout)'(h) {
    assert.equal(h.scope.requestRecheck(), true);   // the lost check: its users read is never answered in time
    h.tick(119999);
    assert.equal(h.scope.requestRecheck(), false);
    assert.equal(h.scope.checking, true);
    h.tick(1);
    assert.equal(h.scope.requestRecheck(), true, 'a lost check does not stop checks for good');
    // the lost one finally answers with an old, refusing answer; the newer check says active
    h.answerAt(0, true, { tenantId: 't1', tenantName: 'Al Shop' }, 200);
    assert.equal(h.pendingCount(), 1, 'the stale answer started nothing');
    h.users('t1');
    h.member(active('owner'));
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.scope.checking, false);
  },

  'Try again supersedes a silent check in flight; the late silent answer is dropped'(h) {
    assert.equal(h.scope.requestRecheck(), true);
    h.tick(5000);
    h.scope.recheckAccess();
    assert.equal(h.scope.checking, false, 'the full load owns the screen now');
    assert.equal(h.scope.profileResolved, false);
    h.users('t1');                                  // the OLD silent users read answers: ignored
    assert.equal(h.pendingCount(), 1, 'only the new load is waiting');
    h.users('t1');
    h.member(active('owner'));
    assert.equal(h.scope.profileResolved, true);
    assert.deepEqual(h.calls.tenantContextReady.map((c) => c.r), ['owner'], 'a full load always opens: the first resolve is never "no change"');
  },

  'Try again counts as the latest check for the 60 s spacing'(h) {
    h.scope.recheckAccess();
    h.users('t1'); h.member(active('owner'));
    h.tick(59999);
    assert.equal(h.scope.requestRecheck(), false);
    h.tick(1);
    assert.equal(h.scope.requestRecheck(), true);
  },

  'Try again offline does nothing and does not start the spacing window'(h) {
    h.scope.isOnline = false;
    h.scope.recheckAccess();
    assert.equal(h.calls.get.length, 0);
    h.scope.isOnline = true;
    assert.equal(h.scope.requestRecheck(), true, 'an offline tap did not burn the window');
  },

  'sign-out mid check: the check is forgotten, checking clears, a late answer cannot revive the session'(h, make) {
    assert.equal(h.scope.requestRecheck(), true);
    h.scope.signOut();
    assert.equal(h.scope.checking, false);
    h.users('t1');
    assert.equal(h.pendingCount(), 0, 'the stale answer started no member read');
    assert.equal(h.AuthStore.tenantId, '');
    nothingApplied(h);
    // second phase: the member read is already out when the user signs out
    const x = make({});
    assert.equal(x.scope.requestRecheck(), true);
    x.users('t1');
    x.scope.signOut();
    x.member(active('owner'));
    assert.equal(x.AuthStore.tenantId, '');
    assert.equal(x.scope.accessBlock, '');
    nothingApplied(x);
  },

  'resume: 50 resumes inside 60 s start exactly one check; the next window starts one more'(h) {
    for (let i = 0; i < 50; i++) { h.scope.onAppResumed(); h.tick(1000); }
    assert.equal(h.usersReads(), 1);
    h.users('t1'); h.member(active('owner'));
    h.tick(10000);                                  // exactly 60 s after the first resume (50 x 1 s + 10 s)
    h.scope.onAppResumed();
    assert.equal(h.usersReads(), 2);
  },

  'resume with a token near expiry refreshes first; the refresh success runs the check silently (once)'(h) {
    h.AuthStore.expiresAtEpochSec = Math.floor(h.clock.t / 1000) + 60;
    const m = h.mark();
    h.scope.onAppResumed();
    assert.equal(h.calls.post, 1);
    assert.equal(h.usersReads(), 0, 'no read is sent with an expiring token');
    h.answer('POST', true, { expires_in: '3600', id_token: 'new', refresh_token: 'rt', user_id: 'u1' });
    assert.equal(h.calls.tokenRefreshed, 1);
    assert.equal(h.usersReads(), 1);
    assert.equal(h.scope.checking, true, 'the check after the refresh is the silent one');
    h.users('t1'); h.member(active('owner'));
    assert.equal(h.falseWrites(m), 0, 'no sign-in cover');
    nothingApplied(h);
  },

  'resume while offline or signed out does nothing and does not burn the window'(h, make) {
    h.scope.isOnline = false;
    h.scope.onAppResumed();
    h.scope.isOnline = true;
    h.scope.onAppResumed();
    assert.equal(h.usersReads(), 1, 'the offline resume did not consume the window');
    const x = make({ store: { isAuthenticated: false } });
    x.scope.onAppResumed();
    assert.equal(x.calls.get.length + x.calls.post, 0);
  },

  'a token refresh while open is silent; a refresh landing during a resume check adds no second check'(h) {
    h.scope.onAppResumed();
    assert.equal(h.usersReads(), 1);
    h.scope.refreshIdToken();
    h.answer('POST', true, { expires_in: '3600', id_token: 'new', refresh_token: 'rt', user_id: 'u1' });
    assert.equal(h.usersReads(), 1, 'one check, not two');
    assert.equal(h.falseWrites(), 0);
  },

  'a token refresh on a session that is not open (cold start) is a full load that always opens'(h) {
    const x = h;
    x.own.profileResolved = false;
    x.AuthStore.isAuthenticated = false;
    x.AuthStore.idToken = '';
    x.scope.refreshIdToken();
    x.answer('POST', true, { expires_in: '3600', id_token: 'new', refresh_token: 'rt', user_id: 'u1' });
    assert.equal(x.scope.profileResolved, false, 'cold start keeps the sign-in cover until the profile resolves');
    x.users('t1'); x.member(active('owner'));
    assert.equal(x.scope.profileResolved, true);
    assert.deepEqual(x.calls.tenantContextReady.map((c) => c.r), ['owner'], 'the saved session already held t1/owner, yet the stores must sync once');
  },

  'a refresh answer that lands after sign-out is dropped (it must not revive the old user)'(h) {
    h.scope.refreshIdToken();
    h.scope.signOut();
    h.answer('POST', true, { expires_in: '3600', id_token: 'new', refresh_token: 'rt2', user_id: 'u1' });
    assert.equal(h.AuthStore.isAuthenticated, false);
    assert.equal(h.calls.tokenRefreshed, 0);
    assert.equal(h.usersReads(), 0);
    assert.equal(h.calls.applyAuth.filter((a) => a && a.idToken).length, 0);
  },

  'a refresh answer that lands after ANOTHER account signed in is dropped'(h) {
    h.scope.refreshIdToken();
    h.AuthStore.refreshToken = 'other-account-rt';
    h.answer('POST', true, { expires_in: '3600', id_token: 'old-account-token', refresh_token: 'rt', user_id: 'u1' });
    assert.equal(h.AuthStore.idToken, 'tok');
    assert.equal(h.calls.tokenRefreshed, 0);
  },

  'a refresh that fails still reports (and still only while it is the current session)'(h) {
    h.scope.refreshIdToken();
    h.answer('POST', false, null, 400);
    assert.deepEqual(h.calls.authFailed, ['refresh failed']);
    const x = h;
    x.scope.refreshIdToken();
    x.scope.signOut();
    x.answer('POST', false, null, 400);
    assert.equal(x.calls.authFailed.length, 1, 'a failure for a gone session is not reported');
  },

  'first resolve, real cold-start order (offline resolve, then online): the first silent check syncs the stores once'(h) {
    const x = h;
    x.own.isOnline = false; x.own._contextSynced = false; x.own.profileResolved = false;
    x.scope._loadUserProfile();                       // init() runs before Main.qml has set isOnline
    assert.equal(x.scope.profileResolved, true, 'offline resolves the cover');
    assert.equal(x.calls.get.length, 0);
    x.scope.isOnline = true;
    x.scope._recheckOrLoad();                         // what onIsOnlineChanged does when profileResolved
    assert.equal(x.scope.checking, true, 'a silent check: the cover is already down');
    x.users('t1'); x.member(active('owner'));         // the answer equals the saved tenant and role
    assert.deepEqual(x.calls.tenantContextReady.map((c) => c.r), ['owner'], 'the stores still sync, exactly once');
    assert.equal(x.rosterReads(), 1);
    assert.equal(x.scope._contextSynced, true);
    assert.deepEqual(x.calls.roleChanged, []);
    x.tick(60000);
    assert.equal(x.scope.requestRecheck(), true);
    x.users('t1'); x.member(active('owner'));
    assert.equal(x.calls.tenantContextReady.length, 1, 'and the next unchanged check emits nothing');
  },

  'first resolve via a refresh token only (no saved id token): the refresh success runs a check that syncs the stores'(h) {
    h.own._contextSynced = false;
    h.AuthStore.isAuthenticated = false; h.AuthStore.idToken = '';
    h.scope.refreshIdToken();
    h.answer('POST', true, { expires_in: '3600', id_token: 'new', refresh_token: 'rt', user_id: 'u1' });
    h.users('t1'); h.member(active('owner'));
    assert.deepEqual(h.calls.tenantContextReady.map((c) => c.r), ['owner']);
  },

  'first resolve with an unreadable answer still syncs with the role this device already verified'(h, make) {
    const a = make({ state: { _contextSynced: false } });
    silentWith(a, 't1', (y) => y.memberFails(500));
    assert.deepEqual(a.calls.tenantContextReady.map((c) => c.r), ['owner']);
    assert.equal(a.scope.accessBlock, '');
    const b = make({ state: { _contextSynced: false } });
    assert.equal(b.scope.requestRecheck(), true);
    b.usersFails(500);
    assert.deepEqual(b.calls.tenantContextReady.map((c) => c.r), ['owner'], 'an unreadable users doc decides the same way');
  },

  'first resolve that is refused blocks and stays "not synced"; the later let-in then syncs'(h) {
    h.own._contextSynced = false;
    silentWith(h, 't1', (y) => y.member({ status: 'suspended', role: 'owner' }));
    assert.equal(h.scope.accessBlock, 'suspended');
    assert.equal(h.scope._contextSynced, false);
    assert.equal(h.calls.tenantContextReady.length, 0);
    h.tick(60000);
    silentWith(h, 't1', (y) => y.member(active('owner')));
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.calls.tenantContextReady.length, 1);
    assert.equal(h.scope._contextSynced, true);
  },

  'first resolve is not announced as a role change even when the saved role is out of date'(h) {
    const x = h;
    x.own._contextSynced = false; x.AuthStore.role = 'admin';
    silentWith(x, 't1', (y) => y.member(active('staff')));
    assert.equal(x.AuthStore.role, 'staff');
    assert.deepEqual(x.calls.tenantContextReady.map((c) => c.r), ['staff']);
    assert.deepEqual(x.calls.roleChanged, [], 'no toast on first resolve');
  },

  'sign-out forgets that the stores were synced, so the next sign-in syncs again'(h) {
    assert.equal(h.scope._contextSynced, true);
    h.scope.signOut();
    assert.equal(h.scope._contextSynced, false);
  },

  'regression: Try again with nothing changed still emits tenantContextReady (a full load is never silent)'(h) {
    h.scope.recheckAccess();
    assert.equal(h.scope.profileResolved, false);
    h.users('t1'); h.member(active('owner'));
    assert.equal(h.calls.tenantContextReady.length, 1);
    assert.equal(h.calls.get.includes('tenants/t1/members'), true, 'and the roster is loaded');
  },

  'regression: _recheckOrLoad on an open session is silent, on a session still loading it is a full load'(h, make) {
    h.scope._recheckOrLoad();
    assert.equal(h.scope.checking, true);
    assert.equal(h.scope.profileResolved, true);
    const x = make({ state: { profileResolved: false } });
    x.scope._recheckOrLoad();
    assert.equal(x.scope.checking, false);
    assert.equal(x.scope.profileResolved, false);
  },

  'a silent load that finds the phone offline clears checking and does not resolve anything'(h) {
    h.scope.isOnline = false;
    h.scope._loadUserProfile(true);
    assert.equal(h.scope.checking, false);
    assert.equal(h.scope.profileResolved, true);
    assert.equal(h.calls.get.length, 0);
  },

  'a silent load with no uid ends without onboarding'(h) {
    h.AuthStore.uid = '';
    h.scope._loadUserProfile(true);
    assert.equal(h.scope.checking, false);
    assert.equal(h.scope.onboardingNeeded, false);
    assert.equal(h.calls.onboardingRequired, 0);
  },

  'the full (non-silent) load is untouched: flips the cover, clears onboarding, offline resolves'(h, make) {
    h.scope._loadUserProfile();
    assert.equal(h.scope.profileResolved, false);
    assert.equal(h.scope.checking, false);
    const x = make({});
    x.scope.isOnline = false;
    x.scope._loadUserProfile();
    assert.equal(x.scope.profileResolved, true);
    const y = make({ store: { uid: '' } });
    y.scope._loadUserProfile();
    assert.equal(y.scope.onboardingNeeded, true);
    assert.equal(y.calls.onboardingRequired, 1);
  },

  // ---- PR #180 review sweep (2026-11-01) ---------------------------------------------------------------
  'Q3: ensureFreshToken refreshes only a signed-in session whose token is near expiry (once per call)'(h, make) {
    const out = make({ store: { isAuthenticated: false, expiresAtEpochSec: Math.floor(T0 / 1000) + 60 } });
    out.scope.ensureFreshToken();
    assert.equal(out.calls.post, 0, 'signed out: nothing sent');
    const fresh = make({});
    fresh.scope.ensureFreshToken();
    assert.equal(fresh.calls.post, 0, 'a token with an hour left is not refreshed');
    for (const secs of [299, 300, 1, 0, -3600]) {
      const x = make({ store: { expiresAtEpochSec: Math.floor(T0 / 1000) + secs } });
      x.scope.ensureFreshToken();
      assert.equal(x.calls.post, secs <= 300 ? 1 : 0, `${secs} s left`);
    }
    const edge = make({ store: { expiresAtEpochSec: Math.floor(T0 / 1000) + 301 } });
    edge.scope.ensureFreshToken();
    assert.equal(edge.calls.post, 0, '301 s left is outside the 5 minute margin');
  },

  'Q3: a failed ensureFreshToken refresh is silent (no authFailed into an open dialog), whatever the failure'(h, make) {
    for (const status of [0, 400, 401, 500, 503]) {
      const x = make({ store: { expiresAtEpochSec: Math.floor(T0 / 1000) + 60 } });
      x.scope.ensureFreshToken();
      assert.equal(x.calls.post, 1);
      x.answer('POST token', false, null, status);
      assert.deepEqual(x.calls.authFailed, [], `status ${status}`);
      assert.equal(x.calls.tokenRefreshed, 0);
      assert.equal(x.pendingCount(), 0);
    }
  },

  'Q3: ensureFreshToken with no refresh token fails silently too (nothing sent, no authFailed)'(h, make) {
    const x = make({ store: { refreshToken: '', expiresAtEpochSec: Math.floor(T0 / 1000) + 60 } });
    x.scope.ensureFreshToken();
    assert.equal(x.calls.post, 0);
    assert.deepEqual(x.calls.authFailed, []);
  },

  'Q3: a good ensureFreshToken refresh still applies the new token, re-checks silently and announces tokenRefreshed'(h, make) {
    const x = make({ store: { expiresAtEpochSec: Math.floor(T0 / 1000) + 60 } });
    x.scope.ensureFreshToken();
    x.answer('POST token', true, { expires_in: '3600', id_token: 'new', refresh_token: 'rt2', user_id: 'u1' }, 200);
    assert.equal(x.AuthStore.idToken, 'new');
    assert.equal(x.AuthStore.refreshToken, 'rt2');
    assert.equal(x.calls.tokenRefreshed, 1);
    assert.deepEqual(x.calls.authFailed, []);
    assert.equal(x.pendingCount(), 1, 'one silent check went out');
    assert.equal(x.scope.checking, true);
  },

  'Q3: a late failure after sign-out or after another account signed in reports nothing'(h, make) {
    const x = make({ store: { expiresAtEpochSec: Math.floor(T0 / 1000) + 60 } });
    x.scope.ensureFreshToken();
    x.scope.signOut();
    x.answer('POST token', false, null, 400);
    assert.deepEqual(x.calls.authFailed, []);
    assert.equal(x.calls.tokenRefreshed, 0);
  },

  'Q3: the explicit refreshIdToken() (no argument) still reports a failure; only the silent callers hide it'(h, make) {
    const x = make({});
    x.scope.refreshIdToken();
    x.answer('POST token', false, null, 400);
    assert.deepEqual(x.calls.authFailed, ['refresh failed']);
    const y = make({ store: { refreshToken: '' } });
    y.scope.refreshIdToken();
    assert.deepEqual(y.calls.authFailed, ['Missing refresh token']);
  },

  'R180-1: an unreadable answer is not a check: it frees the 60 s window; a healthy answer or a refusal keeps it'(h, make) {
    assert.equal(h.scope.requestRecheck(), true);
    h.users('t1'); h.memberFails(401);
    assert.equal(h.scope.requestRecheck(), true, 'member doc unreadable (401): the window is free');
    h.users('t1'); h.memberFails(500);
    assert.equal(h.scope.requestRecheck(), true, 'member doc unreadable (500): the window is free');
    h.users('t1'); h.member('junk');                          // a body that is not a member doc is unreadable, not a refusal
    h.tick(60000);
    assert.equal(h.scope.requestRecheck(), true);
    h.usersFails(500);
    assert.equal(h.scope.requestRecheck(), true, 'users doc unreadable: the window is free');
    h.users('t1'); h.member(active('owner'));
    assert.equal(h.scope.requestRecheck(), false, 'a healthy answer keeps the window');
    assert.equal(h.scope.checking, false);
    const x = make({});
    assert.equal(x.scope.requestRecheck(), true);
    x.users('t1'); x.member({ status: 'suspended', role: 'owner' });
    assert.equal(x.scope.accessBlock, 'suspended');
    assert.equal(x.scope.requestRecheck(), false, 'a refusal is a real answer: it keeps the window');
  },

  'R180-2: expired-token 401, then the refresh lands seconds later: the refresh success runs the check at once'(h) {
    assert.equal(h.scope.requestRecheck(), true);            // a reconnect check goes out with the expired token
    h.usersFails(401);
    h.tick(2000);
    h.AuthStore.expiresAtEpochSec = Math.floor(h.clock.t / 1000) + 60;
    h.scope.onAppResumed();                                   // the resume refreshes first
    assert.equal(h.calls.post, 1);
    h.answer('POST', true, { expires_in: '3600', id_token: 'new', refresh_token: 'rt', user_id: 'u1' });
    assert.equal(h.usersReads(), 2, 'the check after the refresh is not dropped by the 401 one');
    assert.equal(h.scope.checking, true);
    h.users('t1'); h.member(active('admin'));
    assert.deepEqual(h.calls.roleChanged, ['admin'], 'the access change is seen');
  },

  'R180-3: first resolve with an unreadable answer opens the app but is not "synced": the next definitive answer syncs once, no toast'(h, make) {
    const a = make({ state: { _contextSynced: false } });
    silentWith(a, 't1', (y) => y.memberFails(500));
    assert.deepEqual(a.calls.tenantContextReady.map((c) => c.r), ['owner']);
    assert.equal(a.scope._contextSynced, false, 'an unreadable answer does not count as synced');
    a.tick(60000);
    silentWith(a, 't1', (y) => y.member(active('owner')));
    assert.equal(a.calls.tenantContextReady.length, 2, 'the first definitive answer syncs the stores again');
    assert.equal(a.scope._contextSynced, true);
    assert.deepEqual(a.calls.roleChanged, [], 'not announced as a role change');
    a.tick(60000);
    silentWith(a, 't1', (y) => y.member(active('owner')));
    assert.equal(a.calls.tenantContextReady.length, 2, 'and then an unchanged answer touches nothing');
    const b = make({ state: { _contextSynced: false } });    // still unreadable: each check may retry, none marks synced
    for (let i = 0; i < 3; i++) { silentWith(b, 't1', (y) => y.memberFails(503)); b.tick(60000); }
    assert.equal(b.calls.tenantContextReady.length, 3);
    assert.equal(b.scope._contextSynced, false);
  },

  'R180-4: a full load with an unreadable answer opens the app but does not mark synced; a verified one marks it and an unreadable one never un-marks it'(h, make) {
    const b = make({ state: { _contextSynced: false } });
    b.scope.recheckAccess(); b.usersFails(500);
    assert.deepEqual(b.calls.tenantContextReady.map((c) => c.r), ['owner']);
    assert.equal(b.scope._contextSynced, false);
    b.tick(60000);
    silentWith(b, 't1', (y) => y.member(active('owner')));
    assert.equal(b.calls.tenantContextReady.length, 2, 'the later definitive answer syncs');
    assert.equal(b.scope._contextSynced, true);
    const c = make({});                                       // synced already
    c.scope.recheckAccess(); c.usersFails(500);
    assert.equal(c.calls.tenantContextReady.length, 1, 'a full load always emits');
    assert.equal(c.scope._contextSynced, true, 'an unreadable answer never un-marks');
  },

  'R180-5: a refresh nobody asked for (resume) fails silently; a refresh somebody asked for still reports'(h, make) {
    h.AuthStore.expiresAtEpochSec = Math.floor(h.clock.t / 1000) + 60;
    h.scope.onAppResumed();
    assert.equal(h.calls.post, 1);
    h.answer('POST', false, null, 400);
    assert.deepEqual(h.calls.authFailed, [], 'no sign-in error pops up inside an open dialog');
    assert.equal(h.calls.tokenRefreshed, 0);
    assert.equal(h.usersReads(), 0, 'a failed refresh runs no check');
    const x = make({ store: { refreshToken: '', expiresAtEpochSec: Math.floor(T0 / 1000) + 60 } });
    x.scope.onAppResumed();
    assert.equal(x.calls.post, 0, 'nothing to send without a refresh token');
    assert.deepEqual(x.calls.authFailed, [], 'and nothing reported');
    const y = make({}); y.scope.refreshIdToken(); y.answer('POST', false, null, 400);
    assert.deepEqual(y.calls.authFailed, ['refresh failed'], 'an explicit refresh still reports a failure');
    const z = make({ store: { refreshToken: '' } }); z.scope.refreshIdToken();
    assert.deepEqual(z.calls.authFailed, ['Missing refresh token'], 'and a missing token');
    const w = make({}); w.scope.refreshIdToken(false); w.answer('POST', false, null, 400);
    assert.deepEqual(w.calls.authFailed, ['refresh failed'], 'only an explicit true silences it');
  },

  'R180-6: sign-out forgets the spacing windows of the account that left'(h) {
    h.scope.onAppResumed();                                   // opens the resume window and the check window
    assert.equal(h.usersReads(), 1);
    h.scope.signOut();
    Object.assign(h.AuthStore, { isAuthenticated: true, uid: 'u2', tenantId: 't1', role: 'owner', refreshToken: 'rt2', idToken: 'tok2' });
    h.scope.profileResolved = true;
    h.tick(1000);
    h.scope.onAppResumed();
    assert.equal(h.usersReads(), 2, 'the next account is not held back by the last one\'s windows');
    assert.equal(h.scope.checking, true);
  },
};

// ---------------------------------------------------------------------------------------------------------
// Seeded monkey: a random sequence of everything that can happen, checked step by step against a reference model
// written from the design (not from the code). Each step compares what the system started, what an answer changed
// and what it emitted with what the design says must happen.
// profile 'ws' (workspace profile) steers the monkey to workspace changes and unreadable member answers, the states of PR #180 Q1/Q2,
// which the default mix reaches only a handful of times.
function runMonkey(src, seed, steps, profile) {
  let s = seed;
  const rnd = () => { s = (s * 1664525 + 1013904223) % 4294967296; return s / 4294967296; };
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const h = makeHarness(src, {});
  const { AuthStore: A, scope: sc, calls, pending, clock } = h;
  const truth = { users: 'ok1', member: 'active:owner' };
  // Sessions must stay open long enough for the silent path to matter: mostly healthy answers, with the odd bad one.
  const USERS = profile === 'ws' ? ['ok1', 'ok1', 'ok1', 'ok2', 'ok2', 'ok2', '404', '500'] : ['ok1', 'ok1', 'ok1', 'ok1', 'ok1', 'ok1', 'ok1', 'ok1', 'ok2', 'ok2', 'ok2', '404', '500', 'notenant'];
  const MEMBERS = profile === 'ws' ? ['active:owner', 'active:owner', 'active:admin', 'active:staff', 'active:staff', 'active:manager', '500', '500', '500', 'junk', 'junk', 'suspended'] : ['active:owner', 'active:owner', 'active:admin', 'active:admin', 'active:manager', 'active:manager', 'active:staff', 'active:staff', 'suspended', 'removed', 'badrole', '500', 'junk'];
  let lastStart = 0, lastResume = 0;       // model's own clocks for the 60 s spacing and the resume spacing
  let synced = true;                       // model's own record of "the stores have synced for this sign-in" (the harness starts an open, synced session)
  const log = [];
  const stats = { silent: 0, full: 0, refresh: 0, stale: 0, answers: 0, moved: 0, ignored: 0 };

  const refCan = (inFlight, last, now) => (inFlight ? now - last >= 120000 : (now - last < 0 || now - last >= 60000));
  const sessionOpen = () => A.isAuthenticated && sc.profileResolved && !sc.onboardingNeeded && A.tenantId.length > 0;
  const inflight = () => pending.some((p) => p.silent && p.seq === sc._profileSeq && p.p !== 'POST token');
  const expiring = () => A.expiresAtEpochSec <= Math.floor(clock.t / 1000) + 300;
  const snap = () => ({ block: sc.accessBlock, tenant: A.tenantId, role: A.role, resolved: sc.profileResolved, onboarding: sc.onboardingNeeded, checking: sc.checking,
    emits: calls.tenantContextReady.length, toasts: calls.roleChanged.length, onbEmits: calls.onboardingRequired, roster: h.rosterReads(), users: h.usersReads(), posts: calls.post, refreshed: calls.tokenRefreshed });

  // What a trigger that reaches _recheckOrLoad should start, by the design (L3-D1c, D2a).
  function silentOrFull() {
    if (sessionOpen()) return silentTry();
    return 'full';
  }
  function silentTry() {
    if (!sc.isOnline || !sessionOpen()) return 'none';
    if (!refCan(inflight(), lastStart, clock.t)) return 'none';
    lastStart = clock.t;
    return 'silent';
  }

  const answerBody = {
    users: (u) => ({ ok1: [true, { tenantId: 't1', tenantName: 'Al Shop' }, 200], ok2: [true, { tenantId: 't2', tenantName: 'Al Shop' }, 200], 404: [false, null, 404], 500: [false, null, 500], notenant: [true, {}, 200] })[u],
    member: (m) => (m.startsWith('active:') ? [true, active(m.slice(7)), 200] : ({ suspended: [true, { status: 'suspended', role: 'staff' }, 200], removed: [false, null, 404], badrole: [true, { status: 'active', role: 'viewer' }, 200], 500: [false, null, 500], junk: [true, 'junk', 200] })[m]),
  };

  // The decision, from the design: only a conclusive answer changes the screen; an unreadable one keeps a showing block or lets a verified member stay.
  function decide(pre, X) {
    const m = truth.member;
    if (m.startsWith('active:')) return { a: 'enter', role: m.slice(7), v: true };
    if (m === 'suspended' || m === 'removed' || m === 'badrole') return { a: 'block', reason: m === 'badrole' ? 'role' : m };
    if (pre.block) return { a: 'block', reason: pre.block };
    const held = X === pre.tenant ? pre.role : '';
    return held ? { a: 'enter', role: held, v: false } : { a: 'block', reason: 'unverified' };
  }

  function expectAnswer(pend, pre) {
    const e = { ...pre, emits: 0, toasts: 0, onbEmits: 0, roster: 0, users: 0, posts: 0, refreshed: 0 };
    const silent = pend.silent;
    if (pend.p.startsWith('users/')) {
      const u = truth.users;
      if (u === 'ok1' || u === 'ok2') return e;                       // the member read follows
      if (silent) {
        e.checking = false;
        // only an unreadable users doc reaches the access decision; before the first sync it still opens the app with the held role
        if (u === '500' && !pre.block && !synced) { e.block = ''; e.emits = 1; e.roster = 1; e.unv = true; }
        else if (u === '500' && !pre.block) lastStart = 0;     // unreadable decided nothing: the 60 s window is free again
        return e;
      }
      e.resolved = true;
      if (u === '404' || u === 'notenant') {
        if (u === '404' && pre.block) return e;                       // a showing block is never offered onboarding (D13)
        if (u === 'notenant') e.block = '';                           // no workspace at all is definitive
        e.onboarding = true; e.onbEmits = 1; return e;
      }
      // 500: an unreadable users doc decides against the workspace this device holds
      if (pre.block) return e;
      if (pre.role) { e.block = ''; e.emits = 1; e.roster = 1; e.unv = true; return e; }
      e.block = 'unverified'; return e;
    }
    if (MEMBER_DOC.test(pend.p)) {
      const X = pend.p.split('/')[1];
      const d = decide(pre, X);
      if (silent) {
        e.checking = false;
        if (d.a === 'block') {
          // Q1: an unreadable answer for a workspace this device never verified is ignored by a silent check unless a block is already showing; it decided nothing, so the 60 s window is free again
          if (d.reason === 'unverified' && !pre.block) { lastStart = 0; stats.ignored++; return e; }
          e.block = d.reason; return e;
        }
        if (pre.block) { e.block = ''; e.tenant = X; e.role = d.role; e.emits = 1; e.roster = 1; return e; }
        if (!synced) { e.tenant = X; e.role = d.role; e.emits = 1; e.roster = 1; e.unv = !d.v; return e; }   // first resolve: always a change, never a toast; an unreadable answer does not count as synced
        // Q2: another workspace under an open, synced session: the "moved" screen, nothing is switched, resynced or announced
        if (X !== pre.tenant) { e.block = 'moved'; stats.moved++; return e; }
        if (d.role !== pre.role) { e.role = d.role; e.emits = 1; e.roster = 1; e.toasts = 1; return e; }
        if (!d.v) lastStart = 0;                                  // unreadable and nothing changed: the window is free again
        return e;
      }
      e.resolved = true; e.onboarding = false;
      if (d.a === 'block') { e.block = d.reason; return e; }
      e.block = ''; e.tenant = X; e.role = d.role; e.emits = 1; e.roster = 1; e.unv = !d.v; return e;
    }
    return e;
  }

  function check(label, pre, exp, expectStart) {
    const now = snap();
    const where = `seed ${seed} step ${log.length} ${label} ${JSON.stringify({ pre, exp, now })}`;
    for (const k of ['block', 'tenant', 'role', 'resolved', 'onboarding', 'checking']) assert.equal(now[k], exp[k], `${k}: ${where}`);
    for (const k of ['emits', 'toasts', 'onbEmits', 'roster', 'users', 'posts', 'refreshed']) assert.equal(now[k] - pre[k], exp[k] || 0, `${k} delta: ${where}`);
    assert.equal(sc.checking, inflight(), `checking tracks the silent check in flight: ${where}`);
    assert.equal(sc._contextSynced, synced, `the synced mark follows the last emission: ${where}`);
    if (expectStart !== 'full') assert.equal(h.falseWrites(h._m), 0, `only a full load may flip the cover: ${where}`);
  }

  const ACTIONS = profile === 'ws' ? [
    ['answer', 40], ['tick', 20], ['resume', 24], ['serverChange', 20], ['tryAgain', 3], ['offline', 1], ['online', 2],
    ['refresh', 3], ['expiryToggle', 1], ['signOut', 1], ['signIn', 2],
  ] : [
    ['answer', 34], ['tick', 18], ['resume', 16], ['serverChange', 12], ['tryAgain', 3], ['offline', 2], ['online', 3],
    ['refresh', 4], ['expiryToggle', 2], ['signOut', 1], ['signIn', 2],
  ];
  const total = ACTIONS.reduce((a, b) => a + b[1], 0);
  const choose = () => { let r = rnd() * total; for (const [n, w] of ACTIONS) { if ((r -= w) < 0) return n; } return 'tick'; };

  for (let i = 0; i < steps; i++) {
    const act = choose();
    log.push(act);
    const pre = snap();
    h._m = h.mark();
    let exp = { ...pre, emits: 0, toasts: 0, onbEmits: 0, roster: 0, users: 0, posts: 0, refreshed: 0 };
    let start = 'none';
    switch (act) {
      case 'tick': h.tick(rnd() < 0.3 ? 60000 + Math.floor(rnd() * 300000) : 1 + Math.floor(rnd() * 60000)); break;
      case 'serverChange': truth.users = pick(USERS); truth.member = pick(MEMBERS); break;
      case 'expiryToggle': A.expiresAtEpochSec = Math.floor(clock.t / 1000) + (rnd() < 0.5 ? 60 : 3600); break;
      case 'offline': sc.isOnline = false; break;
      case 'online': {
        if (sc.isOnline) break;
        sc.isOnline = true;
        // the onIsOnlineChanged handler: signed out -> init() (not modelled), else re-check when the profile is resolved
        if (A.isAuthenticated && sc.profileResolved) { start = silentOrFull(); sc._recheckOrLoad(); }
        break;
      }
      case 'resume': {
        // predictions are made BEFORE the system acts: they read the state the trigger saw
        if (A.isAuthenticated && sc.isOnline && refCan(false, lastResume, clock.t)) {
          lastResume = clock.t;
          if (expiring()) { exp.posts = 1; start = 'refresh'; } else start = silentTry();
        }
        sc.onAppResumed();
        break;
      }
      case 'refresh': {
        if (A.refreshToken) { exp.posts = 1; start = 'refresh'; }   // no refresh token: authFailed, nothing sent
        sc.refreshIdToken();
        break;
      }
      case 'tryAgain': {
        if (!A.isAuthenticated) break;
        if (sc.isOnline) { lastStart = clock.t; start = 'full'; }
        sc.recheckAccess();
        break;
      }
      case 'signOut': {
        if (!A.isAuthenticated) break;
        sc.signOut();
        synced = false;
        lastStart = 0; lastResume = 0;                   // the next account starts with no spacing window left by this one
        exp = { ...exp, block: '', tenant: '', role: '', resolved: true, onboarding: false, checking: false };
        break;
      }
      case 'signIn': {
        if (A.isAuthenticated || !sc.isOnline) break;
        Object.assign(A, { isAuthenticated: true, uid: 'u1', idToken: 'tok', refreshToken: 'rt', tenantId: 't1', tenantName: 'Al Shop', role: 'owner', expiresAtEpochSec: Math.floor(clock.t / 1000) + 3600 });
        sc.profileResolved = false; sc.onboardingNeeded = false;
        sc._loadUserProfile();
        start = 'full';
        exp.tenant = 't1'; exp.role = 'owner';          // the saved session is restored before the profile is read
        break;
      }
      case 'answer': {
        if (pending.length === 0) break;
        const idx = Math.floor(rnd() * pending.length);
        const pend = pending[idx];
        const stale = pend.p === 'POST token' ? A.refreshToken !== pend.rt : pend.seq !== sc._profileSeq;
        if (pend.p === 'POST token') {
          const ok = rnd() < 0.8;
          if (!stale && ok) { exp.refreshed = 1; start = silentOrFull(); }   // a good, current answer re-enters through _recheckOrLoad
          h.answerAt(idx, ok, ok ? { expires_in: '3600', id_token: 'new', refresh_token: pend.rt, user_id: 'u1' } : null, ok ? 200 : 400);
          break;
        }
        const path = pend.p;
        const [ok, data, status] = path.startsWith('users/') ? answerBody.users(truth.users) : MEMBER_DOC.test(path) ? answerBody.member(truth.member) : ROSTER.test(path) ? [true, [], 200] : [true, { name: 'Al Shop' }, 200];
        if (stale) { stats.stale++; h.answerAt(idx, ok, data, status); check('stale answer', pre, exp, 'none'); continue; }
        stats.answers++;
        exp = expectAnswer(pend, pre);
        h.answerAt(idx, ok, data, status);
        if (path.startsWith('users/') && (truth.users === 'ok1' || truth.users === 'ok2')) exp.users = 0;
        if (exp.emits > 0 && !exp.unv) synced = true;    // only a verified answer counts as synced; the model learns of it before the system is compared with it
        check(`answer ${path} silent=${pend.silent}`, pre, exp, pend.silent ? 'none' : 'answer');
        continue;
      }
      default: break;
    }
    if (start === 'silent' || start === 'full' || start === 'refresh') stats[start]++;
    // expected counters for a start
    if (start === 'silent') { exp.users = 1; exp.checking = true; }
    if (start === 'full') { exp.users = sc.isOnline ? 1 : 0; exp.resolved = sc.isOnline ? false : true; exp.onboarding = false; exp.checking = false; }
    if (start === 'refresh') exp.posts = 1;
    if (act === 'signOut') exp.checking = false;
    if (start === 'silent') assert.equal(sc.checking, true);
    // the refresh answer re-enters through _recheckOrLoad: counted above through silentOrFull() before the answer ran
    check(act, pre, act === 'answer' ? { ...exp, posts: 0 } : exp, start);
  }
  // Drain: answer everything left against the current truth; the system must settle with nothing in flight.
  sc.isOnline = true;
  let guard = 0;
  while (pending.length && guard++ < 200) {
    const pend = pending[0];
    if (pend.p === 'POST token') { h.answerAt(0, true, { expires_in: '3600', id_token: 'new', refresh_token: pend.rt, user_id: 'u1' }); continue; }
    const [ok, data, status] = pend.p.startsWith('users/') ? answerBody.users(truth.users) : MEMBER_DOC.test(pend.p) ? answerBody.member(truth.member) : [true, [], 200];
    h.answerAt(0, ok, data, status);
  }
  assert.equal(pending.length, 0, `seed ${seed}: the drain settled`);
  assert.equal(sc.checking, false, `seed ${seed}: nothing is checking after the drain`);
  const acc = h.writes.filter((w) => w[0] === 'accessBlock');
  return { n: log.length, ...stats, toasts: calls.roleChanged.length, emits: calls.tenantContextReady.length, onboarding: calls.onboardingRequired,
    movedWrites: acc.filter((w) => w[1] === 'moved').length, blocks: acc.filter((w) => w[1] !== '').length, unblocks: acc.filter((w) => w[1] === '').length, refreshed: calls.tokenRefreshed, signOuts: calls.signedOut };
}

// ---------------------------------------------------------------------------------------------------------
test('S-A behaviour: every scenario passes on the real AuthService text', () => {
  for (const [name, fn] of Object.entries(SCENARIOS)) {
    try { fn(makeHarness(AUTH_SRC, {}), (i) => makeHarness(AUTH_SRC, i)); } catch (e) { e.message = `[${name}] ${e.message}`; throw e; }
  }
});

for (const [name, fn] of Object.entries(SCENARIOS)) {
  test(`S-A scenario: ${name}`, () => { fn(makeHarness(AUTH_SRC, {}), (i) => makeHarness(AUTH_SRC, i)); });
}

for (const seed of [1, 7, 42, 2026]) {
  test(`S-A monkey (seed ${seed}, 6000 steps) agrees with the reference model at every step`, () => {
    const r = runMonkey(AUTH_SRC, seed, 6000);
    // The monkey must reach the states the feature is about, or "agrees with the model" proves nothing.
    assert.equal(r.n, 6000);
    assert.ok(r.silent >= 60, `silent starts ${r.silent}`);
    assert.ok(r.full >= 50, `full loads ${r.full}`);
    assert.ok(r.refresh >= 60, `token refreshes ${r.refresh}`);
    assert.ok(r.stale >= 40, `stale answers ${r.stale}`);
    assert.ok(r.toasts >= 4, `role changes ${r.toasts}`);
    assert.ok(r.blocks >= 15 && r.unblocks >= 15, `blocks ${r.blocks} unblocks ${r.unblocks}`);
    assert.ok(r.emits >= 30, `tenantContextReady ${r.emits}`);
    assert.ok(r.signOuts >= 8, `sign-outs ${r.signOuts}`);
    assert.ok(r.moved >= 3 && r.movedWrites >= 3, `moved screens ${r.moved}/${r.movedWrites}`);
    assert.ok(r.ignored >= 1, `unreadable answers for another workspace ignored ${r.ignored}`);
  });
  test(`S-A monkey, workspace profile (seed ${seed}, 6000 steps) agrees with the reference model at every step`, () => {
    const r = runMonkey(AUTH_SRC, seed, 6000, 'ws');
    assert.equal(r.n, 6000);
    assert.ok(r.silent >= 60, `silent starts ${r.silent}`);
    assert.ok(r.moved >= 5 && r.movedWrites >= 5, `moved screens ${r.moved}/${r.movedWrites}`);
    assert.ok(r.ignored >= 3, `unreadable answers for another workspace ignored ${r.ignored}`);
    assert.ok(r.unblocks >= 20, `unblocks ${r.unblocks}`);
  });
}

// ---------------------------------------------------------------------------------------------------------
// Mutants of AuthService.qml: each hand-made break must be caught by a scenario or by the monkey.
const MUTANTS = [
  ['if (!quiet) {\n            profileResolved = false\n            onboardingNeeded = false\n        }', 'if (true) {\n            profileResolved = false\n            onboardingNeeded = false\n        }', 'the sign-in cover flips on every check again'],
  ['        if (kind === "none") return\n', '', 'an unchanged answer resyncs every store again'],
  ['        checking = false\n        if (kind === "none") return', '        if (kind === "none") return', 'checking is never cleared by an answer'],
  ['if (!SessionRecheck.canStart(checking, _lastRecheckMs, now)) return false', 'if (false) return false', 'no throttle on automatic checks'],
  ['        _lastRecheckMs = now\n        _loadUserProfile(true)', '        _loadUserProfile(true)', 'an automatic check does not start the spacing window'],
  ['        _lastRecheckMs = Date.now()\n        _loadUserProfile()\n    }', '        _loadUserProfile()\n    }', 'Try again is not counted as the latest check'],
  ['if (!isOnline || !_sessionOpen()) return false', 'if (!_sessionOpen()) return false', 'an automatic check goes out offline'],
  ['if (!isOnline || !_sessionOpen()) return false', 'if (!isOnline) return false', 'an automatic check runs on a session that is not open'],
  ['return AuthStore.isAuthenticated && profileResolved && !onboardingNeeded && AuthStore.tenantId.length > 0', 'return AuthStore.isAuthenticated && !onboardingNeeded && AuthStore.tenantId.length > 0', 'the open-session test ignores a profile still loading'],
  ['return AuthStore.isAuthenticated && profileResolved && !onboardingNeeded && AuthStore.tenantId.length > 0', 'return AuthStore.isAuthenticated && profileResolved && AuthStore.tenantId.length > 0', 'the open-session test ignores onboarding'],
  ['return AuthStore.isAuthenticated && profileResolved && !onboardingNeeded && AuthStore.tenantId.length > 0', 'return AuthStore.isAuthenticated && profileResolved && !onboardingNeeded', 'the open-session test ignores a missing workspace'],
  ['return AuthStore.isAuthenticated && profileResolved && !onboardingNeeded && AuthStore.tenantId.length > 0', 'return profileResolved && !onboardingNeeded && AuthStore.tenantId.length > 0', 'the open-session test ignores sign-out'],
  ['if (!SessionRecheck.canStart(false, _lastResumeMs, now)) return', 'if (false) return', 'resume reacts to every resume'],
  ['        _lastResumeMs = now\n', '', 'resume never starts its window'],
  ['if (!AuthStore.isAuthenticated || !isOnline) return\n        var now = Date.now()', 'if (!AuthStore.isAuthenticated) return\n        var now = Date.now()', 'resume goes out offline'],
  ['if (!AuthStore.isAuthenticated || !isOnline) return\n        var now = Date.now()', 'if (!isOnline) return\n        var now = Date.now()', 'resume runs signed out'],
  ['if (_tokenExpiring()) refreshIdToken(true)\n        else requestRecheck()', 'requestRecheck()', 'resume sends reads with an expiring token'],
  ['if (_tokenExpiring()) refreshIdToken(true)\n        else requestRecheck()', 'refreshIdToken(true)', 'resume always refreshes the token'],
  ['if (_sessionOpen()) requestRecheck()\n        else _loadUserProfile()', 'requestRecheck()', 'a cold-start refresh is silent (stores never sync)'],
  ['if (_sessionOpen()) requestRecheck()\n        else _loadUserProfile()', '_loadUserProfile()', 'every refresh still flashes the sign-in form'],
  ['accessBlock.length > 0, tenantId, out, _contextSynced)', 'false, tenantId, out, _contextSynced)', 'a reinstated member is never let back in silently'],
  ['accessBlock.length > 0, tenantId, out, _contextSynced)', 'accessBlock.length > 0, tenantId, out, true)', 'the first answer is not counted as a change (no store ever syncs at cold start)'],
  ['        _contextSynced = _contextSynced || out.verified === true\n        tenantContextReady(AuthStore.tenantId, AuthStore.role)\n        if (kind', '        tenantContextReady(AuthStore.tenantId, AuthStore.role)\n        if (kind', 'the session is never marked synced, so every check resyncs'],
  ['        checking = false\n        _contextSynced = false\n        profileResolved = true', '        checking = false\n        profileResolved = true', 'sign-out keeps the synced mark for the next account'],
  ['        if (kind === "role") roleChanged(AuthStore.role)\n', '', 'a role change is never announced'],
  ['if (kind === "role") roleChanged(AuthStore.role)', 'if (kind !== "none") roleChanged(AuthStore.role)', 'every change is announced as a role change'],
  ['                    // start decides "Create your workspace" (design E2). The member doc stays the authority.\n                    if (quiet) { checking = false; return }', '                    // start decides "Create your workspace" (design E2). The member doc stays the authority.\n', 'an open session is offered onboarding when the users doc vanishes'],
  ['                if (quiet) { checking = false; return }\n                accessBlock = ""', '                accessBlock = ""', 'an open session is offered onboarding when the users doc has no workspace'],
  ['            if (quiet) { checking = false; return }\n            accessBlock = ""\n            onboardingNeeded = true', '            accessBlock = ""\n            onboardingNeeded = true', 'a silent load with no uid opens onboarding'],
  ['            checking = false\n            if (!quiet) profileResolved = true\n            return', '            if (!quiet) profileResolved = true\n            return', 'an offline silent load leaves checking stuck'],
  ['        _profileSeq++\n        checking = false\n        _contextSynced = false\n        profileResolved = true', '        _profileSeq++\n        _contextSynced = false\n        profileResolved = true', 'sign-out leaves checking stuck'],
  ['var seq = ++_profileSeq\n        checking = quiet', 'var seq = _profileSeq\n        checking = quiet', 'loads do not take a sequence number'],
  ['_verifyMembership(seq, tenantId, data.tenantName || "", quiet)', '_verifyMembership(seq, tenantId, data.tenantName || "")', 'the member answer forgets the check is silent'],
  ['_applyAccess(AuthStore.tenantId, AuthStore.tenantName, false, null, status, quiet)', '_applyAccess(AuthStore.tenantId, AuthStore.tenantName, false, null, status)', 'an unreadable users doc forgets the check is silent'],
  ['            _recheckOrLoad()\n            tokenRefreshed()', '            _loadUserProfile()\n            tokenRefreshed()', 'a token refresh flashes the sign-in form again'],
  ['            if (AuthStore.refreshToken !== sentWith) return\n', '', 'a refresh answer after sign-out revives the old user'],
  ['        _lastRecheckMs = Date.now()\n        _loadUserProfile()\n    }', '        _lastRecheckMs = Date.now()\n        _loadUserProfile(true)\n    }', 'Try again becomes silent (the access screen would never spin)'],
  ['        var held = tenantId && AuthStore.tenantId === tenantId ? AuthStore.role : ""', '        var held = AuthStore.role', 'a role held for another workspace is reused'],
  // PR #180 review sweep
  ['_contextSynced = _contextSynced || out.verified === true', '_contextSynced = true', 'an unreadable answer counts as synced (stores never resync after a flaky first answer)'],
  ['_contextSynced = _contextSynced || out.verified === true', '_contextSynced = out.verified === true', 'an unreadable answer un-marks the synced stores'],
  ['        if (kind === "none" && (!out || out.verified !== true)) _lastRecheckMs = 0\n', '', 'an unreadable answer uses up the 60 s window'],
  ['if (kind === "none" && (!out || out.verified !== true)) _lastRecheckMs = 0', 'if (kind === "none") _lastRecheckMs = 0', 'every unchanged answer frees the window (the throttle is gone)'],
  ['if (kind === "none" && (!out || out.verified !== true)) _lastRecheckMs = 0', 'if (kind !== "open" && (!out || out.verified !== true)) _lastRecheckMs = 0', 'a refused answer frees the window'],
  ['refreshIdToken(true)\n        else requestRecheck()', 'refreshIdToken()\n        else requestRecheck()', 'a resume refresh reports its failure inside open dialogs'],
  ['if (silent !== true) authFailed("Missing refresh token")', 'authFailed("Missing refresh token")', 'a resume without a refresh token reports an error'],
  ['if (silent !== true) authFailed(_parseErrorReason())', 'authFailed(_parseErrorReason())', 'a resume refresh failure is reported'],
  ['if (silent !== true) authFailed(_parseErrorReason())', 'if (silent === true) authFailed(_parseErrorReason())', 'an explicit refresh failure is hidden'],
  ['        _lastResumeMs = 0\n        _profileSeq++', '        _profileSeq++', 'sign-out keeps the resume window of the account that left'],
  ['        _lastRecheckMs = 0   // the next account starts with no spacing window left by the last one\n', '', 'sign-out keeps the check window of the account that left'],
  // PR #180 decisions Q1-Q3 (fold-in)
  ['        if (kind === "tenant") {\n            accessTenantName = tenantName || ""\n            accessBlock = AccessState.STATE_MOVED\n            return\n        }\n\n', '', 'Q2: a workspace change switches the stores under open forms again'],
  ['            accessBlock = AccessState.STATE_MOVED\n            return', '            accessBlock = AccessState.STATE_MOVED', 'Q2: the moved screen is shown and the workspace is switched anyway'],
  ['            accessBlock = AccessState.STATE_MOVED', '            accessBlock = "suspended"', 'Q2: a workspace change shows the suspended screen'],
  ['            accessTenantName = tenantName || ""\n            accessBlock = AccessState.STATE_MOVED', '            accessTenantName = tenantName || AuthStore.tenantName\n            accessBlock = AccessState.STATE_MOVED', 'Q2: the moved screen names the old shop'],
  ['            accessTenantName = tenantName || ""\n            accessBlock = AccessState.STATE_MOVED', '            accessBlock = AccessState.STATE_MOVED', 'Q2: the moved screen keeps whatever name was showing'],
  ['if (kind === "tenant") {\n            accessTenantName', 'if (kind === "tenant" || kind === "role") {\n            accessTenantName', 'Q2: a role change is also a moved screen'],
  ['if (kind === "tenant") {\n            accessTenantName', 'if (kind === "tenant" || kind === "first") {\n            accessTenantName', 'Q2: the first resolve is also a moved screen (cold start never opens)'],
  ['            if (out.reason !== AccessState.STATE_MOVED)\n                accessTenantName', '            accessTenantName', 'Q2: a kept moved screen loses the name it shows'],
  ['tenantName || (tenantId === AuthStore.tenantId ? AuthStore.tenantName : "")', 'tenantName || AuthStore.tenantName', 'a refusal for another workspace names the old shop'],
  ['tenantName || (tenantId === AuthStore.tenantId ? AuthStore.tenantName : "")', 'tenantName || ""', 'a refusal for the same workspace loses the shop name'],
  ['        if (_tokenExpiring()) refreshIdToken(true)\n    }', '        if (_tokenExpiring()) refreshIdToken()\n    }', 'Q3: ensureFreshToken reports its failure inside open dialogs again'],
  ['        if (_tokenExpiring()) refreshIdToken(true)\n    }', '        refreshIdToken(true)\n    }', 'Q3: ensureFreshToken refreshes a token that is not expiring'],
  ['        if (!AuthStore.isAuthenticated) return\n        if (_tokenExpiring()) refreshIdToken(true)', '        if (_tokenExpiring()) refreshIdToken(true)', 'Q3: ensureFreshToken refreshes while signed out'],
  ['        if (!AuthStore.isAuthenticated) return\n        if (_tokenExpiring()) refreshIdToken(true)', '        if (!AuthStore.isAuthenticated) return\n        if (false) refreshIdToken(true)', 'Q3: ensureFreshToken never refreshes'],
];

function failsSomewhere(src) {
  for (const [name, fn] of Object.entries(SCENARIOS)) {
    try { fn(makeHarness(src, {}), (i) => makeHarness(src, i)); } catch (e) { return name; }
  }
  for (const seed of [1, 7]) {
    try { runMonkey(src, seed, 1500); } catch (e) { return `monkey seed ${seed}`; }
  }
  for (const seed of [3, 11]) {
    try { runMonkey(src, seed, 1500, 'ws'); } catch (e) { return `workspace monkey seed ${seed}`; }
  }
  return '';
}

for (const [from, to, what] of MUTANTS) {
  test(`S-A mutant is caught: ${what}`, () => {
    const hits = AUTH_SRC.split(from).length - 1;
    assert.equal(hits, 1, `mutant anchor must occur exactly once (found ${hits}); AuthService.qml changed, update this mutant`);
    assert.notEqual(failsSomewhere(AUTH_SRC.replace(from, to)), '', `nothing failed for mutant: ${what}`);
  });
}
