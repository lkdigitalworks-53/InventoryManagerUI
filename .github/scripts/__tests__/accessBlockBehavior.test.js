'use strict';

// S2f-3 behaviour pins. AuthService cannot be instantiated under qmltestrunner (Felgo, no App context), and
// accessBlockWiring.test.js only reads the source. This file RUNS the real function text of AuthService.qml
// (_loadUserProfile, _verifyMembership, _applyAccess, recheckAccess, signOut, _ensureTenantName, loadTenantMembers, createTenantForCurrentUser) in a
// vm sandbox against stubs for FirebaseService / AuthStore, with the real qml/helper/AccessState.js.
//
// The sandbox resolves bare names (accessBlock, profileResolved, tenantContextReady(...)) through a Proxy,
// exactly as QML resolves them against the root object. Nothing here re-implements the logic under test:
// if the QML function changes, these tests see the change. Mutants at the bottom prove the tests bite.
// Not covered (needs a device): the QML property bindings and what the screen draws. See the test plan.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '..', '..', '..');
const AUTH_PATH = 'qml/model/AuthService.qml';
const AUTH_SRC = fs.readFileSync(path.join(REPO, AUTH_PATH), 'utf8');
const ACCESS_SRC = fs.readFileSync(path.join(REPO, 'qml/helper/AccessState.js'), 'utf8').replace(/^\.pragma library/m, '');

const FNS = ['_loadUserProfile', '_verifyMembership', '_applyAccess', 'recheckAccess', 'signOut', '_ensureTenantName', 'loadTenantMembers', 'createTenantForCurrentUser'];
const ROLES = ['owner', 'admin', 'manager', 'staff'];
// tenants/{t}/members/{uid}: the member doc, not the roster read (tenants/{t}/members) that a successful load also issues.
const MEMBER_DOC = /^tenants\/[^/]+\/members\/[^/]+$/;

// Full text of `function name(...) { ... }` (comments stripped so braces in them cannot confuse the match).
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

function makeAccessState() {
  const ctx = vm.createContext({});
  vm.runInContext(ACCESS_SRC + '\n;this.__x = { classify, outcome, copy, isValidRole }', ctx);
  return ctx.__x;
}

