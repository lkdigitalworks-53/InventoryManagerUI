'use strict';

// Pins the safety properties of the Firebase deploy jobs in checks.yml. The workflow cannot run in the
// sandbox, so these source checks are the only thing that notices if a later edit weakens the gate.
// Every rule is mutated: the mutant text must exist (non-vacuous) and the rule must then fail.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const WORKFLOW = fs.readFileSync(path.join(__dirname, '..', '..', 'workflows', 'checks.yml'), 'utf8');

const stripComments = (t) => t.split('\n').map((l) => l.replace(/^\s*#.*$/, '').replace(/\s+#\s.*$/, '')).join('\n');

// A job block = from "  <id>:" at 2-space indent up to the next 2-space-indent key (or EOF).
function job(text, id) {
  const lines = stripComments(text).split('\n');
  const start = lines.findIndex((l) => l === `  ${id}:`);
  if (start < 0) return '';
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^ {2}[A-Za-z0-9_-]+:\s*$/.test(lines[i])) { end = i; break; }
  }
  return lines.slice(start, end).join('\n');
}

const TEST_JOBS = ['qml-tests', 'functions-tests', 'firestore-rules-tests', 'e2e-tests'];

const RULES = {
  'deploy needs every test job and the check job': (t) => {
    const needs = (job(t, 'deploy').match(/needs:\s*\[([^\]]*)\]/) || [, ''])[1].split(',').map((s) => s.trim());
    return [...TEST_JOBS, 'deploy-check'].every((j) => needs.includes(j));
  },
  'deploy is gated by the approval environment': (t) => /^\s{4}environment:\s*firebase-deploy\s*$/m.test(job(t, 'deploy')),
  'deploy only runs on main': (t) => /github\.ref == 'refs\/heads\/main'/.test(job(t, 'deploy')),
  'deploy-check never runs on pull requests': (t) => {
    const j = job(t, 'deploy-check');
    return /github\.ref == 'refs\/heads\/main'/.test(j) && !/pull_request/.test(j) && /github\.event_name == 'push'/.test(j);
  },
  'deploys never overlap and are never cancelled mid-flight': (t) => {
    const j = job(t, 'deploy');
    return /group:\s*firebase-deploy/.test(j) && /cancel-in-progress:\s*false/.test(j);
  },
  'deploy has no --force (a deleted function must fail, not delete)': (t) => !/--force\b/.test(job(t, 'deploy').replace(/git push --force origin/g, '')),
  'deploy ships exactly functions + firestore rules + indexes, never storage': (t) => {
    const m = job(t, 'deploy').match(/firebase-tools@[\d.]+ deploy --only (\S+)/);
    return !!m && m[1].split(',').sort().join() === 'firestore:indexes,firestore:rules,functions' && !/storage/.test(m[1]);
  },
  'deploy is non-interactive and pinned to the one project': (t) => {
    const j = job(t, 'deploy');
    return /--non-interactive/.test(j) && /--project inventorymanager-48392/.test(j);
  },
  'firebase-tools is version-pinned': (t) => /firebase-tools@\d+\.\d+\.\d+ deploy/.test(job(t, 'deploy')),
  'auth is keyless (WIF) and no JSON key secret is used': (t) => {
    const j = job(t, 'deploy');
    return /id-token:\s*write/.test(j) && /workload_identity_provider:/.test(j) && !/credentials_json|secrets\./.test(j);
  },
  'functions deps are installed before the deploy runs': (t) => {
    const j = job(t, 'deploy');
    const i = j.indexOf('npm ci');
    return i > -1 && i < j.indexOf('firebase-tools@');
  },
  'the deployed commit is recorded only after the deploy step': (t) => {
    const j = job(t, 'deploy');
    const d = j.indexOf('firebase-tools@');
    const r = j.indexOf('tag -f deployed-main');
    return d > -1 && r > d && /contents:\s*write/.test(j);
  },
  'path filter diffs against the last deployed tag and fails open to "deploy"': (t) => {
    const j = job(t, 'deploy-check');
    return /git diff --name-only deployed-main/.test(j) && /needed=true/.test(j) && /fetch-depth:\s*0/.test(j);
  },
  'manual re-run (workflow_dispatch) is declared and skips the path filter': (t) => /^ {2}workflow_dispatch:/m.test(stripComments(t)) && /\$EVENT" != "workflow_dispatch"/.test(job(t, 'deploy-check')),
};

