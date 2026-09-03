# Test plan — price_adjust ledger events must book a tax delta, not just revenue

**Branch:** `fix/2026-09-02-price-adjust-tax-delta` off `main`.
**Covers two bugs, same root cause, fixed together:**
1. Order-level: `TransactionStore.recordPriceAdjust` / `TransactionStore.totalsForOrder`
   (`qml/model/TransactionStore.qml`), and both of its call sites in
   `DataModel._tryAdjustOrder` (`qml/model/DataModel.qml`) — the discount-rate-edit scanner
   and the price-only-modify block.
2. Analysis/Reports-level: `RealisedMath.js`'s `_accumulatePriceAdjust` / `byDimension`
   (`qml/helper/RealisedMath.js` and its Node port `functions/lib/realisedMath.js`) — found
   while investigating bug 1, same defect class, initially flagged as a separate decision
   point, then bundled into this same branch on Taher's explicit call.

**What it does:** a post-completion discount or price edit on a **taxable** order line now
books a proportional signed tax delta on the `price_adjust` ledger event it writes (bug 1
fix), and that delta now also flows through to every Analysis/Reports dimension and total
that reads the event log (bug 2 fix). Previously `price_adjust` events carried revenue only
("no tax field, contributes 0" by explicit prior design in both files), so:
- A completed order's authoritative tax (used by `OrdersStore.applyAdjustment`) stayed
  frozen at its pre-edit value after a discount/price edit, and a later full return — which
  correctly reverses tax at the *live*, post-edit rate — left a residual fraction of
  unreconciled tax/revenue sitting in the order (bug 1).
- The Analysis page's Tax column, and any export/breakdown reading `RealisedMath.totals` or
  `byDimension`, silently under/over-reported tax for any date range containing such an edit
  — the price_adjust event contributed to Revenue, Profit, and the Discount column, but
  never Tax (bug 2).

**Bug 1 report, reproduced exactly:** product cp 50 / sp 60 / tax 5%, 1-unit order completed
(tax 3, total 63). Add a 5% discount, no quantity change — expected tax 2.85, total 59.85
(app showed tax still 3). Return the item afterward — expected the order to net to exactly
0; app left a 0.15 phantom residual.

**Bug 2, same scenario, Analysis-page angle:** with the discount applied (net 57, tax should
be 2.85), the Analysis page's Tax total/by-dimension breakdown for that period still summed
to 3.00 — the `price_adjust` event carrying the −0.15 tax correction (once bug 1 is fixed to
stamp it) was never read by the aggregator.

**Not covered by this plan / out of scope:** `RealisedMath.bucketWalk` — it only ever
reports `"net"` or `"profit"` as a time-series metric, there is no `"tax"` metric option to
fix. No Cloud Functions HTTP-handler changes beyond the pure `RealisedMath` port — the
`computeAnalysis` handler in `index.js` calls into it unchanged. No Firestore rules changes
— `transactions` writes are `allow write: if false` (Admin-SDK-only), so the new `tax` field
on the `price_adjust` payload has no rules surface.

---

## 1. Unit test coverage

### 1a. Order-level (`TransactionStore.qml`, `DataModel.qml`) — bug 1

**New file `tests/tst_TransactionStore_priceAdjustTax.qml`** — 11 cases, calling the real
`TransactionStore` singleton directly (`import "../qml/model"`), same pattern as
`tst_TransactionStore_resetGuard.qml` / `tst_TransactionStore_syncRetry.qml`.
**Written, traced by hand against the implementation, NOT run** — no Qt/qmltestrunner
toolchain in this session's sandbox (standing rule — always rely on CI). Every assertion's
expected number was independently re-derived from the actual formula
(`revenueDelta * taxRate/100`) while writing the test, not copied from the implementation.

