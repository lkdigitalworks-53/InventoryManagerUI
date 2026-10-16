# Test plan — Atomic operations with server-minted ids; restock first (v2, Q-A1..Q-A5 answered)

Standard format (Skill 49). Design: `docs/superpowers/specs/2026-10-16-restock-atomic-operation-design.md` (v2).
Case ids follow Taher's answers (Q-A1 generic mint, Q-A2 no optimistic batch + hidden product, Q-A3 ActivityLog in-op, Q-A4 server seed). Cases marked `[Q-A6]` wait for that open question (sign-out with a queued restock).

**Verification status (2026-10-16):** PLANNED. Nothing written, nothing run. No Qt tools in the sandbox: QML cases CI-only; `functions/` and pure-JS cases run in Node before push. Coverage target: 100% lines and branches on the new server code (`mint`, substitution, guards, counter registry, seed fallback), `RestockPlan.js`, `OperationKeys` additions.

## 1. Unit tests

**Server `functions/test/operationMint.test.js` (Node):**
- U01 `mint` binds a name; `{{name}}` in `entityId` is replaced.
- U02 substitution inside an `after` string value, embedded (`tx-p-{{batch}}`) and whole-string.
- U03 two mints (supplier, batch) bind independent names, ids sequential per counter.
- U04 id format equals client format (parity fixture for `BAT-<year>-NNN` incl. 3-digit padding and >999, `SUP-NNN`).
- U05 counter doc incremented by exactly 1 per mint, in the same transaction.
- U06 counter missing: seed from max existing id for the prefix (none, one, many, other-year ids ignored); then doc created.
- U07 rejected operation (any op fails) leaves the counter unchanged: no gap.
- U08 replay of the same `requestId` returns the same minted ids from the marker and mints nothing.
- U09 guards, each zero writes: unknown counter; placeholder before its mint; unbound name; bad name pattern; >5 mints; placeholder in `before`, `deltas` or a key; resulting id with `/`; duplicate bind name.
- U10 write budget counts counter writes; operation at the ceiling accepted, one over rejected.
- U11 `restock` opType accepted; requestId prefix `restock:` enforced; `completeOrder:` prefix on `restock` rejected.
- U12 full restock op: stock, batch, supplier (when new), purchase doc, activity doc, audit rows, marker, `receipt` movement (after #146) all in one transaction.
- U13 missing product: 404, no batch, no counter change.

**Client pure `tests/tst_RestockPlan.qml` + Node mirror:**
- U14 op order and shapes (mint, create, delta, create, create); no supplier ops when the supplier is known or empty.
- U15 delta `{stock:+qty}`, empty floors/clamps; qty default 10 for 0/missing; fractional kept.
- U16 batch doc fields (supplierId literal or `{{sup}}`), purchase doc fields (kind purchase, total = qty × cost, orderId empty).
- U17 same inputs and key give identical ops (determinism); unit cost non-number falls back to product price.
- U18 key matches `^restock:`, no `/` or `~`, within 200 chars.
- U19 apply-from-results builds local batch, purchase, supplier, activity docs from the marker `results`; replay results identical.

## 2. Regression tests

- R01 (the bug) delta rejected with 4xx: no batch, no purchase, no supplier, no counter movement, local state unchanged. `tests/tst_InventoryStore_restockAtomic.qml`.
- R02 applied signal with no live callback (relaunch): local stock, batch, purchase, activity entry each appear once.
- R03 offline tap: operation persisted with a request id and no ids; nothing minted; applied on reconnect with sequential ids.
- R04 resend of the persisted item (hang, relaunch): same `requestId`, server replays, one batch, one increment.
- R05 two `restock` calls, same product, same tick: second refused by the latch; one outbox item.
- R05b latch released after enqueue (second deliberate restock gets its own key), after refusal, after failure.
- R06 parked write on the product still refuses before anything is queued (D2).
- R07 `completeOrder` marker and result shapes unchanged (golden fixture captured before the engine change).
- R08 `StockBatchStore.addBatch` + pending-mint queue still work for create/import.
- R10 [Q-A6] sign-out with an unapplied queued restock behaves as decided (default pick: sign-out blocked with the count; nothing cleared).
- R09 product hidden from order pickers while its restock is pending; visible again after applied or Discard.

## 3. Functional tests

- F01 online happy path within the await window: callback(true), stock = server value, batch/purchase present with server-minted ids.
- F02 queued (offline) path: callback(true), no local batch yet, picker hides product.
- F03 await window elapses: same as F02, later applied settles state.
- F04 rejected `not-found`: cause text, latch released, nothing local.
- F05 rejected `no-tenant-context` (suspended member): access text; no counter burned (server test U07 pairs with this).
- F06 Discard from the stuck sheet: nothing server-side, picker visible again, no activity entry.
- F07 new supplier name: supplier, batch, purchase created with the minted supplier id in one operation; existing supplier name: no supplier ops.
- F08 same product restocked twice: two batches, ids consecutive, stock +q1 +q2.
- F09 [Q-A3] ActivityLog entry text (qty, new stock, supplier, reason), id `act-<batch>`, replay does not duplicate.
- F10 cancel the dialog before tap: no state anywhere (no outbox item, no latch).
- F11 reject, user edits, resubmits: new key, succeeds.

## 4. Monkey tests

- M01 random restock / retry now / discard / offline / online / relaunch, 200 steps (shape of the `tst_OrdersE2E` monkey): after settle, per product sum of restock batch qty equals restocked stock, purchase rows equal batch rows, batch ids unique and gapless.
- M02 random qty (0, negative, fractional, huge), cost, supplier strings (empty, long, unicode, `{{x}}`, `/`): refused or stored literally; never interpreted as a placeholder.
- M03 random triple taps around the await window: one batch per tap burst.
- M04 server Node: random interleavings of the same `requestId` from two callers and of two different requests: one marker per id, ids unique, counter equals count of applied mints.

## 5. Rules tests / E2E

- E01 emulator: apply a restock, one snapshot of stock, batch, transaction, activity, supplier, counters, audit marker.
- E02 emulator: same `requestId` again, counts unchanged, same ids returned.
- E03 emulator: suspended member gets 403, **no** doc and no counter changed.
- E04 emulator: client REST mint and server mint interleaved on one counter doc, no duplicate id (the two-writer risk).
- E05 `firestore.rules`: existing suite green; [Q-A3] `activity_log` rule reviewed and a test added if the path rules change.
- E06 QML e2e for restock not written unless a `recordOperation` recipe exists under `qmltestrunner`; state the decision in the status block when built.

## On-device test plan

Prerequisites: P1 server with `mint` + `restock` deployed (`recordOperation` itself is live and device-tested per Taher), P2 Firebase console open, P3 product with stock 5 and a known supplier, P4 airplane mode, P5 note the current highest `BAT-` number.

### Happy path
1. Restock by 3, known supplier, reason. Expect: dialog closes, stock 8, one new batch numbered P5+1, one purchase row, one activity entry.
2. Restock with a brand-new supplier name: supplier `SUP-` created, batch and purchase carry it; console shows one `restock:` marker with all docs.

### Negative
1. Member `suspended`, restock: access text, stock 5, **no** batch, **no** new supplier, next successful restock gets number P5+1 (no gap).
2. Product with a parked edit (edit a product name offline): refused with the stuck-change text.
3. Qty 0, negative, blank cost: refused in the dialog.

### Edge cases
1. Airplane mode, restock by 3: dialog closes, product hidden from the new-order picker, stuck sheet shows one queued item; network on: stock 8, one batch, product visible again.
2. Restock, kill the app, relaunch online: stock 8, one batch, one activity entry.
2b. [Q-A6] Airplane mode, restock, try to sign out: blocked with "1 change not synced"; network on, it applies, sign-out works.
3. Double tap Confirm: one restock.
4. Cancel the dialog, reopen, restock: works, no stray batch or id burned.
5. Two phones restock the same product at once: two batches, stock +q1+q2, ids distinct and consecutive.
6. Supplier name `{{batch}}` or with `/`: stored as typed, not interpreted.

### Affected areas
| File | Automated coverage | Where to look on-device |
|---|---|---|
| `functions/lib/operationLogic.js` (mint, substitution, guards, budget) | U01-U13, R07, M04, E01-E04 | Firebase console |
| server counter registry | U04-U06, E04 | counters docs, batch/supplier numbers |
| `InventoryStore.restock`, `RestockPlan.js`, `OperationKeys.js` | U14-U19, R01-R06, F01-F11 | Restock dialog, stock |
| `StockBatchStore`, `TransactionStore`, `SupplierStore` apply-from-results | U19, R02 | batch history, transactions, suppliers |
| `ActivityLog` (id param) | F09 | Activity feed |
| Order pickers (pending-restock hide) | R09 | New order picker |
| `StockBatchStore.addBatch`, pending-mint queue, `SupplierStore.addSupplier` | R08 | Add product with opening stock, import |

### Regression tests (run before merge)
1. Suspended-member restock leaves no batch and no number gap (the bug that started this).
2. Complete an order: marker and totals as before the engine change.
3. Create a product with opening stock and bulk import: unchanged (still client-minted).
4. Order completion against a restocked product: FIFO consumes the restock batch; stock equals batch sum.
