# Design — Round 2: I1–I4 + 3 known gaps (async-write-sequencing review)

**Branch:** `fix/async-write-sequencing-review-fixes` (continuing directly — this is already
the fix-implementation branch, C1–C8 are its first 8 commits).
**Context:** C1–C8 (all 8 Critical findings) are done and verified (see
`2026-08-08-orders-normalize-consumption-fix-CHECKPOINT.md` for the re-verification: all 8
independently traced against code, `functions/` test suite actually run — 87/87 passing).
Remaining scope, confirmed with Taher via `/superpowers:brainstorming`:

1. I3 — `acquireLock`/`releaseLock` skip entity allowlist validation
2. I4 — 3 dialogs' "try again" lock-denial message doesn't actually retry
3. StockBatchStore's 3 FIFO functions → `recordDelta`, **full async rewrite** (not the smaller
   mechanical-swap alternative — explicitly chosen after being shown the real blast radius:
   5 call sites in `DataModel.qml`, 3 with retry-loop coupling to the synchronous return value)
4. Partial-multi-line-completion gap (new, found during C5) — successful line's `product.stock`
   deduction isn't reversed when a sibling line's deduction fails
5. `ConfirmReturnSheet` lock-span gap — lock releases before the user confirms the return
6. I2 — bulk order approval never acquires a lock
7. I1 — `applyMutationsBatch` has no CAS check (**live path**, not dead code — feeds every
   bulk import: Supplier/Order/StockBatch/Inventory/Transaction `Gateway.recordMutations`)

I5 is excluded — resolved as a side effect of C1, only remaining action is an on-device
`qmltestrunner` run (not code).

## Sequencing (small/mechanical → large, so the harder items build on proven patterns)

