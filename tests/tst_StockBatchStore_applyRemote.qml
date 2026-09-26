import QtQuick
import QtTest
import "../qml/model"

// StockBatchStore.applyRemoteQty / addLocalBatch / removeLocalBatch —
// local-only hooks added for the atomic order-completion operation (C-3,
// 2026-09-20 plan Task 9). None of these send anything: they reflect a
// server-confirmed outcome (recordOperation result, or a CAS conflict's
// `current`) into local state, or undo an optimistic local change after a
// rejection. See docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available. Written
// against the live qml/model/StockBatchStore.qml (re-read fresh on current
// main) and traced by hand against its existing consumeFifo/restoreFifo
// slice-and-replace conventions; needs a real qmltestrunner pass (CI)
// before merge.
TestCase {
    name: "StockBatchStore_applyRemote"

    function init() {
        StockBatchStore.batches = []
        OutboxStore.clear()
    }

    function _batch(id, productId, qtyRemaining) {
        return { batchId: id, productId: productId, supplierId: "S1",
                 qtyReceived: qtyRemaining, qtyRemaining: qtyRemaining, unitCost: 5,
                 receivedDate: "2026-09-01T00:00:00.000Z", poId: "", note: "" }
    }

    // -- applyRemoteQty -----------------------------------------------------

    function test_applyRemoteQty_unknown_batch_returns_undefined_and_changes_nothing() {
        StockBatchStore.batches = [_batch("B1", "P1", 10)]
        var result = StockBatchStore.applyRemoteQty("GHOST", 3)
        compare(result, undefined)
        compare(StockBatchStore.batches[0].qtyRemaining, 10)
    }

    function test_applyRemoteQty_happy_path_sets_the_new_qty_and_returns_the_previous_value() {
        StockBatchStore.batches = [_batch("B1", "P1", 10)]
        var result = StockBatchStore.applyRemoteQty("B1", 7)
        compare(result, 10)
        compare(StockBatchStore.batches[0].qtyRemaining, 7)
    }

    function test_applyRemoteQty_only_the_targeted_batch_changes() {
        StockBatchStore.batches = [_batch("B1", "P1", 10), _batch("B2", "P1", 4)]
        StockBatchStore.applyRemoteQty("B2", 0)
        compare(StockBatchStore.batches[0].qtyRemaining, 10)
        compare(StockBatchStore.batches[1].qtyRemaining, 0)
    }

    function test_applyRemoteQty_bumps_revision_on_a_real_change() {
        StockBatchStore.batches = [_batch("B1", "P1", 10)]
        var before = StockBatchStore.revision
        StockBatchStore.applyRemoteQty("B1", 9)
        compare(StockBatchStore.revision, before + 1)
    }

    function test_applyRemoteQty_preserves_the_batchs_other_fields() {
        StockBatchStore.batches = [_batch("B1", "P1", 10)]
        StockBatchStore.applyRemoteQty("B1", 9)
        compare(StockBatchStore.batches[0].supplierId, "S1")
        compare(StockBatchStore.batches[0].unitCost, 5)
        compare(StockBatchStore.batches[0].qtyReceived, 10, "only qtyRemaining is touched")
    }

    // -- addLocalBatch --------------------------------------------------------

    function test_addLocalBatch_appends_a_new_batch_and_returns_true() {
        StockBatchStore.batches = [_batch("B1", "P1", 10)]
        var doc = _batch("BAT-RPR-o1-1-0", "P1", 0)
        var added = StockBatchStore.addLocalBatch(doc)
        compare(added, true)
        compare(StockBatchStore.batches.length, 2)
        compare(StockBatchStore.batches[1].batchId, "BAT-RPR-o1-1-0")
    }

    function test_addLocalBatch_is_a_no_op_when_the_id_already_exists() {
        StockBatchStore.batches = [_batch("B1", "P1", 10)]
        var added = StockBatchStore.addLocalBatch(_batch("B1", "P1", 999))
        compare(added, false)
        compare(StockBatchStore.batches.length, 1)
        compare(StockBatchStore.batches[0].qtyRemaining, 10, "the existing batch is untouched, not overwritten")
    }

    function test_addLocalBatch_twice_with_the_same_doc_is_idempotent() {
        var doc = _batch("BAT-RPR-o1-1-0", "P1", 0)
        compare(StockBatchStore.addLocalBatch(doc), true)
        compare(StockBatchStore.addLocalBatch(doc), false)
        compare(StockBatchStore.batches.length, 1, "a replay must never duplicate a repair batch")
    }

    // -- removeLocalBatch -------------------------------------------------------

    function test_removeLocalBatch_removes_an_existing_batch_and_returns_true() {
        StockBatchStore.batches = [_batch("B1", "P1", 10), _batch("B2", "P1", 4)]
        var removed = StockBatchStore.removeLocalBatch("B1")
        compare(removed, true)
        compare(StockBatchStore.batches.length, 1)
        compare(StockBatchStore.batches[0].batchId, "B2")
    }

    function test_removeLocalBatch_unknown_id_returns_false_and_changes_nothing() {
        StockBatchStore.batches = [_batch("B1", "P1", 10)]
        var removed = StockBatchStore.removeLocalBatch("GHOST")
        compare(removed, false)
        compare(StockBatchStore.batches.length, 1)
    }

    function test_add_then_remove_round_trips_back_to_the_original_list() {
        StockBatchStore.batches = [_batch("B1", "P1", 10)]
        StockBatchStore.addLocalBatch(_batch("BAT-RPR-o1-1-0", "P1", 0))
        StockBatchStore.removeLocalBatch("BAT-RPR-o1-1-0")
        compare(StockBatchStore.batches.length, 1)
        compare(StockBatchStore.batches[0].batchId, "B1")
    }

    function test_none_of_these_hooks_send_anything_to_the_outbox() {
        StockBatchStore.batches = [_batch("B1", "P1", 10)]
        StockBatchStore.applyRemoteQty("B1", 3)
        StockBatchStore.addLocalBatch(_batch("B2", "P1", 5))
        StockBatchStore.removeLocalBatch("B2")
        compare(OutboxStore.items.length, 0)
    }
}
