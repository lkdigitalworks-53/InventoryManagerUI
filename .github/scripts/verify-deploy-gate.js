'use strict';

/**
 * Fail-closed check that the GitHub Environment `firebase-deploy` really has an approval gate.
 *
 * Why: a workflow that names an Environment which does not exist AUTO-CREATES it with NO protection
 * rules, and the job then runs without anyone approving. The whole "one-tap approval" design would be a
 * no-op (and the repo is public, so nothing else warns). This runs as the first step of the deploy job,
 * before any third-party code and before cloud login, so a missing gate deploys nothing.
 *
 *   curl -fsS .../environments/firebase-deploy | node verify-deploy-gate.js   (exit 0 = gate present)
 */

/**
 * @param {unknown} env parsed `GET /repos/{owner}/{repo}/environments/{name}` response
 * @returns {{ok: boolean, reason: string}}
 */
function checkGate(env) {
  if (!env || typeof env !== 'object' || Array.isArray(env)) return { ok: false, reason: 'environment response is not an object' };
  const rules = Array.isArray(env.protection_rules) ? env.protection_rules : [];
  const required = rules.filter((r) => r && r.type === 'required_reviewers');
  if (required.length === 0) return { ok: false, reason: 'no "required reviewers" rule on the environment' };
  const reviewers = required.reduce((n, r) => n + (Array.isArray(r.reviewers) ? r.reviewers.length : 0), 0);
  if (reviewers === 0) return { ok: false, reason: 'the "required reviewers" rule lists no reviewer' };
  return { ok: true, reason: `${reviewers} required reviewer(s)` };
}

if (require.main === module) {
  let input = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => { input += chunk; });
  process.stdin.on('end', () => {
    let env;
    try { env = JSON.parse(input); } catch (e) { env = null; }
    const { ok, reason } = checkGate(env);
    if (ok) { console.log(`Approval gate present: ${reason}.`); return; }
    console.error(`::error::Refusing to deploy: ${reason}. Create/repair the Environment "firebase-deploy" with a required reviewer (see docs/superpowers/specs/2026-10-28-ci-deploy-on-merge-design.md). Nothing was deployed.`);
    process.exitCode = 1;
  });
}

module.exports = { checkGate };
