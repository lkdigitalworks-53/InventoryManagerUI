import QtQuick
import QtTest
import "../qml/model"

// TransactionStore.buildSaleDocs / addLocalEntries / removeLocalEntries —
// added for the atomic order-completion operation (C-3, 2026-09-20 plan
// Task 9). buildSaleDocs is the pure half of recordSaleFromOrder (builds the
// sale docs a completion needs WITHOUT pushing them into `entries` or the
// Gateway — the CompletionPlan needs the doc list up front to include in the
// operation it sends). addLocalEntries/removeLocalEntries merge or undo a
// server-confirmed/reverted outcome locally, without sending anything.
//
// NOTE ON DETERMINISM: buildSaleDocs stamps `timestamp`/`date` with
// `new Date()` at call time (unchanged from the original recordSaleFromOrder
// — not something this task's plan asked to change), so two calls a
// millisecond apart can differ on that one field. The "same input yields the
// same output" test below asserts on every field EXCEPT timestamp for that
// reason, not because the two calls are only "mostly" deterministic.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available. Written
// against the live qml/model/TransactionStore.qml (re-read fresh on current
// main) and qml/helper/OrderMath.js's real allocate(); needs a real
// qmltestrunner pass (CI) before merge.
TestCase {
    name: "TransactionStore_buildSaleDocs"

    function init() {
        TransactionStore.entries = []
        InventoryStore.products = []
        Gateway.mode = "gateway"
        OutboxStore.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = "" // see tst_Gateway.qml header / CHECKPOINT.md 2026-08-18
    }

    function _line(overrides) {
        var base = { productId: "P1", name: "Widget", price: 100, quantity: 1,
                     taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0,
                     consumption: [] }
        return Object.assign(base, overrides || {})
    }

    function _order(products, overrides) {
        var base = { orderId: "ORD-001", date: "2026-09-26", orderChannel: "store", staffId: "S1",
                      products: products }
        return Object.assign(base, overrides || {})
    }

    // -- basic shape / math (regression against the pre-extraction function) ---

    function test_a_no_discount_no_tax_line_matches_recordSaleFromOrders_previous_math() {
        var order = _order([_line({ price: 100, quantity: 2 })])
        var docs = TransactionStore.buildSaleDocs(order, 1, false)
        compare(docs.length, 1)
        var d = docs[0]
        compare(d.kind, "sale")
        compare(d.productId, "P1")
        compare(d.productName, "Widget")
        compare(d.quantity, 2)
        compare(d.unitPrice, 100)
        compare(d.net, 200, "gross 200, no discount")
        compare(d.tax, 0)
        compare(d.discountShare, 0)
        compare(d.total, 200)
        compare(d.orderId, "ORD-001")
        compare(d.orderChannel, "store")
        compare(d.staffId, "S1")
        compare(JSON.stringify(d.consumption), "[]")
    }

    function test_taxable_line_carries_the_allocated_tax_into_the_doc() {
        var order = _order([_line({ price: 100, quantity: 1, taxable: true, taxPercent: 18 })])
        var docs = TransactionStore.buildSaleDocs(order, 1, false)
        compare(docs[0].net, 100)
        compare(docs[0].tax, 18)
    }

    function test_a_flat_discount_reduces_net_and_is_reported_on_the_doc() {
        var order = _order([_line({ price: 100, quantity: 1, discountType: "flat", discountValue: 20 })])
        var docs = TransactionStore.buildSaleDocs(order, 1, false)
        compare(docs[0].discountShare, 20)
        compare(docs[0].net, 80)
    }

    function test_consumption_is_carried_through_as_a_copy() {
        var cons = [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 5 }]
        var order = _order([_line({ consumption: cons })])
        var docs = TransactionStore.buildSaleDocs(order, 1, false)
        compare(JSON.stringify(docs[0].consumption), JSON.stringify(cons))
        docs[0].consumption.push({ batchId: "X" })
        compare(cons.length, 1, "the caller's own consumption array is not mutated")
    }

    // -- ids: deterministic (atomic path) vs legacy (existing callers) ---------

    function test_deterministic_ids_use_OperationKeys_saleTxId_per_line() {
        var order = _order([_line({ productId: "P1" }), _line({ productId: "P2" })])
        var docs = TransactionStore.buildSaleDocs(order, 3, false)
        compare(docs[0].txId, "tx-s-ORD-001-3-0")
        compare(docs[1].txId, "tx-s-ORD-001-3-1")
    }

    function test_legacy_ids_use_the_random_nextId_prefix_and_differ_per_line() {
        var order = _order([_line({ productId: "P1" }), _line({ productId: "P2" })])
        var docs = TransactionStore.buildSaleDocs(order, 0, true)
        verify(docs[0].txId.indexOf("tx-s-") === 0)
        verify(docs[1].txId.indexOf("tx-s-") === 0)
        verify(docs[0].txId !== docs[1].txId)
    }

    function test_a_different_epoch_yields_a_different_deterministic_txId() {
        var order = _order([_line({ productId: "P1" })])
        var a = TransactionStore.buildSaleDocs(order, 1, false)
        var b = TransactionStore.buildSaleDocs(order, 2, false)
        verify(a[0].txId !== b[0].txId)
    }

    // -- edge cases ---------------------------------------------------------

    function test_zero_quantity_lines_are_skipped() {
        var order = _order([_line({ productId: "P1", quantity: 0 }), _line({ productId: "P2", quantity: 1 })])
        var docs = TransactionStore.buildSaleDocs(order, 1, false)
        compare(docs.length, 1)
        compare(docs[0].productId, "P2")
    }

    function test_an_order_with_no_products_yields_no_docs() {
        var order = _order([])
        compare(TransactionStore.buildSaleDocs(order, 1, false).length, 0)
    }

    function test_null_or_productless_order_returns_an_empty_array_not_null() {
        compare(TransactionStore.buildSaleDocs(null, 1, false).length, 0)
        compare(TransactionStore.buildSaleDocs({ orderId: "X" }, 1, false).length, 0)
    }

    function test_the_same_input_yields_identical_docs_across_two_calls_aside_from_timestamp() {
        var order = _order([_line({ productId: "P1", quantity: 2, price: 50 })])
        var a = TransactionStore.buildSaleDocs(order, 1, false)[0]
        var b = TransactionStore.buildSaleDocs(order, 1, false)[0]
        var stripTs = function(d) { var c = Object.assign({}, d); delete c.timestamp; return c }
        compare(JSON.stringify(stripTs(a)), JSON.stringify(stripTs(b)))
        compare(a.txId, b.txId, "same order+epoch -> same deterministic key, by design")
    }

    // -- recordSaleFromOrder still works end to end (thin regression: full
    //    math coverage lives in the tests above, this only proves the entry
    //    point still pushes what buildSaleDocs builds) -----------------------

    function test_recordSaleFromOrder_pushes_one_entry_per_line_and_records_a_mutation() {
        var order = _order([_line({ productId: "P1", quantity: 1 }), _line({ productId: "P2", quantity: 2 })])
        var beforeOutbox = OutboxStore.items.length
        TransactionStore.recordSaleFromOrder(order)
        compare(TransactionStore.entries.length, 2)
        compare(OutboxStore.items.length, beforeOutbox + 2, "one recordMutation per sale doc")
        verify(TransactionStore.entries[0].txId.indexOf("tx-s-") === 0, "legacy random id, unchanged behaviour")
    }

    // -- addLocalEntries ------------------------------------------------------

    function test_addLocalEntries_adds_new_docs_and_returns_the_count() {
        var added = TransactionStore.addLocalEntries([
            { txId: "tx-s-ORD-001-1-0", kind: "sale" },
            { txId: "tx-s-ORD-001-1-1", kind: "sale" }
        ])
        compare(added, 2)
        compare(TransactionStore.entries.length, 2)
    }

    function test_addLocalEntries_skips_a_txId_already_present() {
        TransactionStore.entries = [{ txId: "tx-s-ORD-001-1-0", kind: "sale" }]
        var added = TransactionStore.addLocalEntries([{ txId: "tx-s-ORD-001-1-0", kind: "sale" }])
        compare(added, 0)
        compare(TransactionStore.entries.length, 1, "a replay must never duplicate a ledger row")
    }

    function test_addLocalEntries_dedupes_within_the_same_batch_too() {
        var added = TransactionStore.addLocalEntries([
            { txId: "tx-s-ORD-001-1-0", kind: "sale" },
            { txId: "tx-s-ORD-001-1-0", kind: "sale" }
        ])
        compare(added, 1)
        compare(TransactionStore.entries.length, 1)
    }

    function test_addLocalEntries_bumps_revision_only_when_something_was_added() {
        TransactionStore.entries = [{ txId: "existing", kind: "sale" }]
        var before = TransactionStore.revision
        compare(TransactionStore.addLocalEntries([{ txId: "existing", kind: "sale" }]), 0)
        compare(TransactionStore.revision, before, "nothing added -> no revision bump")
        TransactionStore.addLocalEntries([{ txId: "new-one", kind: "sale" }])
        compare(TransactionStore.revision, before + 1)
    }

    function test_addLocalEntries_never_calls_the_gateway() {
        var before = OutboxStore.items.length
        TransactionStore.addLocalEntries([{ txId: "tx-s-ORD-001-1-0", kind: "sale" }])
        compare(OutboxStore.items.length, before)
    }

    // -- removeLocalEntries -----------------------------------------------------

    function test_removeLocalEntries_removes_matching_entries() {
        TransactionStore.entries = [
            { txId: "a", kind: "sale" }, { txId: "b", kind: "sale" }, { txId: "c", kind: "sale" }
        ]
        TransactionStore.removeLocalEntries(["a", "c"])
        compare(TransactionStore.entries.length, 1)
        compare(TransactionStore.entries[0].txId, "b")
    }

    function test_removeLocalEntries_is_a_no_op_for_ids_not_present() {
        TransactionStore.entries = [{ txId: "a", kind: "sale" }]
        var before = TransactionStore.revision
        TransactionStore.removeLocalEntries(["ghost"])
        compare(TransactionStore.entries.length, 1)
        compare(TransactionStore.revision, before, "nothing removed -> no revision bump")
    }

    function test_add_then_remove_round_trips_back_to_empty() {
        TransactionStore.addLocalEntries([{ txId: "tx-s-ORD-001-1-0", kind: "sale" }])
        TransactionStore.removeLocalEntries(["tx-s-ORD-001-1-0"])
        compare(TransactionStore.entries.length, 0)
    }
}
