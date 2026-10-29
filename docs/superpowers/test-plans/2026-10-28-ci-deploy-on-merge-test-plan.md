# Test plan — Firebase deploy on merge (one-tap approval)

**Design:** `../specs/2026-10-28-ci-deploy-on-merge-design.md`. **Branch:** `ci/2026-10-28-deploy-on-merge`.
**Scope:** CI/infra only. No QML, no Cloud Function code, no rules changed, so no unit/rules/e2e tests of the app apply. There is no on-device (phone) step; "on device" here means a real run on GitHub + Firebase, which only Taher can do.
**Coverage target (user rule: 100% of new code):** measured with `node --test --experimental-test-coverage`: `deploy-paths.js` and `verify-deploy-gate.js` are **100% line / branch / function**. The two shell scripts have no coverage tool; every branch is enumerated below and exercised by a named test against real throwaway git repos (DC/DT), and 14 mutants of the three scripts were all killed. The workflow YAML cannot be executed in the sandbox; its safety properties are pinned by source tests with mutants (section 2).
**Sandbox result after the PR #173 review sweep (2026-10-29):** whole `.github/scripts/__tests__/*.test.js` glob = **274/274** (was 219).

## 1. Unit + executed script tests
### 1a. `deploy-paths.test.js` (18)
| ID | Case |
|---|---|
| DP01-DP05 | happy: functions source / lib+package files / firestore.rules / firestore.indexes.json / firebase.json each trigger |
| DP06 | negative: docs, QML, C++, CI-only changes do not trigger |
| DP07 | `functions/test/**` alone does not trigger; with a source file beside it, it does |
| DP08 | look-alikes (`functions-old/`, `FIRESTORE_RULES.md`, `test/firestore.rules.test.js`, `sub/firebase.json`, `.bak`) do not trigger |
| DP09 | `storage.rules` does not trigger (Q3 scope) |
| DP10-DP14 | edge: empty / blank, CRLF + whitespace, 1 among 200, non-array + non-string members, unicode names |
| DP15 | MONKEY: 3000 seeded random paths agree with an independent oracle |
| DP16 | CLI: `true` / `false` / empty stdin -> `false`, exit 0 |
| DP17 | CLI: NUL-separated input (`git diff -z`) incl. a non-ASCII `functions/` path |
| DP18 | CLI: NUL and newline mixed; paths never glued together |
### 1b. `deployCheck.script.test.js` (16) — EXECUTES `deploy-check.sh` in temp git repos
| ID | Case |
|---|---|
| DC01-DC02 | happy: functions source, rules, indexes, firebase.json, functions/package.json, functions/lib => `true` |
| DC03-DC05 | negative: docs/QML/CI only => `false`; `functions/test` only => `false`; head == tag => `false` |
| DC06 | no tag yet => `true` (first deploy) |
| DC07 | `workflow_dispatch` => `true` even for docs-only; `push` => `false` |
| DC08 | git cannot diff (unknown sha) => `true`, exit 0 (fail open) |
| DC09 | paths helper prints junk / crashes / `false` + exit 1 => `true` (never trust a non-boolean) |
| DC10 | a file MOVED OUT of `functions/` still deploys (non-vacuous: default git lists only the new path) |
| DC11-DC12 | NON-ASCII: `functions/é.js` deploys (non-vacuous: plain git quotes it); docs-only non-ASCII stays `false` |
| DC13 | a BRANCH named `deployed-main` never stands in for the tag (branch only => `true`; both => tag decides) |
| DC14 | deleting a deployable file deploys |
| DC15 | MONKEY: 30 seeded random change sets agree with `needsDeploy` over git's own list |
| DC16 | script present, bash shebang |
### 1c. `deployTag.script.test.js` (15) — EXECUTES `deploy-tag.sh` with a real bare origin
| ID | Case |
|---|---|
| DT01-DT03 | `stale`: no tag ok; sha newer ok; sha equal ok (same commit may be re-deployed) |
| DT04 | `stale`: sha OLDER than tag => exit 1, `::error::` annotation naming the newer commit |
| DT05-DT06 | `stale`: diverged branch ok; annotated tag handled |
| DT07-DT08 | `mark`: no tag => created locally + on origin; tag behind => moved forward on origin |
| DT09 | `mark`: tag already ahead => NOT moved backwards, origin untouched |
| DT10-DT11 | `mark`: equal idempotent; diverged => moves (self-heal after a history rewrite) |
| DT12 | `mark`: a failing push is loud (non-zero) |
| DT13 | missing `GITHUB_SHA`, no mode, unknown mode => non-zero, usage = 2 |
| DT14 | EXHAUSTIVE: all 36 (tag, sha) pairs on a 6-commit line: `stale` <=> strictly older; `mark` never backwards |
| DT15 | script present, bash shebang |
### 1d. `verifyDeployGate.test.js` (10)
| ID | Case |
|---|---|
| VG01-VG02 | happy: one reviewer; reviewers summed across rules |
| VG03-VG05 | negative: auto-created env (no rules); only branch_policy/wait_timer; reviewers rule with empty / missing / non-array list |
| VG06 | malformed input (null, string, number, array, bad `protection_rules`) never throws, refused |
| VG07 | MONKEY: 2000 seeded random environments agree with an oracle |
| VG08-VG10 | CLI: gated => 0; ungated => 1 + `::error::` naming the fix; invalid JSON / empty / HTML error page / `{"message":"Not Found"}` => 1 (fail closed) |

