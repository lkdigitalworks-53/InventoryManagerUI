# Test plan — Sales Analysis deleted-product breakdown labels (DELETE-FEATURE-ROADMAP item 3)

**Branch:** `fix/2026-09-26-sales-analysis-deleted-product-labels` off `main`.

**What it does:** Purchased, Sold, Revenue, and Profit's Realised sub-mode no longer dump a deleted
product's historical rows into "(uncategorised)" / a raw `productId`. `category` is now stamped on
every relevant `TransactionStore` entry at time-of-transaction (mirroring how `productName` already
worked); both `BreakdownMath.js` and `RealisedMath.js` prefer that stamp only once the live product
no longer exists. Applied identically to the server-side parity port (`functions/lib/`).

**Source:** `docs/superpowers/DELETE-FEATURE-ROADMAP.md` item 3 (MEDIUM). Design:
`docs/superpowers/specs/2026-09-26-sales-analysis-deleted-product-labels-design.md`.

**Not covered by this fix / out of scope (decided with Taher or found and documented, not silently
dropped)**: no historical backfill (dev environment only, tested clean per PR — Taher's call); the
category *filter* dropdown (separate from the breakdown *label*, stays live-only); an order-wide
(not per-line) price adjustment spreading across a deleted product; `BreakdownMath._revenue()`
(dead code, unreachable from `SalesPage.qml`'s current wiring) — all documented in `KNOWN-ISSUES.md`.

---

## 1. Unit / functional test coverage

**Write side**, `tests/tst_TransactionStore_categoryStamp.qml` (new file, 14 cases): `recordPurchase`
(explicit category, live-product fallback, empty when neither resolves, `null` param treated as
omitted), `recordCreated` (from `snapshot.category`, empty when snapshot omits it or is omitted
entirely), `recordSaleFromOrder` (from the live product, empty when already gone), `recordReturn`
and `recordPriceAdjust` (reuses the *original sale's* stamped category when the product is now
deleted, falls back to a live lookup when no matching sale exists in history, empty when neither
resolves, an order-wide adjustment with no `line.productId` gets `""`).

**Read side**, `tests/tst_BreakdownMath.qml` (extended, +6 cases): deleted product uses its stamped
category/name for both Purchased and Sold dimensions; an entry with an empty stamped value still
falls to the "(uncategorised)"/"(unnamed)" placeholder, not an empty-string key; **regression
guard** — a still-live, recategorized product's CURRENT category keeps winning over whatever is
stamped on an old entry (proves zero behavior change for existing products).

**Read side**, `tests/tst_RealisedMath.qml` (extended, +4 cases): deleted product uses its stamped
category in `byDimension`'s sale/return path and both `price_adjust` code paths (with and without a
supplier filter — two genuinely different branches in the source); **regression guard** — same
live-wins proof as above, specific to `RealisedMath`'s function-based lookup.

**Server-side parity**, `functions/test/breakdownMath.test.js` (+4) and
`functions/test/realisedMath.test.js` (+4): the identical cases ported to the Node runtime, since
`functions/lib/{breakdownMath,realisedMath}.js` are byte-identical parity ports called by a live
Cloud Function (`computeAnalysis`) reading the same Firestore collections.

## 2. End-to-end test coverage

None added. `SalesPage.qml`'s `_namedProductMap`/`_stampedProductName` (the Revenue/Profit "by name"
list and its export) is a Felgo `App`-context page — not runnable in the `QML Tests` CI job or this
sandbox. Verified by code symmetry with the tested `BreakdownMath`/`RealisedMath` fix instead, same
discipline as every other page-level mirror in this codebase. On-device case 6 below is the only
coverage for this specific function.

## 3. Regression test coverage

Tests that exist because of this fix or its adjacent findings, so a wrong fix would fail them:

- `test_live_product_current_category_wins_over_stale_stamped_value` (BreakdownMath) and
  `test_bydimension_category_live_product_wins_over_stale_stamp` (RealisedMath, both QML and Node):
  a still-existing product's current category must never be overridden by a stale stamp. **This
  exact test caught a real precedence bug in the first pass of this fix** — see "What was genuinely
  run" below.
- `test_deleted_product_empty_stamped_values_still_use_placeholder`: an empty stamped value must
  not become a literal empty-string bucket key.
- The `_stampedCategoryFor` return/price-adjust cases: a return of a since-deleted product must
  reuse the *original sale's* category, not a live re-lookup that would fail for the exact reason
  this fix exists.
- All pre-existing `tst_BreakdownMath.qml` / `tst_RealisedMath.qml` / `functions/test/*Math.test.js`
  cases (243 Node tests before this change): must stay green — proves zero behavior change for
  every already-covered scenario.

## 4. Firestore rules test coverage

