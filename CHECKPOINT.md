# Session Checkpoint — By-name chart on all six Analysis reports

**Started:** 2026-07-11
**Branch:** `feature/analysis-by-name-chart-all-views`
**Status:** Brainstorming — exploration done, awaiting Taher's answers on scope questions before design is finalized.

## Step log

1. Cloned `InventoryManagerUI` fresh (`main`, up to date with origin, clean tree).
   Note: repo cloned without any auth — currently reachable as public, contradicting last
   session's memory note that it was "made private mid-development." Not investigated further
   since it didn't block the session; flagged to Taher in chat.
2. Found a stale root `CHECKPOINT.md` left over from the 2026-07-10 tax/size-field session
   (mid-plan snapshot, not the final state — that feature is actually complete per memory).
   Archived it to `docs/superpowers/specs/2026-07-10-product-tax-export-size-field-CHECKPOINT.md`
   before starting this session's checkpoint, so nothing is lost.
3. Created branch `feature/analysis-by-name-chart-all-views` off `main`.
4. Read prior spec `docs/superpowers/specs/2026-06-15-analysis-category-supplier-reports-design.md`
   — this is the design that originally added the by-category/by-supplier cards to all six views
   and extracted `BreakdownBarCard.qml`. Directly reusable pattern for this feature.
5. Traced `qml/pages/SalesPage.qml` (2317 lines) breakdown-building code (`_rebuildBreakdown()`)
   for all six `_MODE_*` branches (Value, Purchased, Current, Revenue, Sold, Profit
   [Realised + Potential submodes]). Findings:
   - Only **3** `BreakdownBarCard` instances exist on the page today: by-category (always 1st),
     by-supplier (always 2nd), and one overloaded "Breakdown" card (3rd) whose bound model
     (`_breakdown`) means something different per view:
     - Value: top-8 products by value (i.e. already "by name", just mislabeled "Breakdown")
     - Profit -> Potential: top-8 products by profit (also already "by name")
     - Profit -> Realised: period-bucketed profit trend (Day/Week/Month/Year bars) — NOT by-name
     - Current: 3-bar "stock health" (In stock / Low / Out) — NOT by-name
     - Sold / Purchased / Revenue: period-bucketed trend bars — NOT by-name
   - A separate property `_topByName` already exists and is **already populated** for Value,
     Current, and both Profit submodes (reusing existing per-mode aggregation) — it's just never
     rendered as its own chart card today.
   - `_topByName` is **never computed** for Sold, Purchased, or Revenue — this is the one place
     genuine new aggregation logic is needed. Matches Taher's "some reports already have it, add
     to the rest" — 3 of 6 modes have the data, 3 don't.
   - The by-category/by-supplier aggregation for Sold/Purchased/Revenue goes through
     `_breakdownByDimension()` -> `qml/helper/BreakdownMath.js` `breakdown({dim: "category"|"supplier"})`.
     This file only supports those two dims today. Extending it with a `"product"` dim is
     structurally easy — product id is already available at the line/event level for all three
     metrics (no FIFO/consumption-level attribution needed, unlike the supplier dim), so it mirrors
     the existing `category` branch in each of `_revenue`/`_sold`/`_purchased`.
   - **Parity constraint found:** `qml/helper/BreakdownMath.js` has a byte-for-byte (module
     boilerplate aside) Node.js mirror at `functions/lib/breakdownMath.js`, independently tested by
     `functions/test/breakdownMath.test.js` against `functions/test/fixtures/breakdownMathFixtures.js`.
     Confirmed via diff — logic is identical, semicolons/require() aside. Adding a `"product"` dim
     to the QML file without mirroring it breaks that parity convention (silently — nothing enforces
     it automatically today). Flagged to Taher as a scope decision.
   - Existing QML tests to extend: `tests/tst_BreakdownMath.qml` (284 lines),
     `tests/tst_BreakdownMathParityFixtures.qml` (66 lines) — good precedent for testing the new dim.
6. Two scope questions asked and answered:
   - 3rd card fate -> "Keep it as an untouched 4th card below the 3 mandatory ones."
   - CF mirror -> "Yes, update the mirror + its Node tests too."
7. Deeper investigation surfaced a real edge case the above answer didn't anticipate: for Value
   and Profit->Potential, the old 3rd card is literally identical data to the new by-name card
   (both already show top-8-by-name). Flagged to Taher as a follow-up question; recommended
   suppressing the old card for just those two modes. Taher confirmed: "Suppress it for
   Value/Profit->Potential only."
8. Investigation also narrowed the aggregation scope favorably: only Sold/Purchased actually need
   a new `dim: "name"` branch in `BreakdownMath.js` (and its Node mirror). Revenue's by-name data
   reuses the already-existing, already-tested `InventoryStore.realisedProfitByDimension("productId", ...)`
   call (same pattern Profit->Realised already uses), extracted via a new optional `field` param on
   `_profitTopN()` — no `BreakdownMath.js` change needed for Revenue. Verified this is necessary:
   `_breakdownByDimension()`'s revenue branch has a `field = dim === "supplier" ? "supplierId" : "category"`
   ternary that would silently mis-resolve `dim: "name"` as `"category"` if naively extended —
   documented as a guardrail in the spec.
9. Design spec written and self-reviewed against actual source (line numbers, variable names,
   and function signatures all verified by direct inspection, not assumed):
   `docs/superpowers/specs/2026-07-11-analysis-by-name-chart-design.md`
10. ⏳ Presenting spec to Taher for his review now (per standing convention: show full file
    content before taking any action). Awaiting his go-ahead before `writing-plans` skill /
    implementation.

## Open decisions
- None outstanding — all resolved. Awaiting Taher's review of the written spec itself.

## Next steps
- Taher reviews the spec file -> incorporate any changes -> `writing-plans` skill for the
  implementation plan -> execute per build sequence in the spec -> tests -> Taher reviews diffs
  -> commit (only after explicit confirmation) -> push (only with a session PAT).
- Not committed to git yet (per standing instruction: commit only after explicit confirmation).
