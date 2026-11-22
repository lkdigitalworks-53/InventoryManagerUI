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

    function test_nextEpoch_ignores_anything_that_is_not_a_non_negative_integer() {
        var bad = ["2", null, NaN, Infinity, -1, 1.5, true, [], {}]
        for (var i = 0; i < bad.length; ++i)
            compare(OK.nextEpoch({ completionEpoch: bad[i] }), 1, "epoch " + String(bad[i]))
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

    // ── add product (atomic-ops AP2) ───────────────────────────────────────

    function test_addProductKey_format_and_refusals() {
        compare(OK.addProductKey("a-b_c.1"), "addProduct:a-b_c.1")
        var bad = ["", "a/b", "a~b", "a b", "a:b", null, undefined, 5, {}, []]
        for (var i = 0; i < bad.length; ++i)
            compare(OK.addProductKey(bad[i]), "", "nonce " + String(bad[i]))
        compare(OK.addProductKey(new Array(101).join("x")), "addProduct:" + new Array(101).join("x"))
        compare(OK.addProductKey(new Array(102).join("x")), "")
    }

    function test_isAddProductKey_accepts_only_its_own_keys() {
        verify(OK.isAddProductKey(OK.addProductKey("n1")))
        var bad = ["addProduct:", "addProduct:a/b", "restock:n1", "completeOrder:o1:1", "addproduct:x", " addProduct:x", "", null, undefined, 7]
        for (var i = 0; i < bad.length; ++i)
            verify(!OK.isAddProductKey(bad[i]), String(bad[i]))
        verify(!OK.isRestockKey(OK.addProductKey("n1")))
        verify(!OK.isAddProductKey(OK.restockKey("n1")))
    }

    function test_addProductNonce_is_the_restock_nonce() {
        var zero = function() { return 0 }
        compare(OK.addProductNonce(1700000000123, zero), "1700000000123-000000000000")
        compare(OK.addProductNonce(1700000000123, zero), OK.restockNonce(1700000000123, zero))
    }

    function test_restockKey_is_unchanged_by_the_shared_nonce_rule() {
        compare(OK.restockKey("a-b_c.1"), "restock:a-b_c.1")
        compare(OK.restockKey("a/b"), "")
        compare(OK.restockKey(""), "")
    }

    function test_history_ids_carry_product_and_nonce() {
        compare(OK.createdTxId("PRD-007", "n1"), "tx-c-PRD-007-n1")
        compare(OK.createdTxId("{{prd}}", "n1"), "tx-c-{{prd}}-n1")
        compare(OK.productAddedActId("PRD-007", "n1"), "act-PRD-007-n1")
        verify(OK.createdTxId("PRD-007", "n1") !== OK.createdTxId("PRD-007", "n2"))
    }

    // ---- create order (atomic-ops NO2) ----
    function test_createOrderNonce_is_the_restock_nonce() {
        compare(OK.createOrderNonce(1781000000000, function() { return 0 }), OK.restockNonce(1781000000000, function() { return 0 }))
        verify(/^1781000000000-[0-9a-z]{12}$/.test(OK.createOrderNonce(1781000000000.9, Math.random)))
    }

    function test_createOrderKey_accepts_a_plain_token_only() {
        compare(OK.createOrderKey("1781000000000-abcdefabcdef"), "createOrder:1781000000000-abcdefabcdef")
        var bad = ["", "a/b", "a~b", "a b", new Array(102).join("x"), null, undefined, 5, {}]
        for (var i = 0; i < bad.length; ++i) compare(OK.createOrderKey(bad[i]), "", String(bad[i]))
    }

    function test_isCreateOrderKey_is_not_fooled_by_another_operations_key() {
        verify(OK.isCreateOrderKey("createOrder:1781000000000-abcdefabcdef"))
        var bad = ["", "createOrder:", "createOrder:a/b", "restock:1781000000000-abcdefabcdef", "addProduct:1781000000000-abcdefabcdef",
                   "completeOrder:ORD-001:1", "CreateOrder:1781000000000-abcdefabcdef", null, 5]
        for (var i = 0; i < bad.length; ++i) verify(!OK.isCreateOrderKey(bad[i]), String(bad[i]))
        verify(!OK.isRestockKey("createOrder:1781000000000-abcdefabcdef"))
        verify(!OK.isAddProductKey("createOrder:1781000000000-abcdefabcdef"))
    }
}
