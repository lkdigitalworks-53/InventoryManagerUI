'use strict';

// L3 slice A: unit tests for the pure helper qml/helper/SessionRecheck.js (the throttle and the decision
// of what a silent check's answer changes). The same cases run under qmltestrunner in tests/tst_SessionRecheck.qml
// (CI only, no Qt in the sandbox); this file is the one that runs here. Hand mutants at the bottom prove the
// battery bites. Design: docs/superpowers/specs/2026-10-31-l3-session-lifecycle-design.md (L3-D1c, L3-D2a).

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '..', '..', '..');
const SRC = fs.readFileSync(path.join(REPO, 'qml/helper/SessionRecheck.js'), 'utf8');

function load(src) {
  const ctx = vm.createContext({});
  vm.runInContext(src.replace(/^\.pragma library/m, '') + '\n;this.__x = { AUTO_SPACING_MS, STALE_MS, canStart, changeKind }', ctx);
  return ctx.__x;
}

const ROLES = ['owner', 'admin', 'manager', 'staff'];
const enter = (role, verified = true) => ({ action: 'enter', role, verified });
const block = (reason) => ({ action: 'block', reason });
const JUNK = [undefined, null, NaN, Infinity, -Infinity, '', 'x', '1700000000000', true, false, {}, [], () => 1];