// A harness over one copy of AuthService source (the mutants pass a broken copy).
function makeHarness(authSrc, init = {}) {
  const calls = { applyTenantContext: [], tenantContextReady: [], onboardingRequired: 0, ensureName: 0, get: [], put: [], authFailed: [] };
  const pending = [];
  const state = {
    accessBlock: '', accessTenantName: '', _profileSeq: 0, profileResolved: false, onboardingNeeded: false,
    isOnline: true, tenantMembers: [], membersBusy: false, busy: false, tenantCreateBusy: false,
  };
  const AuthStore = {
    uid: 'u1', isAuthenticated: true, tenantId: '', tenantName: '', role: '', email: 'u@x.in', displayName: 'U', photoUrl: '',
    ...init,
    applyTenantContext(c) {
      calls.applyTenantContext.push(c);
      this.tenantId = c.tenantId || ''; this.tenantName = c.tenantName || ''; this.role = c.role || '';
    },
    applyAuth() {}, updateProfile() {}, saveSession() {},
    clear() { this.uid = ''; this.isAuthenticated = false; this.tenantId = ''; this.tenantName = ''; this.role = ''; },
  };
  const FirebaseService = {
    get(p, cb) { calls.get.push(p); pending.push({ p, cb }); },
    put(p, doc, cb) { calls.put.push(p); pending.push({ p: 'PUT ' + p, cb }); },
    toArray: (d) => d,
  };
  const noop = new Proxy(function () {}, { get: (t, k) => (k === Symbol.toPrimitive ? () => '' : noop), apply: () => noop });
  const own = {
    ...state, AuthStore, FirebaseService, AccessState: makeAccessState(),
    tenantContextReady(t, r) { calls.tenantContextReady.push({ t, r, blockAtEmit: scope.accessBlock }); },
    onboardingRequired() { calls.onboardingRequired++; },
    tenantMembersLoaded() {}, memberOperationFailed() {}, signedOut() {},
    authFailed(m) { calls.authFailed.push(m); },
  };
  const scope = new Proxy(own, {
    has: () => true,
    get(t, k) {
      if (k === Symbol.unscopables) return undefined;
      if (k in t) return t[k];
      if (typeof k === 'string' && k in globalThis) return globalThis[k];
      return noop;
    },
    set(t, k, v) { t[k] = v; return true; },
  });
  // The functions are created INSIDE the with-block (so bare names resolve through the proxy) and returned;
  // the identifier `scope` itself must not be used in there, the proxy would answer it too.
  const fnSrc = FNS.map((n) => `${n}: ${fnText(authSrc, n).replace(`function ${n}(`, 'function(')}`).join(',\n');
  Object.assign(own, new Function('scope', `with (scope) { return { ${fnSrc} } }`)(scope));
  // _ensureTenantName is called by _verifyMembership; count it but still run it.
  const realEnsure = own._ensureTenantName;
  own._ensureTenantName = function (t) { calls.ensureName++; return realEnsure(t); };

  const h = {
    calls, scope, AuthStore,
    // Answer the OLDEST pending read whose path starts with `prefix`.
    answer(prefix, ok, data, status) {
      const i = pending.findIndex((x) => (prefix instanceof RegExp ? prefix.test(x.p) : x.p.startsWith(prefix)));
      assert.ok(i >= 0, `no pending read for ${prefix} (have: ${pending.map((x) => x.p)})`);
      const [{ cb }] = pending.splice(i, 1);
      cb(ok, data, status);
    },
    pendingCount: () => pending.length,
    users(tenantId, tenantName = 'Al Shop') { h.answer('users/', true, { tenantId, tenantName, role: 'owner' }, 200); },
    member(doc) { h.answer(MEMBER_DOC, true, doc, 200); },
    memberGone() { h.answer(MEMBER_DOC, false, null, 404); },
    memberFails(status = 0) { h.answer(MEMBER_DOC, false, null, status); },
    snapshot: () => JSON.stringify([state && Object.keys(state).map((k) => own[k]), AuthStore.tenantId, AuthStore.role, calls.tenantContextReady.length]),
  };
  return h;
}

const active = (role) => ({ status: 'active', role });

// ---------------------------------------------------------------------------------------------------------
const SCENARIOS = {
  'active member: the role comes from the MEMBER doc, never from the users doc (which says owner)'(h) {
    h.scope._loadUserProfile();
    assert.equal(h.scope.profileResolved, false);
    h.users('t1');
    h.member(active('staff'));
    assert.equal(h.AuthStore.role, 'staff');
    assert.equal(h.AuthStore.tenantId, 't1');
    assert.deepEqual(h.calls.tenantContextReady.map((c) => c.r), ['staff']);
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.scope.profileResolved, true);
    assert.equal(h.scope.onboardingNeeded, false);
  },
  'nothing is applied or announced before the member doc has been read'(h) {
    h.scope._loadUserProfile();
    h.users('t1');
    assert.equal(h.calls.applyTenantContext.length, 0);
    assert.equal(h.calls.tenantContextReady.length, 0);
    assert.equal(h.scope.profileResolved, false);
  },
  'removed (404): blocked, tenant context never applied, shop name kept for the screen'(h) {
    h.scope._loadUserProfile(); h.users('t1', 'Al Shop'); h.memberGone();
    assert.equal(h.scope.accessBlock, 'removed');
    assert.equal(h.scope.accessTenantName, 'Al Shop');
    assert.equal(h.calls.applyTenantContext.length, 0);
    assert.equal(h.calls.tenantContextReady.length, 0);
    assert.equal(h.scope.profileResolved, true);
  },
  'suspended and inactive and status-less docs are blocked as suspended (fail closed)'(h) {
    for (const doc of [{ status: 'suspended', role: 'staff' }, { status: 'inactive', role: 'staff' }, { role: 'staff' }]) {
      h.scope._loadUserProfile(); h.users('t1'); h.member(doc);
      assert.equal(h.scope.accessBlock, 'suspended', JSON.stringify(doc));
    }
    assert.equal(h.calls.tenantContextReady.length, 0);
  },
  'active with an invalid or missing role is blocked as role, never defaulted'(h) {
    for (const doc of [{ status: 'active', role: 'viewer' }, { status: 'active' }, { status: 'active', role: '' }]) {
      h.scope._loadUserProfile(); h.users('t1'); h.member(doc);
      assert.equal(h.scope.accessBlock, 'role', JSON.stringify(doc));
    }
    assert.equal(h.calls.applyTenantContext.length, 0);
  },
  'unreadable answer, nothing verified before: blocked as unverified'(h) {
    h.scope._loadUserProfile(); h.users('t1'); h.memberFails(0);
    assert.equal(h.scope.accessBlock, 'unverified');
    assert.equal(h.calls.tenantContextReady.length, 0);
  },
  '403 and 500 on the member doc are unverified, not removed or suspended'(h) {
    for (const st of [403, 500, 503]) {
      h.scope._loadUserProfile(); h.users('t1'); h.memberFails(st);
      assert.equal(h.scope.accessBlock, 'unverified', String(st));
    }
  },
  'unreadable answer for a member this device already verified (same tenant): the app opens with the held role'(h) {
    h.scope._loadUserProfile(); h.users('t1'); h.memberFails(0);
    assert.equal(h.scope.accessBlock, '');
    assert.deepEqual(h.calls.tenantContextReady.map((c) => c.r), ['manager']);
    assert.equal(h.AuthStore.role, 'manager');
  },
  'a held role from ANOTHER tenant is not reused'(h) {
    h.scope._loadUserProfile(); h.users('t2'); h.memberFails(0);
    assert.equal(h.scope.accessBlock, 'unverified');
  },
  'B1: Try again keeps the screen up while it asks, and a definitive ok clears it'(h) {
    h.scope._loadUserProfile(); h.users('t1'); h.memberGone();
    assert.equal(h.scope.accessBlock, 'removed');
    h.scope.recheckAccess();
    assert.equal(h.scope.accessBlock, 'removed', 'block must not be cleared up front');
    assert.equal(h.scope.profileResolved, false, 'checking = true');
    h.users('t1'); h.member(active('admin'));
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.scope.profileResolved, true);
    assert.deepEqual(h.calls.tenantContextReady.map((c) => c.r), ['admin']);
  },
  'B2: a failed retry keeps the block that is showing even though a role was held before the block'(h) {
    h.AuthStore.tenantId = 't1'; h.AuthStore.role = 'owner';
    h.scope._loadUserProfile(); h.users('t1'); h.member({ status: 'suspended', role: 'owner' });
    assert.equal(h.scope.accessBlock, 'suspended');
    const readyBefore = h.calls.tenantContextReady.length;
    h.scope.recheckAccess(); h.users('t1'); h.memberFails(0);
    assert.equal(h.scope.accessBlock, 'suspended');
    assert.equal(h.calls.tenantContextReady.length, readyBefore, 'a flaky retry must never let a blocked member in');
  },
  'a conclusive retry answer replaces the block (removed -> suspended -> role)'(h) {
    h.scope._loadUserProfile(); h.users('t1'); h.memberGone();
    h.scope.recheckAccess(); h.users('t1'); h.member({ status: 'suspended', role: 'staff' });
    assert.equal(h.scope.accessBlock, 'suspended');
    h.scope.recheckAccess(); h.users('t1'); h.member({ status: 'active', role: 'x' });
    assert.equal(h.scope.accessBlock, 'role');
  },
  'offline Try again asks nothing and changes nothing'(h) {
    h.scope._loadUserProfile(); h.users('t1'); h.memberGone();
    h.scope.isOnline = false;
    const gets = h.calls.get.length;
    h.scope.recheckAccess();
    assert.equal(h.calls.get.length, gets);
    assert.equal(h.scope.accessBlock, 'removed');
    assert.equal(h.scope.profileResolved, true);
  },
  'offline Try again does not invalidate a check that is already in flight (it would bump the load number)'(h) {
    h.scope._loadUserProfile(); h.users('t1');        // member read in flight
    h.scope.isOnline = false;
    h.scope.recheckAccess();
    h.scope.isOnline = true;
    h.member(active('staff'));
    assert.equal(h.scope.accessBlock, '');
    assert.deepEqual(h.calls.tenantContextReady.map((c) => c.r), ['staff']);
  },
  'the member role beats a held role that disagrees (a demoted member gets the new role)'(h) {
    h.scope._loadUserProfile(); h.users('t1'); h.member(active('staff'));
    assert.equal(h.AuthStore.role, 'staff');
    assert.deepEqual(h.calls.tenantContextReady.map((c) => c.r), ['staff']);
  },
  'a stale answer (an older load) is dropped, the newer load decides'(h) {
    h.scope._loadUserProfile();                       // load 1
    h.scope._loadUserProfile();                       // load 2
    h.users('tOLD');                                  // answers load 1: must be ignored
    assert.equal(h.pendingCount(), 1);
    assert.equal(h.calls.get.filter((p) => p.startsWith('tenants/')).length, 0);
    h.users('t1'); h.member(active('staff'));
    assert.equal(h.AuthStore.tenantId, 't1');
  },
  'a stale member answer cannot let a member in after a newer load blocked them'(h) {
    h.scope._loadUserProfile(); h.users('t1');        // load 1 waits on its member doc
    h.scope._loadUserProfile(); h.users('t1');        // load 2 waits on its member doc
    h.answer(MEMBER_DOC, false, null, 404);           // load 1's answer = removed: stale, dropped
    assert.equal(h.scope.accessBlock, '');
    h.member({ status: 'suspended', role: 'staff' }); // load 2
    assert.equal(h.scope.accessBlock, 'suspended');
  },
  'sign-out while a check is in flight: the late answer changes nothing'(h) {
    h.scope._loadUserProfile(); h.users('t1');
    h.scope.signOut();
    const snap = h.snapshot();
    h.member(active('owner'));
    assert.equal(h.snapshot(), snap);
    assert.equal(h.calls.applyTenantContext.length, 0);
    assert.equal(h.scope.accessBlock, '');
  },
  'sign-out clears the block, the shop name and the roster of the old session'(h) {
    h.scope._loadUserProfile(); h.users('t1'); h.memberGone();
    h.scope.tenantMembers = [{ uid: 'x' }]; h.scope.membersBusy = true;
    h.scope.signOut();
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.scope.accessTenantName, '');
    assert.deepEqual(h.scope.tenantMembers, []);
    assert.equal(h.scope.membersBusy, false);
  },
  'users doc without a tenant: the block is cleared and onboarding starts'(h) {
    h.scope.accessBlock = 'removed';
    h.scope._loadUserProfile(); h.users('');
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.scope.onboardingNeeded, true);
    assert.equal(h.calls.onboardingRequired, 1);
  },
  'users doc unreadable while blocked: the block stays and onboarding is never offered'(h) {
    h.scope.accessBlock = 'suspended';
    h.scope._loadUserProfile(); h.answer('users/', false, null, 0);
    assert.equal(h.scope.accessBlock, 'suspended');
    assert.equal(h.calls.onboardingRequired, 0);
    assert.equal(h.scope.onboardingNeeded, false);
    assert.equal(h.scope.profileResolved, true);
  },
  'users doc 404 (a new account): onboarding, no block, no tenant context'(h) {
    h.scope._loadUserProfile(); h.answer('users/', false, null, 404);
    assert.equal(h.scope.onboardingNeeded, true);
    assert.equal(h.calls.onboardingRequired, 1);
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.calls.applyTenantContext.length, 0);
    assert.equal(h.scope.profileResolved, true);
  },
  'users doc unreadable (0, 401, 403, 500, 503), nothing held: "unverified", NEVER onboarding'(h) {
    for (const st of [0, undefined, 401, 403, 500, 503]) {
      h.scope._loadUserProfile(); h.answer('users/', false, null, st);
      assert.equal(h.scope.accessBlock, 'unverified', String(st));
      assert.equal(h.scope.onboardingNeeded, false, String(st));
    }
    assert.equal(h.calls.onboardingRequired, 0);
    assert.equal(h.calls.tenantContextReady.length, 0);
    assert.equal(h.calls.applyTenantContext.length, 0);
  },
  'users doc unreadable for a member this device already verified: the app keeps working with the held role'(h) {
    h.scope._loadUserProfile(); h.answer('users/', false, null, 503);
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.calls.onboardingRequired, 0);
    assert.deepEqual(h.calls.tenantContextReady.map((c) => c.r), ['manager']);
    assert.equal(h.AuthStore.tenantId, 't1');
    assert.equal(h.AuthStore.role, 'manager');
  },
  'users doc unreadable with a saved tenant but no valid role: unverified, not in'(h) {
    for (const role of ['', 'viewer']) {
      const h2 = makeHarness(AUTH_SRC, { tenantId: 't1', role });
      h2.scope._loadUserProfile(); h2.answer('users/', false, null, 0);
      assert.equal(h2.scope.accessBlock, 'unverified', role);
      assert.equal(h2.calls.tenantContextReady.length, 0);
    }
  },
  'users doc readable but empty body (ok, no data) is unreadable, not "no workspace"'(h) {
    h.scope._loadUserProfile(); h.answer('users/', true, null, 200);
    assert.equal(h.scope.accessBlock, 'unverified');
    assert.equal(h.calls.onboardingRequired, 0);
  },
  'a stale users-doc failure is dropped'(h) {
    h.scope._loadUserProfile(); h.scope._loadUserProfile();
    h.answer('users/', false, null, 0);               // answers load 1
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.scope.profileResolved, false);
    h.users('t1'); h.member(active('staff'));
    assert.equal(h.AuthStore.role, 'staff');
  },
  'create workspace: users doc could not be read -> nothing is written, the user is told'(h) {
    for (const st of [0, undefined, 401, 403, 500]) {
      h.scope.createTenantForCurrentUser('Shop');
      h.answer('users/', false, null, st);
      assert.equal(h.calls.put.length, 0, String(st));
    }
    assert.equal(h.calls.authFailed.length, 5);
    assert.match(h.calls.authFailed[0], /check/i);
    assert.equal(h.scope.busy, false);
    assert.equal(h.scope.tenantCreateBusy, false);
  },
  'create workspace: users doc 404 (new account) goes on to create the tenant'(h) {
    h.scope.createTenantForCurrentUser('Shop');
    h.answer('users/', false, null, 404);
    assert.deepEqual(h.calls.put.map((p) => p.split('/')[0]), ['tenants']);
    assert.equal(h.calls.authFailed.length, 0);
  },
  'create workspace: users doc already points at a shop -> re-verify, no write'(h) {
    h.scope.createTenantForCurrentUser('Shop');
    h.answer('users/', true, { tenantId: 'tX' }, 200);
    assert.equal(h.calls.put.length, 0);
    assert.ok(h.calls.get.filter((p) => p.startsWith('users/')).length === 2, 'users doc read again by the load');
    assert.equal(h.scope.tenantCreateBusy, false);
  },
  'create workspace: users doc exists without a tenant (left a shop) -> may create'(h) {
    h.scope.createTenantForCurrentUser('Shop');
    h.answer('users/', true, { tenantId: '' }, 200);
    assert.equal(h.calls.put.length, 1);
  },
  'no uid: the block is cleared (nothing to verify)'(h) {
    h.AuthStore.uid = ''; h.scope.accessBlock = 'removed';
    h.scope._loadUserProfile();
    assert.equal(h.scope.accessBlock, '');
    assert.equal(h.scope.onboardingNeeded, true);
  },
  'offline load: no read, resolved, block untouched'(h) {
    h.scope.isOnline = false; h.scope.accessBlock = 'removed';
    h.scope._loadUserProfile();
    assert.equal(h.calls.get.length, 0);
    assert.equal(h.scope.profileResolved, true);
    assert.equal(h.scope.accessBlock, 'removed');
  },
  'the member path is the signed-in user\'s own doc under the users-doc tenant'(h) {
    h.AuthStore.uid = 'uidX';
    h.scope._loadUserProfile(); h.users('tZ');
    assert.ok(h.calls.get.includes('tenants/tZ/members/uidX'), h.calls.get.join(','));
  },
  'shop name: the users-doc name wins, else the member doc name, else the stored one; a missing name triggers the lookup'(h) {
    h.scope._loadUserProfile(); h.users('t1', 'From Users'); h.member({ ...active('staff'), tenantName: 'From Member' });
    assert.equal(h.AuthStore.tenantName, 'From Users');
    assert.equal(h.calls.ensureName, 0);
    h.scope._loadUserProfile(); h.users('t1', ''); h.member({ ...active('staff'), tenantName: 'From Member' });
    assert.equal(h.AuthStore.tenantName, 'From Member');
    const h2 = makeHarness(AUTH_SRC);
    h2.scope._loadUserProfile(); h2.users('t1', ''); h2.member(active('staff'));
    assert.equal(h2.calls.ensureName, 1);
  },
  'late tenant-name answer after sign-out or a tenant switch writes nothing'(h) {
    h.AuthStore.tenantId = 't1'; h.AuthStore.role = 'staff';
    h.scope._ensureTenantName('t1');
    h.scope.signOut();
    h.answer('tenants/t1', true, { name: 'Shop A' }, 200);
    assert.equal(h.calls.applyTenantContext.length, 0);
    assert.equal(h.AuthStore.tenantName, '');
    // switch: B is current when A's answer lands
    const h2 = makeHarness(AUTH_SRC, { tenantId: 'tA', role: 'staff' });
    h2.scope._ensureTenantName('tA');
    h2.AuthStore.tenantId = 'tB'; h2.AuthStore.tenantName = 'Shop B';
    h2.answer('tenants/tA', true, { name: 'Shop A' }, 200);
    assert.equal(h2.AuthStore.tenantName, 'Shop B');
    // control: still the same tenant -> applied
    const h3 = makeHarness(AUTH_SRC, { tenantId: 'tA', role: 'staff' });
    h3.scope._ensureTenantName('tA');
    h3.answer('tenants/tA', true, { name: 'Shop A' }, 200);
    assert.equal(h3.AuthStore.tenantName, 'Shop A');
  },
  'a late roster of the old tenant never replaces the current roster'(h) {
    h.AuthStore.tenantId = 'tA';
    h.scope.loadTenantMembers();
    h.AuthStore.tenantId = 'tB'; h.scope.tenantMembers = [{ uid: 'b1' }];
    h.answer('tenants/tA/members', true, [{ uid: 'a1' }], 200);
    assert.deepEqual(h.scope.tenantMembers, [{ uid: 'b1' }]);
    // control: same tenant -> applied, busy cleared
    const h2 = makeHarness(AUTH_SRC, { tenantId: 'tA' });
    h2.scope.loadTenantMembers();
    assert.equal(h2.scope.membersBusy, true);
    h2.answer('tenants/tA/members', true, [{ uid: 'a1' }], 200);
    assert.deepEqual(h2.scope.tenantMembers, [{ uid: 'a1' }]);
    assert.equal(h2.scope.membersBusy, false);
  },
  'roster load with no tenant or not signed in clears the list'(h) {
    h.scope.tenantMembers = [{ uid: 'x' }];
    h.scope.loadTenantMembers();
    assert.deepEqual(h.scope.tenantMembers, []);
  },
};

