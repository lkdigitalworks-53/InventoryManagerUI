'use strict';

// EXECUTES .github/scripts/deploy-check.sh against real throwaway git repos (not a text check).

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { makeRepo } = require('./gitFixture');
const { needsDeploy } = require('../deploy-paths');

const SCRIPT = path.join(__dirname, '..', 'deploy-check.sh');

/** Repo with a base commit tagged deployed-main, then `files` committed on top. Returns {repo, base, head}. */
function scenario(files, { tag = true } = {}) {
  const repo = makeRepo();
  const base = repo.commit({ 'README.md': 'x', 'functions/index.js': 'a', 'functions/test/a.test.js': 't', 'docs/a.md': 'd' }, 'base');
  if (tag) repo.git('tag', 'deployed-main', base);
  const head = repo.commit(files, 'change');
  return { repo, base, head };
}
const check = (repo, head, env) => {
  const r = repo.run('bash', [SCRIPT], { GITHUB_SHA: head, ...(env || {}) });
  return { out: r.stdout.trim(), status: r.status };
};
const withRepo = (files, opts, fn) => {
  const s = scenario(files, opts);
  try { return fn(s); } finally { s.repo.cleanup(); }
};

// ---- happy path --------------------------------------------------------------------------------
test('DC01 functions source change => true', () => withRepo({ 'functions/index.js': 'b' }, {}, ({ repo, head }) => {
  assert.deepEqual(check(repo, head), { out: 'true', status: 0 });
}));
test('DC02 every deployable artifact => true (rules, indexes, firebase.json, functions/package.json)', () => {
  for (const f of ['firestore.rules', 'firestore.indexes.json', 'firebase.json', 'functions/package.json', 'functions/lib/x.js']) {
    withRepo({ [f]: 'new' }, {}, ({ repo, head }) => assert.equal(check(repo, head).out, 'true', f));
  }
});

// ---- negatives ---------------------------------------------------------------------------------
test('DC03 docs / QML / CI-only change => false', () => withRepo({ 'docs/b.md': 'x', 'qml/A.qml': 'x', '.github/workflows/checks.yml': 'x' }, {}, ({ repo, head }) => {
  assert.deepEqual(check(repo, head), { out: 'false', status: 0 });
}));
test('DC04 functions/test only => false', () => withRepo({ 'functions/test/a.test.js': 'changed' }, {}, ({ repo, head }) => {
  assert.equal(check(repo, head).out, 'false');
}));
test('DC05 nothing new since the tag (head == tag) => false', () => withRepo({}, {}, ({ repo, base }) => {
  assert.equal(check(repo, base).out, 'false');
}));

