import QtQuick
import QtTest
import "../qml/model"

// Coverage for the synchronous/pure pieces of the 2026-08-27 async
// batch-id-minting change (docs/superpowers/specs/
// 2026-08-27-async-stock-batch-id-minting-design.md) -- everything
// reachable without a live Firestore/Cloud Functions emulator.
//
// nextBatchId()/addBatch()'s actual mint round-trip (FirebaseService.
// mintCounterValue) has no mock layer anywhere in this codebase -- same
// established gap as every other async id-minter (nextSupplierId,
// nextStaffId, nextOrderId; see tst_OrdersStore_mutations.qml's
// test_addOrder_dispatches_without_throwing). Real round-trip and
// collision behavior is covered by test/e2e/tst_StockBatchStoreE2E.qml
// against the emulator instead. This file covers: the pure id-format
// helpers, addBatch/addBatchWithId/topUpOldest's synchronous guard
// clauses, and a dispatches-without-throwing smoke test for the async
// paths' synchronous setup.
//
// NOT RUN IN THIS SANDBOX -- no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local
// `qmltestrunner` pass before merge (same status as tst_FirebaseService.qml,
// tst_Gateway.qml).
TestCase {
    name: "StockBatchStore"

    function init() {
        StockBatchStore.batches = []
        StockBatchStore.revision = 0
    }

    // ── _batchIdPrefixForYear ────────────────────────────────────────────

    function test_batchIdPrefixForYear_formats_as_BAT_dash_year_dash() {
        compare(StockBatchStore._batchIdPrefixForYear(2026), "BAT-2026-")
    }

    // ── _seedBatchMaxForPrefix ───────────────────────────────────────────

    function test_seedBatchMaxForPrefix_returns_zero_for_empty_batches() {
        compare(StockBatchStore._seedBatchMaxForPrefix("BAT-2026-"), 0)
    }

    function test_seedBatchMaxForPrefix_finds_the_highest_matching_number() {
        StockBatchStore.batches = [
            { batchId: "BAT-2026-003" },
            { batchId: "BAT-2026-001" },
            { batchId: "BAT-2026-007" }
        ]
        compare(StockBatchStore._seedBatchMaxForPrefix("BAT-2026-"), 7)
    }

    function test_seedBatchMaxForPrefix_ignores_ids_from_other_years() {
        StockBatchStore.batches = [
            { batchId: "BAT-2025-099" },
            { batchId: "BAT-2026-002" }
        ]
        compare(StockBatchStore._seedBatchMaxForPrefix("BAT-2026-"), 2)
    }

    function test_seedBatchMaxForPrefix_ignores_malformed_ids() {
        StockBatchStore.batches = [
            { batchId: "BAT-2026-NOTANUMBER" },
            { batchId: "" },
            { batchId: "BAT-2026-005" }
        ]
        compare(StockBatchStore._seedBatchMaxForPrefix("BAT-2026-"), 5)
    }

    // ── _buildBatchDoc ───────────────────────────────────────────────────

    function test_buildBatchDoc_fills_in_the_full_shape() {
        var doc = StockBatchStore._buildBatchDoc("BAT-2026-001", "prod-1", "sup-1", 10, 5, "A note")
        compare(doc.batchId, "BAT-2026-001")
        compare(doc.productId, "prod-1")
        compare(doc.supplierId, "sup-1")
        compare(doc.qtyReceived, 10)
        compare(doc.qtyRemaining, 10)
        compare(doc.unitCost, 5)
        compare(doc.note, "A note")
        compare(doc.poId, "")
    }

    function test_buildBatchDoc_defaults_missing_supplierId_and_note() {
        var doc = StockBatchStore._buildBatchDoc("BAT-2026-001", "prod-1", "", 10, 5, "")
        compare(doc.supplierId, "")
        compare(doc.note, "")
    }

    function test_buildBatchDoc_parses_a_string_unitCost() {
        var doc = StockBatchStore._buildBatchDoc("BAT-2026-001", "prod-1", "sup-1", 10, "12.5", "")
        compare(doc.unitCost, 12.5)
    }

    function test_buildBatchDoc_defaults_an_unparseable_unitCost_to_zero() {
        var doc = StockBatchStore._buildBatchDoc("BAT-2026-001", "prod-1", "sup-1", 10, "not-a-number", "")
        compare(doc.unitCost, 0)
    }

    // ── addBatchWithId ───────────────────────────────────────────────────

    function test_addBatchWithId_returns_null_for_missing_id() {
        var doc = StockBatchStore.addBatchWithId("", "prod-1", "sup-1", 10, 5, "note", true)
        compare(doc, null)
        compare(StockBatchStore.batches.length, 0)
    }

    function test_addBatchWithId_returns_null_for_zero_quantity() {
        var doc = StockBatchStore.addBatchWithId("BAT-2026-001", "prod-1", "sup-1", 0, 5, "note", true)
        compare(doc, null)
        compare(StockBatchStore.batches.length, 0)
    }

    function test_addBatchWithId_returns_null_for_missing_productId() {
        var doc = StockBatchStore.addBatchWithId("BAT-2026-001", "", "sup-1", 10, 5, "note", true)
        compare(doc, null)
        compare(StockBatchStore.batches.length, 0)
    }

    function test_addBatchWithId_appends_to_batches_with_the_given_id() {
        var doc = StockBatchStore.addBatchWithId("BAT-2026-042", "prod-1", "sup-1", 10, 5, "note", true)
        verify(doc !== null, "addBatchWithId returned null for valid input")
        compare(doc.batchId, "BAT-2026-042")
        compare(StockBatchStore.batches.length, 1)
        compare(StockBatchStore.getById("BAT-2026-042").qtyReceived, 10)
    }

    // ── addBatch (synchronous guard clauses only -- see file header) ─────

    function test_addBatch_calls_back_with_null_for_zero_quantity() {
        var received = "not called"
        StockBatchStore.addBatch("prod-1", "sup-1", 0, 5, "note", false, function(doc) { received = doc })
        compare(received, null)
        compare(StockBatchStore.batches.length, 0)
    }

    function test_addBatch_calls_back_with_null_for_missing_productId() {
        var received = "not called"
        StockBatchStore.addBatch("", "sup-1", 10, 5, "note", false, function(doc) { received = doc })
        compare(received, null)
        compare(StockBatchStore.batches.length, 0)
    }

    function test_addBatch_guard_clause_does_not_throw_without_a_callback() {
        StockBatchStore.addBatch("", "sup-1", 10, 5, "note")
        verify(true)
    }

    function test_addBatch_valid_input_dispatches_without_throwing() {
        // Real outcome (the minted batchId, the local batches[] update)
        // needs the emulator -- see test/e2e/tst_StockBatchStoreE2E.qml's
        // test_addBatch_creates_real_emulator_doc. This only confirms the
        // synchronous portion before nextBatchId's network call doesn't
        // throw, matching this codebase's established convention for
        // network-backed id minters.
        StockBatchStore.addBatch("prod-1", "sup-1", 10, 5, "note", false, function(doc) {})
        verify(true)
    }

    // ── topUpOldest (synchronous guard clauses only) ─────────────────────

    function test_topUpOldest_calls_back_immediately_for_zero_deficit() {
        var called = false
        StockBatchStore.topUpOldest("prod-1", 0, function() { called = true })
        compare(called, true)
    }

    function test_topUpOldest_calls_back_immediately_for_missing_productId() {
        var called = false
        StockBatchStore.topUpOldest("", 5, function() { called = true })
        compare(called, true)
    }

    function test_topUpOldest_is_a_no_op_without_a_callback_for_zero_deficit() {
        StockBatchStore.topUpOldest("prod-1", 0)
        verify(true)
    }
}
