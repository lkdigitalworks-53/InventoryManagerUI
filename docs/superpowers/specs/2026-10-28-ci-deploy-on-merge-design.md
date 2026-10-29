# Firebase deploy on merge to `main` (one-tap approval)

**Date:** 2026-10-28 | **Branch:** `ci/2026-10-28-deploy-on-merge` | **Status:** implemented + review-swept 2026-10-29 (PR #173), CI-untested on GitHub/GCP (needs Taher's one-time setup below, **in the given order**).
**Brainstorm and trade-offs:** `2026-10-28-ci-deploy-on-merge-brainstorm-CHECKPOINT.md`. **Test plan:** `../test-plans/2026-10-28-ci-deploy-on-merge-test-plan.md`.

## Decisions (Taher, 2026-10-28)
- Q1: one Firebase project (`inventorymanager-48392`), no separate dev, and no prod stage yet. When a real prod stage exists, revisit this design (see "When prod arrives").
- Q2: **one-tap approval**, not zero-touch.
- Q3: deploy **functions + firestore rules + firestore indexes**. Not `storage.rules`.
- This reverses the old rule "Taher deploys functions manually, no CI deploy" (`2026-10-03-photos-ph3-CHECKPOINT.md` D-3).

## What it does
Workflow `.github/workflows/checks.yml`, three new jobs after the four test jobs. Logic lives in `.github/scripts/` so it is executed by tests, not just read:

1. `deploy-check` (push to `main` or manual run only): `deploy-check.sh` lists files changed since the last deployed commit (git tag `deployed-main`; `--no-renames -z`) and asks `deploy-paths.js` whether any is deployable (`functions/**` except `functions/test/**`, `firestore.rules`, `firestore.indexes.json`, `firebase.json`). Docs-only / QML-only merges: no approval prompt. Fails open to `true`.
2. `deploy` (needs all four test jobs + `deploy-check`; Environment `firebase-deploy` = approval gate; `contents: read`, `id-token: write`, 45 min timeout). Steps, in this order: checkout (no stored token) -> **verify the approval gate exists** (`verify-deploy-gate.js`, fail closed) -> **refuse an older commit than the last deployed one** (`deploy-tag.sh stale`) -> `npm ci --ignore-scripts` in `functions/` -> keyless GCP login (Workload Identity Federation, action pinned to a commit) ->
   `firebase deploy --only functions,firestore:rules,firestore:indexes --project inventorymanager-48392 --non-interactive`.
3. `mark-deployed` (needs `deploy`; the only job with `contents: write`; runs no third-party code, holds no cloud login): `deploy-tag.sh mark` moves tag `deployed-main` to the deployed commit, **forward only**.

You get a GitHub notification, check it, tap **Approve** (GitHub mobile app works). Nothing deploys before that.

## Why these choices
- **Tag, not "this push's diff".** A pending approval can be superseded by a newer run (concurrency keeps one pending). A push-only diff would then forget the older run's functions change. Diffing against `deployed-main` cannot lose a change. No tag, or a git error: fail open to "deploy needed".
- **No `--force`.** Removing a function from `index.js` makes the deploy fail instead of deleting it from the shared project (Skill 123: the deployed copy survives anyway). Delete by hand with `firebase functions:delete`, then re-run.
- **`concurrency: firebase-deploy`, `cancel-in-progress: false`.** Never two deploys at once, never kill one mid-flight.
- **Keyless auth (WIF), no JSON key secret.** A leaked repo secret would be a prod-write key. The workflow test fails if `credentials_json` or `secrets.` appears in the deploy job.
- **`firebase-tools` pinned** (`15.25.1`, the version a past CI checkpoint ran). Bump on purpose.
- **Manual re-run:** Actions -> Checks -> Run workflow on `main`. Skips the path filter (always deploys, still needs approval and green tests). Only `main` can deploy.
- **Rollback = revert PR.** Merge the revert and approve the deploy. There is no auto-rollback, and a failed deploy can leave functions and rules at different commits (the tag moves only after success; re-run to converge).

## One-time setup (Taher; Claude cannot do these) — ORDER MATTERS
**Why order:** a workflow that names an Environment that does not exist AUTO-CREATES it with **no reviewers**, and the job then runs unapproved. Today (2026-10-29, checked via API) `firebase-deploy` does not exist. The GCP login (step 3) is the arming switch: until it exists nothing can deploy, so do it LAST. The deploy job also refuses to run when the gate is missing (step 1 of the job), so a mistake here fails closed.

**Step 1 — GitHub Environment (before merging PR #173):** repo Settings -> Environments -> New `firebase-deploy`:
- Required reviewers: yourself. Leave "Prevent self-review" OFF (you are the only reviewer).
- Deployment branches: `main` only.
- Do NOT add variables yet.

**Step 2 — verify the gate** (any shell; if the unauthenticated call answers 401/404 or hides the rules, add `-H "Authorization: Bearer <PAT>"` — not verified which, the Environment did not exist when this was written):
```bash
curl -s https://api.github.com/repos/lkdigitalworks-53/InventoryManagerUI/environments/firebase-deploy | grep -c required_reviewers   # expect >= 1
```

**Step 3 — GCP (Cloud Shell or any `gcloud`), the arming step:**
```bash
PROJECT=inventorymanager-48392
REPO=lkdigitalworks-53/InventoryManagerUI          # must match GitHub's exact case
REPO_ID=1151883837                                 # immutable ids (checked via the GitHub API 2026-10-29); a renamed or
OWNER_ID=256964261                                 # re-created repo gets new ids, so name squatting cannot reuse the trust
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
gcloud services enable iamcredentials.googleapis.com sts.googleapis.com --project $PROJECT
gcloud iam service-accounts create gh-firebase-deploy --project $PROJECT
SA=gh-firebase-deploy@$PROJECT.iam.gserviceaccount.com
RUNTIME_SA=$PROJECT_NUMBER-compute@developer.gserviceaccount.com   # Functions v2 default runtime SA; confirm in the console
gcloud iam workload-identity-pools create github --project $PROJECT --location=global
# The condition is the real gate: only a job that uses the Environment (sub), on main, in THIS repo. A workflow on any
# other branch can not get a token, so it cannot deploy around the approval.
gcloud iam workload-identity-pools providers create-oidc github-oidc --project $PROJECT --location=global \
  --workload-identity-pool=github --issuer-uri=https://token.actions.githubusercontent.com \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository_id=assertion.repository_id" \
  --attribute-condition="assertion.repository_id=='$REPO_ID' && assertion.repository_owner_id=='$OWNER_ID' && assertion.sub=='repo:$REPO:environment:firebase-deploy' && assertion.ref=='refs/heads/main'"
gcloud iam service-accounts add-iam-policy-binding $SA --project $PROJECT --role roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository_id/$REPO_ID"
for R in roles/firebaserules.admin roles/datastore.indexAdmin roles/cloudfunctions.admin roles/cloudscheduler.admin \
         roles/run.admin roles/artifactregistry.writer roles/cloudbuild.builds.editor; do
  gcloud projects add-iam-policy-binding $PROJECT --member="serviceAccount:$SA" --role=$R --condition=None
done
# "Act as" on the runtime SA ONLY. Project-wide roles/iam.serviceAccountUser would let the deploy SA run code as ANY SA in
# the project (including Editor-level ones): a privilege escalation.
gcloud iam service-accounts add-iam-policy-binding $RUNTIME_SA --project $PROJECT --member="serviceAccount:$SA" --role=roles/iam.serviceAccountUser
echo "provider: projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/providers/github-oidc"; echo "sa: $SA"
```
The role list is my best reading of what a Functions v2 + scheduler + rules + indexes deploy needs; **not verified against a live deploy**. If the first deploy fails with a permission error, add the role it names (on the runtime SA if it is an "act as" error, not project-wide). The blunt fallback is `roles/firebase.admin` (broader).

**Step 4 — GitHub variables:** Environment `firebase-deploy` -> variables: `GCP_WORKLOAD_IDENTITY_PROVIDER` = the `provider:` line printed above; `GCP_DEPLOY_SERVICE_ACCOUNT` = the `sa:` line.

**Step 5 (optional):** if `main` is already deployed, skip the first deploy by seeding the tag: `git tag deployed-main <deployed-sha> && git push origin deployed-main`. Without it the first merge after this PR deploys everything (after your approval).

## Risks and limits (honest list)
1. **The gate only exists while the approval rule works.** Required reviewers on Environments are free for public repos; on a private repo they need a paid GitHub plan (as far as I know, check GitHub's plan page). Since the 2026-10-29 sweep the deploy job **checks the rule at run time and refuses to deploy** when it is missing (private repo on Free, deleted rule, auto-created Environment), so this now fails closed instead of running unattended. Cost: if the check itself cannot read the Environment (token or API change), deploys stop until fixed (first-run check N8).
2. **Merge now means "ready to deploy", not "device-tested".** One tap approves what main contains at that run. Pending runs are not an automatic safety net: approving blindly equals auto-deploy.
3. **Functions are shared by dev/test/prd.** A deploy hits every environment at once; that was already true for manual deploys.
4. **`firestore.rules` + `firestore.indexes.json` go to `(default)` only.** `test` and `dev1` rules stay manual (`firebase.json` has a single `firestore` block).
5. **Not verified, no live GitHub/GCP/Firebase here:** the exact IAM roles and the runtime SA name; `--non-interactive` failing (not deleting) when a function was removed; `npx firebase-tools@15.25.1` behaviour under CI; the WIF condition (claim names, `sub` format for an Environment job); that `GITHUB_TOKEN` with `actions: read` can read the Environment's protection rules; whether a job waiting for approval occupies the concurrency slot. All are covered by the first-run steps in the test plan.
6. **`storage.rules` and hosting stay manual** (Q3).

## When prod arrives
Then Functions and rules will have a real prod and a place to test first. Revisit: deploy to the staging environment automatically on merge, and keep prod behind this approval (a second Environment, `production`, with its own variables). The jobs are written so that is one more `deploy` job with a different `--project` and environment.
7. **Accepted, not fixed:** (a) `npx --yes firebase-tools@15.25.1` is pinned by version but has no lockfile integrity at deploy time (moving it into a lockfile would make every CLI bump a functions-dependency change); (b) `deployed-main` is a plain tag, movable by anyone with write access (single-owner repo; the forward-only move and the stale guard protect against our own runs, not a malicious writer); (c) no `dependabot.yml` for `github-actions`, so the SHA-pinned `google-github-actions/auth` is bumped by hand (`v2.1.13` today; look at the release notes first); (d) `main` has no branch protection (checked via API): the approval gate protects the deploy, not the merge. See `KNOWN-ISSUES.md`.
8. **A stale approved run is refused, loudly.** If an older run is approved after a newer one already deployed, the `Deploy` job goes red with "older than the last deployed commit". That is the guard working, not a failure to fix. A re-run of the SAME commit is allowed.

## Review sweep of PR #173 (2026-10-29): what changed and the trade-off of each
| # | Finding | Fix | Trade-off / cost |
|---|---|---|---|
| 1 | Missing Environment auto-creates with no reviewers => unapproved deploy | `verify-deploy-gate.js` first step (fail closed) + setup order (arm GCP last) | Deploys stop if the API read breaks (N8). One extra step (~2 s). |
| 2 | WIF trusted the whole repo: any branch workflow could mint a token and bypass the Environment | Provider condition: repo id + owner id + Environment `sub` + `ref == main` | Setup is stricter; a typo in the condition fails the auth step (N4, N9). |
| 3 | Project-wide `serviceAccountUser` = privilege escalation | Grant on the runtime SA only | If Cloud Build needs another SA, one more targeted grant. |
| 4 | Older approved run could overwrite newer code, tag moved backwards | `deploy-tag.sh stale` + forward-only `mark` | A superseded approval shows a red job. |
| 5 | Path filter missed renames out of `functions/` and non-ASCII names | `--no-renames -z`, NUL-aware script | none |
| 6 | The job running `npm ci` + `npx` had `contents: write` + a stored token | `mark-deployed` job, deploy is read-only, `persist-credentials: false` | One more job (~20 s) and one more lock. |
| 7 | No timeout: a hung deploy holds the non-cancelling lock for 6 h | `timeout-minutes: 45` | A genuinely slow deploy (>45 min) is killed mid-flight; re-run converges. |
| 8 | Install scripts of dependencies ran beside cloud credentials | `npm ci --ignore-scripts` (checked: only `protobufjs` has one, a version note) | A future dependency that NEEDS an install script fails the deploy; remove the flag then, on purpose. |
| 9 | `google-github-actions/auth@v2` movable tag in the credential job | Pinned to `c200f36...` (= `v2.1.13`, verified) | Manual bumps (see Risk 7c). |
| 10 | Wiring tests missed `always()` in the deploy `if` and the `needed == 'true'` gate | 20 rules + mutants; shell logic now EXECUTED in temp git repos | More test code to maintain (~700 lines). |

