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
const ifLine = (j) => ((j.match(/^ {4}if:\s*(.*)$/m) || [, ''])[1]);
const before = (j, a, b) => { const x = j.indexOf(a); const y = j.indexOf(b); return x > -1 && y > -1 && x < y; };
const SCRIPTS_DIR = path.join(__dirname, '..');

const RULES = {
  'deploy needs every test job and the check job': (t) => {
    const needs = (job(t, 'deploy').match(/needs:\s*\[([^\]]*)\]/) || [, ''])[1].split(',').map((s) => s.trim());
    return [...TEST_JOBS, 'deploy-check'].every((j) => needs.includes(j));
  },
  'deploy is gated by the approval environment': (t) => /^\s{4}environment:\s*firebase-deploy\s*$/m.test(job(t, 'deploy')),
  'deploy only runs on main and only when the check says so': (t) => {
    const c = ifLine(job(t, 'deploy'));
    return /github\.ref == 'refs\/heads\/main'/.test(c) && /needs\.deploy-check\.outputs\.needed == 'true'/.test(c) && /&&/.test(c);
  },
  'no status-check override can run a job after a red test (always/failure/cancelled)': (t) => {
    const bad = /\b(always|failure|cancelled)\s*\(/;
    return ['deploy', 'mark-deployed', 'deploy-check'].every((id) => job(t, id) !== '' && !bad.test(ifLine(job(t, id))));
  },
  'deploy-check never runs on pull requests': (t) => {
    const j = job(t, 'deploy-check');
    return /github\.ref == 'refs\/heads\/main'/.test(j) && !/pull_request/.test(j) && /github\.event_name == 'push'/.test(j);
  },
  'deploys never overlap and are never cancelled mid-flight': (t) => {
    const j = job(t, 'deploy');
    return /group:\s*firebase-deploy\s*$/m.test(j) && /cancel-in-progress:\s*false/.test(j);
  },
  'no job in the deploy chain uses --force (a deleted function must fail, not delete)': (t) => ['deploy', 'mark-deployed', 'deploy-check'].every((id) => !/--force\b/.test(job(t, id))),
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
  'third-party actions in the deploy chain are pinned to a commit SHA': (t) => {
    const uses = ['deploy', 'mark-deployed', 'deploy-check'].flatMap((id) => [...job(t, id).matchAll(/uses:\s*(\S+)/g)].map((m) => m[1]));
    const third = uses.filter((u) => !u.startsWith('actions/'));
    return third.length > 0 && third.every((u) => /@[0-9a-f]{40}$/.test(u));
  },
  'the approval gate is verified (fail closed) before any third-party code or cloud login': (t) => {
    const j = job(t, 'deploy');
    return /verify-deploy-gate\.js/.test(j) && /set -o pipefail/.test(j) && /actions:\s*read/.test(j)
      && before(j, 'verify-deploy-gate.js', 'npm ci') && before(j, 'verify-deploy-gate.js', 'google-github-actions/auth');
  },
  'an older approved run cannot deploy over newer code': (t) => {
    const j = job(t, 'deploy');
    return /deploy-tag\.sh stale/.test(j) && /fetch-depth:\s*0/.test(j) && before(j, 'deploy-tag.sh stale', 'npm ci') && before(j, 'deploy-tag.sh stale', 'google-github-actions/auth');
  },
  'functions deps are installed without install scripts, before the deploy runs': (t) => {
    const j = job(t, 'deploy');
    return /npm ci --ignore-scripts/.test(j) && before(j, 'npm ci --ignore-scripts', 'firebase-tools@');
  },
  'the deploy job cannot write to the repo and leaves no repo token on disk': (t) => {
    const j = job(t, 'deploy');
    return !/contents:\s*write/.test(j) && /contents:\s*read/.test(j) && /persist-credentials:\s*false/.test(j);
  },
  'a hung deploy cannot hold the lock for hours': (t) => ['deploy', 'mark-deployed', 'deploy-check'].every((id) => /timeout-minutes:\s*\d+/.test(job(t, id))) && Number((job(t, 'deploy').match(/timeout-minutes:\s*(\d+)/) || [, 999])[1]) <= 60,
  'the tag moves in its own job, only after a successful deploy, forward only, with write access and no cloud login': (t) => {
    const j = job(t, 'mark-deployed');
    const needs = (j.match(/needs:\s*\[([^\]]*)\]/) || [, ''])[1].split(',').map((s) => s.trim());
    return needs.includes('deploy') && /contents:\s*write/.test(j) && !/id-token/.test(j) && /deploy-tag\.sh mark/.test(j)
      && !/\bnpm\b|\bnpx\b|firebase-tools/.test(j) && /group:\s*firebase-deploy-mark/.test(j) && /cancel-in-progress:\s*false/.test(j);
  },
  'path filter runs deploy-check.sh (diff vs last deployed tag, fail open) and manual runs skip it': (t) => {
    const j = job(t, 'deploy-check');
    return /bash \.github\/scripts\/deploy-check\.sh/.test(j) && /EVENT:\s*\$\{\{\s*github\.event_name\s*\}\}/.test(j) && /fetch-depth:\s*0/.test(j) && /^ {2}workflow_dispatch:/m.test(stripComments(t));
  },
  'every script the deploy chain calls exists': (t) => {
    const names = new Set(['deploy', 'mark-deployed', 'deploy-check'].flatMap((id) => [...job(t, id).matchAll(/\.github\/scripts\/([\w.-]+)/g)].map((m) => m[1])));
    return names.size >= 3 && [...names].every((n) => fs.existsSync(path.join(SCRIPTS_DIR, n)));
  },
};

