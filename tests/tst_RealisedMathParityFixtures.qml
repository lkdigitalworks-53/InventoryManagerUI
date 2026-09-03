import QtQuick
import QtTest
import "../qml/helper/RealisedMath.js" as RM

// PAIRED FILE: functions/test/fixtures/realisedMathFixtures.js holds the SAME
// literal scenario data for the Node port (functions/lib/realisedMath.js).
// This file proves the QML original agrees with it. Kept in sync manually
// (not loaded from a shared file -- this repo has no established pattern for
// a QML test reading an external JSON file synchronously). If you change a
// scenario here, change it there too, and vice versa.
//
// Every scenario/expected value is copied from an existing, already-verified
// case in tests/tst_RealisedMath.qml (see that file for the fuller test suite
// this doesn't replace) -- this file exists ONLY to prove cross-runtime
// parity on a representative subset, not to re-litigate correctness.
TestCase {
    name: "RealisedMathParityFixtures"
    function _round2(x) { return Math.round(x * 100) / 100 }

    function test_sale_plus_return_nets_down() {
        var entries = [
            {
                kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 4,
                unitPrice: 100, net: 400, tax: 0, discountShare: 0,
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 60 }]
            },
            {
                kind: "return", timestamp: "2026-06-21T10:00:00Z", productId: "P1", quantity: -1,
                unitPrice: 100, net: -100, tax: 0, discountShare: 0,
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: -1, unitCost: 60 }]
            }
        ]
        var t = RM.totals(entries, null, {})
        compare(_round2(t.net), 300)
        compare(_round2(t.cogs), 180)
        compare(_round2(t.profit), 120)

        var m = RM.byDimension("supplierId", entries, null, {})
        fuzzyCompare(m["S1"].revenue, 300, 0.011)
        fuzzyCompare(m["S1"].profit, 120, 0.011)
    }

    function test_supplier_filter_includes_stamped_price_adjust() {
        var entries = [
            { kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 2,
              unitPrice: 100, net: 200, tax: 0, discountShare: 0, orderChannel: "online",
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 60 }] },
            { kind: "price_adjust", timestamp: "2026-06-20T11:00:00Z", productId: "P1",
              total: -20, reason: "discount", orderChannel: "online",
              supplierSlices: [{ key: "S1", amount: -20 }] }
        ]
        var tS1 = RM.totals(entries, { supplierId: "S1" }, {})
        compare(_round2(tS1.net), 180)
        compare(_round2(tS1.discount), 20)

        var tS2 = RM.totals(entries, { supplierId: "S2" }, {})
        compare(_round2(tS2.net), 0)

        var tAll = RM.totals(entries, null, {})
        compare(_round2(tAll.net), 180)
    }

    function test_no_net_fails_closed() {
        var entries = [{
            kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 2,
            unitPrice: 100,   // net DELIBERATELY absent (legacy/un-stamped)
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 40 }]
        }]
        var m = RM.byDimension("supplierId", entries, null, {})
        compare(_round2(m["S1"].revenue), 0)
        compare(_round2(m["S1"].cogs), 80)
    }

    function test_price_adjust_discount_column() {
        var entries = [
            { kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 2,
              unitPrice: 100, net: 200, tax: 0, discountShare: 0,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 60 }] },
            { kind: "price_adjust", timestamp: "2026-06-20T11:00:00Z", productId: "P1",
              total: -20, reason: "discount",
              supplierSlices: [{ key: "S1", amount: -20 }] }
        ]
        var m = RM.byDimension("supplierId", entries, null, {})
        compare(_round2(m["S1"].revenue), 180)
        compare(_round2(m["S1"].discount), 20)
    }

    // 2026-09-02 fix (SKILLS Skill 57): price_adjust events now carry a
    // signed tax delta. Mirrors functions/test/fixtures/realisedMathFixtures.js
    // "price_adjust_tax_share_no_scope_supplier_dimension" / "..._supplier_filtered"
    // / "..._unknown_bucket" — same literal scenario data, proving the QML
    // original agrees with the Node port on this fix too.
    function test_price_adjust_tax_share_no_scope_supplier_dimension() {
        var entries = [
            { kind: "sale", timestamp: "2026-09-02T10:00:00Z", productId: "P1", quantity: 1,
              unitPrice: 60, net: 60, tax: 3, discountShare: 0,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] },
            { kind: "price_adjust", timestamp: "2026-09-02T11:00:00Z", productId: "P1",
              total: -3, tax: -0.15, reason: "discount",
              supplierSlices: [{ key: "S1", amount: -3 }] }
        ]
        var t = RM.totals(entries, null, {})
        compare(_round2(t.net), 57)
        compare(_round2(t.tax), 2.85)

        var m = RM.byDimension("supplierId", entries, null, {})
        compare(_round2(m["S1"].revenue), 57)
        compare(_round2(m["S1"].tax), 2.85)
        compare(_round2(m["S1"].discount), 3)
    }

    function test_price_adjust_tax_share_supplier_filtered() {
        var entries = [
            { kind: "sale", timestamp: "2026-09-02T10:00:00Z", productId: "P1", quantity: 1,
              unitPrice: 60, net: 60, tax: 3, discountShare: 0, orderChannel: "online",
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] },
            { kind: "price_adjust", timestamp: "2026-09-02T11:00:00Z", productId: "P1",
              total: -3, tax: -0.15, reason: "discount", orderChannel: "online",
              supplierSlices: [{ key: "S1", amount: -3 }] }
        ]
        var tS1 = RM.totals(entries, { supplierId: "S1" }, {})
        compare(_round2(tS1.net), 57)
        compare(_round2(tS1.tax), 2.85)

        var tS2 = RM.totals(entries, { supplierId: "S2" }, {})
        compare(_round2(tS2.net), 0)
        compare(_round2(tS2.tax), 0)
    }

    function test_price_adjust_tax_no_lineage_unknown_bucket() {
        var entries = [
            { kind: "sale", timestamp: "2026-09-02T10:00:00Z", productId: "P1", quantity: 1,
              unitPrice: 60, net: 60, tax: 3, discountShare: 0,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] },
            { kind: "price_adjust", timestamp: "2026-09-02T11:00:00Z", productId: "P1",
              total: -3, tax: -0.15, reason: "discount" }
        ]
        var m = RM.byDimension("supplierId", entries, null, {})
        compare(_round2(m[""].revenue), -3)
        compare(_round2(m[""].tax), -0.15)
    }

    // Cross-check the core invariant (Skill 29) on the richest fixture, same
    // as the Node test's equivalent case.
    function test_invariant_sum_byDimension_equals_totals() {
        var entries = [
            {
                kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 4,
                unitPrice: 100, net: 400, tax: 0, discountShare: 0,
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 60 }]
            },
            {
                kind: "return", timestamp: "2026-06-21T10:00:00Z", productId: "P1", quantity: -1,
                unitPrice: 100, net: -100, tax: 0, discountShare: 0,
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: -1, unitCost: 60 }]
            }
        ]
        var t = RM.totals(entries, null, {})
        var fields = ["productId", "supplierId", "category", "channel", "staffId"]
        for (var f = 0; f < fields.length; ++f) {
            var m = RM.byDimension(fields[f], entries, null, {})
            var sumRevenue = 0, sumProfit = 0, sumCogs = 0
            var keys = Object.keys(m)
            for (var k = 0; k < keys.length; ++k) {
                sumRevenue += m[keys[k]].revenue
                sumProfit += m[keys[k]].profit
                sumCogs += m[keys[k]].cogs
            }
            fuzzyCompare(sumRevenue, t.net, 0.011, "field=" + fields[f] + " revenue")
            fuzzyCompare(sumProfit, t.profit, 0.011, "field=" + fields[f] + " profit")
            fuzzyCompare(sumCogs, t.cogs, 0.011, "field=" + fields[f] + " cogs")
        }
    }
}
