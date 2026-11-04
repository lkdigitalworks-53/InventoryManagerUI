import QtQuick
import QtTest
import "../qml/helper/RestockFlow.js" as RF
import "../qml/helper/OperationKeys.js" as OK

// Headless tests for the pure restock wiring decisions (atomic-ops R4). Pure JS, no singletons.
// Design: docs/superpowers/specs/2026-11-02-r4-restock-wire-design.md
// The same cases run in Node in functions/test/restockFlow.test.js (incl. the real server); this is the
// qmltestrunner copy so a QML-engine difference cannot hide.
TestCase {
    name: "RestockFlow"

    readonly property var suppliers: [{ supplierId: "SUP-001", name: "Acme Farms" }, { supplierId: "SUP-002", name: "Bolt & Co" }]
    readonly property var product: ({ productId: "p1", name: "Tomato", category: "Veg", price: 12.5 })

    function _args(over) {
        return Object.assign({ key: "restock:1-a", product: product, qty: 5, unitCost: 10, reason: "weekly",
                               party: "", suppliers: suppliers, now: new Date(2026, 5, 15, 23, 59, 59, 900) }, over || {})
    }

    function test_newKey_is_a_restock_key() { verify(OK.isRestockKey(RF.newKey(1781000000000, function() { return 0.5 }))) }
    function test_localDate_pads_and_uses_local_parts() {
        compare(RF.localDate(new Date(2026, 0, 5, 0, 0, 1)), "2026-01-05")
        compare(RF.localDate(new Date(2026, 11, 31, 23, 59, 59)), "2026-12-31")
    }

    function test_supplierFor() {
        compare(RF.supplierFor("", suppliers).supplier, null)
        compare(RF.supplierFor(null, suppliers).supplier, null)
        compare(RF.supplierFor(undefined, suppliers).supplier, null)
        compare(RF.supplierFor("SUP-777", []).supplier.id, "SUP-777")
        compare(RF.supplierFor("acme FARMS", suppliers).supplier.id, "SUP-001")
        compare(RF.supplierFor("  Bolt & Co ", suppliers).supplier.id, "SUP-002")
        compare(RF.supplierFor(" Newco ", suppliers).supplier.newName, "Newco")
        compare(RF.supplierFor("   ", suppliers).ok, false)
        compare(RF.supplierFor("   ", suppliers).reason, "bad-supplier")
        compare(RF.supplierFor("Acme", null).supplier.newName, "Acme")
        compare(RF.supplierFor(42, suppliers).supplier.newName, "42")
    }

    function test_makeInput_assembles_the_planner_input_from_one_date() {
        var a = _args()
        var r = RF.makeInput(a)
        verify(r.ok)
        compare(r.input.productId, "p1")
        compare(r.input.productName, "Tomato")
        compare(r.input.category, "Veg")
        compare(r.input.qty, 5)
        compare(r.input.unitCost, 10)
        compare(r.input.reason, "weekly")
        compare(r.input.supplier, null)
        compare(r.input.now, a.now.toISOString())
        compare(r.input.date, "2026-06-15")
    }
    function test_makeInput_default_cost() {
        compare(RF.makeInput(_args({ unitCost: undefined })).input.unitCost, 12.5)
        compare(RF.makeInput(_args({ unitCost: NaN })).input.unitCost, 12.5)
        compare(RF.makeInput(_args({ unitCost: "7" })).input.unitCost, 12.5)
        compare(RF.makeInput(_args({ unitCost: 0 })).input.unitCost, 0)
    }
    function test_makeInput_refusals() {
        compare(RF.makeInput(_args({ product: null })).reason, "bad-product")
        compare(RF.makeInput(undefined).reason, "bad-product")
        compare(RF.makeInput(_args({ now: undefined })).reason, "bad-time")
        compare(RF.makeInput(_args({ now: "2026-06-15" })).reason, "bad-time")
        compare(RF.makeInput(_args({ now: new Date(NaN) })).reason, "bad-time")
        compare(RF.makeInput(_args({ party: "  " })).reason, "bad-supplier")
    }

    function test_classify() {
        compare(RF.classify({ ok: true, results: [] }), "applied")
        compare(RF.classify({ ok: true, queued: true }), "queued")
        compare(RF.classify({ ok: false, pending: true, error: "timeout" }), "queued")
        compare(RF.classify({ ok: false, error: "conflict" }), "rejected")
        compare(RF.classify({ ok: false, error: "discarded", discarded: true }), "rejected")
        compare(RF.classify(undefined), "rejected")
        compare(RF.classify(null), "rejected")
        compare(RF.classify({}), "rejected")
        compare(RF.classify({ ok: 1 }), "rejected")
    }

    function test_refusalText() {
        compare(RF.refusalText("bad-quantity"), "Quantity must be greater than zero")
        compare(RF.refusalText("bad-cost"), "Unit cost is not a valid amount")
        compare(RF.refusalText("bad-supplier"), "Supplier name is not valid")
        verify(RF.refusalText("too-large").length > 0)
        verify(RF.refusalText("reserved-text").length > 0)
        verify(RF.refusalText("bad-key").indexOf("bad-key") >= 0)
    }

    function test_activityText() {
        var out = { stock: 15, batch: { qtyReceived: 5, note: "weekly" }, purchase: { productName: "Tomato" } }
        var t = RF.activityText(out, "Acme Farms")
        compare(t.title, "Restocked: Tomato")
        compare(t.subtitle, "+5 · now 15 in stock · from Acme Farms · weekly")
        compare(RF.activityText({ stock: 15, batch: { qtyReceived: 2.5, note: "" }, purchase: { productName: "T" } }, "").subtitle, "+2.5 · now 15 in stock")
        compare(RF.activityText({ stock: 3 }, "").title, "Restocked: ")
    }

    // -- review D-2: the cost field's text ----------------------------------
    function test_costFromText() {
        verify(isNaN(RF.costFromText("")))
        verify(isNaN(RF.costFromText("   ")))
        verify(isNaN(RF.costFromText(undefined)))
        verify(isNaN(RF.costFromText(null)))
        verify(isNaN(RF.costFromText(12)), "not a string = not given")
        compare(RF.costFromText("0"), 0)
        compare(RF.costFromText(" 7.25 "), 7.25)
        compare(RF.costFromText("-3"), -3)
        compare(RF.costFromText("abc"), -1)
        compare(RF.costFromText("12abc"), -1)
        compare(RF.costFromText("1,5"), -1)
        compare(RF.costFromText("Infinity"), -1)
        compare(RF.costFromText("1e999"), -1)
    }

    function test_costFromText_blank_falls_back_to_the_product_cost_and_junk_is_refused() {
        compare(RF.makeInput(_args({ unitCost: RF.costFromText("") })).input.unitCost, 12.5)
        compare(RF.makeInput(_args({ unitCost: RF.costFromText("0") })).input.unitCost, 0)
        compare(RF.makeInput(_args({ unitCost: RF.costFromText("9.5") })).input.unitCost, 9.5)
        compare(RF.makeInput(_args({ unitCost: RF.costFromText("abc") })).input.unitCost, -1, "makeInput passes it on; the plan refuses it")
    }
}
