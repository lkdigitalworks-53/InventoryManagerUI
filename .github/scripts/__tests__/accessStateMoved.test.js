'use strict';

// PR #180 Q2/Q4 unit tests for qml/helper/AccessState.js: the "moved" state and roleLabel. The same cases run in
// the Qt JS engine in tests/tst_AccessState.qml (CI only). Hand mutants at the bottom prove the battery bites.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const SRC = fs.readFileSync(path.resolve(__dirname, '..', '..', '..', 'qml/helper/AccessState.js'), 'utf8');
const load = (src) => {
  const ctx = vm.createContext({});
  vm.runInContext(src.replace(/^\.pragma library/m, '') + '\n;this.__x = { STATE_MOVED, ROLE_LABELS, isBlockedState, roleLabel, copy, classify, outcome, isValidRole, VALID_ROLES }', ctx);
  return ctx.__x;
};
const JUNK = [undefined, null, NaN, '', ' ', 'x', 0, 1, true, false, {}, [], ['owner'], () => 1, '<b>x</b>'];

function battery(m) {
  const f = [];
  const check = (n, fn) => { try { if (fn() !== true) f.push(n); } catch (e) { f.push(n + ' threw ' + e.message); } };
  check('state id', () => m.STATE_MOVED === 'moved');
  check('five blocked states', () => ['removed', 'suspended', 'role', 'unverified', 'moved'].every((s) => m.isBlockedState(s)));
  check('junk is not a blocked state', () => [...JUNK, 'Moved', 'ok'].every((s) => !m.isBlockedState(s)));
  check('roleLabel four', () => m.roleLabel('owner') === 'Owner' && m.roleLabel('admin') === 'Admin' && m.roleLabel('manager') === 'Manager' && m.roleLabel('staff') === 'Staff');
  check('roleLabel covers every valid role', () => m.VALID_ROLES.every((r) => typeof m.ROLE_LABELS[r] === 'string' && m.ROLE_LABELS[r].length > 0) && Object.keys(m.ROLE_LABELS).length === m.VALID_ROLES.length);
  check('roleLabel never echoes a raw value', () => [...JUNK, 'Owner', ' owner', 'viewer', 'toString', '__proto__', 'constructor'].every((r) => m.roleLabel(r) === 'a new role'));
  check('copy moved with a name', () => { const c = m.copy('moved', 'Beta Traders'); return c.title === 'Your workspace changed' && c.body.startsWith('Your account now uses Beta Traders. Tap Continue'); });
  check('copy moved without a name', () => [undefined, null, '', ' ', '\n\t', 0, 5, {}, [], true].every((n) => m.copy('moved', n).body.startsWith('Your account now uses a different shop. Tap Continue')));
  check('copy moved name is single line and capped', () => m.copy('moved', ' A\nB ').body.startsWith('Your account now uses A B. ') && m.copy('moved', 'a'.repeat(5000)).body.length < 300);
  check('copy moved never empty and says Continue', () => { const c = m.copy('moved', 'x'); return c.title.length > 0 && /Tap Continue/.test(c.body); });
  check('classify never produces moved', () => [[false, 500, null], [false, 404, null], [true, 200, {}], [true, 200, { status: 'active', role: 'staff' }], [false, 0, 'x']].every((a) => m.classify(...a).state !== 'moved'));
  check('failed check keeps moved', () => [[false, 500, null], [false, 0, null], [true, 200, 'junk'], [true, 200, null]].every((a) => { const o = m.outcome(m.classify(...a), 'owner', 'moved'); return o.action === 'block' && o.reason === 'moved'; }));
  check('conclusive answer beats moved', () => m.outcome(m.classify(true, 200, { status: 'active', role: 'staff' }), 'owner', 'moved').action === 'enter' && m.outcome(m.classify(false, 404, null), 'owner', 'moved').reason === 'removed' && m.outcome(m.classify(true, 200, { status: 'suspended', role: 'staff' }), '', 'moved').reason === 'suspended');
  check('other copy unchanged', () => m.copy('unverified', 'S').title === 'Could not check your access' && m.copy('removed', 'S').title === 'Your access was removed');
  return f;
}

test('the real AccessState honours the moved / roleLabel contract', () => assert.deepEqual(battery(load(SRC)), []));

const MUTANTS = {
  'moved not blocked': (s) => s.replace(' || state === STATE_UNVERIFIED || state === STATE_MOVED', ' || state === STATE_UNVERIFIED'),
  'moved id changed': (s) => s.replace('var STATE_MOVED = "moved"', 'var STATE_MOVED = "changed"'),
  'roleLabel echoes raw': (s) => s.replace('isValidRole(role) ? ROLE_LABELS[role] : "a new role"', 'ROLE_LABELS[role] || role'),
  'roleLabel accepts inherited keys': (s) => s.replace('isValidRole(role) ? ROLE_LABELS[role] : "a new role"', 'ROLE_LABELS[role] !== undefined ? ROLE_LABELS[role] : "a new role"').replace('var ROLE_LABELS = {', 'var ROLE_LABELS = Object.assign(Object.create({ toString: "T" }), {').replace('staff: "Staff" }', 'staff: "Staff" })'),
  'label typo': (s) => s.replace('admin: "Admin"', 'admin: "Administrator"'),
  'fallback label changed': (s) => s.replace(': "a new role"\n', ': "role"\n'),
  'moved copy missing': (s) => s.replace('    case STATE_MOVED:', '    case "nope":'),
  'moved copy always names the shop': (s) => s.replace('_hasName(shopName)\n                        ?', 'true\n                        ?'),
  'moved copy forgets Continue': (s) => s.replace('Tap Continue to reload', 'Reload'),
  'moved copy title changed': (s) => s.replace('Your workspace changed', 'Changed'),
};
for (const [name, mutate] of Object.entries(MUTANTS)) {
  test(`mutant is caught: ${name}`, () => {
    const m = mutate(SRC);
    assert.notEqual(m, SRC, 'the mutation did not apply');
    assert.ok(battery(load(m)).length > 0, 'not noticed');
  });
}