// Every assertion of the helper contract, collected instead of thrown so a mutant can be asked "does the
// battery notice you?". Returns the list of failed checks (empty = the module honours the contract).
function battery(m) {
  const fails = [];
  const check = (name, fn) => { try { if (fn() !== true) fails.push(name); } catch (e) { fails.push(name + ' threw ' + e.message); } };
  const T = 1_700_000_000_000;
  const ck = (a, b, c, d, e, ...rest) => m.changeKind(a, b, c, d, e, rest.length ? rest[0] : true);   // an omitted synced means an ordinary open session; an explicit undefined stays undefined

  check('spacing is 60 s', () => m.AUTO_SPACING_MS === 60000);

  // canStart
  check('never started runs (0)', () => m.canStart(false, 0, T) === true);
  check('never started runs (null)', () => m.canStart(false, null, T) === true);
  check('never started runs (undefined)', () => m.canStart(false, undefined, T) === true);
  check('same instant is dropped', () => m.canStart(false, T, T) === false);
  check('1 ms later is dropped', () => m.canStart(false, T, T + 1) === false);
  check('59 999 ms is dropped', () => m.canStart(false, T, T + 59999) === false);
  check('exactly 60 000 ms runs', () => m.canStart(false, T, T + 60000) === true);
  check('60 001 ms runs', () => m.canStart(false, T, T + 60001) === true);
  check('hours later runs', () => m.canStart(false, T, T + 6 * 3600 * 1000) === true);
  check('in flight is dropped even when the 60 s window passed', () => m.canStart(true, T, T + 60000) === false && m.canStart(true, T, T + 119999) === false);
  check('in flight at 0 ms and 1 ms is dropped', () => m.canStart(true, T, T) === false && m.canStart(true, T, T + 1) === false);
  check('a check lost for 120 000 ms may be replaced', () => m.canStart(true, T, T + 120000) === true && m.canStart(true, T, T + 6 * 3600000) === true);
  check('in flight with an unknown start is dropped', () => m.canStart(true, null, T) === false && m.canStart(true, undefined, T) === false && m.canStart(true, NaN, T) === false);
  check('in flight with a backwards clock keeps waiting', () => m.canStart(true, T, T - 1) === false && m.canStart(true, T, T - 3600000) === false);
  check('truthy junk in-flight is dropped', () => m.canStart('yes', T, T + 1000) === false && m.canStart(1, T, T + 59999) === false && m.canStart({}, T, T + 1) === false && m.canStart('yes', T, T + 61000) === false && m.canStart(1, T, T + 119999) === false);
  check('clock went backwards runs', () => m.canStart(false, T, T - 1) === true && m.canStart(false, T, T - 3600000) === true);
  for (const j of JUNK) {
    check('junk now fails to run: ' + String(j), () => m.canStart(false, T, j) === true);
  }
  for (const j of JUNK) {
    check('junk last start fails to run: ' + String(j), () => m.canStart(false, j, T) === true);
  }
  check('junk now but in flight is still dropped', () => JUNK.every((j) => m.canStart(true, T, j) === false));
  check('stale window is 120 s', () => m.STALE_MS === 120000);
  check('window is the same at any start time', () => [0, 1, 86400000, T, 4e12].every((s) => m.canStart(false, s, s + 59999) === false && m.canStart(false, s, s + 60000) === true));

  // changeKind
  for (const r of ROLES) {
    check('same role, same tenant -> none: ' + r, () => ck('t1', r, false, 't1', enter(r)) === 'none');
    check('unreadable answer keeps the held role (verified false) -> none: ' + r, () => ck('t1', r, false, 't1', enter(r, false)) === 'none');
    for (const to of ROLES.filter((x) => x !== r)) {
      check(`role ${r} -> ${to}`, () => ck('t1', r, false, 't1', enter(to)) === 'role');
    }
    check('another tenant, same role -> tenant: ' + r, () => ck('t1', r, false, 't2', enter(r)) === 'tenant');
    check('another tenant wins over a role change: ' + r, () => ck('t1', r, false, 't2', enter(ROLES[(ROLES.indexOf(r) + 1) % 4])) === 'tenant');
    check('was blocked and let in -> unblock even if nothing else changed: ' + r, () => ck('t1', r, true, 't1', enter(r)) === 'unblock');
    check('was blocked, let in as another role/tenant -> unblock: ' + r, () => ck('t1', r, true, 't2', enter('staff')) === 'unblock');
    for (const was of [false, true]) {
      for (const reason of ['removed', 'suspended', 'role', 'unverified']) {
        check(`block ${reason} (wasBlocked ${was}) -> block: ${r}`, () => ck('t1', r, was, 't1', block(reason)) === 'block');
      }
    }
  }
  for (const j of [...JUNK, 'enter', 'block', 5]) {
    check('malformed answer is none: ' + String(j), () => ck('t1', 'owner', false, 't1', j) === 'none');
  }
  check('unknown action is none', () => ck('t1', 'owner', false, 't1', { action: 'noop', role: 'staff' }) === 'none');
  check('enter without a role is none, never an empty role', () => ['', undefined, null, 5, {}, []].every((rl) => ck('t1', 'owner', false, 't1', { action: 'enter', role: rl }) === 'none'));
  check('enter without a role is none even when it was blocked', () => ck('t1', 'owner', true, 't1', { action: 'enter' }) === 'none');
  check('junk previous values never throw and never claim a block', () => JUNK.every((j) => ['none', 'tenant', 'role', 'unblock'].includes(ck(j, j, j, j, enter('staff')))));
  // first resolve: the saved session already holds tenant and role, so "nothing changed" must not skip the first store sync
  for (const r of ROLES) {
    check('not synced yet -> first, even when nothing differs: ' + r, () => ck('t1', r, false, 't1', enter(r), false) === 'first');
    check('not synced yet with an unreadable answer (held role) -> first: ' + r, () => ck('t1', r, false, 't1', enter(r, false), false) === 'first');
    check('synced exactly true -> none: ' + r, () => ck('t1', r, false, 't1', enter(r), true) === 'none');
  }
  check('only exactly true counts as synced', () => [undefined, null, false, 0, 1, 'true', 'yes', {}, [], NaN].every((v) => ck('t1', 'owner', false, 't1', enter('owner'), v) === 'first'));
  check('first beats a tenant or role change (no role toast at first resolve)', () => ck('t1', 'owner', false, 't2', enter('staff'), false) === 'first' && ck('t1', 'admin', false, 't1', enter('staff'), false) === 'first');
  check('unblock beats first', () => ck('t1', 'owner', true, 't1', enter('owner'), false) === 'unblock' && ck('t1', 'owner', true, 't1', enter('owner'), undefined) === 'unblock');
  check('a refusal is block whether or not synced', () => ['removed', 'suspended', 'role', 'unverified'].every((rs) => ck('t1', 'owner', false, 't1', block(rs), false) === 'block' && ck('t1', 'owner', true, 't1', block(rs), undefined) === 'block'));
  check('a malformed answer is none even when not synced', () => [...JUNK, 'enter', 5].every((j) => ck('t1', 'owner', false, 't1', j, false) === 'none') && ck('t1', 'owner', false, 't1', { action: 'enter', role: '' }, false) === 'none');
  check('wasBlocked must be exactly true', () => ['yes', 1, {}, [], 'true'].every((w) => ck('t1', 'owner', w, 't1', enter('owner')) === 'none'));
  return fails;
}

