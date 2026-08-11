import QtQuick
import QtTest
import "../qml/model"

// Regression test for a bug found by Taher's own manual testing
// (2026-08-10): add an order -> complete it -> open it, adjust the price,
// save -> spurious "This order was updated elsewhere — your change didn't
// save" toast, even though nothing else touched the order.
//
// Root cause: OrdersStore.applyAdjustment() took `before` as a SHALLOW copy
// of the order (`Object.assign({}, o)`), then called `o.adjustments.push(...)`
// to append the new adjustment record. Object.assign only copies top-level
// properties — before.adjustments and o.adjustments were the exact same
// array reference, so the in-place push() leaked the new adjustment into
// `before` too. That corrupted `before` is what Gateway.recordMutation sends
// as the CAS "before" to functions/lib/gatewayLogic.js's applyMutation,
// which rejects the whole write (409, nothing persisted — not just the
// adjustment, the WHOLE mutation including the new price) whenever
// _deepEqual(current, before) doesn't match the server's actual prior
// state. See docs/superpowers/specs/2026-08-10-before-snapshot-aliasing-CHECKPOINT.md
// for the full investigation (a full-codebase sweep confirmed this specific
// call site was the ONLY instance of the pattern in this project).
//
// Fix: build o.adjustments via `.concat()` (a new array) instead of
// `.push()` (in-place mutation of the shared array) — same
// replace-don't-mutate convention already used everywhere else in this
// codebase (StockBatchStore, OutboxStore, Gateway, NewOrderDialog).
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Written to convention (structure mirrors tst_OrdersStore_normalization.qml
// and tst_Gateway.qml) and manually reviewed; needs a local qmltestrunner
// pass before merge, same status as every other client-side test this
// session.
TestCase {
    name: "OrdersStore_applyAdjustment"

    function init() {
        OrdersStore.orders = []
        Gateway.mode = "gateway"   // so recordMutation enqueues into OutboxStore instead of writing direct
        OutboxStore.clear()
        AuthStore.idToken = ""    // keeps Gateway._send's guard closed — no real network (see tst_Gateway.qml header)
        InventoryStore.products = []
    }

    // A minimal pending order with no adjustments yet — the exact shape
    // OrdersStore.orders holds after _normalizeOrder runs on it.
    function _pendingOrderWithNoAdjustments() {
        return {
            orderId: "ORD-ADJ-1", customer: "Test Customer", status: "pending",
            date: "2026-08-10", email: "", phone: "", notes: "",
            orderChannel: "", staffId: "", adjustments: [],
            products: [{ productId: "SKU-1", name: "Widget", price: 100, quantity: 1 }]
        }
    }

    // Same, but already carries one adjustment — used to prove the fix
    // doesn't just handle the empty-array case, and that a second
    // adjustment doesn't drop or duplicate the first.
    function _pendingOrderWithOneAdjustment() {
        var o = _pendingOrderWithNoAdjustments()
        o.adjustments = [
            { date: "2026-08-01", reason: "first return", condition: "resellable",
              lineDeltas: [], refundAmount: 5, note: "", actorUid: "actor-1" }
        ]
        return o
    }

    function _secondAdjustmentRecord() {
        return { date: "2026-08-10", reason: "price correction", condition: "",
                  lineDeltas: [], refundAmount: 10, note: "test", actorUid: "actor-2" }
    }

    // ── the core regression: before must not see the new adjustment ────────

    function test_applyAdjustment_before_snapshot_excludes_the_new_adjustment() {
        OrdersStore.orders = [_pendingOrderWithNoAdjustments()]

        OrdersStore.applyAdjustment("ORD-ADJ-1",
            [{ productId: "SKU-1", name: "Widget", price: 90, quantity: 1 }],
            _secondAdjustmentRecord())

        compare(OutboxStore.pendingCount, 1)
        var item = OutboxStore.items[0]
        compare(item.before.adjustments.length, 0,
                "before must reflect the order's PRE-mutation state (no adjustments yet), " +
                "or the server's CAS check (_deepEqual(current, before) in gatewayLogic.js) " +
                "will spuriously reject the write")
    }

    function test_applyAdjustment_after_snapshot_includes_the_new_adjustment() {
        OrdersStore.orders = [_pendingOrderWithNoAdjustments()]

        OrdersStore.applyAdjustment("ORD-ADJ-1",
            [{ productId: "SKU-1", name: "Widget", price: 90, quantity: 1 }],
            _secondAdjustmentRecord())

        var item = OutboxStore.items[0]
        compare(item.after.adjustments.length, 1)
        compare(item.after.adjustments[0].reason, "price correction")
    }

    function test_applyAdjustment_before_and_after_adjustments_are_different_array_references() {
        OrdersStore.orders = [_pendingOrderWithNoAdjustments()]

        OrdersStore.applyAdjustment("ORD-ADJ-1",
            [{ productId: "SKU-1", name: "Widget", price: 90, quantity: 1 }],
            _secondAdjustmentRecord())

        var item = OutboxStore.items[0]
        verify(item.before.adjustments !== item.after.adjustments,
               "before.adjustments and after.adjustments must be independent arrays, " +
               "never the same reference — that aliasing is exactly what caused the bug")
    }

    // ── sequential adjustments: prior history must survive, not leak forward ─

    function test_applyAdjustment_second_adjustment_before_snapshot_shows_only_the_first() {
        OrdersStore.orders = [_pendingOrderWithOneAdjustment()]

        OrdersStore.applyAdjustment("ORD-ADJ-1",
            [{ productId: "SKU-1", name: "Widget", price: 80, quantity: 1 }],
            _secondAdjustmentRecord())

        var item = OutboxStore.items[0]
        compare(item.before.adjustments.length, 1,
                "before must show exactly the ONE pre-existing adjustment — not zero (dropped) " +
                "and not two (the new one leaked in)")
        compare(item.before.adjustments[0].reason, "first return")
    }

    function test_applyAdjustment_second_adjustment_after_snapshot_has_both_in_order() {
        OrdersStore.orders = [_pendingOrderWithOneAdjustment()]

        OrdersStore.applyAdjustment("ORD-ADJ-1",
            [{ productId: "SKU-1", name: "Widget", price: 80, quantity: 1 }],
            _secondAdjustmentRecord())

        var item = OutboxStore.items[0]
        compare(item.after.adjustments.length, 2)
        compare(item.after.adjustments[0].reason, "first return")
        compare(item.after.adjustments[1].reason, "price correction")
    }

    // ── functional sanity: the fix must not change observable behavior ─────

    function test_applyAdjustment_updates_local_order_lines_and_totals() {
        OrdersStore.orders = [_pendingOrderWithNoAdjustments()]

        OrdersStore.applyAdjustment("ORD-ADJ-1",
            [{ productId: "SKU-1", name: "Widget", price: 90, quantity: 1 }],
            _secondAdjustmentRecord())

        var updated = OrdersStore.getById("ORD-ADJ-1")
        verify(updated !== null)
        compare(updated.products[0].price, 90)
        compare(updated.total, 90)
        compare(updated.adjustments.length, 1)
    }

    function test_applyAdjustment_on_unknown_order_id_is_a_no_op() {
        OrdersStore.orders = [_pendingOrderWithNoAdjustments()]

        OrdersStore.applyAdjustment("ORD-DOES-NOT-EXIST",
            [{ productId: "SKU-1", name: "Widget", price: 90, quantity: 1 }],
            _secondAdjustmentRecord())

        compare(OutboxStore.pendingCount, 0, "no mutation should be recorded for an order that doesn't exist")
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].adjustments.length, 0)
    }
}
