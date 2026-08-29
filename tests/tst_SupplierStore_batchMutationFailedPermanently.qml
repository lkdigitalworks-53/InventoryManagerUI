import QtQuick
import QtTest
import "../qml/model"

// No unit test file existed for SupplierStore before this (only
// test/e2e/tst_SupplierStoreE2E.qml, which needs the Firebase emulator and
// isn't runnable here) — scoped deliberately narrow to just the bulk-import
// chunking fix (2026-08-29), not an attempt to backfill full SupplierStore
// coverage. See tst_InventoryStore_upsertMany.qml's identical section for
// the full root-cause writeup; addSupplierWithIdMany (called from inside
// InventoryStore.upsertMany for newly-discovered supplier names) shares the
// exact same optimistic-commit-then-fire-and-forget shape.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local
// `qmltestrunner` pass before merge (same status as every other file in
// this directory).
TestCase {
    name: "SupplierStore_batchMutationFailedPermanently"

    function init() { SupplierStore.suppliers = [] }
    function cleanup() { SupplierStore.suppliers = [] }

    function test_removes_only_the_failed_suppliers() {
        SupplierStore.suppliers = [
            { supplierId: "SUP-600", name: "Kept" },
            { supplierId: "SUP-601", name: "Failed" }
        ]

        SupplierStore._onBatchMutationFailedPermanently("supplier", [{ entityId: "SUP-601", action: "create" }], "missing-fields")

        compare(SupplierStore.suppliers.length, 1)
        compare(SupplierStore.suppliers[0].supplierId, "SUP-600")
    }

    function test_ignores_other_entities() {
        SupplierStore.suppliers = [{ supplierId: "SUP-610", name: "Kept" }]
        SupplierStore._onBatchMutationFailedPermanently("inventory", [{ entityId: "SUP-610", action: "create" }], "missing-fields")
        compare(SupplierStore.suppliers.length, 1, "a failure for a DIFFERENT entity must not touch suppliers")
    }

    function test_is_a_no_op_for_an_unknown_supplierId() {
        SupplierStore.suppliers = [{ supplierId: "SUP-620", name: "Kept" }]
        SupplierStore._onBatchMutationFailedPermanently("supplier", [{ entityId: "SUP-does-not-exist", action: "create" }], "missing-fields")
        compare(SupplierStore.suppliers.length, 1)
    }

    // End-to-end through the real signal — confirms Component.onCompleted's
    // Gateway.batchMutationFailedPermanently connection is actually live.
    function test_gateway_signal_reaches_SupplierStore_and_rolls_back() {
        SupplierStore.suppliers = [{ supplierId: "SUP-630", name: "Will Fail" }]
        Gateway.batchMutationFailedPermanently("supplier", [{ entityId: "SUP-630", action: "create" }], "batch-too-large")
        compare(SupplierStore.suppliers.length, 0, "the live signal connection must reach the store and roll back")
    }
}
