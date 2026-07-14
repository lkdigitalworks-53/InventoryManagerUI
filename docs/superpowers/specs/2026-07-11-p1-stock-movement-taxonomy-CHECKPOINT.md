# Checkpoint — P1 Stock-Movement Taxonomy

**Date:** 2026-07-11
**Branch:** `feature/p1-stock-movement-taxonomy` (off latest `main`, which now includes the merged
P0 gateway fast-follow — verified content-level, not just commit messages, before branching)
**Status:** Audit complete. No code changes yet — several real scope/design decisions need
sign-off first (see below).

## Context

P0 (gateway + inventory/stock/orders/staff/suppliers migration) is merged to `main` via PR #32.
This is a fresh session starting P1 per the roadmap
(`docs/superpowers/specs/2026-06-06-india-compliance-roadmap-design.md` §4.3, CGST 56(2)).

## What P1 actually is (spec §4.3)

A new immutable `stock_movements/{id}` ledger. `kind` enum:
`receipt | sale | loss | theft | destroyed | write_off | free_sample | gift | adjustment`.
Each row: `{ id, productId, kind, qty, reason, valueAtCost, batchRef?, serverTimestamp, actorUid }`.
Plus: "a derived read model produces the opening balance / receipts / supplies / closing balance
register required by CGST 56(2)" — this is a second, distinct deliverable (a report/page), not
just a data-model change.

## Audit findings — mapping existing code to the taxonomy

`stock_movement` is already a registered entity (`ENTITY_COLLECTIONS`/`Gateway._collections` both
have it, from the original P0 session) — nothing to add there. But **zero code anywhere in `qml/`
writes to it** — no `StockMovementStore` exists, and grepping the whole tree for the taxonomy
words themselves (loss/theft/destroyed/write_off/free_sample) returns only unrelated English
(`onDestruction`, "focus-loss", etc.) — confirmed false positives, not prior art.

Existing stock-changing code paths, and how cleanly each maps to a `kind`:

| Code path | Current behavior | Kind mapping | Notes |
|---|---|---|---|
| `InventoryStore.restock()` | +stock, `TransactionStore.recordPurchase`, `StockBatchStore.addBatch`, free-text `reason` | **`receipt`** — clean | `valueAtCost` = `batchCost`, already computed right there |
| Order completion (`DataModel._tryCompleteOrder`, `completeImportedOrder`) → `InventoryStore.deductStock` | −stock after `StockBatchStore.consumeFifo` | **`sale`** — clean | `valueAtCost` available for free from `consumption[]`'s per-batch detail — no new cost-tracking needed |
| `InventoryStore.updateProduct()`'s direct stock-field edit | ±stock, `TransactionStore.recordStockAdjustment`, free-text `reason` | **Ambiguous — this is the gap.** | Today there's no `kind` at all here, just free text. This is exactly where loss/theft/destroyed/write_off/free_sample/gift/adjustment needs a real UI decision (see Q2 below) |
| `InventoryStore.creditStockNoBatch()` (returns flow, `DataModel`) | +stock, no batch, no `TransactionStore` entry today | **Not in the spec's enum at all.** | A return isn't a receipt (no supplier), doesn't cleanly fit any listed kind. Real decision needed (Q3) |

The existing free-text `reason` field (added in an earlier, separate feature — "Reason field on
product adjustments") is exactly the `reason` field the spec wants — this isn't new work, it's
already wired on `restock()` and `updateProduct()`. What's missing is the structured `kind`
alongside it.

## Open decisions (need sign-off before writing code)

1. **Scope for this session.** Full P1 is: (a) `StockMovementStore` + wiring the 3-4 existing
   mutation paths to emit movement records, **and** (b) the opening/closing-balance register
   report — a distinct, sizable UI deliverable in its own right. Recommend splitting, same as P0
   was split into gateway-core + fast-follow: do (a) this session, treat (b) as its own follow-up.
   Alternative: do both if you want it all in one sitting — flag if so, it changes the shape of
   the plan a lot.
2. **The `kind`-selection UI for manual adjustments.** When a user decreases stock via Edit
   Product, should picking a `kind` (loss/theft/destroyed/write_off/free_sample/gift/adjustment)
   be **required** (accurate, but more friction) or **optional with an "adjustment" default**
   (less friction, but risks most real loss/theft events landing in a useless generic bucket,
   undermining the whole point of the CGST register)?
3. **Returns.** `creditStockNoBatch` doesn't map to any kind in the spec's enum. Options: (a) no
   `stock_movements` row for returns at all — pure working-tier update, not ledger-relevant;
   (b) treat as `adjustment`; (c) add a `return` kind not in the original spec (deviation worth
   flagging explicitly, not doing quietly).
4. **Gateway routing.** Assume new `stock_movement` writes go through `Gateway.recordMutation`,
   exactly like every P0-migrated entity (behavior-preserving today since `mode` is still
   `"direct"`) — confirming this is the default rather than something to silently assume, since
   `stock_movements` is a brand-new collection being written for the first time, not an existing
   one gaining audit coverage.

## Not yet done / next steps

Nothing implemented. Waiting on the 4 decisions above before any design/plan doc or code.

---

## Session complete — 2026-07-11

All 6 plan tasks done. Summary:

- **New `qml/model/StockMovementStore.qml`** — write-only this session, `recordMovement(kind,
  productId, qty, reason, valueAtCost, batchRef)` → `Gateway.recordMutation("stock_movement",
  ...)`. Registered in `qml/model/qmldir`.
- **`kind` enum**: the spec's 8 values + `sales_return` (documented deviation — CGST Rule 56(2),
  verified via web search, has no "return" column; a sales return is GST-mechanically a
  reduction to "supply," not an independent event).
- **All 5 wiring points done**: `restock()` → `receipt`; order completion (both
  `_tryCompleteOrder` and `completeImportedOrder`) → `sale`, one movement per FIFO-consumed batch
  portion, cost/batchRef free from `consumeFifo`'s own return shape; returns
  (`_reverseCompletedOrder`, `_tryAdjustOrder`) → `sales_return`, plus an additional `destroyed`
  for the damaged-goods branch — a real gap fix, that branch had zero ledger footprint before
  today; manual stock-decrease adjustments (`EditProductDialog` → `updateProduct`) → a required
  `kind` picker threaded through the full signal chain, enforced at the dialog's validation step.
- **No new Cloud Function code** — `stock_movement` was already a registered entity from the
  original P0 session. This means **none of this session's work is TDD-verified with
  `node --test`** — it's all QML, and (same as P0) this sandbox has no Qt toolchain. Every file
  touched was manually reviewed and brace/paren-balance-checked as a partial substitute; needs a
  real `qmltestrunner` pass (or at minimum, a manual on-device pass through restock/sell/return/
  edit-product flows) before merge.
- **`Gateway.mode` is still `"direct"`** — nothing here changes that. These movements aren't
  reaching a real `audit_log` yet, same caveat as every P0 entity.
- **Explicitly not done**: the opening/closing-balance register report (P1's second deliverable,
  deferred to its own future session per the agreed scope split).

### 2026-07-11 — Post-session: standing rule added, Task 7 planned (not implemented)

User: no feature ships without a test plan going forward (added to memory). P1 shipped with zero
automated coverage — closing that gap is now Task 7 in the plan doc: `tests/tst_StockMovementStore.qml`.
**Spec/plan only per explicit instruction — waiting for confirmation before writing any code.**