| Test | What it locks down |
|---|---|
| `test_books_proportional_tax_delta_for_taxable_line` | The core fix: `recordPriceAdjust(order, line, 1, 3, "discount", note, 5)` books `tax: -0.15` on the ledger doc and returns it. |
| `test_zero_tax_when_taxRate_omitted` | Backward compat: an omitted `taxRate` must not silently assume a rate. |
| `test_zero_tax_when_line_not_taxable` | Explicit `taxRate: 0` books `tax: 0`. |
| `test_negative_taxRate_treated_as_zero` | Defensive: a corrupt/negative `taxPercent` never flips the sign of the booked delta. |
| `test_tax_delta_sign_flips_when_discount_decreases` | A *shrinking* discount (negative `discDelta`) correctly increases tax owed, mirroring the revenue delta's own sign flip. |
| `test_price_modify_call_shape_also_books_tax` | The *other* call site's calling convention (`survivingQty * perUnitDelta`, not the discount site's `(1, discDelta)` trick) computes the same correct tax math. |
| `test_no_write_when_perUnitDelta_zero` | Pre-existing guard clause is untouched by the new parameter. |
| `test_orderwide_adjustment_taxRate_still_optional` | An order-wide adjustment (no `productId`) that never passed a tax rate before this fix keeps working unchanged. |
| `test_totalsForOrder_reproduces_the_reported_bug_numbers` | **The flagship case.** Seeds the original sale event (net 60, tax 3) + a 5%-discount `price_adjust`; `totalsForOrder` returns net 57 / tax 2.85 / total 59.85 — Taher's own expected math, not the buggy 3. |
| `test_totalsForOrder_full_return_after_discount_edit_reconciles_to_zero` | Continues the case above with a return event allocated at the live discounted rate (net −57, tax −2.85, unchanged behavior); `totalsForOrder` nets to exactly 0/0/0 — the 0.15 residual is gone. |
| `test_totalsForOrder_multiple_sequential_discount_edits_reconcile` | Two sequential discount edits (0%→8%, then 8%→5%) settle at the *same* final tax as a single 0%→5% edit — proves the fix is correctly additive across multiple `price_adjust` events, not a single-edit special case. |

**Extended existing file `tests/tst_AdjustDiscountRepro.qml`** — 1 new case
(`test_taxable_line_discount_edit_books_matching_tax_delta`), mirroring the file's own
"hand-derive the discount-scanner formula" convention. This file's original test only ever
used `taxable: false`, which is exactly why the net-side fix it verified didn't also catch
the tax-side gap this session fixes — the new case closes that specific hole using the same
convention so it can't silently reopen.

### 1b. Analysis/Reports-level (`RealisedMath.js`, both ports) — bug 2

**Node port (`functions/lib/realisedMath.js`) — GENUINELY RUN, not just traced.** Extended
`functions/test/realisedMath.test.js` + `functions/test/fixtures/realisedMathFixtures.js`
with 3 new fixtures and 4 new test cases (one is a reconciliation-invariant loop, not tied to
a single fixture). `npm install` then `node --test test/realisedMath.test.js` →
**9/9 passing** (5 pre-existing + 4 new). Ran the full `functions/` suite afterward to check
for regressions in `computeAnalysis` (the only other consumer of `RealisedMath` in
`functions/`) — **194/194 passing.**

| Test | What it locks down |
|---|---|
| `price_adjust_tax_share_no_scope_supplier_dimension` | Reproduces the exact bug numbers end to end: sale (net 60, tax 3) + 5%-discount `price_adjust` (total −3, tax −0.15) → `totals().tax` = 2.85, and the `"supplierId"` `byDimension` row for the (unfiltered) supplier also carries `tax: 2.85`. Exercises `_accumulatePriceAdjust`'s lineSlices branch. |
| `price_adjust_tax_share_supplier_filtered` | Same scenario, `scope.supplierId` set — exercises `byDimension`'s *own* scope-filtered price_adjust branch (`_priceAdjustSupplierAmount` + the new `_priceAdjustTaxShare`), a different code path from the row above. An unrelated supplier sees tax 0, not a leak. |
| `price_adjust_tax_no_lineage_unknown_bucket` | No `supplierSlices` and no resolvable `orderLookup` (legacy/pre-FIFO shape) — falls to the `""` "Unknown" bucket, which gets the **whole** event's tax unsplit (nothing to proportion it across), not the sliced formula the two cases above use. |
| `invariant: sum(byDimension) == totals for every field, with a taxable price_adjust present` | The pre-existing "Σ byDimension == totals" reconciliation invariant (Skill 29) still holds for `.tax` specifically once a taxable `price_adjust` event is in the mix — proves the fix folds tax in consistently across every dimension, not just the one it was written against. |

**QML port (`qml/helper/RealisedMath.js`) — same 4 scenarios mirrored, per the file's own
"byte-identical port" design goal.** Extended `tests/tst_RealisedMath.qml` (4 new cases,
real production-function calls, same style as its existing `test_price_adjust_discount_column`)
and `tests/tst_RealisedMathParityFixtures.qml` (3 new cases, literal fixture data mirrored
from the Node fixtures file, per that file's own stated "kept in sync manually" discipline —
the invariant-loop case wasn't mirrored here since that file is explicitly scoped to
cross-runtime *data* parity, not correctness re-litigation). **Written and traced by hand,
NOT run via qmltestrunner** — same sandbox limitation as 1a. Additionally syntax-checked as
plain JS: `node --check` on the `.pragma library`/`.import`-stripped file passes clean,
confirming valid JS syntax (not a QML/Qt-API-level check, but real evidence beyond hand-tracing).

