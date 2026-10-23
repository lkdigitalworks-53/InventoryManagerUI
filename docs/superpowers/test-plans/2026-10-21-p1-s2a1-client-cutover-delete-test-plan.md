# Test plan — P1 S2a-1: delete client `runCutover` + drop `stock_movement` from the client entity map

**Branch:** `feat/2026-10-21-p1-s2a1-client-cutover-delete` off `main` @ 773c4ef (PR #151 merged). **Design:** `specs/2026-10-19-p1-s2-design.md` (S2a, split in two this session, see CHECKPOINT).
**Covers:** `qml/model/Gateway.qml` (`runCutover()`, `cutoverUrl`, `cutoverFinished` removed; `"stock_movement"` removed from `_collections`), `tests/tst_Gateway.qml` (1 assertion removed, 3 test functions added), docs.
**Not covered (S2a-2):** `direct` mode, the `mode` property and the 22 test files that assign it. Untouched here on purpose.

## 1. Unit / functional
| Check | Where | Result |
|---|---|---|
| QML tests | CI job `qml-tests` (`qmltestrunner -input tests -platform offscreen`). NOT run in the sandbox (no Qt, standing rule) | CI green on `3755713`: 2107/2107 (PR #151 had 2104, so the 3 new cases ran). Re-check after the review-sweep commit |
| Server suite unchanged | `cd functions && node --test` | 722/722 (run 2026-10-21, Node 22, after `npm ci`; server untouched) |
| Skills index current | `node .github/scripts/skills-index.js --write` | 125 skills |

New QML cases (all in `tst_Gateway.qml`):
- **Negative:** `test_collectionFor_refuses_stock_movement` (`""`).
- **Negative / multi-path:** `test_stock_movement_is_refused_by_the_four_per_entity_write_entry_points_without_touching_the_outbox` (`recordMutation`, `recordEdit`, `recordMutations`, `recordDelta` all return `""`, outbox stays empty). `recordOperation` is not gated on the client by design; the server rejects `stock_movement` per op (`unsupported-entity`, pinned in `operationLogic.test.js` + `movementWiring.test.js`).
- **Regression pin:** `test_client_cutover_api_is_gone` (`typeof Gateway.runCutover/cutoverUrl/cutoverFinished === "undefined"`).
- **Happy path kept:** `test_collectionFor_covers_every_registered_entity` now asserts all 7 registered entities (review sweep added `removed_staff`, which was untested); the unknown-entity case still returns `""`.
- **Review sweep 2026-10-23:** `tst_DataModel_discardResync` lost a dead `ignored = {stock_movement}` branch (test renamed `test_every_gateway_entity_is_mapped`); `DataModel.qml` comment corrected. No new test functions, one new assertion.
Coverage: deletion only; no new branch. The deleted block had no caller and no test. `_captureBeforeStatusIsLost` is still used by 5 other senders (`_send`, `_sendBatch`, `_sendDelta`, `_sendOperation`, `provisionMember`; 6 on `main` with `runCutover`).
Mutation check to run in CI review: put `"stock_movement": "stock_movements"` back, the two stock_movement cases must fail; put `function runCutover() {}` back, the pin must fail.

## 2. Rules / e2e
None changed. `firestore.rules` already has `allow write: if false` on `stock_movements`, so the client narrowing is defence in depth. `firestore.rules` is untouched (S2c). The emulator e2e job is the regression signal.

## Deployed `runCutover` (Taher, 2026-10-23)
Taher deleted the deployed `runCutover` by hand in the Firebase console (the terminal delete command failed). `firebase deploy --only functions` will therefore NOT ask to delete it. Verify: `curl -s -o /dev/null -w "%{http_code}\n" -X POST https://asia-south1-inventorymanager-48392.cloudfunctions.net/runCutover` must print `404`. Not checked by the reviewer (sandbox has no route to `cloudfunctions.net`).

## On-device test plan (Taher, after merge, app build only; no functions deploy needed)
- **Happy path:** sign in, add a product, restock it, complete an order, edit an order, add staff. All work as before.
- **Negative:** nothing in the UI called `runCutover`, so there is nothing to tap. Check Logcat for `ReferenceError` or `is not a function` mentioning `Gateway` while using the app: none expected.
- **Edge cases:** go offline, restock and complete an order, go online: writes drain. Open the Stuck writes dialog with a parked write: Retry and Discard still work.
- **Multiple scenarios:** two devices on one tenant, product edit on A, delete on B: unchanged behaviour (this PR touches no write path).
- **Monkey:** 2 minutes of random taps across Inventory, Orders, Staff, Analysis; no crash, no new warning.
- **Regression watch:** Discard of a parked completion (PR #90 path) and the "Saved. Syncing..." caption (Task 11) still behave.