test('the real helper honours the whole contract', () => {
  assert.deepEqual(battery(load(SRC)), []);
});

test('the helper file is plain ES5-style JS a QML engine accepts and exports no more than it should', () => {
  const code = SRC.split('\n').map((l) => l.replace(/\/\/.*$/, '')).join('\n');   // comments may name Date.now
  assert.match(SRC, /^\.pragma library/m);
  assert.doesNotMatch(code, /=>|\blet\b|\bconst\b|\bclass\b|\bimport\b|require\(/, 'QML V4 helpers in this repo use var and function only');
  assert.doesNotMatch(code, /Date\.now|new Date|setTimeout|Qt\./, 'pure: the caller supplies the clock');
  const fns = [...code.matchAll(/^function (\w+)\(/gm)].map((x) => x[1]).sort();
  assert.deepEqual(fns, ['canStart', 'changeKind', 'isNum']);
});

test('the throttle and the lost-check rule match an independent reference over 20 000 seeded cases', () => {
  const m = load(SRC);
  let s = 12345;
  const rnd = () => { s = (s * 1664525 + 1013904223) % 4294967296; return s / 4294967296; };
  // Independent formulation: elapsed time as a number, window as a comparison against a literal.
  const reference = (inFlight, last, now) => {
    const known = typeof now === 'number' && isFinite(now) && typeof last === 'number' && isFinite(last);
    if (inFlight) return known && now - last >= 120000;
    if (!known) return true;
    const elapsed = now - last;
    if (elapsed < 0) return true;
    return elapsed >= 60000;
  };
  for (let i = 0; i < 20000; i++) {
    const last = rnd() < 0.1 ? JUNK[Math.floor(rnd() * JUNK.length)] : Math.floor(rnd() * 5e12);
    const now = rnd() < 0.1 ? JUNK[Math.floor(rnd() * JUNK.length)] : (typeof last === 'number' && isFinite(last) && rnd() < 0.7 ? last + Math.floor(rnd() * 260000) - 5000 : Math.floor(rnd() * 5e12));
    const inFlight = rnd() < 0.3;
    assert.equal(m.canStart(inFlight, last, now), reference(inFlight, last, now), JSON.stringify({ inFlight, last, now }));
  }
});

test('a storm of triggers inside one window yields exactly one start; the next window yields one more', () => {
  const m = load(SRC);
  let last = 0, starts = 0;
  const trigger = (now) => { if (m.canStart(false, last, now)) { last = now; starts++; } };
  const T = 1_700_000_000_000;
  for (let i = 0; i < 500; i++) trigger(T + i * 100);           // 50 s of triggers
  assert.equal(starts, 1);
  for (let i = 0; i < 500; i++) trigger(T + 50000 + i * 100);   // crosses the 60 s mark once
  assert.equal(starts, 2);
});

// ---------------------------------------------------------------------------------------------------------
// Mutants: each one breaks the helper by hand; the battery must notice every one of them.
const MUTANTS = {
  'boundary: >= becomes >': (s) => s.replace('gap >= AUTO_SPACING_MS', 'gap > AUTO_SPACING_MS'),
  'window 59 999': (s) => s.replace('AUTO_SPACING_MS = 60000', 'AUTO_SPACING_MS = 59999'),
  'window 60 001': (s) => s.replace('AUTO_SPACING_MS = 60000', 'AUTO_SPACING_MS = 60001'),
  'window 30 s': (s) => s.replace('AUTO_SPACING_MS = 60000', 'AUTO_SPACING_MS = 30000'),
  'in-flight guard removed': (s) => s.replace(/    if \(inFlight\) return gap >= STALE_MS.*\n/, ''),
  'in-flight guard only for true': (s) => s.replace('if (inFlight) return gap', 'if (inFlight === true) return gap'),
  'a lost check blocks for good': (s) => s.replace('if (inFlight) return gap >= STALE_MS', 'if (inFlight) return false'),
  'stale window 119 999': (s) => s.replace('STALE_MS = 120000', 'STALE_MS = 119999'),
  'stale window 120 001': (s) => s.replace('STALE_MS = 120000', 'STALE_MS = 120001'),
  'stale boundary >= becomes >': (s) => s.replace('return gap >= STALE_MS', 'return gap > STALE_MS'),
  'in flight replaced inside the 60 s window': (s) => s.replace('return gap >= STALE_MS', 'return gap >= AUTO_SPACING_MS'),
  'backwards clock wedges the throttle': (s) => s.replace('return gap < 0 || gap >= AUTO_SPACING_MS', 'return gap >= AUTO_SPACING_MS'),
  'backwards clock replaces a check in flight': (s) => s.replace('return gap >= STALE_MS', 'return gap < 0 || gap >= STALE_MS'),
  'junk clock no longer fails to run': (s) => s.replace('var known = isNum(nowMs) && isNum(lastStartMs)', 'var known = isNum(lastStartMs)'),
  'junk last start no longer fails to run': (s) => s.replace('var known = isNum(nowMs) && isNum(lastStartMs)', 'var known = isNum(nowMs)'),
  'isNum accepts NaN': (s) => s.replace('typeof n === "number" && isFinite(n)', 'typeof n === "number"'),
  'unblock lost': (s) => s.replace('if (wasBlocked === true) return "unblock"', ''),
  'first lost': (s) => s.replace('    if (synced !== true) return "first"\n', ''),
  'first only for explicit false': (s) => s.replace('synced !== true', 'synced === false'),
  'first only for falsy': (s) => s.replace('synced !== true', '!synced && synced !== 1 && synced !== "yes" && synced !== "true"'),
  'first before unblock': (s) => s.replace('    if (wasBlocked === true) return "unblock"\n    if (synced !== true) return "first"\n', '    if (synced !== true) return "first"\n    if (wasBlocked === true) return "unblock"\n'),
  'first after the tenant compare': (s) => s.replace('    if (synced !== true) return "first"\n    if (tenantId !== prevTenantId) return "tenant"\n', '    if (tenantId !== prevTenantId) return "tenant"\n    if (synced !== true) return "first"\n'),
  'first before the malformed guard': (s) => s.replace('    if (out === null || typeof out !== "object") return "none"\n', '    if (synced !== true) return "first"\n    if (out === null || typeof out !== "object") return "none"\n'),
  'unblock on any truthy wasBlocked': (s) => s.replace('wasBlocked === true', 'wasBlocked'),
  'tenant compare inverted': (s) => s.replace('tenantId !== prevTenantId', 'tenantId === prevTenantId'),
  'role compare inverted': (s) => s.replace('out.role !== prevRole', 'out.role === prevRole'),
  'role compare dropped': (s) => s.replace('if (out.role !== prevRole) return "role"', ''),
  'tenant compare dropped': (s) => s.replace('if (tenantId !== prevTenantId) return "tenant"', ''),
  'block answered as none': (s) => s.replace('if (out.action === "block") return "block"', 'if (out.action === "block") return "none"'),
  'malformed answer guard removed': (s) => s.replace('if (out === null || typeof out !== "object") return "none"\n', ''),
  'malformed answer blocks': (s) => s.replace('if (out === null || typeof out !== "object") return "none"', 'if (out === null || typeof out !== "object") return "block"'),
  'empty role accepted': (s) => s.replace(' || typeof out.role !== "string" || out.role.length === 0', ''),
  'unknown action accepted': (s) => s.replace('out.action !== "enter" || ', ''),
};

for (const [name, mutate] of Object.entries(MUTANTS)) {
  test(`mutant is caught: ${name}`, () => {
    const mutated = mutate(SRC);
    assert.notEqual(mutated, SRC, 'the mutation did not apply: the helper text changed, update the mutant');
    assert.ok(battery(load(mutated)).length > 0, 'the battery did not notice this mutant');
  });
}