## 2. Functional / end-to-end test coverage

**New file `tests/tst_DataModel_discountEditTax.qml`** — 3 cases, driving the **real**
`DataModel._tryAdjustOrder` orchestration (not hand-derived formulas), same
child-item-instantiation pattern as `tst_DataModel_adjustOrderSyncGuard.qml`. This is the
closest automated equivalent to how Taher actually reproduced the bug in the app.
**Written, traced by hand, NOT run** — same sandbox limitation as above.

| Test | What it locks down |
|---|---|
| `test_discount_edit_on_completed_taxable_order_recomputes_tax_correctly` | Full repro steps 1–2: complete a cp-50/sp-60/tax-5% 1-unit order, then call `_tryAdjustOrder` with a 5% discount. Asserts `order.tax == 2.85` and `order.total == 59.85` on the persisted order — the exact field the bug report says displayed wrong. |
| `test_discount_edit_books_a_reconciling_ledger_entry` | Same scenario, asserts exactly one `price_adjust` event exists with `total: -3` / `tax: -0.15` — the ledger-level proof behind the order-level assertion above. |
| `test_full_return_after_discount_edit_leaves_no_residual` | Full repro steps 1–3: discount edit, then a full return via a second `_tryAdjustOrder` call with an empty product line. Asserts `order.tax == 0` and `order.total == 0` — the exact "0.15 residual" the bug report describes, now gone. |

No end-to-end equivalent exists for bug 2 (Analysis-page rendering) — `RealisedMath` is a
pure function consuming a plain entries array, and its only caller in an orchestration sense
is `computeAnalysis` (a Cloud Function, not yet wired into `SalesPage.qml` per `AGENTS.md`)
plus `SalesPage.qml` itself calling it directly client-side. The Node genuinely-run tests in
1b are the deepest automated coverage available for bug 2; the Analysis page's actual on-screen
Tax figure is on-device-only, see below.

## 3. Regression test coverage

This whole branch *is* a regression fix — see sections 1–2 above, all of which exist
because of these two specific reported/found defects, not as general-purpose unit coverage
written ahead of a bug. No separate section duplicates that list here per Skill 49's
distinction (unit tests that would exist regardless vs. regression tests that pin a specific
defect) — every test above is explicitly the latter for this branch; none are being
retroactively recategorized.

## 4. Firestore rules test coverage

Not applicable. `transactions` collection writes are `allow write: if false` in
`firestore.rules` (Admin-SDK/Cloud-Functions-gateway-only) — the new `tax` field on the
`price_adjust` payload never passes through a client-facing security rule, so there is no
rules surface to test. Unaffected by bundling in bug 2's fix — `RealisedMath.js` reads
already-fetched entries, no new Firestore query or write shape.

---

## On-Device Test Plan

**Prerequisite:** merge this branch and confirm CI (`qml-tests` job) passes first — the
QML-side automated tests above have been traced by hand but not executed; a genuinely green
CI run is the first real proof the QML syntax and Qt API calls are correct, not just the
math. (The Node-side tests for bug 2 were genuinely run this session — see 1b — so that half
carries higher confidence already.)

### Happy Path

1. Create a taxable product: cost price 50, selling price 60, tax 5%.
2. Create a 1-unit order for that product and mark it **Completed**. Confirm order detail
   shows Tax = 3.00, Total = 63.00.
3. Open the completed order, add a **5% discount** to that line (no quantity change), save.
   **Confirm order detail now shows Tax = 2.85, Total = 59.85** — this is bug 1; before the
   fix it stayed at Tax = 3.00.
