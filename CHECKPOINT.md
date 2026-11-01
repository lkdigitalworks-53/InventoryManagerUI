# CHECKPOINT — 2026-11-01 Functions runtime Node 20 -> 24 (first live deploy failed, resume here)

**Branch:** `fix/2026-11-01-functions-node-24-runtime`, cut from `main` @ `4fcc26b` (PR #172 merged). No QML touched.
**Commit identity:** `dextran52@gmail.com` (Taher). PAT comes from the chat prompt only, never in a remote URL, repo, config or memory. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in sandbox (CI is the QML oracle); push without asking; tests + test plan for every change; caveman FULL in chat only; honest trade-offs, grill before decisions.
**Skills used:** systematic-debugging, ponytail (qt-qml / qt-ui-design N/A: no QML or UI in this slice).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-01-pr172-merged-prev-CHECKPOINT.md`.

## Why this slice
First "Deploy to Firebase" job after merge (Checks run #587, PR #171 merge `f18445e`) failed. Three failures in a row, each fixed or found from the CI log Taher pasted:
1. `iam.serviceAccounts.ActAs` on `inventorymanager-48392@appspot.gserviceaccount.com` missing. Fixed by Taher in GCP (grant `roles/iam.serviceAccountUser` on THAT SA only).
2. `firebase.googleapis.com .../adminSdkConfig` 403. Fixed by Taher in GCP (`roles/firebase.viewer`, project level).
3. "Runtime Node.js 20 was decommissioned on 2026-10-30". NOT an IAM problem: needs a repo change. This slice.

## Decision (Taher, 2026-11-01)
Node 24 (reply "Go" to my default). Trade-off shown: 22 = lowest risk but a second forced upgrade in about 12 months; 24 = decommission 2028-10-31, CI gates the deploy on the same Node.

## Steps
- [x] 1. Read the failed job page (log needs sign-in, so Taher pasted the error lines), workflow, design doc, `firebase.json`, `functions/`.
- [x] 2. Verified the pinned CLI: `firebase-tools@15.25.1` lists `nodejs24` as GA (read from the package source, `runtimes/supported/types.js`).
- [x] 3. Baseline BEFORE the change on a real Node 24 (v24.22.2 via `npm i node@24`): functions suite 937/937.
- [x] 4. Pins changed: `firebase.json` runtime `nodejs24`, `functions/package.json` engines.node `"24"`, 6x `node-version: '24'` in `checks.yml`.
- [x] 5. New drift guard `.github/scripts/__tests__/runtimeVersion.test.js` (8 tests, 3 rules, 3 mutants). Script suite 470/470 on Node 24.
- [x] 6. Docs: test plan, Skill 147 + SKILLS-INDEX, README (deploy section + test-plan index), design doc addendum (real IAM findings), KNOWN-ISSUES.
- [x] 7. Committed and pushed (branch only; open the PR on GitHub).

## Open for a human / next account
- Read CI on the PR: all four test jobs now run on Node 24. Not run in the sandbox: QML (Qt 6.8, independent of Node), Rules, E2E (emulator).
- Merge, approve the `firebase-deploy` Environment, read the deploy log. More missing IAM roles are still possible (unverified: storage bucket for function source, Cloud Build / compute SA actAs, Artifact Registry policy). Paste each error; grant only the role it names.
- After the first green deploy: move the confirmed roles into the design doc's setup block (done only for the two seen so far).
- Not done on purpose: `firebase-functions` is pinned to a release candidate (`^7.3.2-rc.0`), see KNOWN-ISSUES; own PR.