## 2. Functional / regression (workflow wiring) — `deployWorkflowWiring.test.js` (44)
20 rules, each with a mutant that must change the text and be caught (no vacuous mutant), plus: both deploy jobs exist (DW00), every rule has a mutant, comments cannot satisfy a rule, the four test jobs still exist. Rules: `deploy` needs all four test jobs + check job; Environment `firebase-deploy`; `if` = main AND `needed == 'true'`; **no `always()/failure()/cancelled()` in any deploy-chain `if`** (would deploy after a red test); `deploy-check` never on pull requests; non-cancelling single concurrency group; no `--force`; exactly `functions,firestore:rules,firestore:indexes`, never storage; `--non-interactive` + the one project; `firebase-tools` version-pinned; keyless auth, no `secrets.`/`credentials_json`; third-party actions pinned to a commit SHA; **gate verified before any third-party code or login**; **stale guard before login**; `npm ci --ignore-scripts` before the deploy; deploy job read-only with no stored token; timeouts on every job; **tag moves in its own job** (`needs: deploy`, write access, no cloud login, no npm/npx, serialised, forward-only script); path filter runs `deploy-check.sh` + `EVENT` + full history + `workflow_dispatch` declared; every script the chain calls exists on disk.
All five files run in CI in the existing `pr-comment` job step (`node --test .github/scripts/__tests__/*.test.js`; needs `bash`, `git`, `node`, all on `ubuntu-latest`).

## 3. Rules tests / e2e
Not applicable: `firestore.rules`, functions and the app are unchanged. Existing suites must stay green (the new jobs add no steps to them).

