# Test plan — Restock as one atomic operation (design Q-RS-1..7 pending)

Standard format (Skill 49). Design: `docs/superpowers/specs/2026-10-16-restock-atomic-operation-design.md`.
Case ids assume the recommended answers (batch id client-generated, purchase doc inside the operation, dialog-open restock id). A different answer changes only the cases marked `[Q-RS-n]`.

**Verification status (2026-10-16):** PLANNED. Nothing written, nothing run. No Qt tools in the sandbox: QML cases will be CI-only; pure-JS and `functions/` cases will be run in Node before push. Coverage target: every new function and branch, 100% lines on `RestockPlan.js`, `OperationKeys` additions and the new server path.

## 1. Unit tests

**`tests/tst_RestockPlan.qml` + Node mirror of the same body** (pure builder, no stores):
- U01 builds exactly three ops in order: inventory delta, stock_batch create, transaction create.
- U02 delta is `{stock:+qty}` with empty floors and clamps.
- U03 batch doc carries productId, supplierId, qty (received and remaining), unit cost, note.
- U04 purchase doc: kind `purchase`, quantity, unitCost, total = qty × cost, party, reason, category, orderId empty.
- U05 same inputs and restock id give identical key, batch id, tx id (determinism).
- U06 different restock id gives different key, batch id, tx id.
- U07 `qty` default 10 when amount is 0 or missing (matches today's `amount || 10`).
- U08 fractional qty kept exactly; unit cost 0 accepted; unit cost non-number falls back to product price.
- U09 key matches `^restock:` and contains no `/` or `~` (server `isSafeDocId` rules).
- U10 ids stay within the 200-character limit for the longest realistic product id.

**`OperationKeys.js`**: U11 `restockKey`, U12 `restockBatchId` (prefix `BAT-RS-`), U13 `purchaseTxId` (prefix `tx-p-`). [Q-RS-1]

**`functions/test/operationLogic.test.js`** (Node, run before push):
- U14 `restock` accepted by `validateOperationRequest`; unknown opType still rejected.
- U15 requestId must start with `restock:`; `completeOrder:` prefix on a `restock` op rejected.
- U16 applying the three ops writes stock, batch, transaction, 3 audit rows, 1 marker (and 1 `receipt` movement row once #146 is in).
- U17 replay of the same requestId returns the first result and writes nothing.
- U18 missing product gives 404 `not-found`, zero writes (batch and transaction not created).
- U19 batch id already exists gives `conflict`, zero writes (stock not incremented).
- U20 stock delta is applied to the current server value, not the client's stale one.

**Store hooks** (reuse Task 9 `addLocalBatch`/`removeLocalBatch`, `addLocalEntries`/`removeLocalEntries`): U21 add then remove restores exact prior arrays; U22 add is idempotent for the same id.

## 2. Regression tests

- R01 (F1) delta rejected with 4xx: no batch exists afterwards, local state unchanged, no purchase record. `tests/tst_InventoryStore_restockAtomic.qml`.
- R02 (F2) applied signal arrives with no live callback (simulated relaunch): local stock, batch, purchase and ActivityLog entry all appear once.
- R03 (F3) offline restock needs no network mint: operation queued with a locally built batch id. [Q-RS-1]
- R04 (F4) second submit with the same restock id sends nothing new and the server returns a replay; one batch, one stock increment.
- R05 parked write on the product still refuses before anything is written (D2 kept).
- R06 supplier auto-promote failure behaves as before (restock proceeds without supplier, `supplierFailed` true).
- R07 pending-mint queue still works for `StockBatchStore.addBatch` callers other than restock (create, import).

## 3. Functional tests

- F01 happy path online: await window met, `callback(true)`, stock equals server value.
- F02 queued path (offline): `callback(true)` immediately, optimistic stock, undo data held.
- F03 await window elapses: same as F02, later applied signal settles to server stock.
- F04 rejected (`not-found`): undo optimistic state, `callback(false, ...)` with cause text.
- F05 rejected (`no-tenant-context`, member suspended): same, text from `FailureCause`.
- F06 Discard from the stuck sheet: nothing server-side, optimistic state undone, no ActivityLog entry.
- F07 two different products restocked back to back: two independent operations, no key clash.
- F08 same product restocked twice with different restock ids: two batches, stock +qty1 +qty2.
- F09 ActivityLog entry text includes qty, new stock, supplier name, reason; deterministic id, replay does not duplicate. [Q-RS-3]
- F10 `RestockDialog`: restock id created at open, reused on double tap, regenerated after a successful close. [Q-RS-4]
- F11 `RestockDialog`: after a rejection and edit, resubmit reuses the same id and succeeds (server holds no trace of the rejected key).

## 4. Monkey tests

- M01 random sequence of restock, retry now, discard, go offline, go online, relaunch (reuse the `tst_OrdersE2E` monkey harness shape) for 200 steps; invariant after settle: for every product, sum of batch `qtyReceived` of restock batches equals total restocked stock, and purchase rows equal batch rows.
- M02 random qty (0, negative, fractional, huge) and cost values: no exception, invalid values refused before any write.
- M03 random double and triple taps at random delays around the await window: at most one batch per restock id.
- M04 server Node monkey: random interleavings of the same requestId from two callers; exactly one marker, one batch.

## 5. Rules tests / E2E

- E01 emulator: apply the operation, assert stock, batch and transaction docs and the audit marker in one snapshot (pattern of `functions/test/index.handlers.recordOperation.test.js`).
- E02 emulator: second call with the same requestId, assert unchanged counts.
- E03 emulator rules: a suspended member gets 403 and **no** doc changed (this is the on-device bug as a test).
- E04 `firestore.rules`: no new client-writable path is introduced by this change (restock goes through the function, unchanged rules); assert by the existing rules suite staying green.
- E05 `tst_OrdersE2E`-style QML e2e for restock is **not written** unless a recipe exists for the `recordOperation` path under `qmltestrunner`; state the decision in the verification block when built.

## On-device test plan

Prerequisites: P1 `recordOperation` deployed with `restock` (Taher confirms), P2 two phones or one phone plus the Firebase console, P3 a product with stock 5 and a known supplier, P4 airplane mode available.

### Happy path
1. Restock the product by 3 with supplier and reason. Expect: dialog closes, stock 8, one new batch of 3, one purchase row, one "Restocked" activity entry.
2. Firebase console: `inventory/<id>.stock` = 8, `stock_batches` has the batch, `transactions` has `tx-p-…`, `audit_log` has one `restock:…` marker.

### Negative
1. Set the member `suspended` in the console, restock by 3. Expect: "Could not restock" with the access text, stock still 5, **no** new batch in the console (was: batch appeared on Retry now).
2. Product with a parked edit (use a product-name edit): Restock refuses with "Fix or discard the stuck change for this product first".
3. Qty 0, negative, blank cost: refused in the dialog, nothing written.

### Edge cases
1. Airplane mode, restock by 3: dialog closes, stuck sheet shows one queued operation; turn network on: stock 8 with one batch (not two).
2. Restock, kill the app immediately, relaunch online: stock 8, one batch, one activity entry.
3. Double tap Confirm: one restock only.
4. Restock the same product twice in a row (3 then 4): stock 12, two batches.
5. Large qty (100000) and fractional qty (2.5) if allowed by the dialog: stored exactly.

### Affected areas
| File | Automated coverage | Where to look on-device |
|---|---|---|
| `InventoryStore.restock` | R01-R06, F01-F08 | Restock dialog, product list stock |
| `RestockPlan.js`, `OperationKeys.js` | U01-U13 | n/a (pure) |
| `StockBatchStore` hooks | U21-U22, R07 | Product history list (batches) |
| `TransactionStore` hooks | U21-U22 | Transactions / Purchased analytics |
| `ActivityLog` | F09 | Activity feed |
| `RestockDialog.qml` | F10-F11 (logic only; page not loadable headless) | Dialog taps, busy state |
| `functions/lib/operationLogic.js` | U14-U20, E01-E03 | Firebase console |
| `StockBatchStore.addBatch` (create, import) | R07 | Add product with opening stock, bulk import: still one batch each |

### Regression tests (run before merge)
1. The suspended-member restock leaves **no** batch (the bug that started this).
2. Create a product with opening stock: still works exactly as before.
3. Bulk import with opening stock: still works exactly as before.
4. Complete an order against a restocked product: FIFO consumes the restock batch, stock matches the batch sum.
