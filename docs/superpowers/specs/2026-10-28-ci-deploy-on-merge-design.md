# Firebase deploy on merge to `main` (one-tap approval)

**Date:** 2026-10-28 | **Branch:** `ci/2026-10-28-deploy-on-merge` | **Status:** implemented, CI-untested (needs Taher's one-time setup below).
**Brainstorm and trade-offs:** `2026-10-28-ci-deploy-on-merge-brainstorm-CHECKPOINT.md`. **Test plan:** `../test-plans/2026-10-28-ci-deploy-on-merge-test-plan.md`.

## Decisions (Taher, 2026-10-28)
- Q1: one Firebase project (`inventorymanager-48392`), no separate dev, and no prod stage yet. When a real prod stage exists, revisit this design (see "When prod arrives").
- Q2: **one-tap approval**, not zero-touch.
- Q3: deploy **functions + firestore rules + firestore indexes**. Not `storage.rules`.
- This reverses the old rule "Taher deploys functions manually, no CI deploy" (`2026-10-03-photos-ph3-CHECKPOINT.md` D-3).

## What it does
Workflow `.github/workflows/checks.yml`, two new jobs after the four test jobs:

1. `deploy-check` (push to `main` or manual run only): lists files changed since the last deployed commit (git tag `deployed-main`) and asks `.github/scripts/deploy-paths.js` whether any is deployable (`functions/**` except `functions/test/**`, `firestore.rules`, `firestore.indexes.json`, `firebase.json`). Docs-only / QML-only merges: no approval prompt.
2. `deploy` (needs all four test jobs + `deploy-check`; Environment `firebase-deploy` = approval gate): `npm ci` in `functions/`, keyless GCP login (Workload Identity Federation), then
   `firebase deploy --only functions,firestore:rules,firestore:indexes --project inventorymanager-48392 --non-interactive`, then moves tag `deployed-main` to the deployed commit.

You get a GitHub notification, check it, tap **Approve** (GitHub mobile app works). Nothing deploys before that.

## Why these choices
- **Tag, not "this push's diff".** A pending approval can be superseded by a newer run (concurrency keeps one pending). A push-only diff would then forget the older run's functions change. Diffing against `deployed-main` cannot lose a change. No tag, or a git error: fail open to "deploy needed".
- **No `--force`.** Removing a function from `index.js` makes the deploy fail instead of deleting it from the shared project (Skill 123: the deployed copy survives anyway). Delete by hand with `firebase functions:delete`, then re-run.
- **`concurrency: firebase-deploy`, `cancel-in-progress: false`.** Never two deploys at once, never kill one mid-flight.
- **Keyless auth (WIF), no JSON key secret.** A leaked repo secret would be a prod-write key. The workflow test fails if `credentials_json` or `secrets.` appears in the deploy job.
- **`firebase-tools` pinned** (`15.25.1`, the version a past CI checkpoint ran). Bump on purpose.
- **Manual re-run:** Actions -> Checks -> Run workflow on `main`. Skips the path filter (always deploys, still needs approval and green tests). Only `main` can deploy.
- **Rollback = revert PR.** Merge the revert and approve the deploy. There is no auto-rollback, and a failed deploy can leave functions and rules at different commits (the tag moves only after success; re-run to converge).

## One-time setup (Taher; Claude cannot do these)
GCP (Cloud Shell or any `gcloud`):
```bash
PROJECT=inventorymanager-48392
REPO=lkdigitalworks-53/InventoryManagerUI          # must match GitHub's exact case
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
gcloud services enable iamcredentials.googleapis.com sts.googleapis.com --project $PROJECT
gcloud iam service-accounts create gh-firebase-deploy --project $PROJECT
SA=gh-firebase-deploy@$PROJECT.iam.gserviceaccount.com
gcloud iam workload-identity-pools create github --project $PROJECT --location=global
gcloud iam workload-identity-pools providers create-oidc github-oidc --project $PROJECT --location=global \
  --workload-identity-pool=github --issuer-uri=https://token.actions.githubusercontent.com \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='$REPO'"
gcloud iam service-accounts add-iam-policy-binding $SA --project $PROJECT --role roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/$REPO"
for R in roles/firebaserules.admin roles/datastore.indexAdmin roles/cloudfunctions.admin roles/cloudscheduler.admin \
         roles/run.admin roles/artifactregistry.writer roles/cloudbuild.builds.editor roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding $PROJECT --member="serviceAccount:$SA" --role=$R --condition=None
done
echo "provider: projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/providers/github-oidc"; echo "sa: $SA"
```
The role list is my best reading of what a Functions v2 + scheduler + rules + indexes deploy needs; **not verified against a live deploy**. If the first deploy fails with a permission error, add the role it names. The blunt fallback is `roles/firebase.admin` (broader).

GitHub: repo Settings -> Environments -> New `firebase-deploy`:
- Required reviewers: yourself. Leave "Prevent self-review" OFF (you are the only reviewer).
- Deployment branches: `main` only.
- Environment variables: `GCP_WORKLOAD_IDENTITY_PROVIDER` = the `provider:` line printed above; `GCP_DEPLOY_SERVICE_ACCOUNT` = the `sa:` line.

Optional: if `main` is already deployed, skip the first deploy by seeding the tag: `git tag deployed-main <deployed-sha> && git push origin deployed-main`. Without it the first merge after this PR deploys everything (after your approval).

## Risks and limits (honest list)
1. **The gate only exists while the approval rule works.** Required reviewers on Environments are free for public repos; on a private repo they need a paid GitHub plan (as far as I know, check GitHub's plan page). If the repo goes private on Free, this job would run without waiting. Re-check before changing visibility.
2. **Merge now means "ready to deploy", not "device-tested".** One tap approves what main contains at that run. Pending runs are not an automatic safety net: approving blindly equals auto-deploy.
3. **Functions are shared by dev/test/prd.** A deploy hits every environment at once; that was already true for manual deploys.
4. **`firestore.rules` + `firestore.indexes.json` go to `(default)` only.** `test` and `dev1` rules stay manual (`firebase.json` has a single `firestore` block).
5. **Not verified, no live GitHub/GCP/Firebase here:** the exact IAM roles; `--non-interactive` failing (not deleting) when a function was removed; `npx firebase-tools@15.25.1` behaviour under CI; WIF attribute-condition case sensitivity. All are covered by the first-run steps in the test plan.
6. **`storage.rules` and hosting stay manual** (Q3).

## When prod arrives
Then Functions and rules will have a real prod and a place to test first. Revisit: deploy to the staging environment automatically on merge, and keep prod behind this approval (a second Environment, `production`, with its own variables). The jobs are written so that is one more `deploy` job with a different `--project` and environment.