// Scenarios that need a pre-held role start from a harness with it.
const INIT = {
  'users doc unreadable for a member this device already verified: the app keeps working with the held role': { tenantId: 't1', role: 'manager' },
  'the member role beats a held role that disagrees (a demoted member gets the new role)': { tenantId: 't1', role: 'owner' },
  'unreadable answer for a member this device already verified (same tenant): the app opens with the held role': { tenantId: 't1', role: 'manager' },
  'a held role from ANOTHER tenant is not reused': { tenantId: 't1', role: 'owner' },
};

for (const [name, fn] of Object.entries(SCENARIOS)) {
  test(`S2f-3 behaviour: ${name}`, () => fn(makeHarness(AUTH_SRC, INIT[name] || {})));
}

// Seeded monkey: random events against the real functions; invariants must hold after every step.
test('S2f-3 behaviour monkey: invariants hold over 300 seeded random event sequences', () => {
  let seed = 20261029;
  const rnd = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; };
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const memberAnswers = [() => ({ ok: true, doc: active(pick(ROLES)), st: 200 }), () => ({ ok: false, doc: null, st: 404 }),
    () => ({ ok: true, doc: { status: pick(['suspended', 'inactive', undefined]), role: pick(ROLES) }, st: 200 }),
    () => ({ ok: true, doc: { status: 'active', role: pick(['viewer', '', undefined]) }, st: 200 }),
    () => ({ ok: false, doc: null, st: pick([0, 403, 500]) })];
  for (let run = 0; run < 300; run++) {
    const h = makeHarness(AUTH_SRC, rnd() < 0.5 ? { tenantId: 't1', role: pick(ROLES) } : {});
    for (let step = 0; step < 25; step++) {
      const ev = pick(['load', 'load', 'retry', 'users', 'member', 'member', 'signout', 'offline', 'online']);
      const before = h.snapshot();
      try {
        if (ev === 'load') { h.AuthStore.uid = h.AuthStore.uid || 'u1'; h.AuthStore.isAuthenticated = true; h.scope._loadUserProfile(); }
        else if (ev === 'retry') h.scope.recheckAccess();
        else if (ev === 'users' && h.calls.get.length) { try { h.answer('users/', rnd() < 0.9, { tenantId: pick(['t1', 't2', '']), tenantName: 'S' }, 200); } catch (e) { /* none pending */ } }
        else if (ev === 'member') { try { const a = pick(memberAnswers)(); h.answer(MEMBER_DOC, a.ok, a.doc, a.st); } catch (e) { /* none pending */ } }
        else if (ev === 'signout') h.scope.signOut();
        else if (ev === 'offline') h.scope.isOnline = false;
        else if (ev === 'online') h.scope.isOnline = true;
      } catch (e) { assert.fail(`run ${run} step ${step} ${ev}: threw ${e.message}`); }
      // I1: the app is announced only for a valid role and never while a block is showing
      for (const c of h.calls.tenantContextReady) {
        assert.ok(ROLES.includes(c.r), `run ${run}: announced with role ${JSON.stringify(c.r)}`);
        assert.equal(c.blockAtEmit, '', `run ${run}: announced while blocked`);
      }
      // I2: every applied role is a valid role
      for (const c of h.calls.applyTenantContext) assert.ok(ROLES.includes(c.role), `run ${run}: applied role ${JSON.stringify(c.role)}`);
      // I3: after sign-out nothing lingers
      if (ev === 'signout') { assert.equal(h.scope.accessBlock, ''); assert.equal(h.AuthStore.tenantId, ''); }
      // I4: blocks are one of the four reasons
      assert.ok(['', 'removed', 'suspended', 'role', 'unverified'].includes(h.scope.accessBlock), h.scope.accessBlock);
      void before;
    }
  }
});

