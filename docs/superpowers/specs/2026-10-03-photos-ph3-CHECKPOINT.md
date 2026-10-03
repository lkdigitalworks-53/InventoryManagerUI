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

## Session 3b (2026-10-03) -- CI log (results.xml) analysed
14. CI on f11fe0d: E2E 56/57, same test. New message: "marker removed but main 0 still in Storage". Log lines decoded:
    - the product-doc and marker polls were VACUOUS: `pollEmulatorDoc` begins with `latest = null`, so `d === null` is true on tick 1 before any response. Their real replies leak into the NEXT test's log (PRD-010 `status 200`, PRD-012 `status 404 ... pending_cleanup`).
    - `[Gateway] recordMutation conflict -- dropping stale write ... inventory PRD-010` = the delete never applied. Cause: test uploaded photos via direct POST, so the client cache lacks `photoIds`; `deleteProduct` sent that stale row as CAS `before`; server 409 (strict CAS incl. photoIds, KNOWN-ISSUES item 1/F5).
    - So the sweep code was never exercised. Server code is NOT implicated; no server change.
15. Fix (test only): `requireResponse` flag on `pollEmulatorDoc` (+ `_pollDoc`), absence polls pass `true`; cascade test calls `InventoryStore.syncFromFirebase()` and waits for the server `photoIds` before `deleteProduct`; no-photos test uses strict polls.
16. KNOWN-ISSUES item 6 added (two other tests still vacuous, left alone on purpose).
17. UNVERIFIED: nothing run (no Qt in sandbox). Possible next red: the cascade test now really runs the sweep (marker + prefix delete through the Functions+Storage emulators); if it fails, the message names marker JSON or the leftover object.
## Next
- Read CI on this commit. Then E03-E06, E09, E12, R10; PH3b blocked on Q-I.

## Session 4 (2026-10-03, account tsadmin@gmail.com) -- CI GREEN on PR #113
18. Verified via API, not assumed: head `656cd2d`, all 5 checks success. Bot comment: 1957/1957 (QML 1553, Functions 302, Rules 45, E2E 57/57). The cascade e2e now passes with real (non-vacuous) polls, so the sweep + marker removal ran through the Functions+Storage emulators.
19. R10 is NOT missing: `test/storage.rules.test.js` (7 tests, run by checks.yml next to the firestore rules) already pins public read, client write/delete denied, default-deny. `storage.rules` is unchanged in this PR. Test plan row R10 re-marked as covered by pre-existing tests (by inspection, CI does not report the two rules files separately).
20. Commit identity this session: `tsadmin@gmail.com` (Taher's instruction). Earlier sessions used other ids; history is not rewritten.
21. Docs-only branch `docs/2026-10-03-ph3-ci-green-sync` stacked on the PH3 branch. No code touched. SKILLS/AGENTS/README: no change needed (no new lesson, no behaviour change).
## DECISION PENDING (asked Taher, not decided by Claude)
- Add E03/E04/E05/E06/E09/E12 to #113, or ship #113 as is and do them in a follow-up PR? Claude recommends follow-up: each is an unrun e2e case, #113 is 23 files / +1653 and just went green after two red rounds; E03/E05/E09 also need new fixtures/hooks (third seeded user, Storage emulator failure hook, second tenant).
- PH3b stays blocked on Q-I (Blaze / Cloud Scheduler, who deploys). PH4/PH5 are separate PRs after merge.
## Next
1. Taher answers the pending decision. Default if "your call": follow-up PR `test/2026-10-04-ph3-remaining-e2e`, E04 + E06 first (no new fixtures), then E12, then E03/E05/E09.
2. Merge #113, then PH4 design->code.
