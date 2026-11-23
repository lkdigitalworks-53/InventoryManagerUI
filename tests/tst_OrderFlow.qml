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
}