// Mutants: each broken copy of AuthService.qml must make at least one scenario fail.
const MUTANTS = [
  ['if (seq !== _profileSeq) return\n            _applyAccess(', '_applyAccess(', 'stale member answers are applied'],
  ['var out = AccessState.outcome(AccessState.classify(ok, status, data), held, accessBlock)', 'var out = AccessState.outcome(AccessState.classify(ok, status, data), held, "")', 'a failed retry forgets the block (B2)'],
  ['var out = AccessState.outcome(AccessState.classify(ok, status, data), held, accessBlock)', 'var out = AccessState.outcome(AccessState.classify(ok, status, data), "owner", accessBlock)', 'a role is invented'],
  ['var held = tenantId && AuthStore.tenantId === tenantId ? AuthStore.role : ""', 'var held = AuthStore.role', 'a role held for another tenant is reused'],
  ['var seq = ++_profileSeq\n        profileResolved = false', 'var seq = _profileSeq\n        profileResolved = false', 'loads do not take a sequence number'],
  ['var seq = ++_profileSeq\n        profileResolved = false\n        onboardingNeeded = false', 'var seq = ++_profileSeq\n        profileResolved = false\n        onboardingNeeded = false\n        accessBlock = ""', 'Try again clears the block up front (B1)'],
  ['if (!isOnline) return\n        _loadUserProfile()', '_loadUserProfile()', 'offline Try again reaches the profile load'],
  ['        _profileSeq++\n        profileResolved = true', '        profileResolved = true', 'sign-out does not invalidate in-flight loads'],
  ['        tenantMembers = []\n        membersBusy = false\n        AuthStore.clear()', '        AuthStore.clear()', 'sign-out keeps the old roster'],
  ['if (AuthStore.tenantId !== tenantId) return\n            var name', 'var name', 'a late shop-name answer is applied'],
  ['if (AuthStore.tenantId !== tid) return\n            membersBusy = false', 'membersBusy = false', 'a late roster is applied'],
  ['AuthStore.applyTenantContext({ tenantId: tenantId, tenantName: name, role: out.role })', 'AuthStore.applyTenantContext({ tenantId: tenantId, tenantName: name, role: held || out.role })', 'the held role beats the member role'],
  ['if (!ok && status === 404) {', 'if (!ok) {', 'any users-doc failure means onboarding'],
  ['_applyAccess(AuthStore.tenantId, AuthStore.tenantName, false, null, status)', 'onboardingNeeded = true; profileResolved = true; onboardingRequired()', 'an unreadable users doc offers onboarding'],
  ['if (!okExisting && statusExisting !== 404) {', 'if (false) {', 'create workspace writes after an unreadable users doc'],
  ['if (!okExisting && statusExisting !== 404) {', 'if (!okExisting) {', 'create workspace refuses a genuine 404 (new account)'],
  ['accessTenantName = tenantName || AuthStore.tenantName\n            accessBlock = out.reason', 'accessBlock = out.reason', 'the block screen loses the shop name'],
  ['            accessBlock = ""\n            onboardingNeeded = true\n            profileResolved = true\n            onboardingRequired()\n            return\n        }\n\n        if (!isOnline)', '            onboardingNeeded = true\n            profileResolved = true\n            onboardingRequired()\n            return\n        }\n\n        if (!isOnline)', 'no-uid keeps the block'],
];

