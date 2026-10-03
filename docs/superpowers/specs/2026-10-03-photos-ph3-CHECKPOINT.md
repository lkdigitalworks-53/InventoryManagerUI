# CHECKPOINT — photos PH3 (server cascade + hardening), implementation (2026-10-03)

**Branch:** `feat/2026-10-03-photos-ph3-server` (off `main` @ `af2d5b1`, PR #108 merged). **Commit identity:** `dextran52@gmail.com` (Taher's instruction this session).
**Skills invoked by Taher:** qt-qml, qt-ui-design, brainstorming, ponytail; caveman FULL (chat only). qt-qml / qt-ui-design: no QML in PH3 (server only), nothing to apply. Brainstorming gate: design approved in PR #108 (Q1-Q15), no new decision needed.
**Design:** `specs/2026-09-30-photos-s3-s4-design.md` (file is named s3-s4, content = PH3/PH4/PH5). **Test plan:** `test-plans/2026-09-30-photos-s3-s4-s5-test-plan.md`.
**Not this workstream:** root `CHECKPOINT.md` (stuck-writes S3). Not touched.
**Rules:** branch only; push without asking (PAT only in the push header, never in `.git/config` or the repo); no build/run; no Qt tooling (CI is the QML/rules/e2e signal); Node tests CAN run in the sandbox; small scope; honest advisor.

## Step log
1. Read memory, skills, cloned repo, read design + test plan + PR #108 review checkpoint. Next priority item = **PH3** (server). PH3b blocked on Q-I, PH4/PH5 after PH3.
2. Baseline: `cd functions && npm ci && node --test` = 347 pass, 0 fail.
3. Read `index.js` (recordMutation, upload/deletePhoto, deriveContext), `gatewayLogic.applyMutation`, batch/ops validators, handlerHarness, firestore.rules.

## Deviations from the design (decided here, flagged for review)
- `isCascadeEntityDelete` lives in the NEW leaf module `functions/lib/photoCleanup.js` (design said `gatewayLogic.js`, test plan said `photoCleanup.js`). Reason: batch/ops would otherwise need a new import of gatewayLogic internals; a leaf module avoids a cycle.
4. Tasks 1-6 (commits f9be2a4..07e0116): id whitelist; `photoCleanup.js` + 32 unit tests; marker in `applyMutation`; batch/ops reject; handler wiring (role gate, F3 preflight, prefix to applyMutation, awaited post-commit sweep). Harness extended (`deleteFiles`, doc `delete`, `onStorageSave`, `applyMutationCalls`, `storageBucketError`).
5. Handler tests (photos + recordMutation cascade), rules (`pending_cleanup` in `isServerOnlyCollection`) + R-tests, F41 real-logic pin. Node suite 446/446.
6. First push (all code commits) done at start of session 2; PR opened after docs.
7. Risk check: seed tenant `e2e-tenant` passes the whitelist; client `recordMutation` and `PhotoQueue` both send `FirebaseService.environment`, so sweep env matches upload env. `users/{uid}` is client-writable (pre-existing) but `deriveContext` checks tenant membership and the whitelist guards the path.
8. 7 e2e cases added; mutation checks 10/10 killed; docs: test plan status, KNOWN-ISSUES, AGENTS.md, SKILLS 90-91. README has no photos section; unchanged.

## State at end of this session
- Branch pushed, PR to `main`. Waiting for CI (rules + e2e + QML unchanged). **Nothing run against emulators.**
- If CI is red: read `results.xml`/job log first (standing rule). Likely suspects: e2e staff token swap (`fixture.idToken` mutation inside a test), the pre-existing traversal test error code, rules test import of `assert`.

## Next (in order)
1. Fix CI findings on this branch.
2. PH3b (scheduled sweeper) BLOCKED on Taher's answer to Q-I.
3. Remaining e2e: E03, E04, E05, E06, E09, E12.
4. PH4 (client QML) after PH3 merges. PH5 after PH4.

## Session 3 (2026-10-03, account lkdwtaher@gmail.com) -- CI red on PR #113
9. CI on 32fe67e: QML 1553, Functions 302, Rules 45 green; E2E 56/57. Only failure: `test_deleting_a_product_sweeps_its_photos_and_removes_the_marker` ("main 0 not swept"). Job logs unreachable from the sandbox (blob host not allowlisted); PR bot comment + check annotations are the only signal.
10. Ruled out (reproduced in sandbox with firebase-tools' Storage emulator class, admin 12): `bucket.deleteFiles({prefix, force:true})` lists and deletes the prefix correctly and spares a sibling product. Env/prefix wiring also checked: qmltestrunner has no APP_STAGE so the client env is "prd", same as the upload helper.
11. FOUND test bug: `pending_cleanup` is server-only in firestore.rules, so the e2e member-token read gets 403 and `pollEmulatorDoc` maps non-200 to null -> both "marker removed" assertions were vacuous. Fix: `_pollMarker` reads as the emulator admin (`Bearer owner`).
12. Cascade test now checks the marker FIRST and fails with the marker JSON (attempts/lastError) if the sweep did not finish, so the next CI comment names the cause. Root cause of the missing sweep is NOT yet known. This commit is diagnostic + vacuity fix, not a proven product fix.
13. Possible new red: the no-photos test now asserts a real marker removal; if the sweep is broken it fails too (correct).
## Next
- Read the PR bot comment for the marker state, fix the real cause, rerun CI. Then E03-E06, E09, E12, R10; PH3b blocked on Q-I.
