# CHECKPOINT — 2026-10-29 review sweep of PR #173 (CI deploy-on-merge) — resume here

**Branch:** `ci/2026-10-28-deploy-on-merge` (PR #173 head; fixes go on the SAME branch/PR). Base `main` @ `fbd7dec`.
**Commit identity:** `tsadmin@gmail.com`. PAT from the chat prompt only, via `git -c http.extraHeader=...` (helper `/home/claude/gitp.sh` in the sandbox, lost on a new session: recreate). Never in remote URL/config/repo. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in sandbox (CI is the QML oracle); push without asking; tests + test plan for every change; caveman FULL in chat only; keep scope per turn small, state in remote branch.
**Skills run:** requesting-code-review, ponytail-audit, qt-ui-design, qt-qml-review. **Qt skills: N/A** (PR touches no QML/C++; only `.github/**` + docs).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-29-pr170-sweep-prev-CHECKPOINT.md`.

## Facts checked against the live repo (GitHub API, 2026-10-29)
- Repo is **public**, id `1151883837`, owner id `256964261`. No branch protection on `main`.
- **Environment `firebase-deploy` does NOT exist yet.** No `deployed-main` tag yet.
- `google-github-actions/auth` `v2` = `v2.1.13` = `c200f3691d83b41bf9bbd8638997a462592937ed` (checked).
- `firebase-tools@15.25.1` exists, published 2026-07-30 (>14 days), Node >=20 OK. Newer exists (15.34.2), pin is deliberate.
- Functions are v2 (`firebase-functions/v2/*`), no custom runtime service account => default compute SA at runtime.

## Findings (numbered; F = fix in this PR, D = documented, A = accepted)
1. **F** Approval gate can be absent: a workflow that names a missing Environment AUTO-CREATES it with NO reviewers; the job then runs unapproved. Env does not exist today. Fix: runtime fail-closed gate check (`verify-deploy-gate.js`) + doc order "arm GCP last".
2. **F/D** WIF bound to `attribute.repository` only: ANY branch workflow in the repo can mint a token and deploy, bypassing the Environment. Fix (doc): provider condition = repository_id + owner_id + `sub` of the Environment + `ref == main`.
3. **D** `roles/iam.serviceAccountUser` at project level lets the deploy SA act as any SA (privilege escalation). Fix (doc): bind on the runtime SA only.
4. **F** Stale deploy: an older approved run could overwrite newer code and move the tag backwards. Fix: `deploy-tag.sh stale` guard + forward-only tag move.
5. **F** Path filter blind spots: renames (`functions/x.js` -> `docs/x.js` shows only the new path) and non-ASCII names (git quotes them). Fix: `--no-renames`, `-z`, NUL-aware script.
6. **F** Job that runs `npm ci` + `npx` holds `contents: write` + persisted token + `id-token`. Fix: split tag move into `mark-deployed` job; deploy = `contents: read`, `persist-credentials: false`.
7. **F** No `timeout-minutes`: a hung deploy holds the non-cancelling lock 6 h. Fix: 45 min.
8. **F** Wiring tests miss the worst mutation (`always()` in the deploy `if`), the `needed == 'true'` gate, privilege split, pinning. Fix: new rules + mutants; plus REAL executed tests of the shell logic in temp git repos.
9. **F** `google-github-actions/auth@v2` is a movable tag in the job holding cloud creds: pin to SHA.
10. **F** stale name in `deploy-paths.js` header (`deploy-changes`).
11. **A/D** `npx --yes firebase-tools@15.25.1` has no lockfile integrity at deploy time (pinned version only). Accepted, documented.
12. **A/D** Tag `deployed-main` can be moved by anyone with write access. Accepted (single-owner repo), documented.

## Steps
- [x] S1. Clone, checkout PR branch, read workflow, scripts, tests, design, test plan, repo state via API.
- [x] S2. Findings list above.
- [x] S3. Scripts: `deploy-check.sh`, `deploy-tag.sh`, `verify-deploy-gate.js`, `deploy-paths.js` NUL split + header fix.
- [x] S4. Workflow: use scripts, split `mark-deployed`, permissions, timeout, SHA pin, gate + stale steps.
- [x] S5. Tests: executed shell tests (temp git repos), gate unit tests, wiring rules + mutants, DP updates. Run all in sandbox.
- [x] S6. Docs: design (setup order, WIF condition, IAM), test plan (counts, new real-run checks), README, AGENTS, SKILLS Skill 141 + index regen.
- [x] S7. Push, read CI comment on PR #173, record observed counts here.

## Progress log
- S3-S5 DONE, pushed with the commit that adds this line. Sandbox: whole `.github/scripts/__tests__/*.test.js` glob = **274/274** (was 219). New: `deployCheck.script.test.js` 16, `deployTag.script.test.js` 15, `verifyDeployGate.test.js` 10, `deploy-paths` +2 (DP17/18), wiring 44 (was 32; 20 rules, each mutated). Scripts mutation-tested: 14/14 mutants killed (one equivalent single-layer mutant needed a combined mutation, DC13).
- Verified in sandbox: `npm ci --ignore-scripts` in `functions/` is safe (only `protobufjs` postinstall, a version-compat note); `index.js` loads; functions tests 877/877.
- LESSON: first draft of DT14 failed on a TEST helper bug (tag reset without `-f`), not on product code.
- NEXT: S6 docs (design: setup ORDER + WIF condition + IAM; test plan; README; AGENTS; Skill 141 + `node .github/scripts/skills-index.js` regen), then S7 push + CI.
- S6 DONE: design doc (ordered setup, WIF condition w/ immutable ids + Environment sub + ref, runtime-SA-only actAs, 10-row sweep table, accepted risks), test plan (DP 18, DC 16, DT 15, VG 10, wiring 44; real-run R0, N6-N10, E5-E6), README, AGENTS row, Skill 141 rules 9-13 (index check OK), KNOWN-ISSUES (5 accepted items).
- Coverage (node --experimental-test-coverage): deploy-paths.js + verify-deploy-gate.js 100% line/branch/func. Shell scripts: enumerated branches + 14/14 mutants killed.
- NEXT: S7 push, PR #173 body refresh (counts 219 -> 274, sweep summary), poll CI, record OBSERVED counts here.

## S7 RESULT (observed, CI run 40805804603 on b0c9616)
- **ALL GREEN, 3528/3528** (QML 2442, Functions 877, Rules 106, E2E 103). `Deploy Check`, `Deploy to Firebase`, `Record Deployed Commit` all **skipped** on the PR (= test-plan R1 observed). The `pr-comment` step that runs the script glob (`node --test .github/scripts/__tests__/*.test.js`) is green in CI; its count (274 in the sandbox) is not printed in the comment, so 274 is sandbox-observed, "green" is CI-observed.
- PR #173 body refreshed (219 -> 274, sweep summary, setup order, "Environment does not exist today").
- **SWEEP DONE. Nothing left for code.** Open for a human (Taher), in order: (1) create Environment `firebase-deploy` with a reviewer + main-only BEFORE merging; (2) decide whether to adopt the stricter WIF condition (design doc step 3) when doing GCP setup; (3) first-run checks R0, N3, N6-N10, E5-E6; (4) optional: branch protection on `main`, `dependabot.yml` for `github-actions` (KNOWN-ISSUES).
- **Not done / out of scope (scoped for next session if wanted):** pre-existing unpinned `npm install -g firebase-tools` in `firestore-rules-tests`; `npm audit` shows advisories in `functions/` deps (not triaged); no `dependabot.yml`.
