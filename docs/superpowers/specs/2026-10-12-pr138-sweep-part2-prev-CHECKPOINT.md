# CHECKPOINT — 2026-10-12 PR #138 sweep part 2 (resume here)

**Branch:** `feat/2026-10-08-photos-ph4-r1-404-body` (PR #138, base `main`). Last CI-green commit before this part: 1ba0050 (docs-only 6a5f643 on top). Part 2 is pushed as one commit; CI result: see the PR comment. NOTHING IS DEPLOYED, app not built or run.
**Commit identity:** `lkdwtaher@gmail.com`. PAT only in the push command, never in a file or git config.
**Previous checkpoint:** `docs/superpowers/specs/2026-10-09-pr138-final-sweep-prev-CHECKPOINT.md` (R1 build) and the sweep review note `docs/superpowers/specs/2026-10-09-pr138-final-sweep-review.md` (now includes part 2).
**Decision (Taher, 2026-10-12):** fix O1, O2, O3 in PR #138 only; write PH5 e2e E01-E03; tick the reported device tests.

## Done in part 2
- [x] O2/O3: `PhotoQueue._isInFlight` guard in `_failUpload` and new `_completeUpload` (`qml/model/PhotoQueue.qml`)
- [x] O1: `PhotoQueue.purgeOrphanedFailures()` + `InventoryStore.onListCompleteChanged` trigger
- [x] 18 QML tests in `tests/tst_PhotoQueue.qml` (FU13-FU30 in the test plan; CI only). Node harness of the shipped functions: 10 scenarios pass.
- [x] PH5 e2e `test/e2e/tst_ProductLegacyPhotoUrlE2E.qml` (E01, E02, E03, E03b) + `E2EHelpers.createEmulatorDoc` + `functions/test/e2eHelpers.firestoreFields.test.js` (4 tests)
- [x] Device tests ticked per Taher in the test plans: R1, PH4, PH3 server cascade, PH3b DV-1..DV-9, PH5, S3, S2b, batch cleanup, product/order delete UI
- [x] Docs: sweep review, KNOWN-ISSUES, roadmap, README index, AGENTS, Skill 113 (114 skills, index regenerated)
- [x] Sandbox verification: functions 626/626, skills index current, CI-script tests unchanged

## Honest caveats
- QML tests and the e2e are CI-only: not run here. CI is the proof.
- R1 "row gone" device step was run on the pre-O1 build. NEW unticked device steps: O1 re-check and O2 sign-out check (test plan `2026-09-30-photos-s3-s4-s5-test-plan.md` section 9).
- O1 trade-off: the later purge uses the row-gone check alone (R1's body check governs only the immediate 404).
- Device ticks are wholesale per Taher's report; step-level results were not itemised.
- O4 stays open (a server rename of `product-not-found` makes R1 inert, safe).

## NEXT
Taher: read the CI result on the PR, squash-merge #138. Then device re-check of O1/O2, then the atomic-operation work.
