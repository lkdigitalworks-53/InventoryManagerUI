import QtQuick
import QtTest
import "../qml/helper/OrderAdjust.js" as OA

TestCase {
    name: "OrderAdjust"

    function test_diff_partial_reduction() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 3 }]
        var newL = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var d = OA.diffLines(oldL, newL)
        compare(d.length, 1)
        compare(d[0].productId, "P1")
        compare(d[0].returnedQty, 2)
        compare(d[0].addedQty, 0)
        compare(d[0].oldPrice, 100)
        compare(d[0].newPrice, 100)
    }
    function test_diff_full_removal() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 3 }]
        var newL = []
        var d = OA.diffLines(oldL, newL)
        compare(d.length, 1)
        compare(d[0].returnedQty, 3)
        compare(d[0].newQty, 0)
    }
    function test_diff_addition() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var newL = [{ productId: "P1", name: "Widget", price: 100, quantity: 4 }]
        var d = OA.diffLines(oldL, newL)
        compare(d[0].addedQty, 3)
        compare(d[0].returnedQty, 0)
    }
    function test_diff_new_line_added() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var newL = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 },
                    { productId: "P2", name: "Gadget", price: 50, quantity: 2 }]
        var d = OA.diffLines(oldL, newL)
        var p2 = null
        for (var i = 0; i < d.length; ++i) if (d[i].productId === "P2") p2 = d[i]
        verify(p2 !== null)
        compare(p2.addedQty, 2)
        compare(p2.oldQty, 0)
    }
    function test_diff_price_change_only() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 2 }]
        var newL = [{ productId: "P1", name: "Widget", price: 80, quantity: 2 }]
        var d = OA.diffLines(oldL, newL)
        compare(d[0].returnedQty, 0)
        compare(d[0].addedQty, 0)
        compare(d[0].oldPrice, 100)
        compare(d[0].newPrice, 80)
    }
    function test_diff_no_change_empty() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 2 }]
        var newL = [{ productId: "P1", name: "Widget", price: 100, quantity: 2 }]
        compare(OA.diffLines(oldL, newL).length, 0)
    }
    function test_diff_qty_and_price_both_change() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 3 }]
        var newL = [{ productId: "P1", name: "Widget", price: 80, quantity: 1 }]
        var d = OA.diffLines(oldL, newL)
        compare(d.length, 1)
        compare(d[0].returnedQty, 2)
        compare(d[0].addedQty, 0)
        compare(d[0].oldPrice, 100)
        compare(d[0].newPrice, 80)
        compare(d[0].newQty, 1)
    }
    function test_restore_partial_across_batches() {
        var consumption = [
            { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 10 },
            { batchId: "B2", supplierId: "S2", qtyConsumed: 3, unitCost: 12 }
        ]
        var plan = OA.restorePlan(consumption, 4)
        compare(plan.length, 2)
        compare(plan[0].batchId, "B2")
        compare(plan[0].qty, 3)
        compare(plan[0].unitCost, 12)
        compare(plan[1].batchId, "B1")
        compare(plan[1].qty, 1)
        compare(plan[1].unitCost, 10)
    }
    function test_restore_full() {
        var consumption = [
            { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 10 },
            { batchId: "B2", supplierId: "S2", qtyConsumed: 3, unitCost: 12 }
        ]
        var plan = OA.restorePlan(consumption, 5)
        var total = 0
        for (var i = 0; i < plan.length; ++i) total += plan[i].qty
        compare(total, 5)
    }
    function test_restore_empty_consumption_is_empty() {
        compare(OA.restorePlan([], 3).length, 0)
        compare(OA.restorePlan(null, 3).length, 0)
    }
    function test_restore_zero_qty_empty() {
        var consumption = [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 10 }]
        compare(OA.restorePlan(consumption, 0).length, 0)
    }
    function test_surviving_consumption_after_partial_return() {
        // line consumed 2 from B1 (cost10) + 3 from B2 (cost12) = 5 total.
        var consumption = [
            { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 10 },
            { batchId: "B2", supplierId: "S2", qtyConsumed: 3, unitCost: 12 }
        ]
        // return 4 (restorePlan unwinds newest-first: 3 from B2, 1 from B1)
        // → surviving 1 unit should remain on B1 (oldest), cost 10.
        var surv = OA.survivingConsumption(consumption, 4)
        var total = 0
        for (var i = 0; i < surv.length; ++i) total += surv[i].qtyConsumed
        compare(total, 1)
        // the surviving unit is from B1 (oldest, since newest was unwound first)
        compare(surv[0].batchId, "B1")
        compare(surv[0].qtyConsumed, 1)
        compare(surv[0].unitCost, 10)
    }
    function test_surviving_consumption_full_return_empty() {
        var consumption = [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 10 }]
        compare(OA.survivingConsumption(consumption, 2).length, 0)
    }
    function test_surviving_consumption_no_return_unchanged() {
        var consumption = [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 10 }]
        var surv = OA.survivingConsumption(consumption, 0)
        compare(surv.length, 1)
        compare(surv[0].qtyConsumed, 2)
    }
    function test_surviving_consumption_null_safe() {
        compare(OA.survivingConsumption(null, 1).length, 0)
        compare(OA.survivingConsumption([], 1).length, 0)
    }
    function test_diff_carries_tax_fields() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 3, taxable: true, taxPercent: 10 }]
        var newL = [{ productId: "P1", name: "Widget", price: 100, quantity: 1, taxable: true, taxPercent: 10 }]
        var d = OA.diffLines(oldL, newL)
        compare(d.length, 1)
        compare(d[0].taxable, true)
        compare(d[0].taxPercent, 10)
    }
}
