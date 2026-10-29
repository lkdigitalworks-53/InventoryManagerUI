# Test plan — Firebase deploy on merge (one-tap approval)

**Design:** `../specs/2026-10-28-ci-deploy-on-merge-design.md`. **Branch:** `ci/2026-10-28-deploy-on-merge`.
**Scope:** CI/infra only. No QML, no Cloud Function code, no rules changed, so no unit/rules/e2e tests of the app apply. There is no on-device (phone) step; "on device" here means a real run on GitHub + Firebase, which only Taher can do.
**Coverage target (user rule: 100% of new code):** `deploy-paths.js` is 100% line/branch by design (16 tests below, all branches: non-array, non-string, ignored prefix, match, no match, CLI). The workflow YAML cannot be executed in the sandbox; its safety properties are pinned by source tests with mutants.

## 1. Unit — `.github/scripts/__tests__/deploy-paths.test.js` (16)
| ID | Case |
|---|---|
| DP01-DP05 | happy: functions source / lib+package files / firestore.rules / firestore.indexes.json / firebase.json each trigger |
| DP06 | negative: docs, QML, C++, CI-only changes do not trigger |
| DP07 | `functions/test/**` alone does not trigger; with a source file beside it, it does |
| DP08 | look-alikes (`functions-old/`, `FIRESTORE_RULES.md`, `test/firestore.rules.test.js`, `sub/firebase.json`, `.bak`) do not trigger |
| DP09 | `storage.rules` does not trigger (Q3 scope) |
| DP10 | edge: empty list, blank and whitespace-only entries |
| DP11 | edge: CRLF and surrounding whitespace trimmed |
| DP12 | edge: one deployable file among 200, any order |
| DP13 | edge: non-array input and non-string members never throw |
| DP14 | edge: unicode names matched literally |
| DP15 | MONKEY: 3000 seeded random paths, boolean result, equals an independent oracle |
| DP16 | CLI (what the workflow runs): `true` / `false` / empty stdin -> `false`, exit 0 |

## 2. Functional / regression (workflow wiring) — `deployWorkflowWiring.test.js` (32)
14 rules, each with a mutant that must change the text and be caught (no vacuous mutant), plus: both jobs exist (DW00), every rule has a mutant, comments cannot satisfy a rule, the four test jobs still exist. Rules: deploy needs all four test jobs + check job; Environment `firebase-deploy`; main only; `deploy-check` never on pull requests; non-cancelling single concurrency group; no `--force`; exactly `functions,firestore:rules,firestore:indexes` and never storage; `--non-interactive` + the one project; `firebase-tools` version-pinned; keyless auth and no `secrets.`/`credentials_json`; `npm ci` before deploy; tag moved only after the deploy step; diff against `deployed-main` and fail open; `workflow_dispatch` declared and skips the filter.
Both files run in CI in the existing `pr-comment` job step (`node --test .github/scripts/__tests__/*.test.js`). Sandbox result: 219/219 for the whole glob.

## 3. Rules tests / e2e
Not applicable: `firestore.rules`, functions and the app are unchanged. Existing suites must stay green (the new jobs add no steps to them).

## 4. Real run — Taher (after the one-time setup in the design doc)
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
Edge / multi-scenario
| ID | Steps | Expect |
|---|---|---|
| E1 | Merge PR-A (functions change), do not approve; merge docs-only PR-B. | PR-B's run still says `needed=true` (tag unchanged); approving either deploys main including PR-A's change; the older pending run may show as cancelled/replaced. |
| E2 | Merge two deployable PRs quickly. | Deploys never overlap (second waits on concurrency); final state = latest main. |
| E3 | Actions -> Checks -> Run workflow on main. | Always `needed=true`, approval required, same deploy. |
| E4 | New composite index added to `firestore.indexes.json`. | Deploy creates it (console shows "building"). |
Monkey
| ID | Steps | Expect |
|---|---|---|
| M1 | Merge 5 mixed PRs (docs, QML, rules, functions test only, functions source) in random order, approving some and rejecting others. | Only rules / functions-source merges ever prompt; `functions/test`-only and docs never do; the tag only moves after a green deploy. |
Post-run checks: `grep -c ghp_ .git/config` = 0 (unrelated to CI, standing rule); function logs show no change in `cleanupPendingMarkers` cadence after deploy.
