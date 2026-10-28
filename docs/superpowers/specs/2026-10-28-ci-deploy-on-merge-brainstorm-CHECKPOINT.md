# CI deploy on merge (functions + firestore:rules) - brainstorm checkpoint

**Date:** 2026-10-28 | **Branch:** `docs/2026-10-28-ci-deploy-brainstorm` | **Status:** BRAINSTORM ONLY. Design NOT approved. No workflow/code changed.

## Ask (Taher)
After every PR merge to `main`, the workflow should run `firebase deploy --only functions` and `--only firestore:rules` so he stops deploying by hand. Asked for feasibility.

## Verdict
Feasible. Technically ~1 job (~40 lines YAML) + 1 GCP service account + 1 GitHub secret/WIF setup. The hard part is not the YAML; it is blast radius (below). Reverses prior decision D-3 ("Taher deploys functions manually. No CI deploy exists or is planned", `2026-10-03-photos-ph3-CHECKPOINT.md`). Needs an explicit decision, not a quiet change.

## Facts found in repo (verified by reading, not by running)
- `.github/workflows/checks.yml` already runs on `push: main` + PRs. 4 test jobs: qml, functions, firestore-rules, e2e; plus `pr-comment`. No deploy job, no auth, no secrets except `GITHUB_TOKEN`.
- `.firebaserc`: ONE project, `inventorymanager-48392`. `firebase.json` has single `firestore` object (rules + indexes) => `deploy --only firestore:rules` targets `(default)` database = **prd** only.
- Envs are Firestore databases, not projects: `(default)`=prd, `test`, `dev1`. README: Auth, Storage, Cloud Functions are **shared** across envs. So a functions deploy is a prod deploy.
- Older docs say "dev project only, never prd" and `--project <dev-project-id>`; other docs deploy to `inventorymanager-48392`. UNRESOLVED: is there a separate dev Firebase project? (Question Q1.)
- 11 HTTP functions + scheduled `cleanupPendingMarkers` (every 10 min, asia-south1). All in one `functions/index.js`.
- S2f-4/5 default-deny rules (PR #161) are merged first, deployed + device-tested by Taher after. Merge != ready to ship today.
- Skill 123 (SKILLS-INDEX): deleting a function leaves the deployed copy; CI deploy must decide on `--force` / deletion prompts.

## Trade-offs
| Aspect | Auto on merge | One-tap approval (GitHub Environment reviewer) | Manual dispatch button |
|---|---|---|---|
| Terminal/login work | none | none | none |
| Zero-touch | yes | no, 1 tap | no, 1 tap |
| Deploy before device-test | YES (risk) | gate = Taher decides | gate = Taher decides |
| Bad rules lock out users | instantly | after approval | after click |
| Complexity | low | low+ | lowest |

## Risks to design out (any option)
1. Prod blast radius: functions shared, rules hit `(default)`. Default-deny rules + old installed clients = blocked writes.
2. Deploy gated on all 4 test jobs (`needs:`), only `push` to `main`, never PRs/forks.
3. Out-of-order deploys when two PRs merge fast: `concurrency` group, `cancel-in-progress: false`.
4. Docs-only merges should not redeploy: path filter inside the job (not `paths:` on the workflow, that would skip tests).
5. Half-deployed state (functions ok, rules fail): sequence + fail loud; no auto rollback exists. Add `workflow_dispatch` with a ref input as rollback/hotfix path.
6. Auth: Workload Identity Federation (keyless) preferred over a JSON key; `firebase login:ci` token is deprecated. SA roles needed: Firebase Rules Admin, Cloud Functions Admin, Service Account User, Cloud Scheduler Admin, Artifact Registry access (verify at setup time).
7. Non-interactive deletion prompt for removed functions.
8. Indexes + storage rules are same-class artifacts but not in the ask; `--only firestore:rules` skips `firestore.indexes.json`, so a PR needing a new index still breaks until deployed by hand.
9. `test`/`dev1` rules: stay manual (needs `firebase.json` `firestore` array with `database` keys; touches emulator CI config; out of scope).

## Open questions for Taher (answer these, then design)
- Q1: Separate dev Firebase project, or one project with dev1/test/(default) databases? If one project: deploy-on-merge == deploy-to-prod.
- Q2: Zero-touch (auto) vs one-tap approval vs dispatch button? Recommendation: one-tap approval via GitHub Environment `production`.
- Q3: Include `firestore:indexes` (and `storage` rules) now, or exactly functions + rules as asked? Recommendation: add indexes, skip storage.

## Next session (start here)
1. Read Taher's answers to Q1-Q3 (in chat or appended below).
2. Present 2-3 approaches + design, get approval (brainstorming gate).
3. Then: branch `ci/2026-10-28-deploy-on-merge`, add job to `checks.yml` (or `deploy.yml`), a workflow self-test where possible, README + SKILLS.md + test plan. Taher does the GCP service-account / WIF + GitHub secret setup (Claude cannot).
4. Do NOT build/run the app; do NOT install Qt in the sandbox; CI is the signal.

## Answers
(none yet)
