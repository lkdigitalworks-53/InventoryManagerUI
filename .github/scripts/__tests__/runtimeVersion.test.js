'use strict';

// The Cloud Functions runtime is named in three places that must agree: firebase.json (what Google runs),
// functions/package.json engines.node (what the CLI and npm check) and every `node-version` in checks.yml
// (what CI tests on). Node 20 was decommissioned on 2026-10-30 and deploys started failing with
// "Runtime Node.js 20 was decommissioned", so a pin below the supported floor also fails here, in the PR.
// Every rule has a mutant; the mutant text must differ from the real text (non-vacuous) and the rule must then fail.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..', '..', '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const FILES = { firebase: read('firebase.json'), pkg: read('functions/package.json'), wf: read('.github/workflows/checks.yml') };

// shortcut: floor is a constant, bump it when Google decommissions the next Node (nodejs22 on 2027-10-31 per Google's runtime table).
const DECOMMISSIONED_MAX = 20;

const runtimeMajor = (f) => Number(((JSON.parse(f.firebase).functions.runtime || '').match(/^nodejs(\d+)$/) || [, NaN])[1]);
const enginesNode = (f) => JSON.parse(f.pkg).engines.node;
const ciNodes = (f) => [...f.wf.matchAll(/^\s*node-version:\s*'?(\d+)'?\s*$/gm)].map((m) => Number(m[1]));

const RULES = {
  'firebase.json runtime is nodejs<major> and engines.node is that same bare major': (f) => /^\d+$/.test(enginesNode(f)) && runtimeMajor(f) === Number(enginesNode(f)),
  'every node-version in checks.yml equals the runtime major (CI tests what Google runs)': (f) => ciNodes(f).length >= 6 && ciNodes(f).every((n) => n === runtimeMajor(f)),
  'the runtime is newer than the last decommissioned Node': (f) => runtimeMajor(f) > DECOMMISSIONED_MAX,
};

const MUTANTS = {
  'firebase.json runtime is nodejs<major> and engines.node is that same bare major': (f) => ({ ...f, firebase: f.firebase.replace('"nodejs24"', '"nodejs22"') }),
  'every node-version in checks.yml equals the runtime major (CI tests what Google runs)': (f) => ({ ...f, wf: f.wf.replace("node-version: '24'", "node-version: '22'") }),
  'the runtime is newer than the last decommissioned Node': (f) => ({ firebase: f.firebase.replace('"nodejs24"', '"nodejs20"'), pkg: f.pkg.replace('"node": "24"', '"node": "20"'), wf: f.wf.replaceAll("node-version: '24'", "node-version: '20'") }),
};

for (const [name, rule] of Object.entries(RULES)) {
  test(`RV rule holds: ${name}`, () => assert.equal(rule(FILES), true));
  test(`RV mutant is caught: ${name}`, () => {
    const mutant = MUTANTS[name](FILES);
    assert.notDeepEqual(mutant, FILES, 'vacuous mutant');
    assert.equal(rule(mutant), false);
  });
}

test('RV every rule has a mutant', () => assert.deepEqual(Object.keys(MUTANTS).sort(), Object.keys(RULES).sort()));

test('RV the parsers read nothing from a malformed file (NaN / empty, never a throw or a pass)', () => {
  assert.equal(Number.isNaN(runtimeMajor({ firebase: '{"functions":{}}' })), true);
  assert.equal(Number.isNaN(runtimeMajor({ firebase: '{"functions":{"runtime":"python312"}}' })), true);
  assert.deepEqual(ciNodes({ wf: 'steps: []' }), []);
  assert.equal(RULES['every node-version in checks.yml equals the runtime major (CI tests what Google runs)']({ ...FILES, wf: 'steps: []' }), false);
});
