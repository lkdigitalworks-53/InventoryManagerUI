# OrdersStore Totals Coverage — Implementation Plan (Slice 1 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full test coverage for `OrdersStore.qml`'s three pure math/formatting functions —
`computeOrderTotals`, `parseCurrency`, `formatCurrency` — with every scenario dimension the spec
calls for: happy path, edge cases (clamping, guards), negative inputs, and a proof that the
step-wise rounding order is load-bearing, not incidental.

**Architecture:** One new file, `tests/tst_OrdersStore_totals.qml`, built incrementally across three
commits (one per function). All three functions are pure — no `OrdersStore.orders` state, no
network — so the test file needs no `init()`/`cleanup()` state reset beyond what's already
established as defensive convention elsewhere in this suite.

**Tech Stack:** QML/Qt Quick Test (`qmltestrunner`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-20-ordersstore-full-coverage-design.md` — this plan
  implements that spec's Group A row for `computeOrderTotals`, `parseCurrency`, `formatCurrency`,
  and the §5 "happy/edge/negative" and rounding-order scenario requirements for those three.
- **This sandbox cannot run `qmltestrunner`** (no Qt toolchain here, same standing constraint as
  every prior test file in this project). Every expected value in this plan was independently
  verified by porting the exact algorithm to Node.js and executing it (not hand-calculated) —
  the Node port and its output are not part of this plan's deliverables, only the verified numbers
  are. Final pass/fail confirmation happens on Taher's machine or CI, exactly like every other
  `tst_*.qml` file in this project.
- One commit per task (per function), each independently reviewable.
- Follows this file's own established test-writing convention: `import "../qml/model"`, a
  `TestCase { name: ... }` block, `compare()`/`verify()` assertions, descriptive
  `test_<function>_<scenario>` names.

## File Structure

- `tests/tst_OrdersStore_totals.qml` — new. Created in Task 1, extended in Tasks 2 and 3.

---

## Task 1: `computeOrderTotals` — create the file, full coverage for this function

**Files:**
- Create: `tests/tst_OrdersStore_totals.qml`

**Interfaces:**
- Consumes: `OrdersStore.computeOrderTotals(prods)` — takes an array of product-line objects
  (`quantity`, `price`, `discountType`, `discountValue`, `taxable`, `taxPercent`), returns
  `{ subtotal, discount, tax, taxBreakdown: [{rate, amount}], total, itemCount }`. No side effects,
  doesn't touch `OrdersStore.orders`.
- Produces: nothing consumed by later tasks — `parseCurrency`/`formatCurrency` (Tasks 2–3) don't
  depend on this function.

- [ ] **Step 1: Create the test file with `computeOrderTotals` coverage**

```qml
import QtQuick
import QtTest
import "../qml/model"

// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Every expected value below was verified by porting computeOrderTotals
// verbatim to Node.js and executing it, not hand-calculated. Needs a real
// qmltestrunner pass before merge (same status as every other tst_*.qml
// file in this suite when first written).
TestCase {
    name: "OrdersStore_totals"

    function test_computeOrderTotals_single_product_no_discount_no_tax() {
        var result = OrdersStore.computeOrderTotals([
            { quantity: 2, price: 100, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }
        ])
        compare(result.subtotal, 200)
        compare(result.discount, 0)
        compare(result.tax, 0)
        compare(result.taxBreakdown.length, 0)
        compare(result.total, 200)
        compare(result.itemCount, 2)
    }

    function test_computeOrderTotals_multiple_products_mixed_discount_and_tax() {
        var result = OrdersStore.computeOrderTotals([
            { quantity: 2, price: 250, discountType: "percent", discountValue: 10, taxable: true, taxPercent: 18 },
            { quantity: 1, price: 500, discountType: "flat", discountValue: 50, taxable: true, taxPercent: 5 },
            { quantity: 3, price: 20, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }
        ])
        // line 1: gross 500, 10% discount = 50, net 450, 18% tax = 81
        // line 2: gross 500, flat discount 50, net 450, 5% tax = 22.5
        // line 3: gross 60, no discount, not taxable
        compare(result.subtotal, 1060)
        compare(result.discount, 100)
        compare(result.tax, 103.5)
        compare(result.total, 1063.5)
        compare(result.itemCount, 6)
        compare(result.taxBreakdown.length, 2)
        compare(result.taxBreakdown[0].rate, 5)
        compare(result.taxBreakdown[0].amount, 22.5)
        compare(result.taxBreakdown[1].rate, 18)
        compare(result.taxBreakdown[1].amount, 81)
    }

    function test_computeOrderTotals_percent_discount_over_100_clamps_to_100() {
        var result = OrdersStore.computeOrderTotals([
            { quantity: 1, price: 100, discountType: "percent", discountValue: 150, taxable: false, taxPercent: 0 }
        ])
        compare(result.discount, 100)
        compare(result.total, 0)
    }

    function test_computeOrderTotals_percent_discount_negative_clamps_to_0() {
        var result = OrdersStore.computeOrderTotals([
            { quantity: 1, price: 100, discountType: "percent", discountValue: -20, taxable: false, taxPercent: 0 }
        ])
        compare(result.discount, 0)
        compare(result.total, 100)
    }

    function test_computeOrderTotals_flat_discount_exceeding_gross_clamps_to_gross() {
        var result = OrdersStore.computeOrderTotals([
            { quantity: 1, price: 40, discountType: "flat", discountValue: 999, taxable: false, taxPercent: 0 }
        ])
        compare(result.discount, 40)
        compare(result.total, 0)
    }

    function test_computeOrderTotals_flat_discount_negative_clamps_to_0() {
        var result = OrdersStore.computeOrderTotals([
            { quantity: 1, price: 40, discountType: "flat", discountValue: -10, taxable: false, taxPercent: 0 }
        ])
        compare(result.discount, 0)
        compare(result.total, 40)
    }

    function test_computeOrderTotals_taxable_true_but_taxPercent_zero_charges_no_tax() {
        var result = OrdersStore.computeOrderTotals([
            { quantity: 1, price: 100, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 0 }
        ])
        compare(result.tax, 0)
        compare(result.taxBreakdown.length, 0)
    }

    function test_computeOrderTotals_taxable_false_but_taxPercent_set_charges_no_tax() {
        var result = OrdersStore.computeOrderTotals([
            { quantity: 1, price: 100, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 18 }
        ])
        compare(result.tax, 0)
        compare(result.taxBreakdown.length, 0)
    }

    function test_computeOrderTotals_multiple_tax_rates_grouped_and_sorted_ascending() {
        var result = OrdersStore.computeOrderTotals([
            { quantity: 1, price: 100, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 18 },
            { quantity: 1, price: 100, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 5 },
            { quantity: 1, price: 100, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 12 },
            { quantity: 1, price: 50, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 5 } // second 5% line -- must merge into the same bucket, not a duplicate entry
        ])
        compare(result.tax, 37.5)
        compare(result.taxBreakdown.length, 3) // 3 distinct rates, not 4 lines
        compare(result.taxBreakdown[0].rate, 5)
        compare(result.taxBreakdown[0].amount, 7.5) // 5 (from the 100 line) + 2.5 (from the 50 line)
        compare(result.taxBreakdown[1].rate, 12)
        compare(result.taxBreakdown[1].amount, 12)
        compare(result.taxBreakdown[2].rate, 18)
        compare(result.taxBreakdown[2].amount, 18)
    }

    function test_computeOrderTotals_empty_array_returns_zeroed_totals() {
        var result = OrdersStore.computeOrderTotals([])
        compare(result.subtotal, 0)
        compare(result.discount, 0)
        compare(result.tax, 0)
        compare(result.taxBreakdown.length, 0)
        compare(result.total, 0)
        compare(result.itemCount, 0)
    }

    function test_computeOrderTotals_null_input_returns_zeroed_totals() {
        var result = OrdersStore.computeOrderTotals(null)
        compare(result.subtotal, 0)
        compare(result.total, 0)
        compare(result.itemCount, 0)
    }

    function test_computeOrderTotals_rounds_subtotal_and_discount_independently_before_computing_net() {
        // Proves the rounding order is load-bearing, not incidental. Rounding
        // subtotal (10.004 -> 10.00) and discount (0.006 -> 0.01) BEFORE
        // subtracting gives 9.99. Subtracting the raw values first and
        // rounding once at the end would give 10.00 instead -- a genuinely
        // different, wrong answer if the implementation ever "simplified"
        // to a single final round.
        var result = OrdersStore.computeOrderTotals([
            { quantity: 1, price: 10.004, discountType: "flat", discountValue: 0.006, taxable: false, taxPercent: 0 }
        ])
        compare(result.subtotal, 10)
        compare(result.discount, 0.01)
        compare(result.total, 9.99) // NOT 10.00 -- see comment above
    }

    function test_computeOrderTotals_itemCount_sums_quantities_not_line_count() {
        var result = OrdersStore.computeOrderTotals([
            { quantity: 5, price: 10, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 },
            { quantity: 2, price: 10, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }
        ])
        compare(result.itemCount, 7) // 5 + 2, not 2 (the line count)
    }
}
```

- [ ] **Step 2: Run locally (Taher) and confirm all 13 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 13 `OrdersStore_totals::test_computeOrderTotals_*` lines show `PASS`, 0 failures overall.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_totals.qml
git commit -m "test(OrdersStore): full coverage for computeOrderTotals

13 tests: happy path (single + multi-line mixed discount/tax), percent
and flat discount clamping (over-100%, negative, exceeds-gross), the
taxable/taxPercent guard's two independent failure conditions, multi-rate
tax breakdown grouping+sort, empty/null input, itemCount summing
quantities not line count, and a verified proof that subtotal/discount
are rounded independently before computing net (9.99, not the naive
10.00 a single-final-round implementation would produce).

All expected values verified by porting the function to Node.js and
executing it, not hand-calculated."
```

---

## Task 2: `parseCurrency` — extend the file

**Files:**
- Modify: `tests/tst_OrdersStore_totals.qml` (append a new `TestCase` block's worth of test
  functions to the existing one)

**Interfaces:**
- Consumes: `OrdersStore.parseCurrency(str)` — accepts a number (passthrough), or a string (strips
  everything except digits and `.`, then `parseFloat`s it); falsy/unparseable input returns `0`.

- [ ] **Step 1: Append `parseCurrency` tests**

Add these functions inside the existing `TestCase { ... }` block in
`tests/tst_OrdersStore_totals.qml`, after `test_computeOrderTotals_itemCount_sums_quantities_not_line_count`:

```qml

    function test_parseCurrency_passes_a_number_through_unchanged() {
        compare(OrdersStore.parseCurrency(42.5), 42.5)
        compare(OrdersStore.parseCurrency(0), 0)
    }

    function test_parseCurrency_empty_string_returns_zero() {
        compare(OrdersStore.parseCurrency(""), 0)
    }

    function test_parseCurrency_null_returns_zero() {
        compare(OrdersStore.parseCurrency(null), 0)
    }

    function test_parseCurrency_undefined_returns_zero() {
        compare(OrdersStore.parseCurrency(undefined), 0)
    }

    function test_parseCurrency_strips_currency_symbol_and_commas() {
        compare(OrdersStore.parseCurrency("\u20B91,234.50"), 1234.5) // \u20B9 is the Rupee sign
    }

    function test_parseCurrency_non_numeric_string_returns_zero() {
        compare(OrdersStore.parseCurrency("abc"), 0)
    }

    function test_parseCurrency_surrounding_whitespace_is_tolerated() {
        compare(OrdersStore.parseCurrency("  99.99 "), 99.99)
    }

    function test_parseCurrency_multiple_decimal_points_parses_up_to_the_second_one() {
        // The strip regex keeps every '.', but parseFloat itself stops at
        // the second one -- "1.2.3" becomes 1.2, not NaN and not 123.
        compare(OrdersStore.parseCurrency("1.2.3"), 1.2)
    }
```

- [ ] **Step 2: Run locally (Taher) and confirm all 8 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 8 `OrdersStore_totals::test_parseCurrency_*` lines show `PASS`.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_totals.qml
git commit -m "test(OrdersStore): full coverage for parseCurrency

8 tests: number passthrough, empty/null/undefined -> 0, currency-symbol
and comma stripping, non-numeric string -> 0, whitespace tolerance, and
the multiple-decimal-point edge case (parseFloat stops at the second
dot rather than the strip regex rejecting the whole string)."
```

---

## Task 3: `formatCurrency` — extend the file, complete this slice

**Files:**
- Modify: `tests/tst_OrdersStore_totals.qml` (append final test functions)

**Interfaces:**
- Consumes: `OrdersStore.formatCurrency(val)` — calls `parseCurrency` internally, then
  `Intl.NumberFormat('en-IN', {style:'currency', currency:'INR', minimumFractionDigits:0,
  maximumFractionDigits:1})`, with a manual `'INR ' + rounded` fallback if `Intl` throws.

- [ ] **Step 1: Append `formatCurrency` tests**

Add these functions inside the same `TestCase { ... }` block, after
`test_parseCurrency_multiple_decimal_points_parses_up_to_the_second_one`. Assertions check the
digit/decimal content via substring rather than pin the exact locale symbol string, so they hold
whether the primary `Intl` path or the manual fallback path executes — both are designed to
produce the same up-to-1-decimal formatting, and this sandbox can't confirm which one
`qmltestrunner`'s JS engine actually takes:

```qml

    function test_formatCurrency_fractional_value_shows_exactly_one_decimal() {
        var formatted = OrdersStore.formatCurrency(10.5)
        verify(formatted.indexOf("10.5") !== -1,
               "expected '10.5' in formatted output, got: " + formatted)
    }

    function test_formatCurrency_integer_value_shows_no_trailing_decimal() {
        var formatted = OrdersStore.formatCurrency(15)
        verify(formatted.indexOf("15.0") === -1,
               "integer input must not show a trailing '.0', got: " + formatted)
        verify(formatted.indexOf("15") !== -1,
               "expected '15' in formatted output, got: " + formatted)
    }

    function test_formatCurrency_zero() {
        var formatted = OrdersStore.formatCurrency(0)
        verify(formatted.indexOf("0") !== -1, "expected '0' in formatted output, got: " + formatted)
    }

    function test_formatCurrency_rounds_to_one_decimal() {
        // parseCurrency(1234.56) = 1234.56; formatCurrency must round to
        // 1 decimal, i.e. show "1,234.6", not "1,234.56" or "1,234.5".
        var formatted = OrdersStore.formatCurrency(1234.56)
        verify(formatted.indexOf("1,234.6") !== -1,
               "expected '1,234.6' (rounded to 1 decimal) in formatted output, got: " + formatted)
    }

    function test_formatCurrency_delegates_to_parseCurrency_for_string_input() {
        // formatCurrency(str) calls parseCurrency(str) first -- confirms
        // the two functions are actually wired together, not just
        // independently correct in isolation.
        var formatted = OrdersStore.formatCurrency("\u20B91,234.50")
        verify(formatted.indexOf("1,234.5") !== -1,
               "expected the pre-parsed numeric value reflected in the output, got: " + formatted)
    }
```

- [ ] **Step 2: Run locally (Taher) and confirm all 5 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 5 `OrdersStore_totals::test_formatCurrency_*` lines show `PASS`. **If any fail**,
paste back the actual formatted string `qmltestrunner` produced — that tells us directly whether
the `Intl` path or the fallback path is executing in this environment, which was an open question
this plan flagged rather than assumed (spec §3, `formatCurrency` row).

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_totals.qml
git commit -m "test(OrdersStore): full coverage for formatCurrency

5 tests: 1-decimal display for fractional values, no trailing .0 for
integers, zero, rounding to 1 decimal on a multi-digit value, and
confirmation it actually delegates to parseCurrency for string input
rather than just happening to produce similar output independently.

Assertions check digit/decimal substrings rather than pin an exact
locale string, so they hold regardless of whether the primary Intl path
or the manual fallback path executes -- which one does wasn't
independently confirmed in this sandbox (no Qt JS engine here); the test
failure message says exactly what to report if it matters."
```

---

## Self-review (per writing-plans skill)

**Spec coverage:** Spec's Group A table rows for `computeOrderTotals`, `parseCurrency`,
`formatCurrency` — all three now have a task. Spec §5 scenario taxonomy for these three
(zero-line/edge discount clamping/mixed-tax/rounding-order) — each named explicitly as a test.
Spec §2's "verified, not assumed" coverage-claim standard — met via the Node port, not hand
arithmetic.

**Placeholder scan:** No "TBD"/"similar to Task N"/"add appropriate handling" anywhere above —
every step has complete, runnable code and a concrete expected result.

**Type consistency:** All three tasks target the same file/`TestCase` block; function names
(`computeOrderTotals`, `parseCurrency`, `formatCurrency`) match `OrdersStore.qml`'s actual exposed
names exactly, checked against the source, not assumed.

**What this slice does not cover:** `findIndexById`, `get`, `getById`, `openOrdersForProduct`,
`pendingCount`, `completedThisMonth`, `totalRevenue`, `processingCount` — that's Slice 2
(`tst_OrdersStore_queries.qml`), a separate plan, per the spec's file layout (§6) and this skill's
own guidance to split independent subsystems into separate plans rather than one document covering
all 5 files.
