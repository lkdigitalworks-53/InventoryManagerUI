import QtQuick
import QtTest
import "../qml/helper/StockReconcile.js" as Reconcile

// Bug 2: a manual product.stock edit must reconcile into the FIFO batch ledger
// so batch-derived Analysis reports (Value, Potential Profit, by-supplier) stay
// correct. The pure decision — given old vs new stock, what batch op to run —
// is unit-tested here; the side-effecting apply lives in DataModel.
TestCase {
    name: "StockReconcile"

    function test_decrease_consumes_difference() {
        var d = Reconcile.delta(10, 7)
        compare(d.action, "consume")
        compare(d.qty, 3)
    }

    function test_increase_tops_up_difference() {
        var d = Reconcile.delta(10, 12)
        compare(d.action, "topup")
        compare(d.qty, 2)
    }

    function test_no_change_is_noop() {
        var d = Reconcile.delta(5, 5)
        compare(d.action, "none")
        compare(d.qty, 0)
    }

    function test_decrease_to_zero() {
        var d = Reconcile.delta(4, 0)
        compare(d.action, "consume")
        compare(d.qty, 4)
    }

    function test_increase_from_zero() {
        var d = Reconcile.delta(0, 6)
        compare(d.action, "topup")
        compare(d.qty, 6)
    }

    // Defensive: non-numeric / undefined inputs must not produce a bogus op
    // (e.g. a field edit that didn't touch stock passes undefined).
    function test_undefined_inputs_noop() {
        compare(Reconcile.delta(undefined, undefined).action, "none")
        compare(Reconcile.delta(5, undefined).action, "none")
        compare(Reconcile.delta(undefined, 5).action, "none")
    }

    function test_string_inputs_coerced() {
        // EditProductDialog parses with parseInt, but guard anyway.
        var d = Reconcile.delta("10", "8")
        compare(d.action, "consume")
        compare(d.qty, 2)
    }
}
