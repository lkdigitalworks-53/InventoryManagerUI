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
//   4. Retry: offline "Try again" never reaches _loadUserProfile (it would reopen the app).
//   5. Screen: shown for authenticated + resolved + non-empty accessBlock, above the z 200 overlays, dynamic
//      text is plain text, sign-out goes through app.askLeave.
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

// Every rule is a pure function of the sources, so the mutation tests below can feed it broken copies.
function problems(src) {
  const out = [];
  const auth = code(src.auth);
  const load = bodyOf(auth, '_loadUserProfile');
  const verify = bodyOf(auth, '_verifyMembership');
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
  if (!/AccessState\.outcome\(AccessState\.classify\(ok, status, data\), held\)/.test(verify)) out.push('verify-no-classify');
  if (!/AuthStore\.tenantId === tenantId \? AuthStore\.role : ""/.test(verify)) out.push('verify-held-role-same-tenant-only');

  // 2. order: block returns before applyTenantContext, ready only after it
  const iBlock = verify.indexOf('accessBlock = out.reason');
  const iRet = verify.indexOf('return', iBlock);
  const iApply = verify.indexOf('AuthStore.applyTenantContext');
  const iReady = verify.indexOf('tenantContextReady(');
  if (iBlock < 0) out.push('verify-no-block');
  if (!(iBlock >= 0 && iRet > iBlock && iApply > iRet)) out.push('block-not-before-apply');
  if (!(iReady > iApply && iApply > 0)) out.push('ready-not-after-apply');
  if (!/role: out\.role/.test(verify)) out.push('apply-not-member-role');
  if ((verify.match(/applyTenantContext\(/g) || []).length !== 1) out.push('apply-count');
  if ((verify.match(/tenantContextReady\(/g) || []).length !== 1) out.push('ready-count');

  // 3. races
  if (!/var seq = \+\+_profileSeq/.test(load)) out.push('load-no-seq');
  if ((load.match(/if \(seq !== _profileSeq\) return/g) || []).length !== 1) out.push('load-stale-guard');
  if (!/if \(seq !== _profileSeq\) return/.test(verify)) out.push('verify-stale-guard');
  if (!/_profileSeq\+\+/.test(signOut)) out.push('signout-no-seq');
  if (!/accessBlock = ""/.test(signOut) || !/accessTenantName = ""/.test(signOut)) out.push('signout-no-reset');
  if (!/accessBlock = ""/.test(load)) out.push('load-no-reset');

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
    if (!/visible: AuthStore\.isAuthenticated && AuthService\.profileResolved && AuthService\.accessBlock\.length > 0/.test(blk)) out.push('page-visible');
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
  ['auth', 'accessBlock = out.reason', 'accessBlockX = out.reason', 'verify-no-block'],
  ['auth', 'AccessState.outcome(AccessState.classify(ok, status, data), held)', 'AccessState.outcome(AccessState.classify(ok, 0, data), held)', 'verify-no-classify'],
  ['auth', 'AuthStore.tenantId === tenantId ? AuthStore.role : ""', 'AuthStore.role', 'verify-held-role-same-tenant-only'],
  ['auth', 'role: out.role', 'role: data.role', 'apply-not-member-role'],
  ['auth', '            // Tenant and role are applied only after the member doc has been read (S2f-3).\n            _verifyMembership(seq, tenantId, data.tenantName || "")', '            AuthStore.applyTenantContext({ tenantId: tenantId, role: data.role })\n            _verifyMembership(seq, tenantId, data.tenantName || "")', 'load-applies-context'],
  ['auth', 'var seq = ++_profileSeq', 'var seq = _profileSeq', 'load-no-seq'],
  ['auth', '        _profileSeq++\n        profileResolved = true', '        profileResolved = true', 'signout-no-seq'],
  ['auth', 'if (!isOnline) return\n        _loadUserProfile()', '_loadUserProfile()\n        if (!isOnline) return', 'recheck-offline-guard'],
  ['auth', '    property string accessBlock: ""', '    property string accessBlock: ""\n    function _x() { return role || "owner" }', 'role-default'],
  ['auth', '            _loadUserProfile()   // the member doc decides the role, never a default (S2f-3)\n                return\n            }\n\n            FirebaseService.put', '            AuthStore.applyTenantContext({ role: existingUser.role })\n                return\n            }\n\n            FirebaseService.put', 'create-reverify'],
  ['main', 'z: 300', 'z: 150', 'page-z-above-overlays'],
  ['main', 'AuthService.profileResolved && AuthService.accessBlock.length > 0', 'AuthService.accessBlock.length > 0', 'page-visible'],
  ['main', 'onSignOutRequested: app.askLeave({ proceed: function() { logic.signOutRequested() } })\n    }\n\n    InviteMemberDialog', 'onSignOutRequested: logic.signOutRequested()\n    }\n\n    InviteMemberDialog', 'page-signout-guard'],
  ['main', 'if (!AuthService.isOnline) {', 'if (false) {', 'page-retry-offline-toast'],
  ['page', 'textFormat: Text.PlainText\n                wrapMode: Text.Wrap\n                font.pixelSize: sp(Constants.fsH1)', 'wrapMode: Text.Wrap\n                font.pixelSize: sp(Constants.fsH1)', 'page-text-not-plain'],
  ['page', '    MouseArea { anchors.fill: parent }\n', '', 'page-swallow'],
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
