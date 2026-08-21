import QtQuick
import QtTest
import "../qml/model"
import "../qml/helper/OrderAdjust.js" as OrderAdjust

// Functional/integration-level regression test for the returns/analysis-
// revenue bug (Taher, 2026-08-19/20). Exercises the REAL save-then-return
// flow through OrdersStore/TransactionStore/DataModel — one layer above
// tests/tst_ReconcileConsumptionOnSave.qml, which only tests the pure fix
// function in isolation. Full writeup: SKILLS.md Skill 42.
//
// What this proves that the pure-function test can't: that a metadata-only
// edit, persisted the way the FIXED OrderDetailDialog._save() actually
// persists it (OrdersStore.updateOrder's full products replace, fed a
// RECONCILED products array), really does leave consumption[] intact on
// the stored order, and that a SUBSEQUENT return (DataModel._tryAdjustOrder
// -> TransactionStore.recordReturn) then produces a return event
// RealisedMath can actually attribute revenue/profit to.
//
// This calls OrdersStore.updateOrder(orderId, fields) DIRECTLY rather than
// emitting the real `logic.updateOrder(...)` signal that OrderDetailDialog
// actually uses. Checked DataModel.onUpdateOrder's source first: for a
// non-status-transitioning update (this file's entire scope — every order
// here stays "completed" or stays "pending"), that handler's body is
// exactly `OrdersStore.updateOrder(orderId, fields); _updateOrderInModel
// (orderId); logic.orderUpdated(orderId)` — a UI ListModel sync and a
// notification signal, neither of which this file's assertions touch. So
// the direct call is a faithful, verified substitute for what's under
// test here. Also checked: no existing test file in this suite references
// `logic.xxx(...)` at all, and `qml/logic/` has no qmldir — whether `logic`
// resolves without an explicit import in a standalone TestCase is
// genuinely untested territory in this codebase, and not worth risking
// when the direct call is both faithful and already-proven (same
// direct-OrdersStore-call convention as tests/tst_OrdersStore_
// applyAdjustment.qml). `_tryAdjustOrder`, by contrast, IS called directly
// on a real `dm` instance, matching tests/tst_DataModel_
// adjustOrderSyncGuard.qml's established precedent for that function.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available. Needs
// a real qmltestrunner pass before merge, same status as every other
// client-side test this session.
TestCase {
    name: "OrderMetadataEditPreservesConsumption"

    DataModel { id: dm }

    function init() {
        OrdersStore.orders = []
        TransactionStore.entries = []
        TransactionStore.revision = 0
        TransactionStore.hasMore = false   // Skill 38 guard: _tryAdjustOrder refuses a completed-
                                            // order return while true (defaults to true) — every
                                            // test here seeds its ledger directly, never pages it.
        InventoryStore.products = []
        StockBatchStore.batches = []
        Gateway.mode = "gateway"   // enqueue into OutboxStore instead of a real network call
        OutboxStore.clear()
        AuthStore.idToken = ""    // keeps Gateway._send's guard closed — no real network
        dm.stockErrorMsg = ""
    }

    // A just-completed single-line order, exactly the shape
    // DataModel._tryCompleteOrder would have persisted: consumption stamped
    // from a single FIFO batch, quantity 1, no discount.
    function _completedOrderWithConsumption() {
        return {
            orderId: "ORD-META-1", customer: "Original Customer", status: "completed",
            date: "2026-08-20", email: "", phone: "", notes: "",
            orderChannel: "in-store", staffId: "STF-1", adjustments: [],
            products: [{ productId: "P1", name: "Widget", price: 100, quantity: 1,
                         taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0,
                         consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] }]
        }
    }

    // The exact record TransactionStore.recordSaleFromOrder would have
    // written at completion time — seeded directly (not re-derived here)
    // since this file is testing the EDIT + RETURN steps, not completion
    // itself (already covered by test/e2e/tst_OrdersE2E.qml).
    function _seedOriginalSaleEvent() {
        TransactionStore.entries = [{
            txId: "tx-s-1", kind: "sale", timestamp: "2026-08-20T10:00:00.000Z", date: "2026-08-20",
            productId: "P1", productName: "Widget", quantity: 1, unitPrice: 100,
            net: 100, tax: 0, discountShare: 0, total: 100,
            orderId: "ORD-META-1", orderChannel: "in-store", staffId: "STF-1",
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }]
        }]
        TransactionStore.revision = 1
    }

    // Mirrors OrderDetailDialog._save()'s line-rebuild EXACTLY as it exists
    // today (post-fix): editable UI state has no consumption field, so this
    // is what `prods` looks like before reconcileConsumptionOnSave runs.
    function _rebuiltLinesFromDialog(price, quantity) {
        return [{ productId: "P1", name: "Widget", price: price, quantity: quantity,
                   discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }]
    }

    // ── the core regression: metadata-only edit must not lose consumption ──

    function test_metadata_edit_preserves_consumption_the_fixed_way() {
        OrdersStore.orders = [_completedOrderWithConsumption()]
        var originalLines = OrdersStore.getById("ORD-META-1").products

        // Exactly what the FIXED OrderDetailDialog._save() sends: unchanged
        // lines, reconciled through the fix function, for a customer-name-
        // only edit.
        var rebuilt = _rebuiltLinesFromDialog(100, 1)
        var reconciled = OrderAdjust.reconcileConsumptionOnSave(rebuilt, originalLines)

        OrdersStore.updateOrder("ORD-META-1", {
            customer: "Renamed Customer", email: "", phone: "",
            status: "completed", items: 1,
            products: reconciled, orderChannel: "in-store", staffId: "STF-1"
        })

        var updated = OrdersStore.getById("ORD-META-1")
        verify(updated !== null)
        compare(updated.customer, "Renamed Customer", "the actual edit must have applied")
        compare(updated.products[0].consumption.length, 1,
                "consumption must survive a metadata-only edit through the fixed save path")
        compare(updated.products[0].consumption[0].batchId, "B1")
        compare(updated.products[0].consumption[0].qtyConsumed, 1)
    }

    function test_metadata_edit_then_return_produces_a_non_empty_consumption_return_event() {
        OrdersStore.orders = [_completedOrderWithConsumption()]
        _seedOriginalSaleEvent()
        var originalLines = OrdersStore.getById("ORD-META-1").products

        var reconciled = OrderAdjust.reconcileConsumptionOnSave(_rebuiltLinesFromDialog(100, 1), originalLines)
        OrdersStore.updateOrder("ORD-META-1", {
            customer: "Renamed Customer", email: "", phone: "",
            status: "completed", items: 1,
            products: reconciled, orderChannel: "in-store", staffId: "STF-1"
        })

        // Now return the item — full removal, matching the "-" stepper's
        // real UI behavior (OrderDetailDialog.qml confirmed: decrementing
        // to 0 removes the row rather than leaving quantity:0).
        var done = false
        dm._tryAdjustOrder("ORD-META-1", [], "return", "resellable", "", function(ok) { done = true })
        tryVerify(function() { return done }, 5000, "_tryAdjustOrder callback never fired")

        var returnEvent = null
        for (var i = 0; i < TransactionStore.entries.length; ++i) {
            if (TransactionStore.entries[i].kind === "return") { returnEvent = TransactionStore.entries[i]; break }
        }
        verify(returnEvent !== null, "a return event must have been recorded")
        verify(Array.isArray(returnEvent.consumption) && returnEvent.consumption.length > 0,
               "THE regression: the return event's consumption must be non-empty, or " +
               "RealisedMath.byDimension/totals silently attribute zero revenue/profit to it")
        compare(returnEvent.consumption[0].batchId, "B1")
        compare(returnEvent.consumption[0].qtyConsumed, -1, "reversed consumption must be negative")
    }

    function test_realised_totals_net_to_zero_after_metadata_edit_then_full_return() {
        OrdersStore.orders = [_completedOrderWithConsumption()]
        _seedOriginalSaleEvent()
        var originalLines = OrdersStore.getById("ORD-META-1").products

        var reconciled = OrderAdjust.reconcileConsumptionOnSave(_rebuiltLinesFromDialog(100, 1), originalLines)
        OrdersStore.updateOrder("ORD-META-1", {
            customer: "Renamed Customer", email: "", phone: "",
            status: "completed", items: 1,
            products: reconciled, orderChannel: "in-store", staffId: "STF-1"
        })

        var done = false
        dm._tryAdjustOrder("ORD-META-1", [], "return", "resellable", "", function(ok) { done = true })
        tryVerify(function() { return done }, 5000, "_tryAdjustOrder callback never fired")

        var totals = InventoryStore.realisedTotals(null)
        compare(totals.net, 0, "Revenue must net to 0 after a full return — this is the exact " +
                "symptom Taher reported: it silently stayed at 100")
        compare(totals.profit, 0, "Profit must net to 0 after a full return")
    }

    // ── negative / characterization: proves the bug would still exist ──
    // ── if a caller skips reconcileConsumptionOnSave ───────────────────

    function test_characterization_skipping_reconcile_reproduces_the_original_bug() {
        // This test is NOT asserting desired behavior — it documents the
        // ORIGINAL bug so a future refactor that bypasses
        // reconcileConsumptionOnSave (e.g. a new caller of
        // OrdersStore.updateOrder that rebuilds products another way) gets
        // caught here rather than shipping the same silent data loss again.
        OrdersStore.orders = [_completedOrderWithConsumption()]
        var rawRebuilt = _rebuiltLinesFromDialog(100, 1)   // NOT reconciled — the pre-fix behavior

        OrdersStore.updateOrder("ORD-META-1", {
            customer: "Renamed Customer", email: "", phone: "",
            status: "completed", items: 1,
            products: rawRebuilt, orderChannel: "in-store", staffId: "STF-1"
        })

        var updated = OrdersStore.getById("ORD-META-1")
        compare(updated.products[0].consumption.length, 0,
                "documents the original bug: without reconcileConsumptionOnSave, " +
                "OrdersStore.updateOrder's full products replace silently drops consumption " +
                "(OrdersStore._normalizeOrder coerces a missing consumption[] to an empty array, " +
                "never undefined — confirmed by reading _normalizeOrder directly, not assumed) — " +
                "this is EXPECTED/current behavior of the raw store call, which is exactly why " +
                "the fix has to live at the CALLER (OrderDetailDialog._save()), not here")
    }

    // ── edge case: multi-line order, only one line survives the edit ───

    function test_multi_line_order_each_line_consumption_independent_after_edit() {
        var order = _completedOrderWithConsumption()
        order.products.push({ productId: "P2", name: "Gadget", price: 50, quantity: 2,
                               taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0,
                               consumption: [{ batchId: "B2", supplierId: "S2", qtyConsumed: 2, unitCost: 20 }] })
        OrdersStore.orders = [order]
        var originalLines = OrdersStore.getById("ORD-META-1").products

        var rebuilt = [{ productId: "P1", name: "Widget", price: 100, quantity: 1,
                          discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 },
                        { productId: "P2", name: "Gadget", price: 50, quantity: 2,
                          discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }]
        var reconciled = OrderAdjust.reconcileConsumptionOnSave(rebuilt, originalLines)

        OrdersStore.updateOrder("ORD-META-1", {
            customer: "Renamed Customer", email: "", phone: "",
            status: "completed", items: 3,
            products: reconciled, orderChannel: "in-store", staffId: "STF-1"
        })

        var updated = OrdersStore.getById("ORD-META-1")
        compare(updated.products[0].consumption[0].batchId, "B1")
        compare(updated.products[1].consumption[0].batchId, "B2")
    }

    // ── edge case: a PENDING (never-completed) order's metadata edit ───
    // ── is a no-op for consumption — nothing to lose, must not throw ───

    function test_pending_order_metadata_edit_has_no_consumption_to_lose() {
        OrdersStore.orders = [{
            orderId: "ORD-META-PENDING", customer: "Original Customer", status: "pending",
            date: "2026-08-20", email: "", phone: "", notes: "",
            orderChannel: "", staffId: "", adjustments: [],
            products: [{ productId: "P1", name: "Widget", price: 100, quantity: 1,
                         taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }]
        }]
        var originalLines = OrdersStore.getById("ORD-META-PENDING").products
        var reconciled = OrderAdjust.reconcileConsumptionOnSave(
            [{ productId: "P1", name: "Widget", price: 100, quantity: 1,
               discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }],
            originalLines)

        OrdersStore.updateOrder("ORD-META-PENDING", {
            customer: "Renamed Customer", email: "", phone: "",
            status: "pending", items: 1,
            products: reconciled, orderChannel: "", staffId: ""
        })

        var updated = OrdersStore.getById("ORD-META-PENDING")
        verify(updated !== null)
        compare(updated.customer, "Renamed Customer")
        compare(updated.products[0].consumption.length, 0)
    }
}
