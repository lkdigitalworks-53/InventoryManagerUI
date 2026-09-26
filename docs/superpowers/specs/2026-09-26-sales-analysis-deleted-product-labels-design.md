# Sales Analysis deleted-product breakdown labels — design

**Date:** 2026-09-26
**Branch:** `fix/2026-09-26-sales-analysis-deleted-product-labels`
**Source item:** `docs/superpowers/DELETE-FEATURE-ROADMAP.md` item 3 (MEDIUM): five Sales Analysis tabs mislabel a
deleted product's historical rows.

## Problem

Purchased, Sold, Revenue, and Profit's Realised sub-mode group historical `TransactionStore` entries by the
selling product's category and name. Once a product is deleted, the grouping code re-resolves both live from
`InventoryStore` — which fails, dumping every historical row for that product into "(uncategorised)" / the raw
`productId`. Value and Current already handle deletion correctly (Value skips orphaned batches; Current is a
live-stock snapshot by design) and are out of scope here.

## What the trace found

- `productName` is already stamped on every `TransactionStore` entry at creation time
  (`recordPurchase`/`recordSaleFromOrder`/`recordCreated`/`recordCreatedMany`/`recordReturn`/`recordPriceAdjust`
  all set it). The by-name bug is **purely read-side** — `BreakdownMath._productNameKey` and
  `SalesPage._namedProductMap` both re-derive the name from the live `InventoryStore` instead of using what's
  already on the row.
- `category` is **never stamped anywhere**. Every category grouping resolves it live via `categoryOf(productId)`
  → `InventoryStore.getById(pid).category`. This half is a genuine write-path gap, exactly as the roadmap
  originally scoped it.
- `recordFieldChange` / `recordStockAdjustment` / `recordPhotoChange` entries (`kind: field_change` /
  `stock_adjustment` / `photo_change`) are pure audit-trail rows — none of the three consuming aggregators
  (`BreakdownMath._sold`/`_purchased`, `RealisedMath.byDimension`) match those kinds, so they don't feed any of
  the five affected tabs. Left unstamped; out of scope.
- `BreakdownMath._revenue()` (the orders-based revenue path) is dead code from `SalesPage.qml`'s point of view —
  `_breakdownByDimension` handles `revenue`/`tax`/`discount` entirely through
  `InventoryStore.realisedProfitByDimension()` → `RealisedMath.byDimension()` before ever reaching
  `BreakdownMath.breakdown()`. `_revenue()` is only exercised by its own unit tests. Left untouched; a fix there
  would need a different, order-line-based stamping mechanism and isn't reachable from any live UI path.
- The category cross-**filter** (`RealisedMath._passesScope`, `scope.category`) is a separate mechanism from the
  breakdown **label** this ticket fixes — it decides which rows match a user-selected category, not what a row's
  category displays as. It stays live-only; a deleted product can no longer be chosen in the filter dropdown in
  the first place, so it doesn't reproduce this bug. Flagged as a related-but-separate, not-fixed observation in
  `KNOWN-ISSUES.md` rather than folded into this change (Iron Law: one fix at a time).

## Decisions (Taher, 2026-09-26)

| # | Question | Chosen |
|---|---|---|
| Q1 | Scope this session | **Both** name and category, in one pass |
| Q2 | Category semantics once stamped | **At time-of-transaction** — matches how `productName` already works and how this codebase already treats `TransactionStore` as an immutable, point-in-time ledger |
| Q3 | Historical entries with no category (predate this fix) | **No backfill** — dev environment only; Taher always tests clean with a new user/tenant per PR, so there's no real historical data to preserve |

## Design

### Write side — stamp `category` at creation time
1. `TransactionStore.recordPurchase(..., category)` — new trailing param, falls back to a live lookup only as a
   safety net (mirrors the existing `productName` fallback). Caller (`InventoryStore.qml` restock path) passes
   `current.category`.
2. `TransactionStore.recordCreated` — no signature change; every caller already passes `category` inside
   `snapshot` (product creation and bulk-import both do). Promoted to a top-level `category` field, matching
   where `productName` already lives, so the breakdown code doesn't need to know about `snapshot` shape at all.
3. `TransactionStore.recordSaleFromOrder` — stamps `category` from the `inv` product lookup already in scope
   for resolving `productName`.
4. `TransactionStore.recordReturn` / `recordPriceAdjust` — **not** simple passthroughs: the product referenced
   by a return/adjustment may already be deleted by the time the return happens, so a live lookup at
   return-time would fail exactly the case being fixed. New helper `_stampedCategoryFor(productId, orderId)`
   scans this store's own `entries` for the matching original `sale` event on the same order and reuses its
   stamped `category` first, falling back to a live lookup (covers a sale recorded before this fix shipped)
   and then `""`. Self-contained inside `TransactionStore.qml` — no caller changes needed.
   `recordPriceAdjust` skips the lookup entirely for an order-wide adjustment (`line.productId` empty — no
   single product to attribute a category to), matching how it already has no single product then.

### Read side — prefer the stamped value only when the live product is gone
5. `BreakdownMath._categoryKey` / `_productNameKey` gain an optional `entry` param. When `productId` is a key in
   the live `productCategory`/`productName` map (the product still exists), behavior is **byte-for-byte
   unchanged** — a still-existing, recategorized/renamed product's whole history keeps showing its CURRENT
   category/name, exactly as before. Only when the key is **absent** (product deleted) does it fall back to
   `entry.category` / `entry.productName`. `_sold`/`_purchased` (the only production call sites) now pass the
   entry through.
6. `RealisedMath.byDimension` / `_accumulatePriceAdjust` — the three spots resolving a category label
   (sale/return rows, price_adjust-with-supplier-filter, price_adjust-without-lineage) now try `e.category`
   before `categoryOf(e.productId)`, same live-wins-when-present ordering as above (a stamped `category` is
   only ever missing for pre-fix entries or a still-unmatched edge case, so this doesn't change any currently
   correct output).
7. `SalesPage._namedProductMap` (feeds Revenue's and Profit-Realised's "by name" lists, and their exports) gains
   `_stampedProductName(productId)`, reading `TransactionStore.forProduct(productId)[0].productName` when the
   live lookup misses.

### Explicitly not touched
- `InventoryStore.potentialProfitByDimension` / Value tab — already fixed by exclusion (separate prior fix).
- `SalesPage._namedProductMapValue` — feeds the Value tab (`valueByProduct`), same as above.
- `BreakdownMath._revenue()` — dead in production, see trace above.
- `RealisedMath._passesScope`'s category filter — filtering, not labeling; see trace above.
- `record_field_change` / `stock_adjustment` / `photo_change` — don't feed any of the five tabs.

## Test plan

See `docs/superpowers/test-plans/2026-09-26-sales-analysis-deleted-product-labels-test-plan.md`.
