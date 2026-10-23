# Test plan — P1 S2a-2: delete `Gateway` direct mode and the `mode` property

**Branch:** `feat/2026-10-23-p1-s2a2-delete-direct-mode` off `main` @ `d5882ee` (PR #152 + #153 merged). **Design:** `specs/2026-10-19-p1-s2-design.md` (S2a).
**Covers:** `qml/model/Gateway.qml` (`mode`, `_writeDirect`, `_writeDirectBatch`, 3 `direct` branches, 4 `mode !== "gateway"` guards and the error strings `delta-requires-gateway-mode` / `operation-requires-gateway-mode` removed), 3 stale comments (`Main.qml`, `InventoryStore.qml`, `TransactionStore.qml`), 31 test files (every `Gateway.mode = ...` and `_prevMode` plumbing removed; `tst_Gateway.qml` rewritten where it forced `"direct"`).
**Why:** direct mode wrote Firestore without an audit_log entry or ledger rows. Nothing in the UI switched it, but the code path existed. Blast radius counted from `main`: 89 uses in 32 files (Skill 124 said 79 / 22: it missed `test/e2e`).

## 1. What is already covered (before this change)
| Layer | Covered by | Notes |
|---|---|---|
| Unit | `tst_Gateway.qml` 183 functions: enqueue shape, collection map, delta/operation callbacks, stuck writes, discard | CI only (no Qt in sandbox) |
| Functional | 21 store/DataModel QML files that forced `"gateway"` | same |
| Rules | `test/firestore.rules.test.js` 45 | untouched |
| E2E | `test/e2e/*` 93 (emulator) | 9 files forced `"gateway"`; now the only path |
| Regression | server suite 722 | untouched |

## 2. Unit / functional (this change)
| Check | Where | Result |
|---|---|---|
| QML tests | CI `qml-tests` | **predicted 2104** (2107 on `main` − 4 deleted + 1 pin). Not run in the sandbox |
| Server suite | CI `functions-tests` | expected 722 (server untouched) |
| Script suite + index | `node --test .github/scripts/__tests__/*.test.js`; `skills-index.js --check` | run in session, see CHECKPOINT |

Deleted (their premise is gone): `test_recordDelta_requires_gateway_mode`, `test_recordOperation_requires_gateway_mode`, `test_discardParked_refuses_outside_gateway_mode`, `test_recordMutations_direct_mode_is_unaffected_by_chunking`.
Renamed (dropped `in_gateway_mode`): 3 enqueue tests. Added: `test_direct_mode_property_is_gone` (`typeof Gateway.mode === "undefined"`).
- **Happy path:** every kept enqueue / delta / operation / stuck / discard test now runs on the only path.
- **Negative:** unknown entity, bad operation request, `stock_movement` refusals unchanged.
- **Edge:** `drainNow()` is now always live in `tst_Gateway`; protected by the empty-`idToken` guard in `_send*` and by `init()` clearing `AuthStore.idToken` and the on-disk session.
- **Multi-scenario / monkey:** `test_monkey_parked_writes_agree_across_state_outbox_and_drain` kept as is.
- **Isolation:** `tst_Gateway.init()` used to leave `mode = "direct"` for every later file (one qmltestrunner process). That leak is gone. Six later files wrote through stores without ever setting a mode; two really enqueue (`tst_InventoryStore_upsertMany`, `tst_StockBatchStore`) and now clear the outbox in `cleanup()`.
- **Mutation check for CI review:** put `property string mode: "gateway"` back: the pin must fail.

## 3. Rules / e2e
No rules change. E2E: the 9 `Gateway.mode = "gateway"` lines are removed; the emulator run is the regression signal for the real gateway path.

## On-device test plan (Taher, after merge; app build only, no functions deploy)
**Prerequisites:** signed-in owner on a dev tenant with 2 products, 1 supplier, 1 staff; one second device or a second login for the multi-device case; airplane-mode toggle at hand.
### Happy path
Add a product, restock, complete an order, edit an order, add and delete staff, add a supplier, import 5 products from Excel. All sync (no stuck-writes banner) and each leaves an Activity entry.
### Negative
Sign out and back in mid-sync: queued writes resume. Try a write with the network off: it queues, no crash. Check Logcat for `ReferenceError` / `is not a function` / `Cannot assign to non-existent property` mentioning `Gateway`: none.
### Edge cases
Offline: restock + complete an order, go online, both drain in order. Park a write (Stuck writes dialog): Retry and Discard still work. Bulk import of 300 rows: chunked, all arrive. Kill the app with a queued write, reopen: it drains.
### Affected areas
Inventory, Orders (completion, "Saved. Syncing..."), Suppliers, Staff, Transactions, Stock batches, Activity log, Stuck-writes dialog, Excel import.
### Regression tests
PR #90 completion path (parked completion discard reverts to pending); product delete cascade; photo upload + delete; two devices editing the same product (conflict path unchanged).
### Monkey
2 minutes of random taps across Inventory, Orders, Staff, Suppliers, Analysis, toggling airplane mode twice: no crash, no new warning.
