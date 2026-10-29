'use strict';

/**
 * Decides whether a set of changed files needs a Firebase deploy (functions, firestore rules,
 * firestore indexes). Used (through `deploy-check.sh`) by the `deploy-check` job in `.github/workflows/checks.yml` so a
 * docs-only or QML-only merge does not ask Taher for a deploy approval.
 *
 * Pure function plus a tiny stdin CLI:  git diff --name-only --no-renames -z A B | node deploy-paths.js  -> true|false
 * The CLI splits on NUL (git -z: raw paths, no quoting of non-ASCII names) and on newlines.
 *
 * Deliberately NOT deployed: storage.rules (out of scope, Taher 2026-10-28) and functions/test/
 * (tests are not part of the deployed behaviour; a test-only change must not ping for approval).
 */

const DEPLOY_PATHS = [
  /^functions\//,
  /^firestore\.rules$/,
  /^firestore\.indexes\.json$/,
  /^firebase\.json$/,
];
const IGNORED = /^functions\/test\//;

/**
 * @param {unknown} files changed paths, repo-relative, forward slashes
 * @returns {boolean}
 */
function needsDeploy(files) {
  if (!Array.isArray(files)) return false;
  return files.some((f) => {
    if (typeof f !== 'string') return false;
    const p = f.trim();
    return DEPLOY_PATHS.some((re) => re.test(p)) && !IGNORED.test(p);
  });
}

if (require.main === module) {
  let input = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => { input += chunk; });
  process.stdin.on('end', () => { console.log(String(needsDeploy(input.split(/[\0\n]/)))); });
}

module.exports = { needsDeploy };