## 4. Real run — Taher (after the one-time setup in the design doc, in its order)
Before merging (setup order)
| ID | Steps | Expect |
|---|---|---|
| R0 | Setup steps 1-2 of the design doc (Environment + reviewer), THEN step 3 (GCP) and 4 (variables). | `curl .../environments/firebase-deploy` shows a `required_reviewers` rule. Never merge before this. |
Happy path
| ID | Steps | Expect |
|---|---|---|
| R1 | Open this PR. | The four test jobs run; `Deploy Check` and `Deploy` do NOT run (pull request). No approval prompt. |
| R2 | Merge it (docs/CI only). With no `deployed-main` tag yet. | `Deploy Check` says `needed=true` (no tag = fail open) and `Deploy` waits for approval. Seed the tag first (design doc) to see R3 instead. |
| R3 | After a tag exists: merge a docs-only PR. | `Deploy Check` says `needed=false`; `Deploy` is skipped; no approval prompt. |
| R4 | Merge a PR that touches `firestore.rules` (or `functions/index.js`). | `Deploy` waits; GitHub shows "Review deployments"; tap Approve. |
| R5 | After approval. | npm ci, login, deploy all green; Firebase console shows new functions revision and a new rules release; tag `deployed-main` points at the merge commit. |
Negative
| ID | Steps | Expect |
|---|---|---|
| N1 | Click Reject on the approval. | Deploy job is cancelled/failed, nothing deployed, tag unchanged. |
| N2 | Make a test job fail on a main push (or re-run with a red test). | `Deploy` is skipped, never prompts. |
| N3 | Remove a function from `index.js` in a throwaway PR, merge, approve. | Deploy fails with a "would delete" style message; the function is still live in the console. (**Unverified assumption, this is the check.**) Revert afterwards. |
| N4 | Break the setup on purpose (wrong `GCP_DEPLOY_SERVICE_ACCOUNT` value). | Auth step fails clearly; nothing deployed; tag unchanged. |
| N5 | Run workflow manually from a branch other than main. | `Deploy Check`/`Deploy` are skipped. |
| N6 | Delete the required-reviewers rule on the Environment, then run the workflow manually on `main`. | `Deploy` runs without a prompt, then **fails at `Verify the approval gate exists`** with `Refusing to deploy`; nothing deployed. Restore the rule. |
| N7 | Seed tag `deployed-main` on a commit AHEAD of the run (or approve an old run after a newer deploy). | `Refuse to deploy older code over newer` fails the job; nothing deployed; tag unchanged. Re-running the SAME commit as the tag is allowed. |
| N9 | Throwaway branch with a workflow that requests an OIDC token (`id-token: write`, `google-github-actions/auth` with the same variables), no Environment. | **GCP refuses** the exchange (provider condition: Environment `sub`, `ref == main`). Proves a branch cannot deploy around the approval. Delete the branch. |
Edge / multi-scenario
| ID | Steps | Expect |
|---|---|---|
| E1 | Merge PR-A (functions change), do not approve; merge docs-only PR-B. | PR-B's run still says `needed=true` (tag unchanged); approving either deploys main including PR-A's change; the older pending run may show as cancelled/replaced. |
| E2 | Merge two deployable PRs quickly. | Deploys never overlap (second waits on concurrency); final state = latest main. |
| E3 | Actions -> Checks -> Run workflow on main. | Always `needed=true`, approval required, same deploy. |
| E4 | New composite index added to `firestore.indexes.json`. | Deploy creates it (console shows "building"). |
| E5 | Merge a PR that only MOVES a file out of `functions/` (e.g. to `docs/`). | `Deploy Check` says `needed=true` (rename detection off). |
| E6 | After a green deploy. | Tag `deployed-main` = the deployed commit; `Record Deployed Commit` is the only job with write access (check the job's permissions block in the log). |
Monkey
| ID | Steps | Expect |
|---|---|---|
| M1 | Merge 5 mixed PRs (docs, QML, rules, functions test only, functions source) in random order, approving some and rejecting others. | Only rules / functions-source merges ever prompt; `functions/test`-only and docs never do; the tag only moves after a green deploy. |
First-run unverified assumptions to confirm (read the log, not just the colour):
| ID | Check | If it fails |
|---|---|---|
| N8 | `Verify the approval gate exists` succeeds with the job's `GITHUB_TOKEN` (`actions: read`). | `curl` 403/404: grant the right permission or use a read token; deploys stay blocked (fail closed) until then. |
| N3 | (above) removed function => deploy fails, function survives. | Add a guard; do not enable `--force`. |
| N10 | Whether a run waiting for approval occupies the `firebase-deploy` concurrency slot (merge two deployable PRs, approve neither). | Informational: the stale guard (N7) covers the out-of-order case either way. |
Post-run checks: `grep -c ghp_ .git/config` = 0 (unrelated to CI, standing rule); function logs show no change in `cleanupPendingMarkers` cadence after deploy.
