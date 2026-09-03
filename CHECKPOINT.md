# CHECKPOINT — price_adjust tax-delta fix, BOTH bugs bundled, Node side genuinely run, ready to push

**Session date:** 2026-09-02
**Branch:** `fix/2026-09-02-price-adjust-tax-delta` (off `main`)
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-02-pr-ci-status-comment-CHECKPOINT.md`
(unrelated prior session, different branch `feature/pr-ci-status-comment` — untouched this session).

## What this session is

Taher reported a bug via `/superpowers:systematic-debugging`: product cp 50 / sp 60 / tax 5%,
1-unit order completed (tax 3, total 63). Add a 5% discount, no qty change — expected tax 2.85 /
total 59.85 (Taher's own worked math), app showed tax still 3. Return the item afterward —
expected the order to net to exactly 0, app left a 0.15 phantom residual (**bug 1**).

While investigating, found a second bug with the identical root cause in `RealisedMath.js`'s
Analysis/Reports aggregation — flagged to Taher as a separate decision point rather than silently
bundled in. Taher's answer: **bundle it in, add tests for both bugs in the on-device plan.** This
checkpoint reflects that combined state.

## Root cause (bug 1, traced statically — no Qt toolchain in this sandbox, per standing rule)

`OrdersStore.applyAdjustment` sources a *completed* order's tax/total from
`TransactionStore.totalsForOrder(orderId)`, not a live recompute (deliberate — a completed order's
line objects can't represent mixed-vintage tax). `totalsForOrder` only summed tax from `sale`/
`return` events. `TransactionStore.recordPriceAdjust` — called by BOTH the discount-rate-edit
scanner and the price-only-modify block in `DataModel._tryAdjustOrder` — wrote `price_adjust`
events carrying revenue only, explicitly no tax field ("revenue-only" by prior design). A discount
or price edit on a *taxable* completed-order line changes net without ever touching the immutable
original sale event's stamped tax, so the order's authoritative tax stayed frozen forever. A later
full return correctly reverses tax at the live post-edit rate (that half was never wrong) — which
is exactly what turned silent staleness into a visible residual.

## Root cause (bug 2 — same defect class, different file)

`qml/helper/RealisedMath.js`'s `_accumulatePriceAdjust` (and `byDimension`'s own scope-filtered
branch) had the identical gap: a `price_adjust` event contributed to `revenue`/`profit`/`discount`
in every dimension row but never `tax`, for any of its four internal distribution paths
(order-wide slices, supplier-lineage slices, no-lineage "Unknown" bucket, default single-key). Its
Node port `functions/lib/realisedMath.js` (a stated "byte-identical port") had the same gap.

Full narrative for both: `SKILLS.md` Skill 57.

## What's implemented, this session

**Bug 1 — `qml/model/TransactionStore.qml`:**
- `recordPriceAdjust(order, line, survivingQty, perUnitDelta, reason, note, taxRate)` — new
  optional `taxRate` param, computes `taxDelta = revenueDelta * (taxRate/100)` internally, writes
  it to the event's new `tax` field, **returns** `{revenueDelta, taxDelta}` (previously nothing).
- `totalsForOrder` — now sums `price_adjust.tax` alongside `sale`/`return` tax.

**Bug 1 — `qml/model/DataModel.qml`:**
- Discount-rate-edit scanner and price-only-modify block both pass the line's current
  `taxable`/`taxPercent` as `taxRate`, fold `-(revenueDelta + taxDelta)` into `refundAmount`.

**Bug 2 — `qml/helper/RealisedMath.js` AND `functions/lib/realisedMath.js` (kept byte-identical):**
- New `_priceAdjustTaxShare(e, revenueShare)` helper — `revenueShare / e.total` recovers the exact
  proportional tax for a slice, since `e.tax/e.total` is a constant ratio per event by construction
  of `recordPriceAdjust`.
- Folded into all 5 places a `price_adjust` event's revenue gets distributed: `byDimension`'s own
  scope-filtered branch, and `_accumulatePriceAdjust`'s order-wide-slices / supplier-lineage-slices
  / no-lineage-Unknown-bucket / default-single-key branches.
- `bucketWalk` untouched — no `"tax"` metric option exists there to fix.

## Tests, and their actual verification status (be precise about which is which)

**Genuinely run this session (Node, bug 2's port):** `npm install` then
`node --test test/realisedMath.test.js` in `functions/` → **9/9 passing** (5 pre-existing + 4 new:
`price_adjust_tax_share_no_scope_supplier_dimension`, `price_adjust_tax_share_supplier_filtered`,
`price_adjust_tax_no_lineage_unknown_bucket`, and a tax-specific reconciliation-invariant test).
Then ran the FULL `functions/` suite (`npm test`) to check for regressions in `computeAnalysis`,
the only other `RealisedMath` consumer — **194/194 passing**, no regressions anywhere touched.

**Written and hand-traced against the implementation, NOT run (no Qt toolchain — standing rule,
CI is the first real proof):**
- `tests/tst_TransactionStore_priceAdjustTax.qml` — new, 11 cases (bug 1, function-level).
- `tests/tst_DataModel_discountEditTax.qml` — new, 3 cases (bug 1, end-to-end via real
  `DataModel._tryAdjustOrder`).
- `tests/tst_AdjustDiscountRepro.qml` — extended, 1 new case (bug 1, taxable-line variant of an
  existing net-only repro).
- `tests/tst_RealisedMath.qml` — extended, 4 new cases (bug 2, mirrors the Node port's 4).
- `tests/tst_RealisedMathParityFixtures.qml` — extended, 3 new cases (bug 2, literal fixture data
  mirrored from the Node fixtures file, per that file's own stated discipline).

**Additional real evidence for the QML side beyond hand-tracing:** `node --check` on
`qml/helper/RealisedMath.js` with its `.pragma library`/`.import` lines stripped — passes clean,
confirming valid JS syntax (not a QML/Qt-API check, but genuine beyond pure hand-tracing).

**26 new/extended test cases total across 6 files** — counted via `git diff | grep -c`, not a
remembered number (this repo's own Skill 49 has a prior instance of a wrong carried-forward count;
recounted here on purpose).

## Docs updated

- `SKILLS.md` Skill 57 — full root-cause narrative for both bugs, the "flagged then bundled in on
  Taher's call" scope-boundary paragraph, the Node-genuinely-run vs QML-hand-traced distinction.
- `AGENTS.md` Current Feature Status table — row updated to cover both bugs and the 194/194 Node
  result.
- `README.md` Testing section — dated "Update 2026-09-02" paragraph covering both bugs and the
  real Node test counts (corrected from an initial miscount, see above).
- `docs/superpowers/test-plans/2026-09-02-price-adjust-tax-delta-test-plan.md` — full rewrite:
  standard format (Skill 49) covering both bugs, on-device plan now has Analysis-page-specific
  Happy Path steps (4, 6, 13) and a bug-2-specific Regression Tests item (15), per Taher's explicit
  ask to add tests for both bugs in the on-device plan.
- `docs/superpowers/test-plans/README.md` — index row updated to describe the combined scope.

## What still needs Taher

- **CI run is the first real proof for the QML side.** Every QML test above was written and
  hand-traced against the implementation, not executed — no Qt/qmltestrunner toolchain in this
  sandbox. Watch the `qml-tests` job on the PR this branch opens. The Node side already has real
  executed proof (194/194), which meaningfully de-risks the QML side too since the two files are
  byte-identical logic — but it isn't a substitute for the actual `qmltestrunner` run.
- Everything already carried forward from the archived pr-ci-status-comment checkpoint (coverage
  reporting decision) is untouched, unrelated to this branch.

## How to resume if interrupted

Branch `fix/2026-09-02-price-adjust-tax-delta`. As of this checkpoint, all changes above are made
in the local sandbox working tree. If `git status` shows a clean tree and `git log` shows a commit
on this branch, check whether it's been pushed (`git log origin/<branch> 2>&1` or just re-push —
pushing twice to the same branch/SHA is a no-op). If pushed, check whether Taher opened a PR and
whether CI's `qml-tests` job actually passed — if it didn't, that's the next thing to fix, not a
reason to assume the hand-traced math was wrong without reading the actual failure first. The
`functions-tests` CI job should be a formality at this point — the exact same suite already passed
194/194 in this sandbox.
