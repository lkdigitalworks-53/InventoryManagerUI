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
