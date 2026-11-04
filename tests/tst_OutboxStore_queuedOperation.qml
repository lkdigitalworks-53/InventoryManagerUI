import QtQuick
import QtTest
import "../qml/model"

// OutboxStore.hasQueuedOperationFor (atomic-ops R4): the durable latch behind "a restock for this product
// is still syncing". Node twin: functions/test/restockWire.test.js (W-19, the REAL function body).
// NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "OutboxStore_queuedOperation"

    function init() { OutboxStore.clear() }
    function cleanup() { OutboxStore.clear() }

    function _op(key, type, productId) {
        OutboxStore.enqueueOperation({ requestId: key, opType: type, ops: [
            { kind: "mint", counter: "stock_batch", bind: "batch" },
            { kind: "delta", entity: "inventory", entityId: productId, deltas: { stock: 1 }, floors: {}, clamps: {} }] })
    }

    function test_empty_outbox() { compare(OutboxStore.hasQueuedOperationFor("restock", "inventory", "p1"), false) }
    function test_matches_type_entity_and_id() {
        _op("restock:1-a", "restock", "p1")
        compare(OutboxStore.hasQueuedOperationFor("restock", "inventory", "p1"), true)
        compare(OutboxStore.hasQueuedOperationFor("restock", "inventory", "p2"), false)
        compare(OutboxStore.hasQueuedOperationFor("restock", "stock_batch", "p1"), false)
        compare(OutboxStore.hasQueuedOperationFor("completeOrder", "inventory", "p1"), false)
    }
    function test_a_plain_edit_and_a_delta_do_not_count() {
        OutboxStore.enqueue({ requestId: "e", entity: "inventory", entityId: "p1", action: "update", before: { a: 1 }, after: { a: 2 } })
        OutboxStore.enqueueDelta({ requestId: "d", entity: "inventory", entityId: "p1", deltas: { stock: -1 }, floors: { stock: 0 } })
        compare(OutboxStore.hasQueuedOperationFor("restock", "inventory", "p1"), false)
    }
    function test_a_parked_restock_still_counts() {
        _op("restock:1-a", "restock", "p1")
        OutboxStore.setStuckMeta("restock:1-a", { failures: 5, stuck: true, terminal: true })
        compare(OutboxStore.hasQueuedOperationFor("restock", "inventory", "p1"), true)
    }
    function test_it_is_released_when_the_item_is_acked() {
        _op("restock:1-a", "restock", "p1")
        OutboxStore.markAcked("restock:1-a")
        compare(OutboxStore.hasQueuedOperationFor("restock", "inventory", "p1"), false)
    }
}
