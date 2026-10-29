'use strict';

// EXECUTES .github/scripts/deploy-tag.sh (stale | mark) against real repos with a real bare origin.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { makeRepo } = require('./gitFixture');

const SCRIPT = path.join(__dirname, '..', 'deploy-tag.sh');

/** Linear history c0..c5 pushed to origin. */
function history(n = 6) {
  const repo = makeRepo({ withOrigin: true });
  const c = [];
  for (let i = 0; i < n; i++) c.push(repo.commit({ 'f.txt': `v${i}` }, `c${i}`));
  repo.git('push', '-q', 'origin', 'main');
  return { repo, c };
}
const tagAt = (repo, sha, annotated = false) => {
  if (annotated) repo.git('tag', '-f', '-a', 'deployed-main', '-m', 'deployed', sha);
  else repo.git('tag', '-f', 'deployed-main', sha);
  repo.git('push', '-q', '--force', 'origin', 'refs/tags/deployed-main');
};
const sh = (repo, mode, sha) => repo.run('bash', [SCRIPT, mode], sha === undefined ? {} : { GITHUB_SHA: sha });
const remoteTag = (repo) => repo.ls('refs/tags/deployed-main');
const withHistory = (fn) => { const h = history(); try { return fn(h); } finally { h.repo.cleanup(); } };

// ---- stale -------------------------------------------------------------------------------------
test('DT01 stale: no tag => ok (first deploy)', () => withHistory(({ repo, c }) => {
  assert.equal(sh(repo, 'stale', c[2]).status, 0);
}));
test('DT02 stale: sha NEWER than the tag => ok', () => withHistory(({ repo, c }) => {
  tagAt(repo, c[1]);
  assert.equal(sh(repo, 'stale', c[4]).status, 0);
}));
test('DT03 stale: sha EQUAL to the tag => ok (re-deploying the same commit is allowed)', () => withHistory(({ repo, c }) => {
  tagAt(repo, c[3]);
  assert.equal(sh(repo, 'stale', c[3]).status, 0);
}));
test('DT04 stale: sha OLDER than the tag => refused, loud, mentions the newer commit', () => withHistory(({ repo, c }) => {
  tagAt(repo, c[4]);
  const r = sh(repo, 'stale', c[1]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /::error::.*older than the last deployed commit/);
  assert.match(r.stdout, new RegExp(c[4].slice(0, 7)));
}));
test('DT05 stale: tag on a DIVERGED branch (sha not an ancestor) => ok', () => withHistory(({ repo, c }) => {
  repo.git('checkout', '-q', '-b', 'side', c[1]);
  const side = repo.commit({ 'g.txt': 'side' }, 'side');
  repo.git('checkout', '-q', 'main');
  tagAt(repo, side);
  assert.equal(sh(repo, 'stale', c[5]).status, 0);
}));
test('DT06 stale: works with an ANNOTATED tag', () => withHistory(({ repo, c }) => {
  tagAt(repo, c[4], true);
  assert.equal(sh(repo, 'stale', c[1]).status, 1);
  assert.equal(sh(repo, 'stale', c[4]).status, 0);
  assert.equal(sh(repo, 'stale', c[5]).status, 0);
}));

// ---- mark --------------------------------------------------------------------------------------
test('DT07 mark: no tag => creates it locally and on origin', () => withHistory(({ repo, c }) => {
  const r = sh(repo, 'mark', c[3]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(repo.git('rev-parse', 'refs/tags/deployed-main^{commit}'), c[3]);
  assert.equal(remoteTag(repo), c[3]);
}));
test('DT08 mark: tag behind => moves FORWARD on origin', () => withHistory(({ repo, c }) => {
  tagAt(repo, c[1]);
  assert.equal(sh(repo, 'mark', c[4]).status, 0);
  assert.equal(remoteTag(repo), c[4]);
}));
test('DT09 mark: tag already AHEAD => never moved backwards (origin untouched)', () => withHistory(({ repo, c }) => {
  tagAt(repo, c[4]);
  const r = sh(repo, 'mark', c[1]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /already ahead/);
  assert.equal(remoteTag(repo), c[4]);
  assert.equal(repo.git('rev-parse', 'refs/tags/deployed-main^{commit}'), c[4]);
}));
test('DT10 mark: tag EQUAL => idempotent success', () => withHistory(({ repo, c }) => {
  tagAt(repo, c[3]);
  assert.equal(sh(repo, 'mark', c[3]).status, 0);
  assert.equal(remoteTag(repo), c[3]);
}));
test('DT11 mark: tag on a DIVERGED branch => moves (self-heals after a history rewrite)', () => withHistory(({ repo, c }) => {
  repo.git('checkout', '-q', '-b', 'side', c[1]);
  const side = repo.commit({ 'g.txt': 'side' }, 'side');
  repo.git('checkout', '-q', 'main');
  tagAt(repo, side);
  assert.equal(sh(repo, 'mark', c[5]).status, 0);
  assert.equal(remoteTag(repo), c[5]);
}));
test('DT12 mark: a failing push is LOUD (non-zero), never swallowed', () => withHistory(({ repo, c }) => {
  repo.git('remote', 'set-url', 'origin', path.join(repo.dir, 'no-such-remote.git'));
  const r = sh(repo, 'mark', c[3]);
  assert.notEqual(r.status, 0);
}));

// ---- usage / edge ------------------------------------------------------------------------------
test('DT13 missing GITHUB_SHA, no mode, unknown mode => non-zero (usage = 2)', () => withHistory(({ repo, c }) => {
  assert.notEqual(sh(repo, 'stale', undefined).status, 0);
  assert.notEqual(sh(repo, 'mark', undefined).status, 0);
  assert.equal(sh(repo, '', c[1]).status, 2);
  assert.equal(sh(repo, 'bogus', c[1]).status, 2);
  assert.equal(repo.run('bash', [SCRIPT], { GITHUB_SHA: c[1] }).status, 2);
}));

// ---- exhaustive: every (tag, sha) pair on a 6-commit line --------------------------------------
test('DT14 EXHAUSTIVE: for all 36 (tag, sha) pairs, stale <=> sha strictly older, mark never moves backwards', () => {
  const { repo, c } = history(6);
  try {
    for (let a = 0; a < c.length; a++) {
      tagAt(repo, c[a]);
      for (let b = 0; b < c.length; b++) {
        const stale = sh(repo, 'stale', c[b]);
        assert.equal(stale.status, b < a ? 1 : 0, `stale tag=${a} sha=${b}`);
        const before = remoteTag(repo);
        assert.equal(sh(repo, 'mark', c[b]).status, 0, `mark tag=${a} sha=${b}`);
        const after = remoteTag(repo);
        assert.equal(after, b < a ? before : c[b], `mark tag=${a} sha=${b}`);
        tagAt(repo, c[a]); // reset
      }
    }
  } finally { repo.cleanup(); }
});

test('DT15 the script file is present and starts with a bash shebang', () => {
  assert.ok(fs.existsSync(SCRIPT));
  assert.match(fs.readFileSync(SCRIPT, 'utf8'), /^#!\/usr\/bin\/env bash/);
});