function failsSomewhere(src) {
  for (const [name, fn] of Object.entries(SCENARIOS)) {
    try { fn(makeHarness(src, INIT[name] || {})); } catch (e) { return name; }
  }
  return '';
}

test('S2f-3 behaviour: the unmutated source passes every scenario (control for the mutants)', () => {
  assert.equal(failsSomewhere(AUTH_SRC), '');
});

for (const [from, to, what] of MUTANTS) {
  test(`S2f-3 behaviour mutant -> caught: ${what}`, () => {
    const hits = AUTH_SRC.split(from).length - 1;
    assert.equal(hits, 1, `mutant anchor must occur exactly once (found ${hits}); AuthService.qml changed, update this mutant`);
    const killer = failsSomewhere(AUTH_SRC.replace(from, to));
    assert.notEqual(killer, '', `no scenario failed for mutant: ${what}`);
  });
}

// A guard only guards if every path goes through it (Skill 138): applyTenantContext is the call that hands a
// role to the rest of the app. Only these three AuthService functions may call it; anything else must go
// through the access decision (_applyAccess). setTenantContext (applied any role it was given) is gone.
test('S2f-3 caller pin: only _applyAccess, _ensureTenantName and createTenantForCurrentUser apply a tenant context', () => {
  const names = [...AUTH_SRC.matchAll(/^\s*function (\w+)\(/gm)].map((m) => m[1]);
  const callers = names.filter((n) => fnText(AUTH_SRC, n).includes('applyTenantContext('));
  assert.deepEqual(callers.sort(), ['_applyAccess', '_ensureTenantName', 'createTenantForCurrentUser']);
});

test('S2f-3 caller pin: nothing else in qml/ applies a tenant context or revives setTenantContext', () => {
  const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
  const files = walk(path.join(REPO, 'qml')).filter((f) => /\.(qml|js)$/.test(f));
  for (const f of files) {
    const src = fs.readFileSync(f, 'utf8');
    assert.ok(!/setTenantContext/.test(src), `${path.relative(REPO, f)} mentions setTenantContext`);
    if (!f.endsWith(path.join('model', 'AuthService.qml')) && !f.endsWith(path.join('model', 'AuthStore.qml')))
      assert.ok(!/applyTenantContext\(/.test(src), `${path.relative(REPO, f)} applies a tenant context`);
  }
});

// Back on the access-blocked screen must not close overlays or switch tabs behind it (test plan N2).
test('S2f-3 back key: _handleBack skips the overlay and tab steps while the blocked screen is up, dialogs stay first', () => {
  const main = fs.readFileSync(path.join(REPO, 'qml/Main.qml'), 'utf8');
  const body = fnText(main, '_handleBack');
  const iDialogs = body.indexOf('dialogs[i].opened');
  const iGuard = body.indexOf('if (!accessBlockedPage.visible)');
  const iProfile = body.indexOf('profilePage.visible');
  const iTab = body.indexOf('navigation.currentIndex = 0');
  const iExit = body.indexOf('_exitArmed');
  assert.ok(iDialogs >= 0 && iGuard > iDialogs, 'dialogs (the sign-out sheet) must still close first');
  assert.ok(iProfile > iGuard && iTab > iGuard, 'overlay and tab steps must sit inside the guard');
  assert.ok(body.indexOf('}', iTab) < body.indexOf('_exitArmed', iTab) && iExit > iTab, 'the double-tap exit stays outside the guard');
  assert.ok(main.includes('id: accessBlockedPage'));
});
