import QtQuick
import QtTest
import "../qml/helper/OrderFlow.js" as OF
import "../qml/helper/OperationKeys.js" as OK

// Headless tests for the pure create-order wiring helper (atomic-ops NO3a). Pure JS, no singletons.
// Design: docs/superpowers/specs/2026-11-23-no3a-create-order-wire-design.md
// The same rows run in Node in functions/test/orderFlow.test.js; this file is the qmltestrunner copy (QML-engine differences in
// string and number handling cannot hide). NOT RUN IN THIS SANDBOX: CI is the oracle.
TestCase {
    name: "OrderFlow"

    function test_newKey_is_a_valid_create_key_and_unique_per_random() {
        var a = OF.newKey(1781000000000, function() { return 0.25 })
        var b = OF.newKey(1781000000000, function() { return 0.75 })
        compare(OK.isCreateOrderKey(a), true)
        verify(a !== b)
        compare(OK.isRestockKey(a), false)
    }
    function test_localDay() {
        compare(OF.localDay(new Date(2026, 0, 5, 23, 59, 59)), "2026-01-05")
        compare(OF.localDay(new Date(NaN)), "")
        compare(OF.localDay("2026-06-15"), "")
        compare(OF.localDay(null), "")
        compare(OF.localDay(undefined), "")
    }
    function test_classify() {
        compare(OF.classify({ ok: true }), "applied")
        compare(OF.classify({ ok: true, queued: true }), "queued")
        compare(OF.classify({ ok: false, pending: true }), "queued")
        compare(OF.classify({ ok: false }), "rejected")
        compare(OF.classify(null), "rejected")
    }
    function test_refusalText_person_fixable_reasons() {
        compare(OF.refusalText("bad-customer"), "Enter a valid customer name")
        compare(OF.refusalText("too-large"), OF.TOO_LARGE_TEXT)
        compare(OF.refusalText("bad-line", -1, ["A"]), "Add at least one product")
        compare(OF.refusalText("bad-line", NaN, ["A"]), "Add at least one product")
        compare(OF.refusalText("bad-line", undefined, ["A"]), "Add at least one product")
        verify(OF.refusalText("bad-line", 0, ["Tomato"]).indexOf("Line 1 (Tomato): ") === 0)
        verify(OF.refusalText("bad-line", 2, ["A", "B"]).indexOf("Line 3: ") === 0)
        verify(OF.refusalText("bad-line", 0, [""]).indexOf("Line 1: ") === 0)
        verify(OF.refusalText("bad-line", 0, ["Tomato"]).indexOf("1000000000") > 0)
    }
    function test_refusalText_app_problems_ask_for_a_report() {
        var reasons = ["bad-key", "bad-order", "bad-status", "bad-time", "bad-totals", "weird", undefined]
        for (var i = 0; i < reasons.length; ++i) {
            var t = OF.refusalText(reasons[i])
            verify(t.indexOf("Could not place the order (") === 0, String(reasons[i]))
            verify(t.indexOf("Please report this") > 0)
        }
    }
    function test_doneText() {
        compare(OF.doneText("queued"), OF.QUEUED_TEXT)
        compare(OF.doneText("unconfirmed"), OF.UNCONFIRMED_TEXT)
        compare(OF.doneText("applied"), "")
        compare(OF.doneText(undefined), "")
    }
    // ── NO3b: the unit-price field (functions/test/orderFlow.test.js F-8..F-13 carry the same rows in Node) ──
    function test_priceEdit_set() {
        var rows = [["250", 250], ["0", 0], ["007", 7], ["19.99", 19.99], [".5", 0.5], ["5.", 5], ["  42  ", 42], ["1000000000", 1000000000]]
        for (var i = 0; i < rows.length; ++i) {
            var r = OF.priceEdit(rows[i][0], 1, "₹1")
            compare(r.kind, "set", rows[i][0])
            compare(r.price, rows[i][1], rows[i][0])
        }
    }
    function test_priceEdit_invalid_is_never_read_as_another_number() {
        var bad = ["-5", "+5", "1e5", "12abc", "1.2.3", "1,5", "abc", "Infinity", "0x10", "."]
        for (var i = 0; i < bad.length; ++i) {
            var r = OF.priceEdit(bad[i], 1, "₹1")
            compare(r.kind, "refused", bad[i])
            compare(r.reason, "invalid", bad[i])
        }
    }
    function test_priceEdit_blank_and_large() {
        var blank = ["", "   ", undefined, null, 5]
        for (var i = 0; i < blank.length; ++i) compare(OF.priceEdit(blank[i], 1, "₹1").reason, "blank")
        compare(OF.priceEdit("1000000000.01", 1, "₹1").reason, "large")
        compare(OF.priceEdit("99999999999999999999", 1, "₹1").reason, "large")
    }
    function test_priceEdit_unchanged_text_is_not_parsed() {
        compare(OF.priceEdit("120", 120, "₹120").kind, "unchanged")
        compare(OF.priceEdit("₹1,20,000", 120000, "₹1,20,000").kind, "unchanged")
        compare(OF.priceEdit("₹1,20,000", 5, "₹5").reason, "invalid")
        compare(OF.priceEdit("120.0", 120, "₹120").kind, "set")
    }
    function test_priceText() {
        compare(OF.priceText("blank"), "Enter the price of one unit, 0 or more")
        compare(OF.priceText("invalid"), "Price must be a plain number, like 120 or 99.5")
        compare(OF.priceText("large"), "Price is too large. Enter the price of ONE unit, up to 1000000000")
        compare(OF.priceText("weird"), "")
        compare(OF.priceText(undefined), "")
    }
    function test_priceBlockedText() {
        compare(OF.priceBlockedText("Tomato", "₹100"), "Tomato: the new price was not accepted, so it is still ₹100. Tap its price field to keep or change it")
        compare(OF.priceBlockedText("", "₹1").indexOf("An item: "), 0)
    }
    function test_withPriceError_sets_and_removes_without_touching_the_input() {
        var before = { A: "x" }
        var added = OF.withPriceError(before, "B", "y")
        compare(added.B, "y")
        compare(added.A, "x")
        compare(before.B, undefined)
        var removed = OF.withPriceError(added, "A", "")
        compare(removed.A, undefined)
        compare(removed.B, "y")
    }
    function test_prunePriceErrors_keeps_only_cart_ids() {
        var out = OF.prunePriceErrors({ A: "x", B: "y" }, [{ productId: "B" }, null])
        compare(Object.keys(out).length, 1)
        compare(out.B, "y")
        compare(Object.keys(OF.prunePriceErrors({ A: "x" }, undefined)).length, 0)
    }
}
