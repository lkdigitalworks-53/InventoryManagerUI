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
- **Sweep fixes (2026-10-24, PR #155):** (S1) the unreachable `parentId === ""` branch in `InventoryStore.updateProduct` is deleted (coverage only goes up; the 2104 prediction does not change). (S4 + I1) `tst_StockBatchStore`, `tst_InventoryStore_upsertMany` and `tst_Gateway` now blank `AuthStore.idToken`, set `isAuthenticated = false` and clear the on-disk session in `init()`, so a leaked token or authenticated singleton cannot make a unit test call production or refresh a token. (N2) stale "gateway mode" / "direct mode" wording removed from 6 test files and `AGENTS.md`; README line 344 contradiction fixed.
- **Mutation check for CI review:** put `property string mode: "gateway"` back: the pin must fail.

## 3. Rules / e2e
No rules change. E2E: the 9 `Gateway.mode = "gateway"` lines are removed; the emulator run is the regression signal for the real gateway path.

## On-device test plan (Taher, after merge; app build only, no functions deploy)
Rewritten 2026-10-24 (sweep, S2): numbered steps, expected result per step, all unticked. Nothing here has been run.

**Prerequisites**
- P1. App built from `main` after #154 + #155 merge. No functions deploy needed (server untouched).
- P2. Signed in as owner on a dev tenant (a fresh user + tenant is fine). Tenant has 2 products, 1 supplier, 1 staff member.
- P3. A second device, or a second login on an emulator, for R4.
- P4. `adb logcat` running, filtered on `qml`, for N3.
- P5. Airplane-mode toggle at hand; an Excel file with 5 products (H8) and one with 300 rows (E3).

### Happy path
| # | Action | Expected |
|---|---|---|
| H1 | Inventory > Add product (name, SKU, stock 10) | Row appears at once. Within a few seconds the Activity log shows "Product added". No stuck-writes caption in the header. |
| H2 | Open that product > Restock +5 | Stock shows 15. A stock-batch row exists. Activity shows the restock. |
| H3 | Edit the product: change the name and the stock to 12, enter a reason, save | List shows the new name and 12 at once. After the sync Activity shows "Product updated: <new name>" and Transactions shows one field-change row and one stock-adjustment row carrying your reason. |
| H4 | Orders > create an order for 2 units > Approve | Order completes ("Saved. Syncing..." then done). Stock drops by 2. A sale appears in Transactions. |
| H5 | Edit that completed order (change a line price) | Order shows the new total. Activity entry appears. No error toast. |
| H6 | Staff > Add staff member with a role; then delete that member | Member appears, then disappears. No stuck-writes caption. |
| H7 | Suppliers > Add supplier | Supplier listed, Activity entry present. |
| H8 | Import the 5-product Excel file | 5 products appear; Activity shows the import. No stuck-writes caption. |

### Negative
| # | Action | Expected |
|---|---|---|
| N1 | Turn airplane mode on. Add a product. | Product shows locally; header shows the offline/syncing state; no crash, no error dialog. |
| N2 | Turn airplane mode off | The queued product syncs within a minute; Activity entry appears only now. |
| N3 | In logcat, look for `ReferenceError`, `is not a function`, `Cannot assign to non-existent property` mentioning `Gateway`, `mode`, `_writeDirect` during H1-H8 | None. |
| N4 | Sign out and back in while a write is queued (go offline, add a product, sign out, sign in, go online) | The queued write resumes and syncs; nothing is lost or duplicated. |

### Edge cases
| # | Action | Expected |
|---|---|---|
| E1 | Offline: restock a product, then approve an order; go online | Both drain, in the order you made them; final stock is correct. |
| E2 | Park a write (the stuck-writes dialog from #90 / S1): open the dialog | Retry now and Discard still work; a discarded completion reverts the order to pending. |
| E3 | Import the 300-row Excel file | Chunked; all 300 products arrive; no stuck-writes caption. |
| E4 | Queue a write offline, force-stop the app, reopen online | The write drains on its own. |
| E5 | H3 done offline (edit name + stock with a reason) | Activity entry and ledger rows appear only after reconnect, not before (they wait for the server ack). |

### Affected areas
Inventory, Orders (completion, "Saved. Syncing..."), Suppliers, Staff, Transactions, Stock batches, Activity log, Stuck-writes dialog, Excel import.

### Regression
| # | Action | Expected |
|---|---|---|
| R1 | Order completion that gets parked, then Discard (PR #90 path) | Order goes back to pending. |
| R2 | Delete a product that has batches | Product and batches go; no orphan rows. |
| R3 | Add a product photo, then delete it | Upload works; delete removes it. |
| R4 | Two devices edit the same product at the same time | Second saver gets the conflict toast, as before this change. |

### Monkey
| # | Action | Expected |
|---|---|---|
| M1 | 2 minutes of random taps across Inventory, Orders, Staff, Suppliers, Analysis; toggle airplane mode twice | No crash, no new warning in logcat, caption clears once online. |
