import QtQuick
import QtTest
import "../qml/helper/OperationKeys.js" as OK

// Headless tests for the deterministic ids behind the atomic order-completion
// operation. Pure JS, no singletons.
TestCase {
    name: "OperationKeys"

    function test_nextEpoch_first_completion_is_epoch_1() {
        compare(OK.nextEpoch(null), 1)
        compare(OK.nextEpoch(undefined), 1)
        compare(OK.nextEpoch({}), 1)
        compare(OK.nextEpoch({ completionEpoch: 0 }), 1)
    }

    function test_nextEpoch_increments_a_stored_epoch() {
        compare(OK.nextEpoch({ completionEpoch: 1 }), 2)
        compare(OK.nextEpoch({ completionEpoch: 7 }), 8)
    }

    function test_nextEpoch_ignores_a_non_numeric_epoch() {
        compare(OK.nextEpoch({ completionEpoch: "2" }), 1)
        compare(OK.nextEpoch({ completionEpoch: null }), 1)
    }

    function test_completeOrderKey_format_and_determinism() {
        compare(OK.completeOrderKey("ORD-1", 1), "completeOrder:ORD-1:1")
        compare(OK.completeOrderKey("ORD-1", 1), OK.completeOrderKey("ORD-1", 1))
    }

    function test_completeOrderKey_differs_per_order_and_per_epoch() {
        verify(OK.completeOrderKey("ORD-1", 1) !== OK.completeOrderKey("ORD-2", 1))
        verify(OK.completeOrderKey("ORD-1", 1) !== OK.completeOrderKey("ORD-1", 2))
    }

    function test_saleTxId_keeps_its_prefix_and_is_unique_per_line() {
        compare(OK.saleTxId("ORD-1", 2, 0), "tx-s-ORD-1-2-0")
        verify(OK.saleTxId("ORD-1", 2, 0) !== OK.saleTxId("ORD-1", 2, 1))
        verify(OK.saleTxId("ORD-1", 2, 0) !== OK.saleTxId("ORD-1", 3, 0))
    }

    function test_repairBatchId_is_deterministic_and_unique_per_line() {
        compare(OK.repairBatchId("ORD-1", 1, 3), "BAT-RPR-ORD-1-1-3")
        verify(OK.repairBatchId("ORD-1", 1, 3) !== OK.repairBatchId("ORD-1", 1, 4))
    }
}
