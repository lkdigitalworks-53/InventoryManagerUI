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

    // -- review D-C (PR #188 sweep): the typed quantity -----------------------
    // A fake of the editable SpinBox. Qt's default parser throws on text that is not a number.
    function _spin(text, over) {
        return Object.assign({
            value: 10, from: 1, to: 9999, locale: "en_IN", contentItem: { text: text },
            valueFromText: function(t, loc) {
                var n = Number(t)
                if (t !== String(t).trim() || t === "" || isNaN(n)) throw new Error("not a number")
                return n
            }
        }, over || {})
    }
    function test_qtyFromField_typed_text_wins_over_the_stale_value() {
        var r = RF.qtyFromField(_spin("25"))
        compare(r.ok, true)
        compare(r.qty, 25)
        compare(RF.qtyFromField(_spin("  42 ")).qty, 42, "whitespace trimmed")
        compare(RF.qtyFromField(_spin("1")).qty, 1)
        compare(RF.qtyFromField(_spin("9999")).qty, 9999)
    }
    function test_qtyFromField_refuses_and_never_clamps() {
        var bad = ["", "   ", "abc", "2.5", "0", "-5", "10000", "100000", "1e999", "NaN"]
        for (var i = 0; i < bad.length; ++i) {
            var r = RF.qtyFromField(_spin(bad[i]))
            compare(r.ok, false, JSON.stringify(bad[i]))
            compare(r.message, "Enter a whole quantity from 1 to 9999")
        }
        compare(RF.qtyFromField(_spin("5", { valueFromText: function() { throw new Error("boom") } })).ok, false)
    }
    function test_qtyFromField_without_readable_text_uses_the_checked_committed_value() {
        compare(RF.qtyFromField(_spin("x", { contentItem: undefined, value: 7 })).qty, 7)
        compare(RF.qtyFromField(_spin("x", { valueFromText: undefined, value: 7 })).qty, 7)
        compare(RF.qtyFromField(_spin("x", { contentItem: undefined, value: 0 })).ok, false)
        compare(RF.qtyFromField(_spin("x", { contentItem: undefined, value: 2.5 })).ok, false)
        compare(RF.qtyFromField(undefined).ok, false)
        compare(RF.qtyFromField(null).ok, false)
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

    // ---- R5a (design 2026-11-10-r5a-restock-dialog-design.md): typed new supplier joins the operation, limits ----

    function test_supplierFor_structured_party() {
        compare(RF.supplierFor({ newName: "  Newco " }, suppliers).supplier.newName, "Newco")
        compare(RF.supplierFor({ newName: "acme farms" }, suppliers).supplier.id, "SUP-001")
        compare(RF.supplierFor({ newName: "SUP-Foo" }, suppliers).supplier.newName, "SUP-Foo", "a name, not an id")
        compare(RF.supplierFor("SUP-Foo", suppliers).supplier.id, "SUP-Foo", "the plain string form is unchanged")
        compare(RF.supplierFor({ newName: " " }, suppliers).reason, "bad-supplier")
        compare(RF.supplierFor({ id: " SUP-9 " }, suppliers).supplier.id, "SUP-9")
        compare(RF.supplierFor({ id: "" }, suppliers).reason, "bad-supplier")
        compare(RF.supplierFor({}, suppliers).reason, "bad-supplier")
        compare(RF.supplierFor({ newName: "x".repeat(100) }, suppliers).ok, true)
        compare(RF.supplierFor({ newName: "x".repeat(101) }, suppliers).reason, "supplier-too-long")
        compare(RF.supplierFor("y".repeat(101), suppliers).reason, "supplier-too-long")
    }

    function test_partyFor() {
        compare(RF.partyFor("  Newco ", 2, ["", "SUP-1", "SUP-2"]).newName, "Newco")
        compare(RF.partyFor("", 2, ["", "SUP-1", "SUP-2"]), "SUP-2")
        compare(RF.partyFor("   ", 1, ["", "SUP-1"]), "SUP-1")
        compare(RF.partyFor("", 0, ["X", "SUP-1"]), "")
        compare(RF.partyFor("", 99, ["", "SUP-1"]), "")
        compare(RF.partyFor("", -1, ["", "SUP-1"]), "")
        compare(RF.partyFor("", NaN, ["", "SUP-1"]), "")
        compare(RF.partyFor("", 1, undefined), "")
        compare(RF.partyFor("", 1, ["", 7]), "")
    }

    function test_newPartyChoice() {
        compare(RF.newPartyChoice("  ", suppliers).kind, "none")
        compare(RF.newPartyChoice("x".repeat(101), suppliers).kind, "invalid")
        compare(RF.newPartyChoice("x".repeat(101), suppliers).message, RF.refusalText("supplier-too-long"))
        var ex = RF.newPartyChoice(" ACME farms ", suppliers)
        compare(ex.kind, "existing"); compare(ex.id, "SUP-001"); compare(ex.name, "Acme Farms")
        var nw = RF.newPartyChoice(" Newco ", suppliers)
        compare(nw.kind, "new"); compare(nw.name, "Newco")
        compare(RF.newPartyChoice("SUP-Foo", []).kind, "new")
    }

    function test_limits() {
        compare(RF.MAX_REASON, 500); compare(RF.MAX_SUPPLIER_NAME, 100); compare(RF.MAX_UNIT_COST, 1000000000)
        compare(RF.makeInput(_args({ reason: "r".repeat(500) })).ok, true)
        compare(RF.makeInput(_args({ reason: "r".repeat(501) })).reason, "reason-too-long")
        compare(RF.makeInput(_args({ reason: "  " + "r".repeat(500) + "  " })).ok, true)
        compare(RF.makeInput(_args({ unitCost: 1e9 })).ok, true)
        compare(RF.makeInput(_args({ unitCost: 1e9 + 1 })).reason, "cost-too-large")
        compare(RF.makeInput(_args({ unitCost: Infinity })).ok, true, "left for the plan, which refuses it as bad-cost")
        compare(RF.makeInput(_args({ unitCost: NaN })).input.unitCost, 12.5)
    }

    function test_refusalText_new_reasons_are_distinct() {
        var reasons = ["bad-quantity", "bad-cost", "cost-too-large", "bad-supplier", "supplier-too-long", "reason-too-long", "too-large", "reserved-text"]
        var seen = {}
        for (var i = 0; i < reasons.length; ++i) {
            var t = RF.refusalText(reasons[i])
            verify(t.length > 0)
            verify(!seen[t], "duplicate text for " + reasons[i])
            seen[t] = true
        }
        verify(RF.refusalText("reason-too-long").indexOf("500") >= 0)
        verify(RF.refusalText("supplier-too-long").indexOf("100") >= 0)
    }

    // ---- PR #191 review sweep ----

    function test_costFromText_reads_only_a_plain_decimal() {
        var bad = ["0x10", "0b11", "0o7", "1e3", "1e-2", "5e", "1_000", "1 5", "+-1", ".", "+", "-", "1.2.3"]
        for (var i = 0; i < bad.length; ++i) compare(RF.costFromText(bad[i]), -1, JSON.stringify(bad[i]))
        compare(RF.costFromText("5."), 5)
        compare(RF.costFromText(".5"), 0.5)
        compare(RF.costFromText("+7"), 7)
        compare(RF.costFromText("0012"), 12)
        compare(RF.costFromText("9".repeat(400)), -1)
        verify(isNaN(RF.costFromText("  ")))
    }

    function test_known_supplier_matches_whatever_its_length() {
        var long = "L".repeat(150)
        var list = [{ supplierId: "SUP-9", name: long }]
        compare(RF.supplierFor(long, list).supplier.id, "SUP-9")
        compare(RF.supplierFor({ newName: long.toLowerCase() }, list).supplier.id, "SUP-9")
        compare(RF.supplierFor("M".repeat(150), list).reason, "supplier-too-long")
        compare(RF.newPartyChoice(long, list).kind, "existing")
    }

    function test_unusedPartyText() {
        compare(RF.unusedPartyText(""), "")
        compare(RF.unusedPartyText("   "), "")
        compare(RF.unusedPartyText(undefined), "")
        compare(RF.unusedPartyText(5), "")
        verify(RF.unusedPartyText("Newco").indexOf("Tap Use") >= 0)
    }
}
