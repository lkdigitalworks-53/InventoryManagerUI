# Product picker v2, slice S5d: measure the rebuild, then remove the one cost that scales with the cart

**Date:** 2026-11-21. **Branch:** `feat/2026-11-21-picker-s5d-cart-index-and-bench`, cut from `main` @ `68afa5c` (#206 S5c merged).
**Design:** `specs/2026-11-03-product-picker-v2-design.md` (approved). **Test plan:** `test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5d rows, checks 134 to 140). **Items closed or answered here:** KNOWN-ISSUES 14 (debounce), 19c (categories), 25 (dry run), and the "big catalog" line of S5d.
**Status of the roadmap before this slice:** S1 to S5c merged (#185, #187, #194, #196, #200, #202, #206). Left: S5d (this), S5e (TalkBack of the whole sheet, themes, font scale, ToastHost wrap KI 26, small touch targets KI 70, KI 29 cap, final device pass).

## Why this slice looks different from the plan table
The S5a table says "S5d: device numbers first (checks 46, 64)". No device is reachable from here, and waiting for one would leave a real cost in place for another round. So this slice measures what CAN be measured without a phone: the real helper files, run in Node by `scripts/bench/pickerBench.cjs`, with hooks that copy the cost SHAPE of the store lookups the dialogs pass. Node's V8 is faster than QML's V4 (and iOS has no JIT), so each figure is a floor. The ratios carry over; the absolute phone numbers still come from checks 46 and 64. Nothing is tuned by feel: a change is made only where the ratio is large and the fix is small.

## What the numbers say (Node, one run on the sandbox; `--json` gives the same)
One sheet rebuild (`PickerSheetModel.build`), no dry run, 3 cart lines, empty query:

| Catalog | 3 cart lines | 60 cart lines |
|---|---|---|
| 500 | 4 to 8 ms | 14 to 18 ms |
| 2 000 | 13 to 19 ms | 49 to 64 ms |
| 5 000 | 40 to 47 ms | 121 to 152 ms |
| 20 000 | 114 to 168 ms | 556 to 654 ms |

- **The cart scan is the cost that scales.** `inOrderQty` and `availableFor` each walk the whole cart for every product: N x L work, twice. At 5 000 products and 60 lines the two walks are 97 of 117 ms (83%). With the walks removed the same summarize is 6 ms.
- **Edit Order is worse than the table.** Its hooks call `_pickerLinesNow()` per product, per hook: that reads every `ListModel` row with `products.get(i)` and allocates a fresh line list EACH time, so a 5 000 product shop does 10 000 list rebuilds per stepper tap. A completed order adds a third walk (`heldAtCompletion` over the original lines).
- **KI 25, the dry run, is not a problem.** `opsCheck` costs 0.1 ms (5 plan lines) to 4.3 ms (60 lines) on a 20 000 batch ledger. Not memoised.
- **KI 19c, `categories`, is not a problem.** 0.8 ms at 2 000 products, 6 ms at 20 000, about 5% of a rebuild. Not cached (a cache keyed on the catalog array would go stale on an in-place change; the gain does not pay for that risk).
- **KI 14, the 150 ms debounce, stays.** It is a feel question (how long after the last key the list moves) that only a hand can answer. The cost it hides is now much smaller, which makes 150 ms safe rather than tuned.

## Decisions (defaults taken, veto in the PR)
**S5d-D1. How do the hooks get a cheap cart lookup?** (a) an identity cache inside the helper (remember the last `lines` array); (b) let `PickerSheetModel.build` index its own `orderLines`; (c) a per-build scope the dialog opens and closes: `beginBuild()` snapshots the lines and builds an index once, `endBuild()` drops it, the hooks read the index while it is open and fall back to the old scan when it is not. **Chosen: (c).** (a) is wrong the day a caller mutates an array in place (stale stock decisions). (b) is wrong for Edit Order: its `orderLines` is a notifier copy ON PURPOSE ("a stale copy can never decide anything"), the live rows are what decide. (c) has an explicit lifetime, a correct slow fallback, and changes no decision: the index holds exactly what the scan summed (same id match `String(id)`, same positive-finite-quantity rule, same summing order, so even fractional sums are equal).
**S5d-D2. The hooks stay plain closures.** Two new OPTIONAL hooks, `beginBuild` and `endBuild`. A throwing or missing one is ignored (the hooks then scan, as before). `endBuild` runs in a `finally`, so a build that throws still closes the scope.
**S5d-D3. The index is a tagged object** `{ qtyIndex: true, sums: { "k:<id>": n } }`. `cartQty(lines, id, index)` uses it only when the tag is there; a junk third argument (a string, `{}`, an array) is ignored and the scan runs. `"k:"` keys because a product id of `__proto__` must not touch the prototype.
**S5d-D4. Edit Order snapshots ONCE per build**: `_pickerLinesNow()` and `_pickerCtx()` are read in `beginBuild`, and the scope also holds `held`, the index of what a completed order held (`heldAtCompletion`). The ListModel is read once per build instead of twice per product.
**S5d-D5. No partial rebuild for a stepper tap.** A tap changes one row, yet `build` re-classifies the catalog. A delta path is a different design (what else a tap can change: totals, canCommit, draft clamp, the line limit for every disabled row) with a wide blast radius. Left as KNOWN-ISSUES 75, with the number that decides whether it is ever needed (the new bench row).
**S5d-D6. A regression gate that does not read a clock.** CI machines are noisy; a time threshold would flake. The gate counts cart-line reads: they must not grow with the catalog (S5D-04, S5D-05). The bench script is a tool, not a gate; it cross-checks that the indexed and the scanned build return identical views and exits non-zero if they do not.
**S5d-D7. No change to what a person sees.** Same rows, same reasons, same totals. A sheet-level equality test (S5D-03) pins it across states (pending, completed, fractional quantity, numeric ids).

## Scope
1. `NewOrderPicker.qtyIndex(rows, field)`, `cartQty(lines, id, index)`, `availableFor(product, lines, index)`.
2. `EditOrderPicker.scopeOf(lines, ctx)`, `heldAtCompletion(original, id, index)`, `ceilingFor(..., scope)` and `availableFor(product, lines, ctx, scope)` take an optional scope.
3. `PickerSheetModel.build` opens and closes the scope around its work.
4. Both dialogs: `beginBuild` / `endBuild`, hooks read the scope. NOW-03 and EOW-03 (they pin the old hook text) are updated ON PURPOSE.
5. `scripts/bench/pickerBench.cjs`.
6. Tests, test plan (checks 134 to 140), KNOWN-ISSUES, Skill 180, AGENTS, README, checkpoint.

NOT in S5d: a debounce change, a categories cache, a dry run cache, a delta rebuild, windowing of a huge list, any change to what a row says or allows, any layout change.

## Risks
- **A stale scope** (an index from an earlier build read in a later one). Closed by `endBuild` in a `finally`, by `beginBuild` always rebuilding, and by S5D-06 (after a build the hooks scan the live lines again).
- **A hook called with an index and different lines** (the index wins): the dialogs pass the snapshot they indexed, pinned by S5D-02.
- **QML-only risk:** a `property var` written inside a closure. Plain properties (`_buildLines`, `_buildScope`), not an object literal mutated in place, so QML's own change tracking stays out of it. CI runs the twin tests; the glue is run in a Node sandbox (S5D-02).
