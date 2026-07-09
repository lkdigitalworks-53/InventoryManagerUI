import QtQuick
import QtTest
import "../qml/helper/BreakdownMath.js" as BM

// PAIRED FILE: functions/test/fixtures/breakdownMathFixtures.js holds the SAME
// literal scenario data for the Node port. See tst_RealisedMathParityFixtures.qml
// for why this is a manually-mirrored pair rather than a shared loaded file.
TestCase {
    name: "BreakdownMathParityFixtures"

    function test_sold_by_category_nets_returns() {
        var entries = [
            { kind: "sale", productId: "P1", quantity: 5, date: "2026-06-20",
              consumption: [{ supplierId: "S1", qtyConsumed: 5 }] },
            { kind: "sale", productId: "P2", quantity: 3, date: "2026-06-20",
              consumption: [{ supplierId: "S2", qtyConsumed: 3 }] },
            { kind: "return", productId: "P1", quantity: -2, date: "2026-06-21",
              consumption: [{ supplierId: "S1", qtyConsumed: -2 }] }
        ]
        var productCategory = { P1: "Drinks", P2: "Snacks" }
        var supplierName = { S1: "Acme", S2: "Beta" }

        var byCat = BM.breakdown({
            metric: "sold", dim: "category", entries: entries,
            window: null, channel: "", staffId: "", category: "", supplierId: "",
            productCategory: productCategory, supplierName: supplierName
        })
        compare(byCat["Drinks"], 3)
        compare(byCat["Snacks"], 3)

        var bySup = BM.breakdown({
            metric: "sold", dim: "supplier", entries: entries,
            window: null, channel: "", staffId: "", category: "", supplierId: "",
            productCategory: productCategory, supplierName: supplierName
        })
        compare(bySup["Acme"], 3)
        compare(bySup["Beta"], 3)
    }

    function test_purchased_by_supplier() {
        var entries = [
            { kind: "purchase", productId: "P1", quantity: 20, date: "2026-06-15", party: "S1" },
            { kind: "purchase", productId: "P2", quantity: 10, date: "2026-06-16", party: "S2" },
            { kind: "created", productId: "P1", quantity: 5, date: "2026-06-01",
              snapshot: { supplierId: "S1" } }
        ]
        var productCategory = { P1: "Drinks", P2: "Snacks" }
        var supplierName = { S1: "Acme", S2: "Beta" }

        var byCat = BM.breakdown({
            metric: "purchased", dim: "category", entries: entries,
            window: null, channel: "", staffId: "", category: "", supplierId: "",
            productCategory: productCategory, supplierName: supplierName
        })
        compare(byCat["Drinks"], 25)
        compare(byCat["Snacks"], 10)

        var bySup = BM.breakdown({
            metric: "purchased", dim: "supplier", entries: entries,
            window: null, channel: "", staffId: "", category: "", supplierId: "",
            productCategory: productCategory, supplierName: supplierName
        })
        compare(bySup["Acme"], 25)
        compare(bySup["Beta"], 10)
    }
}
