'use strict';

// AuthService, Main.qml, FirebaseService and AccessBlockedPage cannot be instantiated under
// qmltestrunner (Felgo, no App context), so the S2f-3 wiring is pinned here by reading the source.
// The decisions themselves live in qml/helper/AccessState.js and are tested in tests/tst_AccessState.qml.
//
// Rules pinned:
//   1. Trust: the role applied at login comes from the member doc only. The users doc (self-writable) is
//      read for the tenant pointer; applyTenantContext / tenantContextReady are not reached from the users
//      doc callback; no role default ("owner" / "staff") survives in AuthService.
//   2. Order: block outcomes return BEFORE the tenant context is applied.
//   3. Races: every profile load takes a sequence number, callbacks bail when it is stale, sign-out bumps it.
//   4. Retry: offline "Try again" never reaches _loadUserProfile (it would reopen the app). An online retry
//      keeps the blocked screen up (accessBlock is cleared only by a definitive answer, never up front or by
//      an unreadable users doc), shows a spinner and refuses a second tap; Sign out stays available.
//   5. Screen: shown for authenticated + non-empty accessBlock (NOT tied to profileResolved), above the z 200
//      overlays, dynamic text is plain text, sign-out goes through app.askLeave.
//   6. Parity: the helper's role list equals the gateway's and the rules'.
//   7. FirebaseService.get hands the HTTP status to its callback on both outcomes.
// Design: docs/superpowers/specs/2026-10-28-s2f3-access-wording-design.md
// Plan:   docs/superpowers/test-plans/2026-10-28-s2f3-access-blocked-test-plan.md

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..', '..');
const read = (...p) => fs.readFileSync(path.join(REPO, ...p), 'utf8');

function bodyOf(src, name) {
  const at = src.indexOf(`function ${name}(`);
  if (at < 0) return '';
  const open = src.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}' && --depth === 0) return src.slice(open + 1, i);
  }
  return '';
}
const code = (src) => src.split('\n').map((l) => l.replace(/\/\/.*$/, '')).join('\n');
// The text inside the braces that follow `marker` (e.g. an `if (...) {` branch), '' when absent.
function blockAfter(src, marker) {
  const at = src.indexOf(marker);
  if (at < 0) return '';
  const open = src.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}' && --depth === 0) return src.slice(open + 1, i);
  }
  return '';
}

