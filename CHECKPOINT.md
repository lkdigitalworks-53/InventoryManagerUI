# CHECKPOINT — 2026-10-04: order-completion delta behind a parked write (repro + fix)

**Branch:** `test/2026-10-04-order-completion-parked-delta-repro` (off `main` @ `f530865`, PR #119 merged).
**Commit identity:** `taher.lkdw53@gmail.com`. **Rules (standing):** branch only; push without asking (PAT only in the push header via `/tmp/push.sh`, never in `.git/config`); no build/run; no Qt tooling in the sandbox (CI = the QML signal); small scope; honest advisor, grill before deciding. Skills read: brainstorming, ponytail, qt-qml. Caveman FULL (chat only).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-04-pr119-merged-CHECKPOINT.md`.
**Order agreed (Taher):** #120 -> #119 (both merged) -> order-completion repro -> PH3b.

## Step log
1. Cloned repo, read memory + archived checkpoint, read `DataModel._tryCompleteOrder`, `InventoryStore.deductStock`, `Gateway.recordDelta`, `OutboxStore.enqueueDelta/dueItems/_keysForItem`, E2E parked-write pattern (`tst_StockBatchStoreE2E._parkEditFor`), `tst_OrdersE2E`.
2. Answered the checkpoint's open question (code read, NOT run): order completion does NOT use `recordOperation`. `grep -rn "recordOperation(" qml` finds no caller (only the definition). Completion = one `InventoryStore.deductStock` per line -> `Gateway.recordDelta("inventory", id, {stock:-qty}, {stock:0}, ...)` -> `OutboxStore.enqueueDelta`. A delta has NO CAS `before`; the server applies the increment with a floor. So mechanism (A) needs no CAS reasoning.

## Hypothesis (UNVERIFIED, from code read)
- `enqueueDelta` only coalesces into a non-in-flight item that has `.deltas` for the same key. A parked SINGLE edit has none, so the delta is appended as a separate item with key `inventory/<id>`.
- `OutboxStore.dueItems` marks the parked item's keys `claimed`; the later delta shares `inventory/<id>`, hits `clash`, and is skipped on every drain. Never sent.
- `deductStock`'s callback never fires -> `_afterAllDeltas` never runs -> `dataModel._completingOrderIds[orderId]` stays true -> every retry shows "This order is already being completed — please wait" until app restart. Order stays `pending`. The `stock_batch` FIFO deltas (other keys) already went out, so batches are decremented while `product.stock` is not.
- After relaunch the delta is still in the persisted outbox. When the parked edit is Retried/Discarded, the delta finally sends: stock drops for an order that is still `pending`; completing it again deducts twice. This is the drift risk, bigger than the hang.

## Open decisions (asked in chat, answers not yet recorded)
1. Repro form: red-by-design E2E (draft PR) vs characterization test that flips in the fix commit.
2. Mechanism: (A) deltas ignore a parked single edit's key; (B) refuse completion like restock; (C) leave as is. Parked DELETE must keep blocking under A.
3. Scope of the fix: only `deductStock`/`creditStockNoBatch`, or any delta/all-delta op.

## NOT verified
Nothing run here (no Qt toolchain, standing rule). The hang and drift above are code-read hypotheses until the E2E repro runs on CI.
