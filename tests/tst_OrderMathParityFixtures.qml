import QtQuick
import QtTest
import "../qml/helper/OrderMath.js" as OM

// PAIRED FILE: functions/test/fixtures/orderMathFixtures.js holds the SAME
// literal scenario data for the Node port (functions/lib/orderMath.js). This
// file proves the QML original agrees with it. Kept in sync manually (same
// convention as tst_RealisedMathParityFixtures.qml). If you change a
// scenario here, change it there too, and vice versa.
//
// Every scenario is one already verified in tests/tst_OrderMath.qml (see
// that file for the fuller suite this doesn't replace) -- this file exists
// ONLY to prove cross-runtime parity for lineTax/refundPerUnit, the two
// functions this roadmap item scoped, not to re-litigate correctness.
TestCase {
    name: "OrderMathParityFixtures"
    function _round2(x) { return Math.round(x * 100) / 100 }

    function test_lineTax_single_rate_matches_legacy() {
        fuzzyCompare(OM.lineTax({ quantity: 2, price: 20, taxable: true, taxPercent: 10,
                                  discountType: "flat", discountValue: 0 }), 4, 0.001)
        compare(OM.lineTax({ quantity: 2, price: 20, taxable: false, taxPercent: 10 }), 0)
        fuzzyCompare(OM.lineTax({ quantity: 2, price: 20, taxable: true, taxPercent: 10,
                                  discountType: "flat", discountValue: 5 }), 3.5, 0.001)
    }

    function test_lineTax_vintage_split() {
        var ln = { quantity: 2, price: 20, taxable: true, taxPercent: 10,
                   discountType: "flat", discountValue: 0 }
        fuzzyCompare(OM.lineTax(ln, { originalQty: 1, bookedRate: 0 }), 2, 0.001)
        fuzzyCompare(OM.lineTax(ln, { originalQty: 2, bookedRate: 0 }), 0, 0.001)
        fuzzyCompare(OM.lineTax(ln, { originalQty: 5, bookedRate: 0 }), 0, 0.001)
        fuzzyCompare(OM.lineTax(ln, { originalQty: 1, bookedRate: 5 }), 3, 0.001)
        fuzzyCompare(OM.lineTax(ln, { originalQty: 0, bookedRate: 5 }), 4, 0.001)
        fuzzyCompare(OM.lineTax({ quantity: 2, price: 20, taxable: true, taxPercent: 10,
                                  discountType: "flat", discountValue: 10 },
                                { originalQty: 1, bookedRate: 0 }), 1.5, 0.001)
    }

    function test_lineTax_zero_qty_guard() {
        compare(OM.lineTax({ quantity: 0, price: 20, taxable: true, taxPercent: 10 },
                           { originalQty: 0, bookedRate: 0 }), 0)
    }

    function test_lineTax_explicit_current_rate() {
        var bookedSeeded = { quantity: 2, price: 20, taxable: false, taxPercent: 0,
                             discountType: "flat", discountValue: 0 }
        fuzzyCompare(OM.lineTax(bookedSeeded, { originalQty: 1, bookedRate: 0 }), 0, 0.001)
        fuzzyCompare(OM.lineTax(bookedSeeded, { originalQty: 1, bookedRate: 0, currentRate: 10 }), 2, 0.001)
        fuzzyCompare(OM.lineTax(bookedSeeded, { originalQty: 1, bookedRate: 0, currentRate: 0 }), 0, 0.001)
        fuzzyCompare(OM.lineTax({ quantity: 2, price: 20, taxable: false, taxPercent: 0,
                                  discountType: "flat", discountValue: 2 },
                                { originalQty: 1, bookedRate: 0, currentRate: 10 }), 1.9, 0.001)
    }

    function test_lineTax_percent_discount_type() {
        fuzzyCompare(OM.lineTax({ quantity: 2, price: 100, taxable: true, taxPercent: 10,
                                  discountType: "percent", discountValue: 15 }), 17, 0.001)
        fuzzyCompare(OM.lineTax({ quantity: 2, price: 100, taxable: true, taxPercent: 10,
                                  discountType: "percent", discountValue: -5 }), 20, 0.001)
        compare(OM.lineTax({ quantity: 2, price: 100, taxable: true, taxPercent: 10,
                             discountType: "percent", discountValue: 150 }), 0)
        fuzzyCompare(OM.lineTax({ quantity: 2, price: 100, taxable: true, taxPercent: 10,
                                  discountType: "percent" }), 20, 0.001)
    }

    function test_lineTax_flat_discount_clamps() {
        fuzzyCompare(OM.lineTax({ quantity: 2, price: 100, taxable: true, taxPercent: 10,
                                  discountType: "flat", discountValue: -10 }), 20, 0.001)
        compare(OM.lineTax({ quantity: 2, price: 100, taxable: true, taxPercent: 10,
                            discountType: "flat", discountValue: 500 }), 0)
    }

    function test_lineTax_null_line_and_non_numeric_price() {
        compare(OM.lineTax(null), 0)
        compare(OM.lineTax(undefined), 0)
        compare(OM.lineTax({ quantity: 3, taxable: true, taxPercent: 10 }), 0)
    }

    function test_lineTax_taxable_true_zero_rate() {
        compare(OM.lineTax({ quantity: 2, price: 20, taxable: true, taxPercent: 0,
                             discountType: "flat", discountValue: 0 }), 0)
    }

    function test_lineTax_negative_original_qty_clamps() {
        var ln = { quantity: 2, price: 20, taxable: true, taxPercent: 10,
                   discountType: "flat", discountValue: 0 }
        fuzzyCompare(OM.lineTax(ln, { originalQty: -3, bookedRate: 0 }), 4, 0.001)
    }

    function test_refundPerUnit_original_sale_event() {
        var saleEvent = { kind: "sale", productId: "P1", quantity: 4, net: 360, tax: 36,
                          consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 50 }] }
        fuzzyCompare(OM.refundPerUnit(saleEvent), 99, 0.001)
    }

    function test_refundPerUnit_guards() {
        compare(OM.refundPerUnit(null), 0)
        compare(OM.refundPerUnit({ quantity: 0, net: 100, tax: 0 }), 0)
        compare(OM.refundPerUnit({ quantity: 2 }), 0)
    }
}