// ---- the fail-open rules -----------------------------------------------------------------------
test('DC06 no deployed-main tag yet => true (first deploy)', () => withRepo({ 'docs/b.md': 'x' }, { tag: false }, ({ repo, head }) => {
  assert.equal(check(repo, head).out, 'true');
}));
test('DC07 workflow_dispatch always => true, even for a docs-only diff', () => withRepo({ 'docs/b.md': 'x' }, {}, ({ repo, head }) => {
  assert.equal(check(repo, head, { EVENT: 'workflow_dispatch' }).out, 'true');
  assert.equal(check(repo, head, { EVENT: 'push' }).out, 'false');
}));
test('DC08 git cannot diff (unknown sha) => true, exit 0', () => withRepo({ 'docs/b.md': 'x' }, {}, ({ repo }) => {
  assert.deepEqual(check(repo, 'deadbeef'.repeat(5)), { out: 'true', status: 0 });
}));
test('DC09 paths helper prints junk or crashes => true (never trust a non-boolean answer)', () => withRepo({ 'docs/b.md': 'x' }, {}, ({ repo, head }) => {
  const shim = fs.mkdtempSync(path.join(os.tmpdir(), 'shim-'));
  try {
    for (const body of ['echo banana', 'exit 3', 'echo false; exit 1']) {
      fs.writeFileSync(path.join(shim, 'node'), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
      const r = repo.run('bash', [SCRIPT], { GITHUB_SHA: head, PATH: `${shim}:${process.env.PATH}` });
      assert.equal(r.stdout.trim(), 'true', body);
    }
  } finally { fs.rmSync(shim, { recursive: true, force: true }); }
}));

// ---- the two blind spots this script exists to close -------------------------------------------
test('DC10 a file MOVED OUT of functions/ still deploys (rename shows as deletion)', () => {
  const repo = makeRepo();
  try {
    const base = repo.commit({ 'functions/old.js': 'same body\n'.repeat(20), 'docs/a.md': 'd' }, 'base');
    repo.git('tag', 'deployed-main', base);
    repo.git('mv', 'functions/old.js', 'docs/old.js');
    repo.git('commit', '-qm', 'move');
    const head = repo.git('rev-parse', 'HEAD');
    // non-vacuous: with git's default rename detection the old path is NOT listed
    assert.equal(repo.git('diff', '--name-only', base, head), 'docs/old.js');
    assert.equal(check(repo, head).out, 'true');
  } finally { repo.cleanup(); }
});
test('DC11 a NON-ASCII functions/ path still deploys (git would quote it)', () => withRepo({ 'functions/é.js': 'x' }, {}, ({ repo, base, head }) => {
  // non-vacuous: plain `git diff --name-only` quotes the name, so a prefix match on it would miss
  assert.match(repo.git('diff', '--name-only', base, head), /^"functions\/\\303\\251\.js"$/);
  assert.equal(check(repo, head).out, 'true');
}));
test('DC12 a docs-only NON-ASCII path stays false', () => withRepo({ 'docs/é.md': 'x', 'qml/日本.qml': 'x' }, {}, ({ repo, head }) => {
  assert.equal(check(repo, head).out, 'false');
}));
test('DC13 a BRANCH named deployed-main must not stand in for the TAG', () => {
  const repo = makeRepo();
  try {
    const base = repo.commit({ 'functions/index.js': 'a' }, 'base');
    const head = repo.commit({ 'functions/index.js': 'b' }, 'change');
    // branch only, no tag: a bare-name lookup would find the branch (diff empty => false). It is a first deploy => true.
    repo.git('branch', 'deployed-main', head);
    assert.equal(check(repo, head).out, 'true');
    // tag AND same-named branch: the tag decides (git prefers tags; the explicit refs/tags/ path keeps it that way)
    repo.git('tag', 'deployed-main', base);
    assert.equal(check(repo, head).out, 'true');
  } finally { repo.cleanup(); }
});
test('DC14 deleting a deployable file deploys', () => withRepo({ 'functions/index.js': null }, {}, ({ repo, head }) => {
  assert.equal(check(repo, head).out, 'true');
}));

// ---- monkey: random histories agree with an independent oracle ---------------------------------
test('DC15 MONKEY: 30 seeded random change sets agree with needsDeploy over git\'s own file list', () => {
  const pool = ['functions/index.js', 'functions/lib/a.js', 'functions/test/t.js', 'firestore.rules', 'firestore.indexes.json',
    'firebase.json', 'storage.rules', 'docs/a.md', 'qml/A.qml', 'sub/firebase.json', 'functions/é.js', 'docs/é.md', 'README.md'];
  let seed = 7;
  const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
  for (let i = 0; i < 30; i++) {
    const files = {};
    const n = 1 + Math.floor(rnd() * 3);
    for (let j = 0; j < n; j++) files[pool[Math.floor(rnd() * pool.length)]] = `v${i}-${j}`;
    withRepo(files, {}, ({ repo, base, head }) => {
      const listed = repo.git('-c', 'core.quotePath=false', 'diff', '--name-only', '--no-renames', base, head).split('\n');
      assert.equal(check(repo, head).out, String(needsDeploy(listed)), JSON.stringify(files));
    });
  }
});

test('DC16 the script file is present and executable-by-bash', () => {
  assert.ok(fs.existsSync(SCRIPT));
  assert.match(fs.readFileSync(SCRIPT, 'utf8'), /^#!\/usr\/bin\/env bash/);
});
