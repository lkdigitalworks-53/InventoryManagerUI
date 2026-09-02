# Test plan — price_adjust ledger events must book a tax delta, not just revenue

**Branch:** `fix/2026-09-02-price-adjust-tax-delta` off `main`.
**Covers:** `TransactionStore.recordPriceAdjust` / `TransactionStore.totalsForOrder`
(`qml/model/TransactionStore.qml`), and both of its call sites in
`DataModel._tryAdjustOrder` (`qml/model/DataModel.qml`) — the discount-rate-edit scanner
and the price-only-modify block.

**What it does:** a post-completion discount or price edit on a **taxable** order line now
books a proportional signed tax delta on the `price_adjust` ledger event it writes, and
`totalsForOrder` sums that delta in. Previously `price_adjust` events carried revenue only
("no tax field, contributes 0" by explicit prior design), so a completed order's
authoritative tax (used by `OrdersStore.applyAdjustment`) stayed frozen at its pre-edit
value after a discount/price edit, and a later full return — which correctly reverses tax
at the *live*, post-edit rate — left a residual fraction of unreconciled tax/revenue
sitting in the order.

**Bug report, reproduced exactly:** product cp 50 / sp 60 / tax 5%, 1-unit order completed
(tax 3, total 63). Add a 5% discount, no quantity change — expected tax 2.85, total 59.85
(app showed tax still 3). Return the item afterward — expected the order to net to exactly
0; app left a 0.15 phantom residual.

**Not covered by this plan / out of scope:** `RealisedMath.js`'s Analysis/Reports
aggregation (`_accumulatePriceAdjust`) has the *same* defect class — it never reads
`price_adjust.tax` either, before or after this fix — but that's a separate code path with
its own test suite and its own reconciliation invariants (`byDimension` vs `totals`). Not
touched in this branch; flagged to Taher as a decision point, not silently fixed or
silently ignored. No Cloud Functions or Firestore rules changes — `transactions` writes are
`allow write: if false` (Admin-SDK-only), so the new `tax` field on the `price_adjust`
payload has no rules surface, and no `functions/lib/*.js` file implements
`recordPriceAdjust`/`totalsForOrder` (they're QML-only stateful stores, not part of the
Cloud Functions parity set).

---

## 1. Unit test coverage

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

## 3. Regression test coverage

This whole branch *is* a regression fix — see sections 1–2 above, all of which exist
because of this specific reported defect, not as general-purpose unit coverage written
ahead of a bug. No separate section duplicates that list here per Skill 49's distinction
(unit tests that would exist regardless vs. regression tests that pin a specific defect) —
every test above is explicitly the latter for this branch; none are being retroactively
recategorized.

## 4. Firestore rules test coverage

Not applicable. `transactions` collection writes are `allow write: if false` in
`firestore.rules` (Admin-SDK/Cloud-Functions-gateway-only) — the new `tax` field on the
`price_adjust` payload never passes through a client-facing security rule, so there is no
rules surface to test.

---

## On-Device Test Plan

**Prerequisite:** merge this branch and confirm CI (`qml-tests` job) passes first — the
automated tests above have been traced by hand but not executed; a genuinely green CI run
is the first real proof the QML syntax and Qt API calls are correct, not just the math.

### Happy Path

1. Create a taxable product: cost price 50, selling price 60, tax 5%.
2. Create a 1-unit order for that product and mark it **Completed**. Confirm order detail
   shows Tax = 3.00, Total = 63.00.
3. Open the completed order, add a **5% discount** to that line (no quantity change), save.
   **Confirm order detail now shows Tax = 2.85, Total = 59.85** — this is the exact bug;
   before the fix it stayed at Tax = 3.00.
4. From the same (now-discounted) order, return the single unit, condition "resellable".
   **Confirm the order's Tax and Total both settle to 0.00** — before the fix this left a
   phantom Tax ≈ 0.15 / Total ≈ 0.15.

### Negative Cases

5. Repeat steps 1–3 with a **non-taxable** product (taxable off / tax 0%). Confirm the
   discount still reduces Total correctly and Tax stays 0.00 throughout — the fix must not
   introduce a tax figure where none existed.
6. Apply a discount edit that reduces net to exactly the same value twice in a row (e.g.
   save the same 5% discount again without changing it). Confirm Tax/Total don't drift on a
   no-op re-save (should book ~0 delta, not double-book).

### Edge Cases

7. Two sequential discount edits on the same completed order — e.g. 3% then later changed
   to 5% — confirm the FINAL displayed Tax/Total match a direct 0%→5% edit (no path
   dependence / no compounding error from the intermediate step).
8. A **price-only** edit (not a discount) on an already-completed taxable line — e.g.
   correct a sale price from 65 to 60 after completion, no quantity or discount change.
   Confirm Tax recalculates proportionally to the corrected price, not just Total.
9. A discount edit combined with an *added* unit in the same save (e.g. order goes from
   qty 1 with no discount to qty 2 with a 5% discount, in one edit). Confirm both units'
   tax reflect the discount, not just the surviving unit's.
10. 100% discount on a taxable line (free item) — confirm Tax goes to 0.00, not a negative
    or NaN value.

### Affected Areas

| File | Automated coverage | Where to look on-device if it regresses |
|---|---|---|
| `qml/model/TransactionStore.qml` (`recordPriceAdjust`, `totalsForOrder`) | `tests/tst_TransactionStore_priceAdjustTax.qml` (11 cases, written/traced, CI pending) | Order detail Tax/Total fields immediately after any post-completion discount or price edit |
| `qml/model/DataModel.qml` (discount-scanner + price-modify blocks in `_tryAdjustOrder`) | `tests/tst_DataModel_discountEditTax.qml` (3 cases), `tests/tst_AdjustDiscountRepro.qml` (extended) | Same as above, plus the Recent Sales / transaction ledger view for the `price_adjust` row's own values |
| `qml/helper/RealisedMath.js` (Analysis "Tax" column, `_accumulatePriceAdjust`) | **None — explicitly out of scope this branch**, see header | Analysis/Reports page's Tax figure for a date range containing a post-completion taxable discount/price edit; may still under/over-report until addressed separately |
| `functions/lib/*.js` (Cloud Functions parity set) | Not touched, no parity file implements this logic | N/A |
| `firestore.rules` | Not touched, `transactions` is server-write-only | N/A |

### Regression Tests (manual counterpart)

11. **The exact bug report, end to end**: cp 50 / sp 60 / tax 5%, complete a 1-unit order,
    add a 5% discount, confirm Tax shows 2.85 (not 3.00) and Total shows 59.85 (not 60.00),
    then return the item and confirm Tax and Total both read 0.00 (not ~0.15). This is the
    single click-through that would have caught the original defect.
12. Return a **partial** quantity from a multi-unit taxable order that had a discount
    applied post-completion (e.g. qty 3, 5% discount, return 1 of 3) — confirm the
    remaining 2 units' Tax/Total stay internally consistent and the returned unit's
    tax matches its proportional share, not a stale full-order figure.