4. **Open the Analysis page**, filter to a date range covering that order. **Confirm the Tax
   total (and the by-supplier/by-product/by-category breakdown's Tax column, if visible)
   reads 2.85 for this order's contribution, not 3.00** — this is bug 2; before the fix the
   Analysis page's Tax figure never moved off the pre-discount amount even after bug 1's
   order-detail fix landed on its own.
5. From the same (now-discounted) order, return the single unit, condition "resellable".
   **Confirm the order's Tax and Total both settle to 0.00** — before the fix this left a
   phantom Tax ≈ 0.15 / Total ≈ 0.15.
6. **Re-check the Analysis page** for the same date range after the return. **Confirm the Tax
   total for this order's contribution also settles to 0.00**, consistent with step 5.

### Negative Cases

7. Repeat steps 1–3 with a **non-taxable** product (taxable off / tax 0%). Confirm the
   discount still reduces Total correctly and Tax stays 0.00 throughout, on BOTH the order
   detail and the Analysis page — the fix must not introduce a tax figure where none existed.
8. Apply a discount edit that reduces net to exactly the same value twice in a row (e.g.
   save the same 5% discount again without changing it). Confirm Tax/Total don't drift on a
   no-op re-save (should book ~0 delta, not double-book), on both surfaces.

### Edge Cases

9. Two sequential discount edits on the same completed order — e.g. 3% then later changed
   to 5% — confirm the FINAL displayed Tax/Total match a direct 0%→5% edit (no path
   dependence / no compounding error from the intermediate step), on both the order detail
   and the Analysis page.
10. A **price-only** edit (not a discount) on an already-completed taxable line — e.g.
    correct a sale price from 65 to 60 after completion, no quantity or discount change.
    Confirm Tax recalculates proportionally to the corrected price on both surfaces, not
    just Total.
11. A discount edit combined with an *added* unit in the same save (e.g. order goes from
    qty 1 with no discount to qty 2 with a 5% discount, in one edit). Confirm both units'
    tax reflect the discount on both surfaces, not just the surviving unit's.
12. 100% discount on a taxable line (free item) — confirm Tax goes to 0.00 on both surfaces,
    not a negative or NaN value.
13. **Filter the Analysis page by supplier** for an order with a taxable discount edit.
    Confirm the supplier-filtered Tax figure also reflects the discounted rate (2.85, not
    3.00) — this exercises the *other* aggregation code path (`byDimension`'s own
    scope-filtered branch) than the unfiltered view in step 4.

### Affected Areas

| File | Automated coverage | Where to look on-device if it regresses |
|---|---|---|
| `qml/model/TransactionStore.qml` (`recordPriceAdjust`, `totalsForOrder`) | `tests/tst_TransactionStore_priceAdjustTax.qml` (11 cases, written/traced, CI pending) | Order detail Tax/Total fields immediately after any post-completion discount or price edit |
| `qml/model/DataModel.qml` (discount-scanner + price-modify blocks in `_tryAdjustOrder`) | `tests/tst_DataModel_discountEditTax.qml` (3 cases), `tests/tst_AdjustDiscountRepro.qml` (extended) | Same as above, plus the Recent Sales / transaction ledger view for the `price_adjust` row's own values |
| `qml/helper/RealisedMath.js` (Analysis "Tax" column, `_accumulatePriceAdjust`) | `tests/tst_RealisedMath.qml` + `tests/tst_RealisedMathParityFixtures.qml` (4 + 3 cases, written/traced, CI pending) | Analysis page's Tax hero figure and by-dimension breakdown, filtered and unfiltered, for a period containing a post-completion taxable discount/price edit |
| `functions/lib/realisedMath.js` (Node port, feeds `computeAnalysis`) | `functions/test/realisedMath.test.js` (4 new cases) — **genuinely run, 9/9 passing**; full `functions/` suite 194/194 | N/A for now — `computeAnalysis` isn't wired into `SalesPage.qml` yet per `AGENTS.md`; relevant once that cutover happens |
| `firestore.rules` | Not touched, `transactions` is server-write-only | N/A |

### Regression Tests (manual counterpart)

14. **Bug 1, end to end**: cp 50 / sp 60 / tax 5%, complete a 1-unit order, add a 5%
    discount, confirm order-detail Tax shows 2.85 (not 3.00) and Total shows 59.85 (not
    60.00), then return the item and confirm Tax and Total both read 0.00 (not ~0.15). This
    is the single click-through that would have caught the original defect.
15. **Bug 2, end to end**: same scenario as #14, but check the Analysis page's Tax figure
    at each step instead of the order detail — before the fix, the Analysis Tax total would
    have stayed at 3.00 through the discount edit (never moving to 2.85) and then landed
    somewhere inconsistent after the return, since it was never reading the `price_adjust`
    tax delta at all.
16. Return a **partial** quantity from a multi-unit taxable order that had a discount
    applied post-completion (e.g. qty 3, 5% discount, return 1 of 3) — confirm the
    remaining 2 units' Tax/Total stay internally consistent and the returned unit's
    tax matches its proportional share, not a stale full-order figure, on BOTH the order
    detail and the Analysis page.
