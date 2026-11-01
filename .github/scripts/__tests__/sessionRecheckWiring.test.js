'use strict';

// L3 slice A wiring pins: the parts of the silent re-check that only exist as text in AuthService.qml and Main.qml
// (the resume hook, which handler calls what, who may start a silent load, what the sign-in cover and the access
// screen are bound to). The behaviour itself is run in sessionRecheckBehavior.test.js; the property bindings and
// the real foreground transition need a device (test plan H1-H6, N3). Hand mutants at the bottom prove each rule bites.
// Design: docs/superpowers/specs/2026-10-31-l3-session-lifecycle-design.md (L3-D1c, D2a, D5b).

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..', '..');
const read = (p) => fs.readFileSync(path.join(REPO, p), 'utf8');
const AUTH = read('qml/model/AuthService.qml');
const MAIN = read('qml/Main.qml');

const strip = (src) => src.split('\n').map((l) => l.replace(/\/\/.*$/, '')).join('\n');

// Text from the first `{` after `start` to its matching `}` (comments removed first so braces in them cannot count).
function block(src, start) {
  const clean = strip(src);
  const at = clean.indexOf(start);
  if (at < 0) return '';
  const open = clean.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < clean.length; i++) {
    if (clean[i] === '{') depth++;
    if (clean[i] === '}' && --depth === 0) return clean.slice(open, i + 1);
  }
  return '';
}
const fnBody = (src, name) => block(src, `function ${name}(`);
const fnNames = (src) => [...strip(src).matchAll(/^\s*function (\w+)\(/gm)].map((m) => m[1]);
const callers = (src, needle) => fnNames(src).filter((n) => fnBody(src, n).includes(needle)).sort();
const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
const QML_FILES = walk(path.join(REPO, 'qml')).filter((f) => /\.(qml|js)$/.test(f)).map((f) => [path.relative(REPO, f), fs.readFileSync(f, 'utf8')]);

function violations(auth, main, files) {
  const out = [];
  const A = strip(auth);
  const M = strip(main);

  // 1. the resume hook: a thin binding that only reports the transition (R3: device-only, so keep it dumb)
  const hookBody = block(M, 'target: Qt.application');   // the first brace after the target is the handler's own
  if (!/Qt\.application\.state === Qt\.ApplicationActive/.test(hookBody) || !/AuthService\.onAppResumed\(\)/.test(hookBody)) out.push('main-resume-hook');
  if (/_loadUserProfile|recheckAccess|requestRecheck|refreshIdToken|ensureFreshToken/.test(hookBody)) out.push('main-resume-only-reports');
  if (!/Timer\s*\{[^}]*interval: 120000[^}]*onTriggered: AuthService\.ensureFreshToken\(\)/.test(M)) out.push('main-timer-unchanged');

  // 2. triggers that reach a re-check go through one function that decides silent or full
  const online = block(A, 'onIsOnlineChanged:');
  if (!/else if \(profileResolved\)\s*\{\s*_recheckOrLoad\(\)\s*\}/.test(online) || /_loadUserProfile/.test(online)) out.push('auth-online-silent');
  const refresh = fnBody(A, 'refreshIdToken');
  if (!/_recheckOrLoad\(\)\s*tokenRefreshed\(\)/.test(refresh) || /_loadUserProfile|profileResolved = false/.test(refresh)) out.push('auth-refresh-silent');
  const rol = fnBody(A, '_recheckOrLoad');
  if (!/if \(_sessionOpen\(\)\) requestRecheck\(\)\s*else _loadUserProfile\(\)/.test(rol)) out.push('auth-recheckorload-split');

  // 3. a guard only guards if every path goes through it: the silent load has exactly one door
  const silentStarts = (A.match(/_loadUserProfile\(true\)/g) || []).length;
  if (silentStarts !== 1 || !fnBody(A, 'requestRecheck').includes('_loadUserProfile(true)')) out.push('auth-silent-single-door');
  if ((A.match(/_loadUserProfile\((?!true\)|silent\)|\))/g) || []).length !== 0) out.push('auth-silent-odd-arg');
  const rr = fnBody(A, 'requestRecheck');
  const iCan = rr.indexOf('SessionRecheck.canStart(checking, _lastRecheckMs, now)');
  const iSet = rr.indexOf('_lastRecheckMs = now');
  const iLoad = rr.indexOf('_loadUserProfile(true)');
  if (!(iCan >= 0 && iSet > iCan && iLoad > iSet)) out.push('auth-recheck-order');
  if (!/!isOnline \|\| !_sessionOpen\(\)/.test(rr)) out.push('auth-recheck-gates');
  if (!/return AuthStore\.isAuthenticated && profileResolved && !onboardingNeeded && AuthStore\.tenantId\.length > 0/.test(fnBody(A, '_sessionOpen'))) out.push('auth-session-open');
  const resumed = fnBody(A, 'onAppResumed');
  if (!/SessionRecheck\.canStart\(false, _lastResumeMs, now\)/.test(resumed) || !/if \(_tokenExpiring\(\)\) refreshIdToken\(\)\s*else requestRecheck\(\)/.test(resumed)) out.push('auth-resume-throttle');
  if (!/_lastRecheckMs = Date\.now\(\)\s*_loadUserProfile\(\)/.test(fnBody(A, 'recheckAccess'))) out.push('auth-tryagain-full');

  // 4. an answer that changes nothing touches nothing; only a changed answer emits
  const apply = fnBody(A, '_applyAccess');
  const iChecking = apply.indexOf('checking = false');
  const iNone = apply.indexOf('if (kind === "none") return');
  const iCtx = apply.indexOf('applyTenantContext(');
  const iEmit = apply.indexOf('tenantContextReady(');
  // "touches nothing": the early return comes before every state write the answer would make
  const iWrites = Math.min(...['onboardingNeeded = false', 'profileResolved = true', 'accessBlock = out.reason', 'accessBlock = ""'].map((w) => { const i = apply.indexOf(w); return i < 0 ? Infinity : i; }));
  if (!(iChecking >= 0 && iNone > iChecking && iNone < iWrites && iCtx > iNone && iEmit > iCtx)) out.push('auth-none-returns-early');
  if ((apply.match(/tenantContextReady\(/g) || []).length !== 1 || (apply.match(/applyTenantContext\(/g) || []).length !== 1) out.push('auth-emit-once');
  if (!/silent === true\s*\?\s*SessionRecheck\.changeKind\(AuthStore\.tenantId, AuthStore\.role, accessBlock\.length > 0, tenantId, out, _contextSynced\)\s*:\s*"open"/.test(apply)) out.push('auth-full-is-open');
  if (callers(auth, 'tenantContextReady(').filter((n) => n !== 'onIsOnlineChanged').join() !== '_applyAccess,createTenantForCurrentUser,inviteMemberToCurrentTenant') out.push('auth-emit-set');
  if (callers(auth, 'roleChanged(').join() !== '_applyAccess' || !/if \(kind === "role"\) roleChanged\(AuthStore\.role\)/.test(apply)) out.push('auth-role-signal');
  if (callers(auth, 'applyTenantContext(').join() !== '_applyAccess,_ensureTenantName,createTenantForCurrentUser') out.push('auth-apply-set');

  // 5. a refresh that answers for a session that is gone is dropped before anything reads it
  const iSent = refresh.indexOf('var sentWith = AuthStore.refreshToken');
  const iGuard = refresh.indexOf('if (AuthStore.refreshToken !== sentWith) return');
  const iOk = refresh.indexOf('if (!ok) {');
  const iFail = refresh.indexOf('authFailed(', iSent);
  if (!(iSent >= 0 && iGuard > iSent && iOk > iGuard && iFail > iOk) || !/refresh_token: sentWith/.test(refresh)) out.push('auth-refresh-guard');

  // 6. sign-out forgets a check in flight and forgets that the stores were synced (the next sign-in must sync again)
  const so = fnBody(A, 'signOut');
  if (!/_profileSeq\+\+\s*checking = false/.test(so)) out.push('auth-signout-checking');
  if (!/checking = false\s*_contextSynced = false\s*profileResolved = true/.test(so)) out.push('auth-signout-synced');
  // 6b. every function that emits tenantContextReady (Main.qml then syncs ~10 stores) marks the session synced right before it:
  // otherwise the next silent check treats the first answer as a change again, or (worse) never does
  for (const fn of ['_applyAccess', 'createTenantForCurrentUser', 'inviteMemberToCurrentTenant']) {
    const b = fnBody(A, fn);
    if ((b.match(/_contextSynced = true\s*tenantContextReady\(/g) || []).length !== 1 || (b.match(/tenantContextReady\(/g) || []).length !== 1) { out.push('auth-synced-before-emit'); break; }
  }
  if (callers(auth, '_contextSynced = true').join() !== '_applyAccess,createTenantForCurrentUser,inviteMemberToCurrentTenant') out.push('auth-synced-set');

  // 7. declarations
  if (!/import "\.\.\/helper\/SessionRecheck\.js" as SessionRecheck/.test(A)) out.push('auth-import');
  if (!/property bool checking: false/.test(A) || !/property real _lastRecheckMs: 0/.test(A) || !/property real _lastResumeMs: 0/.test(A) || !/property bool _contextSynced: false/.test(A) || !/signal roleChanged\(string role\)/.test(A)) out.push('auth-declarations');

  // 8. the UI: the cover and the access screen stay bound to profileResolved; nothing binds to the silent flag
  if (!/visible: !AuthStore\.isAuthenticated \|\| \(AuthStore\.isAuthenticated && !AuthService\.profileResolved\)/.test(M)) out.push('ui-cover-binding');
  if (!/checking: !AuthService\.profileResolved/.test(M)) out.push('ui-access-spinner-binding');
  for (const [f, src] of files) {
    if (!f.endsWith('AuthService.qml') && /AuthService\.checking/.test(strip(src))) { out.push('ui-binds-checking'); break; }
  }

  // 9. L3-D5b: no tab is role-gated, so there is nothing to jump from; if one ever is, the jump must be built
  const items = [...M.matchAll(/NavigationItem\s*\{([\s\S]*?)\n\s*NavigationStack/g)].map((m) => m[1]);
  if (items.length !== 4) out.push('ui-tab-count');
  for (const it of items) {
    const v = (it.match(/visible:\s*(.*)/) || [])[1] || '';
    if (v.trim() !== 'AuthStore.isAuthenticated') { out.push('ui-tab-role-gated'); break; }
  }
  const rc = block(M, 'function onRoleChanged(');
  if (!/Toast\.show\(qsTr\("Your role is now %1"\)\.arg\(role\)\)/.test(rc) || !/if \(!AuthStore\.canViewStaff\) staffPageOverlay\.close\(\)/.test(rc)) out.push('main-role-toast');
  return out;
}

test('S-A wiring: the real sources satisfy every rule', () => {
  assert.deepEqual(violations(AUTH, MAIN, QML_FILES), []);
});

test('S-A wiring: only requestRecheck starts a silent load, and no other function takes the silent flag from a caller', () => {
  assert.deepEqual(callers(AUTH, '_loadUserProfile(true)'), ['requestRecheck']);
  const names = fnNames(AUTH).filter((n) => /^(_loadUserProfile|_verifyMembership|_applyAccess)$/.test(n)).sort();
  assert.deepEqual(names, ['_applyAccess', '_loadUserProfile', '_verifyMembership']);
});

test('S-A wiring: every full-load entry point still calls _loadUserProfile() with no argument (cold start, sign-in, Try again, create workspace)', () => {
  assert.deepEqual(callers(AUTH, '_loadUserProfile()'), ['_recheckOrLoad', 'createTenantForCurrentUser', 'init', 'recheckAccess', 'signInWithEmail', 'signInWithGoogleIdToken']);
});

const MUTANTS = [
  ['main', '            if (Qt.application.state === Qt.ApplicationActive) AuthService.onAppResumed()', '            AuthService.onAppResumed()', 'main-resume-hook'],
  ['main', '            if (Qt.application.state === Qt.ApplicationActive) AuthService.onAppResumed()', '            if (Qt.application.state === Qt.ApplicationActive) AuthService.requestRecheck()', 'main-resume-hook'],
  ['main', '            if (Qt.application.state === Qt.ApplicationActive) AuthService.onAppResumed()', '            if (Qt.application.state === Qt.ApplicationActive) { AuthService.onAppResumed(); AuthService.recheckAccess() }', 'main-resume-only-reports'],
  ['main', 'onTriggered: AuthService.ensureFreshToken()\n    }\n\n    // Back in', 'onTriggered: AuthService.refreshIdToken()\n    }\n\n    // Back in', 'main-timer-unchanged'],
  ['auth', '            } else if (profileResolved) {\n                _recheckOrLoad()', '            } else if (profileResolved) {\n                _loadUserProfile()', 'auth-online-silent'],
  ['auth', '            _recheckOrLoad()\n            tokenRefreshed()', '            profileResolved = false\n            _recheckOrLoad()\n            tokenRefreshed()', 'auth-refresh-silent'],
  ['auth', '            _recheckOrLoad()\n            tokenRefreshed()', '            _loadUserProfile()\n            tokenRefreshed()', 'auth-refresh-silent'],
  ['auth', '        if (_sessionOpen()) requestRecheck()\n        else _loadUserProfile()', '        requestRecheck()', 'auth-recheckorload-split'],
  ['auth', '        _lastRecheckMs = now\n        _loadUserProfile(true)', '        _loadUserProfile(true)\n        _lastRecheckMs = now', 'auth-recheck-order'],
  ['auth', '        _lastRecheckMs = now\n        _loadUserProfile(true)\n        return true\n    }', '        _lastRecheckMs = now\n        _loadUserProfile(true)\n        return true\n    }\n    function sneaky() { _loadUserProfile(true) }', 'auth-silent-single-door'],
  ['auth', 'if (!isOnline || !_sessionOpen()) return false', 'if (!_sessionOpen()) return false', 'auth-recheck-gates'],
  ['auth', 'return AuthStore.isAuthenticated && profileResolved && !onboardingNeeded && AuthStore.tenantId.length > 0', 'return AuthStore.isAuthenticated && profileResolved', 'auth-session-open'],
  ['auth', 'if (!SessionRecheck.canStart(false, _lastResumeMs, now)) return', 'if (false) return', 'auth-resume-throttle'],
  ['auth', '        _lastRecheckMs = Date.now()\n        _loadUserProfile()\n    }', '        _loadUserProfile()\n    }', 'auth-tryagain-full'],
  ['auth', '        checking = false\n        if (kind === "none") return', '        if (kind === "none") return\n        checking = false', 'auth-none-returns-early'],
  ['auth', '        checking = false\n        if (kind === "none") return\n        onboardingNeeded = false', '        checking = false\n        onboardingNeeded = false\n        if (kind === "none") return', 'auth-none-returns-early'],
  ['auth', '            : "open"', '            : "none"', 'auth-full-is-open'],
  ['auth', '        tenantContextReady(AuthStore.tenantId, AuthStore.role)\n        if (kind === "role")', '        tenantContextReady(AuthStore.tenantId, AuthStore.role)\n        tenantContextReady(AuthStore.tenantId, AuthStore.role)\n        if (kind === "role")', 'auth-emit-once'],
  ['auth', '    function recheckAccess() {', '    function sneakyEmit() { tenantContextReady("t", "owner") }\n    function recheckAccess() {', 'auth-emit-set'],
  ['auth', 'if (kind === "role") roleChanged(AuthStore.role)', 'if (kind !== "none") roleChanged(AuthStore.role)', 'auth-role-signal'],
  ['auth', '            if (AuthStore.refreshToken !== sentWith) return\n', '', 'auth-refresh-guard'],
  ['auth', '            if (AuthStore.refreshToken !== sentWith) return\n            if (!ok) {', '            if (!ok) {\n            if (AuthStore.refreshToken !== sentWith) return\n', 'auth-refresh-guard'],
  ['auth', '        _profileSeq++\n        checking = false\n        _contextSynced = false\n        profileResolved = true', '        _profileSeq++\n        _contextSynced = false\n        profileResolved = true', 'auth-signout-checking'],
  ['auth', '        checking = false\n        _contextSynced = false\n        profileResolved = true', '        checking = false\n        profileResolved = true', 'auth-signout-synced'],
  ['auth', '        loadTenantMembers()\n        _contextSynced = true\n        tenantContextReady(', '        loadTenantMembers()\n        tenantContextReady(', 'auth-synced-before-emit'],
  ['auth', '                        _contextSynced = true\n                        tenantContextReady(', '                        tenantContextReady(', 'auth-synced-before-emit'],
  ['auth', '            _contextSynced = true\n            tenantContextReady(AuthStore.tenantId, AuthStore.role)\n        })', '            tenantContextReady(AuthStore.tenantId, AuthStore.role)\n        })', 'auth-synced-before-emit'],
  ['auth', '    property bool _contextSynced: false', '    property bool _contextSynced: true', 'auth-declarations'],
  ['auth', 'accessBlock.length > 0, tenantId, out, _contextSynced)', 'accessBlock.length > 0, tenantId, out)', 'auth-full-is-open'],
  ['auth', 'import "../helper/SessionRecheck.js" as SessionRecheck\n', '', 'auth-import'],
  ['auth', '    property bool checking: false', '    property bool checking: true', 'auth-declarations'],
  ['main', 'visible: !AuthStore.isAuthenticated || (AuthStore.isAuthenticated && !AuthService.profileResolved)', 'visible: !AuthStore.isAuthenticated || (AuthStore.isAuthenticated && (!AuthService.profileResolved || AuthService.checking))', 'ui-cover-binding'],
  ['main', 'checking: !AuthService.profileResolved', 'checking: AuthService.checking', 'ui-access-spinner-binding'],
  ['main', '            title: qsTr("Stock")\n            iconType: IconType.archive\n            visible: AuthStore.isAuthenticated', '            title: qsTr("Stock")\n            iconType: IconType.archive\n            visible: AuthStore.isAuthenticated && AuthStore.canViewFinancials', 'ui-tab-role-gated'],
  ['main', '            Toast.show(qsTr("Your role is now %1").arg(role))\n', '', 'main-role-toast'],
  ['main', '            if (!AuthStore.canViewStaff) staffPageOverlay.close()', '            staffPageOverlay.close()', 'main-role-toast'],
];

for (const [which, from, to, rule] of MUTANTS) {
  test(`S-A wiring mutant -> ${rule}: ${to.slice(0, 50).replace(/\s+/g, ' ')}`, () => {
    const src = which === 'auth' ? AUTH : MAIN;
    const hits = src.split(from).length - 1;
    assert.equal(hits, 1, `mutant anchor must occur exactly once (found ${hits}); the source changed, update this mutant`);
    const mutated = src.replace(from, to);
    const got = which === 'auth' ? violations(mutated, MAIN, QML_FILES) : violations(AUTH, mutated, QML_FILES);
    assert.ok(got.includes(rule), `expected rule ${rule}, got [${got}]`);
  });
}

test('S-A wiring mutant -> ui-binds-checking: another file reading AuthService.checking is flagged', () => {
  const files = [...QML_FILES, ['qml/pages/Fake.qml', 'Item { visible: AuthService.checking }']];
  assert.ok(violations(AUTH, MAIN, files).includes('ui-binds-checking'));
});