const MUTANTS = {
  'deploy needs every test job and the check job': (t) => t.replace('needs: [qml-tests, functions-tests, firestore-rules-tests, e2e-tests, deploy-check]', 'needs: [qml-tests, deploy-check]'),
  'deploy is gated by the approval environment': (t) => t.replace('    environment: firebase-deploy\n', ''),
  'deploy only runs on main': (t) => t.replace("needs.deploy-check.outputs.needed == 'true' && github.ref == 'refs/heads/main'", "needs.deploy-check.outputs.needed == 'true'"),
  'deploy-check never runs on pull requests': (t) => t.replace("(github.event_name == 'push' || github.event_name == 'workflow_dispatch') && github.ref == 'refs/heads/main'", "github.event_name == 'pull_request' || github.ref == 'refs/heads/main'"),
  'deploys never overlap and are never cancelled mid-flight': (t) => t.replace('cancel-in-progress: false\n    permissions:\n      contents: write', 'cancel-in-progress: true\n    permissions:\n      contents: write'),
  'deploy has no --force (a deleted function must fail, not delete)': (t) => t.replace('--non-interactive\n', '--non-interactive --force\n'),
  'deploy ships exactly functions + firestore rules + indexes, never storage': (t) => t.replace('functions,firestore:rules,firestore:indexes', 'functions,firestore:rules,firestore:indexes,storage'),
  'deploy is non-interactive and pinned to the one project': (t) => t.replace(' --non-interactive\n', '\n'),
  'firebase-tools is version-pinned': (t) => t.replace('firebase-tools@15.25.1 deploy', 'firebase-tools@latest deploy'),
  'auth is keyless (WIF) and no JSON key secret is used': (t) => t.replace('workload_identity_provider: ${{ vars.GCP_WORKLOAD_IDENTITY_PROVIDER }}', 'credentials_json: ${{ secrets.GCP_KEY }}'),
  'functions deps are installed before the deploy runs': (t) => t.replace('        run: npm ci\n\n      - uses: google-github-actions/auth@v2', '        run: echo skip\n\n      - uses: google-github-actions/auth@v2'),
  'the deployed commit is recorded only after the deploy step': (t) => t.replace('git tag -f deployed-main "$GITHUB_SHA"\n          git push --force origin refs/tags/deployed-main\n', ''),
  'path filter diffs against the last deployed tag and fails open to "deploy"': (t) => t.replace('git diff --name-only deployed-main "$GITHUB_SHA"', 'git diff --name-only HEAD~1 "$GITHUB_SHA"'),
  'manual re-run (workflow_dispatch) is declared and skips the path filter': (t) => t.replace('  workflow_dispatch:\n', ''),
};

test('DW00 the workflow defines both deploy jobs', () => {
  assert.notEqual(job(WORKFLOW, 'deploy'), '');
  assert.notEqual(job(WORKFLOW, 'deploy-check'), '');
});

for (const [name, rule] of Object.entries(RULES)) {
  test(`DW rule holds: ${name}`, () => assert.equal(rule(WORKFLOW), true));
  test(`DW mutant is caught: ${name}`, () => {
    const mutant = MUTANTS[name](WORKFLOW);
    assert.notEqual(mutant, WORKFLOW, `mutant for "${name}" changed nothing (vacuous)`);
    assert.equal(rule(mutant), false);
  });
}

test('DW every rule has a mutant', () => {
  assert.deepEqual(Object.keys(MUTANTS).sort(), Object.keys(RULES).sort());
});

test('DW comments are ignored: a rule cannot be satisfied by a comment', () => {
  // The workflow carries the word "--force" and "workflow_dispatch" in comments; stripping must hide them.
  const only = `  deploy:\n    steps:\n      # firebase deploy --force would be bad\n      - run: echo hi\n  next:\n`;
  assert.equal(/--force/.test(job(only, 'deploy')), false);
});

test('DW the existing test jobs still exist (the gate must have something to wait for)', () => {
  for (const id of TEST_JOBS) assert.notEqual(job(WORKFLOW, id), '', id);
});
