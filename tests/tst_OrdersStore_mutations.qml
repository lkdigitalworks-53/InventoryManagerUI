import QtQuick
import QtTest
import "../qml/model"

// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Expected values checked by direct trace against qml/model/OrdersStore.qml
// (line numbers cited per function in the plan doc). Needs a real
// qmltestrunner pass before merge.
TestCase {
    name: "OrdersStore_mutations"

    function init() {
        OrdersStore.orders = []
        InventoryStore.products = []
        Gateway.mode = "gateway"
        OutboxStore.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = "" // see tst_Gateway.qml header / CHECKPOINT.md 2026-08-18
    }

    function test_clear_empties_orders_and_resets_counts() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending" },
            { orderId: "ORD-002", status: "completed" }
        ]
        OrdersStore._refreshCounts()
        verify(OrdersStore.pendingOrderCount > 0)

        OrdersStore.clear()

        compare(OrdersStore.orders.length, 0)
        compare(OrdersStore.pendingOrderCount, 0)
        compare(OrdersStore.completedOrderCount, 0)
        compare(OrdersStore.outOfStockCount, 0)
    }

    function test_clear_increments_revision() {
        var before = OrdersStore.revision
        OrdersStore.clear()
        compare(OrdersStore.revision, before + 1)
    }

    function test_refreshCounts_counts_pending_completed_and_out_of_stock() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending" },
            { orderId: "ORD-002", status: "pending" },
            { orderId: "ORD-003", status: "completed" },
            { orderId: "ORD-004", status: "out of stock" }
        ]
        OrdersStore._refreshCounts()
        compare(OrdersStore.pendingOrderCount, 2)
        compare(OrdersStore.completedOrderCount, 1)
        compare(OrdersStore.outOfStockCount, 1)
    }

    function test_refreshCounts_does_not_count_processing_status() {
        // "processing" is a real order status but _refreshCounts only
        // tracks pending/completed/"out of stock" -- processingCount() is
        // a separate, on-demand loop (Slice 2), not backed by this.
        OrdersStore.orders = [{ orderId: "ORD-001", status: "processing" }]
        OrdersStore._refreshCounts()
        compare(OrdersStore.pendingOrderCount, 0)
        compare(OrdersStore.completedOrderCount, 0)
        compare(OrdersStore.outOfStockCount, 0)
    }

    function test_refreshCounts_all_zero_when_orders_is_empty() {
        OrdersStore._refreshCounts()
        compare(OrdersStore.pendingOrderCount, 0)
        compare(OrdersStore.completedOrderCount, 0)
        compare(OrdersStore.outOfStockCount, 0)
    }

    function test_commit_replaces_orders_and_increments_revision() {
        var before = OrdersStore.revision
        var newArr = [{ orderId: "ORD-001", status: "pending" }]
        OrdersStore._commit(newArr, null, "update", null)
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].orderId, "ORD-001")
        compare(OrdersStore.revision, before + 1)
    }

    function test_commit_refreshes_counts() {
        OrdersStore._commit([{ orderId: "ORD-001", status: "completed" }], null, "update", null)
        compare(OrdersStore.completedOrderCount, 1)
    }

    function test_commit_records_a_mutation_when_changedOrder_is_given() {
        var before = OutboxStore.dueItems().length
        OrdersStore._commit(
            [{ orderId: "ORD-001", status: "pending" }],
            { orderId: "ORD-001", status: "pending" },
            "update", null
        )
        compare(OutboxStore.dueItems().length, before + 1)
    }

    function test_commit_does_not_record_a_mutation_when_changedOrder_is_null() {
        var before = OutboxStore.dueItems().length
        OrdersStore._commit([{ orderId: "ORD-001", status: "pending" }], null, "update", null)
        compare(OutboxStore.dueItems().length, before)
    }

    function test_mergeOrder_incoming_values_override_existing() {
        var existing = { orderId: "ORD-001", customer: "Old Name", status: "pending", products: [] }
        var incoming = { orderId: "ORD-001", customer: "New Name", status: "completed", products: [] }
        var merged = OrdersStore._mergeOrder(existing, incoming)
        compare(merged.customer, "New Name")
        compare(merged.status, "completed")
    }

    function test_mergeOrder_falls_back_to_existing_when_incoming_field_is_undefined() {
        var existing = { orderId: "ORD-001", customer: "Existing Name", status: "pending", products: [] }
        var incoming = { orderId: "ORD-001", status: "completed", products: [] } // customer omitted
        var merged = OrdersStore._mergeOrder(existing, incoming)
        compare(merged.customer, "Existing Name")
    }

    function test_mergeOrder_falls_back_to_existing_when_incoming_field_is_empty_string() {
        var existing = { orderId: "ORD-001", customer: "Existing Name", status: "pending", products: [] }
        var incoming = { orderId: "ORD-001", customer: "", status: "completed", products: [] }
        var merged = OrdersStore._mergeOrder(existing, incoming)
        compare(merged.customer, "Existing Name")
    }

    function test_mergeOrder_falls_back_to_existing_when_incoming_array_field_is_empty() {
        var existingProducts = [{ productId: "P1", name: "Widget", quantity: 1, price: 10 }]
        var existing = { orderId: "ORD-001", customer: "X", status: "pending", products: existingProducts }
        var incoming = { orderId: "ORD-001", customer: "X", status: "pending", products: [] }
        var merged = OrdersStore._mergeOrder(existing, incoming)
        compare(merged.products.length, 1)
        compare(merged.products[0].productId, "P1")
    }

    function test_nextOrderId_dispatches_without_throwing() {
        OrdersStore.nextOrderId(function(id) {})
        verify(true)
    }

    function test_upsertMany_empty_records_array_returns_zeroed_counts_synchronously() {
        var received = null
        OrdersStore.upsertMany([], function(counts) { received = counts })
        // No FirebaseService call happens on this path (:179-185) -- the
        // callback fires synchronously, so `received` is already set here,
        // not just eventually.
        verify(received !== null, "callback must fire synchronously for an empty records array")
        compare(received.added, 0)
        compare(received.updated, 0)
        compare(received.skipped, 0)
        compare(received.addedIds.length, 0)
    }

    function test_upsertMany_null_records_returns_zeroed_counts_synchronously() {
        var received = null
        OrdersStore.upsertMany(null, function(counts) { received = counts })
        verify(received !== null, "callback must fire synchronously for null records")
        compare(received.added, 0)
    }

    function test_upsertMany_with_records_dispatches_without_throwing() {
        // Non-empty input reaches FirebaseService.mintCounterBatch -- real
        // outcome needs the emulator (E2E slice), this only confirms the
        // synchronous portion before that call doesn't throw.
        OrdersStore.upsertMany(
            [{ orderId: "", customer: "New Customer", products: [], _conflictPolicy: "skip" }],
            function(counts) {}
        )
        verify(true)
    }

    // --- Bulk-import chunking fix (2026-08-29) ----------------------------
    // See tst_InventoryStore_upsertMany.qml's identical section for the
    // full root-cause writeup; OrdersStore.upsertMany shares the exact same
    // shape (optimistic commit + fire-and-forget Gateway.recordMutations).

    function test_onBatchMutationFailedPermanently_removes_only_the_failed_orders() {
        OrdersStore.orders = [
            { orderId: "ORD-500", customer: "Kept", products: [], status: "pending" },
            { orderId: "ORD-501", customer: "Failed", products: [], status: "pending" }
        ]
        var revisionBefore = OrdersStore.revision

        OrdersStore._onBatchMutationFailedPermanently("order", [{ entityId: "ORD-501", action: "create" }], "missing-fields")

        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].orderId, "ORD-500")
        verify(OrdersStore.revision > revisionBefore, "revision must bump so UI bound to it re-renders after a rollback")
    }

    function test_onBatchMutationFailedPermanently_ignores_other_entities() {
        OrdersStore.orders = [{ orderId: "ORD-510", customer: "Kept", products: [], status: "pending" }]
        OrdersStore._onBatchMutationFailedPermanently("inventory", [{ entityId: "ORD-510", action: "create" }], "missing-fields")
        compare(OrdersStore.orders.length, 1, "a failure for a DIFFERENT entity must not touch orders")
    }

    function test_onBatchMutationFailedPermanently_is_a_no_op_for_an_unknown_orderId() {
        OrdersStore.orders = [{ orderId: "ORD-515", customer: "Kept", products: [], status: "pending" }]
        OrdersStore._onBatchMutationFailedPermanently("order", [{ entityId: "ORD-does-not-exist", action: "create" }], "missing-fields")
        compare(OrdersStore.orders.length, 1, "nothing to remove, must not throw or touch unrelated rows")
    }

    function test_onBatchMutationFailedPermanently_is_a_no_op_for_empty_items() {
        // Distinct branch from "ignores other entities" above: entity DOES
        // match "order" here, so this exercises the `!items ||
        // items.length === 0` half of the guard.
        OrdersStore.orders = [{ orderId: "ORD-516", customer: "Kept", products: [], status: "pending" }]
        OrdersStore._onBatchMutationFailedPermanently("order", [], "missing-fields")
        compare(OrdersStore.orders.length, 1)
        OrdersStore._onBatchMutationFailedPermanently("order", null, "missing-fields")
        compare(OrdersStore.orders.length, 1)
    }

    function test_gateway_signal_reaches_OrdersStore_and_rolls_back() {
        OrdersStore.orders = [{ orderId: "ORD-520", customer: "Will Fail", products: [], status: "pending" }]
        Gateway.batchMutationFailedPermanently("order", [{ entityId: "ORD-520", action: "create" }], "batch-too-large")
        compare(OrdersStore.orders.length, 0, "the live signal connection must reach the store and roll back")
    }

    function test_updateOrder_updates_the_specified_fields() {
        OrdersStore.orders = [{
            orderId: "ORD-001", customer: "Old Name", email: "old@x.com", phone: "111",
            status: "pending", date: "2026-01-01", notes: "", products: [],
            orderChannel: "", staffId: "", subtotal: 0, discount: 0, tax: 0,
            taxBreakdown: [], total: 0, items: 0, adjustments: []
        }]
        OrdersStore.updateOrder("ORD-001", { status: "completed", notes: "Handled" })
        var updated = OrdersStore.getById("ORD-001")
        compare(updated.status, "completed")
        compare(updated.notes, "Handled")
    }

    function test_updateOrder_leaves_unspecified_fields_unchanged() {
        OrdersStore.orders = [{
            orderId: "ORD-001", customer: "Keep This Name", email: "keep@x.com", phone: "111",
            status: "pending", date: "2026-01-01", notes: "", products: [],
            orderChannel: "", staffId: "", subtotal: 0, discount: 0, tax: 0,
            taxBreakdown: [], total: 0, items: 0, adjustments: []
        }]
        OrdersStore.updateOrder("ORD-001", { status: "completed" }) // customer/email not mentioned
        var updated = OrdersStore.getById("ORD-001")
        compare(updated.customer, "Keep This Name")
        compare(updated.email, "keep@x.com")
    }

    function test_updateOrder_recomputes_totals_when_products_change() {
        OrdersStore.orders = [{
            orderId: "ORD-001", customer: "X", email: "", phone: "",
            status: "pending", date: "2026-01-01", notes: "", products: [],
            orderChannel: "", staffId: "", subtotal: 0, discount: 0, tax: 0,
            taxBreakdown: [], total: 0, items: 0, adjustments: []
        }]
        // Reuses the verified computeOrderTotals case from Slice 1:
        // gross 200, no discount/tax -> subtotal=total=200, itemCount=2.
        OrdersStore.updateOrder("ORD-001", {
            products: [{ productId: "", name: "Widget", price: 100, quantity: 2,
                         taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }]
        })
        var updated = OrdersStore.getById("ORD-001")
        compare(updated.subtotal, 200)
        compare(updated.total, 200)
        compare(updated.items, 2)
    }

    function test_updateOrder_uses_fields_total_directly_when_products_not_given() {
        // subtotal/discount/tax are ALWAYS recomputed from `products` by
        // _normalizeOrder inside _clone() -- unconditionally, on every
        // updateOrder call, regardless of what `fields` contains (see
        // qml/model/OrdersStore.qml:394, no prods.length>0 fallback there,
        // unlike items/total which do have one at :393,:398). An empty
        // products array with a hand-set subtotal would get overwritten to
        // 0 the moment _clone() runs, before fields.total is ever applied
        // -- seeding a REAL product line that computes to subtotal=50 is
        // what actually makes "subtotal stays 50, only total is overridden"
        // a meaningful, correct assertion.
        OrdersStore.orders = [{
            orderId: "ORD-001", customer: "X", email: "", phone: "",
            status: "pending", date: "2026-01-01", notes: "",
            products: [{ productId: "", name: "Widget", price: 50, quantity: 1,
                         taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }],
            orderChannel: "", staffId: "", subtotal: 50, discount: 0, tax: 0,
            taxBreakdown: [], total: 50, items: 1, adjustments: []
        }]
        OrdersStore.updateOrder("ORD-001", { total: "\u20B975.00" }) // string, goes through parseCurrency
        var updated = OrdersStore.getById("ORD-001")
        compare(updated.total, 75)
        compare(updated.subtotal, 50) // untouched -- only products-driven updates recompute subtotal
    }

    function test_updateOrder_is_a_no_op_for_an_unknown_orderId() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        var before = OrdersStore.revision
        OrdersStore.updateOrder("ORD-999", { status: "completed" })
        compare(OrdersStore.revision, before) // findIndexById returns -1, function returns before _commit
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].status, "pending")
    }

    function test_updateOrder_records_a_mutation() {
        OrdersStore.orders = [{
            orderId: "ORD-001", customer: "X", email: "", phone: "",
            status: "pending", date: "2026-01-01", notes: "", products: [],
            orderChannel: "", staffId: "", subtotal: 0, discount: 0, tax: 0,
            taxBreakdown: [], total: 0, items: 0, adjustments: []
        }]
        var before = OutboxStore.dueItems().length
        OrdersStore.updateOrder("ORD-001", { status: "completed" })
        compare(OutboxStore.dueItems().length, before + 1)
    }

    function test_deleteOrder_removes_the_matching_order() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending" },
            { orderId: "ORD-002", status: "pending" }
        ]
        OrdersStore.deleteOrder("ORD-001")
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].orderId, "ORD-002")
    }

    function test_deleteOrder_records_a_mutation() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        var before = OutboxStore.dueItems().length
        OrdersStore.deleteOrder("ORD-001")
        compare(OutboxStore.dueItems().length, before + 1)
    }

    function test_deleteOrder_is_a_no_op_for_an_unknown_orderId_but_still_increments_revision() {
        // Real, traced behavior: orders/revision/_refreshCounts run
        // unconditionally, BEFORE the found-check. Documenting what the
        // code actually does, not routing around it.
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        var beforeRevision = OrdersStore.revision
        OrdersStore.deleteOrder("ORD-999")
        compare(OrdersStore.orders.length, 1) // nothing actually removed
        compare(OrdersStore.revision, beforeRevision + 1) // but revision still bumped
    }

    function test_deleteOrder_does_not_record_a_mutation_for_an_unknown_orderId() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        var before = OutboxStore.dueItems().length
        OrdersStore.deleteOrder("ORD-999")
        compare(OutboxStore.dueItems().length, before) // the one guard that DOES check `found`
    }

    function test_normalizeOrder_fills_in_missing_optional_fields_with_defaults() {
        var result = OrdersStore._normalizeOrder({ orderId: "ORD-001" })
        compare(result.customer, "")
        compare(result.email, "")
        compare(result.phone, "")
        compare(result.notes, "")
        compare(result.orderChannel, "")
        compare(result.staffId, "")
        compare(result.status, "pending")
        compare(result.adjustments.length, 0)
        compare(result.products.length, 0)
    }

    function test_normalizeOrder_computes_items_and_totals_from_products_when_present() {
        var result = OrdersStore._normalizeOrder({
            orderId: "ORD-001",
            products: [{ productId: "", name: "Widget", price: 100, quantity: 2,
                         taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }]
        })
        // Same verified case as Slice 1: gross 200, no discount/tax.
        compare(result.subtotal, 200)
        compare(result.total, 200)
        compare(result.items, 2)
    }

    function test_normalizeOrder_falls_back_to_r_items_and_r_total_when_no_products() {
        var result = OrdersStore._normalizeOrder({ orderId: "ORD-001", items: 5, total: "\u20B9250.00" })
        compare(result.items, 5)
        compare(result.total, 250) // parseCurrency("₹250.00")
    }

    function test_normalizeOrder_resolves_tax_from_inventory_when_line_does_not_specify_it() {
        InventoryStore.products = [
            { productId: "P1", name: "Taxed Widget", taxable: true, taxPercent: 18 }
        ]
        var result = OrdersStore._normalizeOrder({
            orderId: "ORD-001",
            products: [{ productId: "P1", name: "Taxed Widget", price: 100, quantity: 1 }] // no taxable/taxPercent on the line itself
        })
        compare(result.products[0].taxable, true)
        compare(result.products[0].taxPercent, 18)
    }

    function test_normalizeOrder_line_level_taxable_and_taxPercent_override_inventory() {
        InventoryStore.products = [
            { productId: "P1", name: "Taxed Widget", taxable: true, taxPercent: 18 }
        ]
        var result = OrdersStore._normalizeOrder({
            orderId: "ORD-001",
            products: [{ productId: "P1", name: "Taxed Widget", price: 100, quantity: 1,
                         taxable: false, taxPercent: 0 }] // line explicitly overrides
        })
        compare(result.products[0].taxable, false)
        compare(result.products[0].taxPercent, 0)
    }

    function test_normalizeOrder_deep_copies_consumption_so_mutating_the_result_does_not_affect_the_source() {
        var sourceConsumption = [{ batchId: "B1", supplierId: "S1", qtyConsumed: 5, unitCost: 10 }]
        var result = OrdersStore._normalizeOrder({
            orderId: "ORD-001",
            products: [{ productId: "P1", name: "Widget", price: 10, quantity: 1, consumption: sourceConsumption }]
        })
        result.products[0].consumption[0].qtyConsumed = 999
        compare(sourceConsumption[0].qtyConsumed, 5) // source untouched -- proves it's a real copy, not a shared reference
    }

    function test_normalizeOrder_adjustments_defaults_to_empty_array_when_missing_or_not_an_array() {
        var result1 = OrdersStore._normalizeOrder({ orderId: "ORD-001" }) // adjustments omitted
        compare(result1.adjustments.length, 0)
        var result2 = OrdersStore._normalizeOrder({ orderId: "ORD-001", adjustments: "not an array" })
        compare(result2.adjustments.length, 0)
    }

    function test_normalizeOrders_normalizes_every_order_in_the_array() {
        var arr = [
            { order_id: "ORD-001" }, // backend field name, no local orderId yet
            { orderId: "ORD-002", customer: "Already Has Customer" }
        ]
        var result = OrdersStore._normalizeOrders(arr)
        compare(result.length, 2)
        compare(result[0].orderId, "ORD-001") // order_id -> orderId
        compare(result[0].customer, "") // defaulted
        compare(result[1].customer, "Already Has Customer") // left alone
    }

    function test_addOrder_dispatches_without_throwing() {
        // addOrder is fully async (nextOrderId -> FirebaseService.mintCounterValue
        // is its first step) -- real outcome needs the emulator (E2E slice),
        // this only confirms the synchronous portion before that call doesn't throw.
        OrdersStore.addOrder(
            "New Customer", 0, 0, "pending", new Date(), "", "", [], "", "",
            function(ok, id) {}
        )
        verify(true)
    }
}