const MUTANTS = {
  'deploy needs every test job and the check job': (t) => t.replace('needs: [qml-tests, functions-tests, firestore-rules-tests, e2e-tests, deploy-check]', 'needs: [qml-tests, deploy-check]'),
  'deploy is gated by the approval environment': (t) => t.replace('    environment: firebase-deploy\n', ''),
  'deploy only runs on main and only when the check says so': (t) => t.replace("needs.deploy-check.outputs.needed == 'true' && github.ref == 'refs/heads/main'", "needs.deploy-check.outputs.needed == 'true'"),
  'no status-check override can run a job after a red test (always/failure/cancelled)': (t) => t.replace("if: needs.deploy-check.outputs.needed == 'true' &&", "if: always() && needs.deploy-check.outputs.needed == 'true' &&"),
  'deploy-check never runs on pull requests': (t) => t.replace("(github.event_name == 'push' || github.event_name == 'workflow_dispatch') && github.ref == 'refs/heads/main'", "github.event_name == 'pull_request' || github.ref == 'refs/heads/main'"),
  'deploys never overlap and are never cancelled mid-flight': (t) => t.replace('cancel-in-progress: false\n    # Least privilege', 'cancel-in-progress: true\n    # Least privilege'),
  'no job in the deploy chain uses --force (a deleted function must fail, not delete)': (t) => t.replace('--non-interactive\n', '--non-interactive --force\n'),
  'deploy ships exactly functions + firestore rules + indexes, never storage': (t) => t.replace('functions,firestore:rules,firestore:indexes', 'functions,firestore:rules,firestore:indexes,storage'),
  'deploy is non-interactive and pinned to the one project': (t) => t.replace(' --non-interactive\n', '\n'),
  'firebase-tools is version-pinned': (t) => t.replace('firebase-tools@15.25.1 deploy', 'firebase-tools@latest deploy'),
  'auth is keyless (WIF) and no JSON key secret is used': (t) => t.replace('workload_identity_provider: ${{ vars.GCP_WORKLOAD_IDENTITY_PROVIDER }}', 'credentials_json: ${{ secrets.GCP_KEY }}'),
  'third-party actions in the deploy chain are pinned to a commit SHA': (t) => t.replace('google-github-actions/auth@c200f3691d83b41bf9bbd8638997a462592937ed', 'google-github-actions/auth@v2'),
  'the approval gate is verified (fail closed) before any third-party code or cloud login': (t) => t.replace('| node .github/scripts/verify-deploy-gate.js', '| cat'),
  'an older approved run cannot deploy over newer code': (t) => t.replace('run: bash .github/scripts/deploy-tag.sh stale', 'run: echo skip'),
  'functions deps are installed without install scripts, before the deploy runs': (t) => t.replace('run: npm ci --ignore-scripts', 'run: npm ci'),
  'the deploy job cannot write to the repo and leaves no repo token on disk': (t) => t.replace('persist-credentials: false  # no repo token left on disk for later steps', 'persist-credentials: true'),
  'a hung deploy cannot hold the lock for hours': (t) => t.replace('    timeout-minutes: 45\n', ''),
  'the tag moves in its own job, only after a successful deploy, forward only, with write access and no cloud login': (t) => t.replace('bash .github/scripts/deploy-tag.sh mark', 'git tag -f deployed-main "$GITHUB_SHA" && git push --force origin refs/tags/deployed-main'),
  'path filter runs deploy-check.sh (diff vs last deployed tag, fail open) and manual runs skip it': (t) => t.replace('          EVENT: ${{ github.event_name }}\n', ''),
  'every script the deploy chain calls exists': (t) => t.replace('.github/scripts/verify-deploy-gate.js', '.github/scripts/verify-deploy-gate-MISSING.js'),
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