Not applicable — no rules change. `category` is a new field on documents already writable by the
existing `transactions` collection rules; no new collection, no new permission.

---

## What was genuinely run

- **QML, `tests/`:** no Qt toolchain in this sandbox (standing instruction) — CI is the verdict. Not
  yet run anywhere; needs a CI pass on this branch before merge.
- **Functions, real execution in this session:** `npm test` in `functions/` (dependencies installed
  from the network-allowlisted npm registry; sandbox has Node v22.22.2, while
  `functions/package.json` pins `engines.node: "20"` — same version-count-may-differ caveat as prior
  sessions' plans; pass/fail outcome is unaffected). **Baseline 243/243 passing** before any edit,
  confirming the fix didn't start from a broken suite.
  After the fix: **first pass, 250/251 — one real failure**,
  `bydimension_category_live_product_wins_over_stale_stamp`, `Cannot read properties of undefined
  (reading 'revenue')`. Root cause: `e.category || categoryOf(e.productId)` always preferred a
  present stamp regardless of whether the live product still existed — the opposite of the intended
  precedence (see `SKILLS.md` Skill 71 for the full generalized lesson). Fixed with a
  `_resolvedCategory()` helper that checks live-product-existence explicitly (`categoryOf` now
  returns `null` for "doesn't exist" vs. `""` for "exists, no category" — `getById` already knows
  this, it just wasn ot being surfaced). **Final run: 251/251 passing.** This is genuine TDD
  evidence, not staged: the test caught a bug that would otherwise have shipped.
- **Not runnable anywhere automated:** `SalesPage.qml`'s `_namedProductMap` / `_stampedProductName`
  (Felgo `App`-context page).

---

## On-Device Test Plan

**Prerequisite status:** the automated coverage above covers every category/name resolution branch
in both the QML and Node math libraries, and the Node half is genuinely proven, not just traced.
This section is the only coverage for the actual on-screen breakdown lists and their exports.

### Happy Path

1. Create a product with a category, sell some, purchase more (creating both `sale` and `purchase`
   ledger entries), then delete the product. Open Sales Analysis → Purchased tab → by Category and
   by Name: the deleted product's row shows its real category and name, not "(uncategorised)" or a
   raw id.
2. Repeat for the Sold tab.
3. Repeat for the Revenue tab's by-Category breakdown and its by-Name "top products" list.
4. Repeat for the Profit tab's Realised sub-mode, both dimensions.
5. Return part of an order for a product that has since been deleted: the return still nets against
   the correct category in Sold/Revenue, not "(uncategorised)".
6. Export to xlsx from Revenue or Profit's Realised sub-mode: the deleted product's name/category
   appear correctly in the exported sheet (only coverage for `_namedProductMap`'s actual page-level
   behavior).

### Negative / Edge Cases

7. A product that was never given a category, then deleted: its historical rows show
   "(uncategorised)" (same as before this fix, not a new blank/crash).
8. A product renamed and recategorized *after* some sales, but never deleted: its full history (old
   and new sales) shows its CURRENT name/category — proves this fix didn't change existing-product
   behavior.
9. A price adjustment applied to an order line, then that product deleted: the adjustment's category
   in Revenue still resolves correctly (reuses the original sale's stamp).
10. An order-wide (not per-line) price adjustment touching a since-deleted product: known, documented
    limitation (see `KNOWN-ISSUES.md`) — confirm it still shows "(uncategorised)" and does not crash,
    rather than showing something wrong.
11. Filter Sales Analysis by a category, where a different, now-deleted product also belonged to that
    category: known, documented limitation — confirm the deleted product's history is silently
    excluded from the filtered total (not a crash, not a wrong total) rather than newly appearing.
12. Bulk-import products (deferred `recordCreated` path), sell one, delete it: same happy-path check
    as case 1, confirming the deferred/bulk write path also stamps category correctly.

### Affected Areas

- Sales Analysis: Purchased, Sold, Revenue, Profit (Realised sub-mode) — both by-Category and
  by-Name breakdowns, and their exports.
- Value and Current tabs: unaffected by this change — confirm no regression (Value already excludes
  orphaned batches from an earlier fix; Current is a live-stock snapshot by design).
- Restock, sale, return, and price-adjust flows: confirm normal (non-deleted-product) operation is
  unchanged — no new dialogs, no new required fields, no behavior visible to the user day-to-day.

### Regression Tests (manual counterpart)

- Re-run PR #80's staff-delete on-device checklist's Sales Analysis cases (by-staff breakdown) to
  confirm this change didn't touch that unrelated dimension.
- Re-confirm the existing "Potential profit" / "Inventory Value" fixes (2026-09-02) still hold — a
  deleted product with remaining stock still excludes correctly from those two tabs.