// Every rule is a pure function of the sources, so the mutation tests below can feed it broken copies.
function problems(src) {
  const out = [];
  const auth = code(src.auth);
  const load = bodyOf(auth, '_loadUserProfile');
  const verify = bodyOf(auth, '_verifyMembership');
  const apply = bodyOf(auth, '_applyAccess');
  const recheck = bodyOf(auth, 'recheckAccess');
  const signOut = bodyOf(auth, 'signOut');

  // 1. trust
  if (!load) out.push('load-missing');
  if (/applyTenantContext|tenantContextReady/.test(load)) out.push('load-applies-context');
  if (/\.role\b/.test(load)) out.push('load-reads-role');
  if (!/_verifyMembership\(seq, tenantId,/.test(load)) out.push('load-no-verify');
  if (/\|\|\s*"(owner|staff|admin|manager)"/.test(auth)) out.push('role-default');
  if (/_loadMembership/.test(auth)) out.push('old-loadMembership');
  if (!/FirebaseService\.get\("tenants\/" \+ tenantId \+ "\/members\/" \+ AuthStore\.uid,/.test(verify)) out.push('verify-reads-own-member-doc');
  if (!/_applyAccess\(tenantId, tenantName, ok, data, status\)/.test(verify)) out.push('verify-no-apply-access');
  if (!/AccessState\.outcome\(AccessState\.classify\(ok, status, data\), held, accessBlock\)/.test(apply)) out.push('apply-no-classify');
  if (!/AuthStore\.tenantId === tenantId \? AuthStore\.role : ""/.test(apply)) out.push('apply-held-role-same-tenant-only');
  if (!/tenantId && AuthStore\.tenantId === tenantId/.test(apply)) out.push('apply-held-role-needs-tenant');

  // 2. order: block returns before applyTenantContext, ready only after it
  const iBlock = apply.indexOf('accessBlock = out.reason');
  const iRet = apply.indexOf('return', iBlock);
  const iApply = apply.indexOf('AuthStore.applyTenantContext');
  const iReady = apply.indexOf('tenantContextReady(');
  if (iBlock < 0) out.push('apply-no-block');
  if (!(iBlock >= 0 && iRet > iBlock && iApply > iRet)) out.push('block-not-before-apply');
  if (!(iReady > iApply && iApply > 0)) out.push('ready-not-after-apply');
  if (!/role: out\.role/.test(apply)) out.push('apply-not-member-role');
  if ((apply.match(/applyTenantContext\(/g) || []).length !== 1) out.push('apply-count');
  if ((apply.match(/tenantContextReady\(/g) || []).length !== 1) out.push('ready-count');
  if (/applyTenantContext|tenantContextReady/.test(verify)) out.push('verify-applies-context');

  // 3. races
  if (!/var seq = \+\+_profileSeq/.test(load)) out.push('load-no-seq');
  if ((load.match(/if \(seq !== _profileSeq\) return/g) || []).length !== 1) out.push('load-stale-guard');
  if (!/if \(seq !== _profileSeq\) return/.test(verify)) out.push('verify-stale-guard');
  if (!/_profileSeq\+\+/.test(signOut)) out.push('signout-no-seq');
  if (!/accessBlock = ""/.test(signOut) || !/accessTenantName = ""/.test(signOut)) out.push('signout-no-reset');

  // 3b. a retry keeps the blocked screen up: the block is cleared only by a definitive answer
  // (no uid, no tenant on the users doc, member verified), never up front, never by an unreadable users doc
  const iFirstClear = load.indexOf('accessBlock = ""');
  const iUidGuard = load.indexOf('if (!AuthStore.uid)');
  if (iFirstClear >= 0 && iFirstClear < iUidGuard) out.push('load-clears-block-upfront');
  if ((load.match(/accessBlock = ""/g) || []).length !== 2) out.push('load-definitive-clears');
  if (!/accessBlock = ""/.test(blockAfter(load, 'if (!AuthStore.uid)'))) out.push('load-definitive-clears');
  if (!/accessBlock = ""/.test(blockAfter(load, 'if (!tenantId)'))) out.push('load-definitive-clears');
  // the unreadable-users-doc branch may READ accessBlock (D13 guard) but never clear or set it
  if (/accessBlock\s*=(?!=)/.test(blockAfter(load, 'if (!ok || !data)'))) out.push('load-usersdoc-failure-keeps-block');
  {   // D13: a users doc 404 while a block shows keeps the block; the guard must come before onboarding starts
    const blk = blockAfter(load, 'if (!ok || !data)');
    const iG = blk.indexOf('accessBlock.length > 0');
    const iO = blk.indexOf('onboardingRequired()');
    if (!(iG >= 0 && iO > iG)) out.push('load-usersdoc-404-keeps-block');
  }
  if (/accessBlock/.test(blockAfter(load, 'if (!isOnline)'))) out.push('load-offline-keeps-block');
  const iClearOk = apply.indexOf('accessBlock = ""', iRet);
  if (!(iClearOk > iRet && iClearOk < iApply)) out.push('apply-enter-no-clear');

  // 3c. a users doc that could not be READ is not "no workspace": only a 404 goes to onboarding, anything else
  // takes the same access decision as an unreadable member doc; and create-workspace never writes after one
  if (!/function\(ok, data, status\)/.test(load) || !/if \(!ok && status === 404\)/.test(load)) out.push('load-usersdoc-404-only');
  if (!/_applyAccess\(AuthStore\.tenantId, AuthStore\.tenantName, false, null, status\)/.test(load)) out.push('load-usersdoc-unreadable-decides');
  if ((load.match(/onboardingRequired\(\)/g) || []).length !== 3) out.push('load-onboarding-sites');
  const createFn = bodyOf(auth, 'createTenantForCurrentUser');
  const iGuard = createFn.indexOf('if (!okExisting && statusExisting !== 404)');
  const iPut = createFn.indexOf('FirebaseService.put(');
  if (!(iGuard >= 0 && iGuard < iPut)) out.push('create-unreadable-guard');
  // leaving a workspace read-modify-writes the users doc: an unreadable doc is never replaced with blanks
  const leaveFn = bodyOf(auth, 'leaveCurrentTenant');
  const iLG = leaveFn.indexOf('if (!missing && !(okGet && userDoc))');
  const iLP = leaveFn.indexOf('FirebaseService.put(');
  if (!(iLG >= 0 && iLP > iLG && /var missing = !okGet && statusGet === 404/.test(leaveFn))) out.push('leave-unreadable-guard');

  // 4. retry
  const iOff = recheck.indexOf('if (!isOnline) return');
  const iLoad = recheck.indexOf('_loadUserProfile()');
  if (!(iOff >= 0 && iLoad > iOff)) out.push('recheck-offline-guard');

  // createTenant must not default a role
  const create = bodyOf(auth, 'createTenantForCurrentUser');
  if (/role:\s*existingUser\.role/.test(create)) out.push('create-users-role');
  if ((create.match(/_loadUserProfile\(\)/g) || []).length !== 2) out.push('create-reverify');

  // 5. screen
  const main = code(src.main);
  const m = main.match(/AccessBlockedPage \{[\s\S]*?\n    \}\n/);
  if (!m) out.push('page-missing');
  else {
    const blk = m[0];
    // visible must NOT depend on profileResolved: a "Try again" re-resolves the profile, and the login
    // cover (z 100) would show through for the round trip. `checking` carries that state instead.
    if (!/visible: AuthStore\.isAuthenticated && AuthService\.accessBlock\.length > 0\n/.test(blk)) out.push('page-visible');
    if (!/checking: !AuthService\.profileResolved/.test(blk)) out.push('page-checking');
    const z = blk.match(/\bz: (\d+)/);
    if (!z || Number(z[1]) <= 200) out.push('page-z-above-overlays');
    if (!/reason: AuthService\.accessBlock/.test(blk)) out.push('page-reason');
    if (!/onSignOutRequested: app\.askLeave\(\{ proceed: function\(\) \{ logic\.signOutRequested\(\) \} \}\)/.test(blk)) out.push('page-signout-guard');
    const iOffline = blk.indexOf('AuthService.isOnline');
    const iRe = blk.indexOf('AuthService.recheckAccess()');
    if (!(iOffline >= 0 && iRe > iOffline)) out.push('page-retry-offline-toast');
  }
  const zOf = (id) => { const r = main.match(new RegExp(id + ' \\{[\\s\\S]*?z: (\\d+)')); return r ? Number(r[1]) : -1; };
  if (!(zOf('LoginPage') < zOf('TenantSetupPage') && zOf('TenantSetupPage') < 300)) out.push('z-order-login-setup');

  const page = code(src.page);
  const texts = page.match(/Text \{[\s\S]*?\n            \}/g) || [];
  if (texts.length !== 3) out.push('page-text-count');
  for (const t of texts) if (!/textFormat: Text\.PlainText/.test(t)) out.push('page-text-not-plain');
  if (!/AccessState\.copy\(reason, tenantName\)/.test(page)) out.push('page-copy');
  if (!/MouseArea \{ anchors\.fill: parent \}/.test(page)) out.push('page-swallow');
  if (!/signal retryRequested\(\)/.test(page) || !/signal signOutRequested\(\)/.test(page)) out.push('page-signals');
  const tryAgain = blockAfter(page, 'PrimaryButton {');
  if (!/property bool checking: false/.test(page)) out.push('page-checking-property');
  if (!/loading: root\.checking/.test(tryAgain)) out.push('page-busy-feedback');
  if (!/enabled: !root\.checking/.test(tryAgain)) out.push('page-no-double-tap');
  if (/checking/.test(blockAfter(page, 'GhostButton {'))) out.push('page-signout-blocked-while-checking');

  // 7. FirebaseService.get
  const fb = code(src.firebase);
  const get = bodyOf(fb, 'get');
  if (!/callback\(false, null, status\)/.test(get) || !/callback\(true, _decodeDoc\(data\), status\)/.test(get)) out.push('get-status');
  return out;
}

const sources = () => ({
  auth: read('qml', 'model', 'AuthService.qml'),
  main: read('qml', 'Main.qml'),
  page: read('qml', 'pages', 'AccessBlockedPage.qml'),
  firebase: read('qml', 'model', 'FirebaseService.qml'),
});

test('S2f-3 wiring: the real sources satisfy every rule', () => {
  assert.deepEqual(problems(sources()), []);
});

// ---- mutation: each deliberate break must be reported (proves the rules are not vacuous) ----
const MUTANTS = [
  ['auth', 'accessBlock = out.reason', 'accessBlockX = out.reason', 'apply-no-block'],
  ['auth', 'AccessState.outcome(AccessState.classify(ok, status, data), held, accessBlock)', 'AccessState.outcome(AccessState.classify(ok, 0, data), held, accessBlock)', 'apply-no-classify'],
  ['auth', 'AccessState.outcome(AccessState.classify(ok, status, data), held, accessBlock)', 'AccessState.outcome(AccessState.classify(ok, status, data), held)', 'apply-no-classify'],
  ['auth', 'var seq = ++_profileSeq\n        profileResolved = false\n', 'var seq = ++_profileSeq\n        profileResolved = false\n        accessBlock = ""\n', 'load-clears-block-upfront'],
  ['auth', '        if (!AuthStore.uid) {\n            accessBlock = ""\n', '        if (!AuthStore.uid) {\n', 'load-definitive-clears'],
  ['auth', '            if (!tenantId) {\n                accessBlock = ""\n', '            if (!tenantId) {\n', 'load-definitive-clears'],
  ['auth', '            if (!ok || !data) {\n                if (!ok && status === 404) {', '            if (!ok || !data) {\n                accessBlock = ""\n                if (!ok && status === 404) {', 'load-usersdoc-failure-keeps-block'],
  ['auth', '                    if (accessBlock.length > 0) {\n                        profileResolved = true\n                        return\n                    }\n', '', 'load-usersdoc-404-keeps-block'],
  ['auth', 'if (!missing && !(okGet && userDoc)) {', 'if (false) {', 'leave-unreadable-guard'],
  ['auth', 'var missing = !okGet && statusGet === 404', 'var missing = !okGet', 'leave-unreadable-guard'],
  ['auth', 'if (!isOnline) { profileResolved = true; return; }', 'if (!isOnline) { accessBlock = ""; profileResolved = true; return; }', 'load-offline-keeps-block'],
  ['auth', '        accessBlock = ""\n        var name = tenantName', '        var name = tenantName', 'apply-enter-no-clear'],
  ['auth', 'AuthStore.tenantId === tenantId ? AuthStore.role : ""', 'AuthStore.role', 'apply-held-role-same-tenant-only'],
  ['auth', 'role: out.role', 'role: data.role', 'apply-not-member-role'],
  ['auth', '            // Tenant and role are applied only after the member doc has been read (S2f-3).\n            _verifyMembership(seq, tenantId, data.tenantName || "")', '            AuthStore.applyTenantContext({ tenantId: tenantId, role: data.role })\n            _verifyMembership(seq, tenantId, data.tenantName || "")', 'load-applies-context'],
  ['auth', 'var seq = ++_profileSeq', 'var seq = _profileSeq', 'load-no-seq'],
  ['auth', '        _profileSeq++\n        profileResolved = true', '        profileResolved = true', 'signout-no-seq'],
  ['auth', 'if (!isOnline) return\n        _loadUserProfile()', '_loadUserProfile()\n        if (!isOnline) return', 'recheck-offline-guard'],
  ['auth', '    property string accessBlock: ""', '    property string accessBlock: ""\n    function _x() { return role || "owner" }', 'role-default'],
  ['auth', '_loadUserProfile()   // the member doc decides the role, never a default (S2f-3)', 'AuthStore.applyTenantContext({ role: existingUser.role })', 'create-reverify'],
  ['auth', 'tenantId && AuthStore.tenantId === tenantId', 'AuthStore.tenantId === tenantId', 'apply-held-role-needs-tenant'],
  ['auth', '            _applyAccess(tenantId, tenantName, ok, data, status)', '            void 0', 'verify-no-apply-access'],
  ['auth', 'if (!ok && status === 404) {', 'if (!ok) {', 'load-usersdoc-404-only'],
  ['auth', '_applyAccess(AuthStore.tenantId, AuthStore.tenantName, false, null, status)', 'onboardingRequired()', 'load-usersdoc-unreadable-decides'],
  ['auth', 'if (!okExisting && statusExisting !== 404) {', 'if (false) {', 'create-unreadable-guard'],
  ['main', 'z: 300', 'z: 150', 'page-z-above-overlays'],
  ['main', 'visible: AuthStore.isAuthenticated && AuthService.accessBlock.length > 0', 'visible: AuthStore.isAuthenticated && AuthService.profileResolved && AuthService.accessBlock.length > 0', 'page-visible'],
  ['main', 'visible: AuthStore.isAuthenticated && AuthService.accessBlock.length > 0', 'visible: AuthStore.isAuthenticated', 'page-visible'],
  ['main', '        checking: !AuthService.profileResolved\n', '', 'page-checking'],
  ['main', 'onSignOutRequested: app.askLeave({ proceed: function() { logic.signOutRequested() } })\n    }\n\n    InviteMemberDialog', 'onSignOutRequested: logic.signOutRequested()\n    }\n\n    InviteMemberDialog', 'page-signout-guard'],
  ['main', 'if (!AuthService.isOnline) {', 'if (false) {', 'page-retry-offline-toast'],
  ['page', 'textFormat: Text.PlainText\n                wrapMode: Text.Wrap\n                font.pixelSize: sp(Constants.fsH1)', 'wrapMode: Text.Wrap\n                font.pixelSize: sp(Constants.fsH1)', 'page-text-not-plain'],
  ['page', '    MouseArea { anchors.fill: parent }\n', '', 'page-swallow'],
  ['page', '                    loading: root.checking\n', '', 'page-busy-feedback'],
  ['page', '                    enabled: !root.checking\n', '', 'page-no-double-tap'],
  ['page', '    property bool checking: false\n', '', 'page-checking-property'],
  ['page', 'text: qsTr("Sign out")\n', 'text: qsTr("Sign out")\n                    enabled: !root.checking\n', 'page-signout-blocked-while-checking'],
  ['firebase', 'callback(true, _decodeDoc(data), status)', 'callback(true, _decodeDoc(data))', 'get-status'],
];
for (const [file, from, to, expect] of MUTANTS) {
  test(`S2f-3 wiring mutant -> ${expect}`, () => {
    const src = sources();
    assert.ok(src[file].includes(from), `mutation anchor missing in ${file}: ${from.slice(0, 50)}`);
    src[file] = src[file].replace(from, to);
    assert.ok(problems(src).includes(expect), `expected ${expect}, got ${JSON.stringify(problems(src))}`);
  });
}

// ---- 6. parity: one role list in three places ----
test('S2f-3 parity: AccessState.VALID_ROLES = gateway VALID_ROLES = rules roleIsValid', () => {
  const helper = read('qml', 'helper', 'AccessState.js');
  const list = (s) => [...s.matchAll(/"(\w+)"/g)].map((x) => x[1]);
  const h = list(helper.match(/var VALID_ROLES = \[([^\]]*)\]/)[1]);
  const g = list(read('functions', 'index.js').match(/const VALID_ROLES = \[([^\]]*)\]/)[1]);
  const r = [...read('firestore.rules').match(/function roleIsValid\(role\) \{\s*return role in \[([^\]]*)\]/)[1].matchAll(/'(\w+)'/g)].map((x) => x[1]);
  assert.deepEqual(h, ['owner', 'admin', 'manager', 'staff']);
  assert.deepEqual(g, h);
  assert.deepEqual(r, h);
});

test('S2f-3 parity: "active" is the only status the helper lets in, as in the gateway and the rules', () => {
  assert.match(read('qml', 'helper', 'AccessState.js'), /doc\.status !== "active"/);
  assert.match(read('firestore.rules'), /memberDoc\(tenantId, uid\)\.data\.status == 'active'/);
  assert.match(read('functions', 'index.js'), /member\.status !== "active"|status\s*!==\s*"active"/);
});

test('S2f-3: the access-blocked page is picked up by the build (CMake globs qml/*.qml, no list to edit)', () => {
  assert.match(read('CMakeLists.txt'), /GLOB_RECURSE QmlFiles[^\n]*qml\/\*\.qml/);
});
