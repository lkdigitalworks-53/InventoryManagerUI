'use strict';

// Throwaway git repos for the deploy-script tests. Hermetic: no global/system git config, no network.
// Not a test file (no .test.js suffix), so `node --test .github/scripts/__tests__/*.test.js` skips it.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ENV = {
  ...process.env,
  GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_CONFIG_NOSYSTEM: '1',
  GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.com',
  GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.com',
};
delete ENV.GITHUB_SHA;
delete ENV.EVENT;

function run(cmd, args, cwd, extraEnv) {
  const r = spawnSync(cmd, args, { cwd, env: { ...ENV, ...(extraEnv || {}) }, encoding: 'utf8' });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr };
}

/** A repo on branch `main` with an optional bare `origin`. */
function makeRepo({ withOrigin = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'deploy-fx-'));
  const dir = path.join(root, 'work');
  fs.mkdirSync(dir);
  const git = (...args) => {
    const r = run('git', args, dir);
    if (r.status !== 0) throw new Error(`git ${args.join(' ')} failed: ${r.stderr}`);
    return r.stdout.trim();
  };
  git('init', '-q', '-b', 'main');
  let origin = null;
  if (withOrigin) {
    origin = path.join(root, 'origin.git');
    run('git', ['init', '-q', '--bare', origin], root);
    git('remote', 'add', 'origin', origin);
  }
  let n = 0;
  /** files: { path: content | null (delete) }. Returns the new commit sha. */
  const commit = (files, msg) => {
    for (const [p, content] of Object.entries(files || {})) {
      const abs = path.join(dir, p);
      if (content === null) { fs.rmSync(abs, { force: true }); continue; }
      fs.mkdirSync(path.dirname(abs), { recursive: true });
      fs.writeFileSync(abs, content);
    }
    git('add', '-A');
    n += 1;
    git('commit', '-q', '--allow-empty', '-m', msg || `c${n}`);
    return git('rev-parse', 'HEAD');
  };
  return {
    dir, origin, git, commit,
    run: (cmd, args, env) => run(cmd, args, dir, env),
    ls: (ref) => run('git', ['ls-remote', origin, ref], dir).stdout.trim().split(/\s+/)[0] || '',
    cleanup: () => fs.rmSync(root, { recursive: true, force: true }),
  };
}

module.exports = { makeRepo };