1. I3 (mechanical, ~15 min)
2. I4 (same pattern × 3, low-medium)
3. Partial-multi-line-completion (reuses C4's `creditStockNoBatch`, medium)
4. `ConfirmReturnSheet` lock-span handoff (medium, UI coordination)
5. I2 bulk-approve locking (medium, reuses `OrderDetailDialog`'s pattern)
6. StockBatchStore full async rewrite (large — done after the above so the codebase already has
   fresh, tested examples of every sub-pattern it needs: delta+floor calls, retry-on-drift,
   callback-chained completion)
7. I1 batch CAS (large but contained — Cloud Function change + `Gateway._sendBatch` response
   handling; reuses C3's existing `mutationConflicted` signal and all 5 stores' handlers as-is,
   no new store-side code)

## Per-item design

### I3 — entity allowlist
`validateAcquireRequest` and `validateReleaseRequest` (same gap in both) accept any string for
`entity`. Fix: import `ENTITY_COLLECTIONS` from `gatewayLogic.js`, reject with
`{ok:false, status:400, error:"unsupported-entity"}` if not a member — identical shape to
`validateMutationRequest`. Add tests to `functions/test/lockLogic.test.js`.

### I4 — dialogs' try-again
`OrderDetailDialog`, `EditProductDialog`, `StaffDetailDialog` all have the same triplicated
`_lockState`/message pattern. On Save-while-not-granted: kick off a fresh `LockManager.acquire()`,
update `_lockState` and the error label from its result. Does **not** auto-continue the save on
success — user taps Save again. (Rejected auto-continuing: makes `_save()` re-entrant for
marginal UX gain, adds double-submit risk in money-handling code.) Applied identically at all 3
sites; not extracting a shared helper this round (existing triplication is already tolerated in
this codebase; can revisit as a separate cleanup if Taher wants it).

### Partial-multi-line-completion
In `_tryCompleteOrder`'s (and `_tryAdjustOrder`'s) per-line `deductStock` callback, push
`{productId, qty}` onto a new `succeededLines` array when `result.ok`. In `_afterAllDeltas`, when
`deltaFailed`, after the existing FIFO-restore loop, also loop `succeededLines` and call
`InventoryStore.creditStockNoBatch(productId, qty)` for each — reuses the exact primitive already
used for the same "credit product.stock without touching batches" shape in the returns flow
(`DataModel.qml:634,889`), already `recordDelta`-based from C4.

### `ConfirmReturnSheet` lock-span
Handoff flag, not re-acquire (re-acquire races against `OrderDetailDialog`'s own release — traced
in chat: `openFor()` runs synchronously before `dlg.close()` in the same call stack, so a release
fired moments later would kill a freshly re-acquired lock).
- `OrderDetailDialog._save()`: set `_lockHandoffPending = true` immediately before `dlg.close()`
  in the `linesChanged` branch.
- `OrderDetailDialog.onClosed`: `if (_lockHandoffPending) { _lockHandoffPending = false }` —
  skip the release, ConfirmReturnSheet now owns it.
- `ConfirmReturnSheet`: add `onClosed: LockManager.release("order", orderId)` — covers confirm,
  cancel, and tap-outside-dismiss identically (mirrors `OrderDetailDialog`'s own `onClosed`).

### I2 — bulk-approve locking
`OrdersPage._approveAllPending()`'s `_next()` recursion wraps `dataModel.tryCompleteOrder()` with
zero locking today. Fix: wrap each iteration —
`LockManager.acquire("order", orderId, cb)` → if granted, `tryCompleteOrder()` then
`LockManager.release()` → `_next()`; if denied/error, push to a **separate** `lockedOut` list
(not the existing `failed` "Insufficient Inventory" list — that message would be actively wrong
for a lock denial) and show a second dialog/line: "N orders skipped — being edited elsewhere,
try again shortly" when `lockedOut.length > 0`.

### StockBatchStore full async rewrite
`consumeFifo(productId, qty)` becomes `consumeFifo(productId, qty, callback)`:
- Keep the FIFO *selection* logic client-side (walking local `batches[]` oldest-first, deciding
  take-amounts per batch) — this is business logic, not a place to push into the Cloud Function.
- Each batch's actual decrement becomes `Gateway.recordDelta("stock_batch", batchId,
  {qtyRemaining: -take}, {qtyRemaining: 0}, {}, cb)` (same floor pattern as `deductStock`).
- Collect all per-batch delta results; callback fires once all have resolved with
  `{consumption: [...], shortfall: N}` — `shortfall` is qty that came back floored (someone else
  drained the batch first), letting the caller retry against `topUpOldest` exactly like today's
  `consumed < qqty` check, just moved into the callback.
- `topUpOldest` and `restoreFifo` convert the same way individually (single-record delta, no
  selection logic, much smaller change each) — `topUpOldest`'s "create synthetic batch" branch
  (`addBatch`) is a create, not a delta, stays as `recordMutation` (matches how creates are handled
  elsewhere; deltas are for existing-doc numeric fields only).
- `DataModel.qml`'s 3 retry-loop call sites (`_tryCompleteOrder`, `_tryAdjustOrder`, the exchange
  path in `adjustOrder`) restructure their post-`consumeFifo` retry-and-topUp logic to run inside
  the new callback instead of immediately after a synchronous call. The outer per-line
  `deductStock`-await structure these functions already have (from the original async-write-
  sequencing work) is the direct template — same shape, one more level of callback nesting for
  the batch-consumption step.
- `_reconcileBatchesForStockEdit` (line 994) already ignores the return value — trivial, just
  needs a no-op callback.

### I1 — batch CAS
`applyMutationsBatch`: read all `workingRef`s (not just `auditRef`s) in the transaction's read
phase, `_deepEqual(current, item.before)` per item — reuses `_deepEqual` from `gatewayLogic.js`
(export it). Any conflict → reject the **whole batch**, matching the module's own stated
all-or-nothing design (`functions/lib/batchMutationLogic.js`'s header comment), returning
`{ok:false, status:409, conflicts:[{entityId, current}, ...]}` for every conflicting item (not
just the first) so the client isn't left guessing.

Client (`Gateway.qml:_sendBatch`): on 409, `OutboxStore.markSent` (drop, don't retry — retrying
with the same stale `before` values can never succeed) and fire the **existing** `mutationConflicted`
signal once per item in `conflicts[]`. All 5 stores are already wired to it from C3 — no new
store-side code needed. Remove the "deliberately NOT given conflict handling" comment block, it's
now stale.

## Verification plan (this sandbox has no Qt/qmltestrunner — see prior checkpoint)

- `functions/` changes (I1, I3): actually run `npm test` — this sandbox CAN run Node.
- `qml/` changes: static trace against existing + new tests, same as the C1 checkpoint's approach.
  Every new/changed function gets a written trace of its test(s) in the per-item checkpoint.
- Full on-device `qmltestrunner` pass is still owed before merge — flagged consistently, not
  re-litigated per item.
