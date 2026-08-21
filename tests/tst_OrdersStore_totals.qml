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
