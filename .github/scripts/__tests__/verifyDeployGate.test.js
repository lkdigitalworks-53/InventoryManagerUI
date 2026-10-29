'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { checkGate } = require('../verify-deploy-gate');

const reviewer = { type: 'User', reviewer: { login: 'taher', id: 1 } };
const gated = { name: 'firebase-deploy', protection_rules: [{ id: 1, type: 'branch_policy' }, { id: 2, type: 'required_reviewers', prevent_self_review: false, reviewers: [reviewer] }] };

// ---- happy -------------------------------------------------------------------------------------
test('VG01 environment with a required reviewer => ok', () => {
  const r = checkGate(gated);
  assert.equal(r.ok, true);
  assert.match(r.reason, /1 required reviewer/);
});
test('VG02 reviewers are summed across rules; two rules, one valid => ok', () => {
  assert.equal(checkGate({ protection_rules: [{ type: 'required_reviewers', reviewers: [] }, { type: 'required_reviewers', reviewers: [reviewer, reviewer] }] }).reason, '2 required reviewer(s)');
});

// ---- negatives: every way the gate can be missing ----------------------------------------------
test('VG03 auto-created environment (no protection rules) => refused', () => {
  assert.equal(checkGate({ name: 'firebase-deploy', protection_rules: [] }).ok, false);
  assert.equal(checkGate({ name: 'firebase-deploy' }).ok, false);
});
test('VG04 only a branch policy / wait timer, no reviewers rule => refused', () => {
  assert.equal(checkGate({ protection_rules: [{ type: 'branch_policy' }, { type: 'wait_timer', wait_timer: 5 }] }).ok, false);
});
test('VG05 reviewers rule with an empty or missing reviewer list => refused', () => {
  assert.match(checkGate({ protection_rules: [{ type: 'required_reviewers', reviewers: [] }] }).reason, /no reviewer/);
  assert.equal(checkGate({ protection_rules: [{ type: 'required_reviewers' }] }).ok, false);
  assert.equal(checkGate({ protection_rules: [{ type: 'required_reviewers', reviewers: 'taher' }] }).ok, false);
});
test('VG06 malformed input never throws and is refused', () => {
  for (const bad of [null, undefined, 'x', 7, [], true, { protection_rules: 'x' }, { protection_rules: [null, 3, 'a'] }, { protection_rules: {} }]) {
    assert.equal(checkGate(bad).ok, false, JSON.stringify(bad));
  }
});

// ---- monkey ------------------------------------------------------------------------------------
test('VG07 MONKEY: 2000 seeded random environments agree with an independent oracle', () => {
  let seed = 99;
  const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
  const types = ['required_reviewers', 'branch_policy', 'wait_timer', 'x', undefined];
  for (let i = 0; i < 2000; i++) {
    const rules = Array.from({ length: Math.floor(rnd() * 4) }, () => {
      const rule = { type: types[Math.floor(rnd() * types.length)] };
      const k = Math.floor(rnd() * 4);
      if (k === 1) rule.reviewers = [];
      if (k === 2) rule.reviewers = [reviewer];
      if (k === 3) rule.reviewers = [reviewer, reviewer, reviewer];
      return rnd() < 0.1 ? null : rule;
    });
    const env = rnd() < 0.05 ? null : { protection_rules: rules };
    const oracle = !!env && rules.some((r) => r && r.type === 'required_reviewers' && Array.isArray(r.reviewers) && r.reviewers.length > 0);
    assert.equal(checkGate(env).ok, oracle, JSON.stringify(env));
  }
});

// ---- CLI (what the workflow runs) --------------------------------------------------------------
const SCRIPT = path.join(__dirname, '..', 'verify-deploy-gate.js');
const cli = (input) => spawnSync(process.execPath, [SCRIPT], { input, encoding: 'utf8' });

test('VG08 CLI: gated => exit 0 and a confirmation line', () => {
  const r = cli(JSON.stringify(gated));
  assert.equal(r.status, 0);
  assert.match(r.stdout, /Approval gate present/);
});
test('VG09 CLI: ungated => exit 1, GitHub ::error:: annotation naming the fix, nothing on stdout', () => {
  const r = cli(JSON.stringify({ protection_rules: [] }));
  assert.equal(r.status, 1);
  assert.match(r.stderr, /::error::Refusing to deploy/);
  assert.match(r.stderr, /firebase-deploy/);
  assert.equal(r.stdout, '');
});
test('VG10 CLI: invalid JSON, empty stdin, an HTML error page => exit 1 (fail closed)', () => {
  for (const input of ['not json', '', '<html>502</html>', '{"message":"Not Found"}']) {
    assert.equal(cli(input).status, 1, input);
  }
});
