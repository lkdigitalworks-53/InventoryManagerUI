import QtQuick
import QtTest
import "../qml/model"

// InventoryStore.applyRemoteStock — local-only hook added for the atomic
// order-completion operation (C-3, 2026-09-20 plan Task 9). It reflects a
// server-confirmed stock value into local state without sending anything
// (used after Gateway.recordOperation's result, or to reconcile a CAS
// conflict's `current`). See docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available. Written
// against the live qml/model/InventoryStore.qml (re-read fresh on current
// main, not the plan document's draft) and traced by hand against its
// _clone()/products-array conventions; needs a real qmltestrunner pass
// (CI) before merge.
TestCase {
    name: "InventoryStore_applyRemote"

    function init() {
        InventoryStore.products = []
        OutboxStore.clear()
    }

    function _product(id, stock) {
        return { productId: id, name: id, sku: "", category: "", unit: "pc",
                 price: 10, sellingPrice: 10, stock: stock, minStock: 0 }
    }

    function test_unknown_product_returns_undefined_and_leaves_products_untouched() {
        InventoryStore.products = [_product("P1", 5)]
        var result = InventoryStore.applyRemoteStock("GHOST", 99)
        compare(result, undefined)
        compare(InventoryStore.products.length, 1)
        compare(InventoryStore.products[0].stock, 5)
    }

    function test_happy_path_sets_the_new_stock_and_returns_the_previous_value() {
        InventoryStore.products = [_product("P1", 5)]
        var result = InventoryStore.applyRemoteStock("P1", 12)
        compare(result, 5)
        compare(InventoryStore.products[0].stock, 12)
    }

    function test_only_the_targeted_product_changes_among_several() {
        InventoryStore.products = [_product("P1", 5), _product("P2", 8), _product("P3", 1)]
        InventoryStore.applyRemoteStock("P2", 0)
        compare(InventoryStore.products[0].stock, 5)
        compare(InventoryStore.products[1].stock, 0)
        compare(InventoryStore.products[2].stock, 1)
    }

    function test_bumps_revision_on_a_real_change() {
        InventoryStore.products = [_product("P1", 5)]
        var before = InventoryStore.revision
        InventoryStore.applyRemoteStock("P1", 4)
        compare(InventoryStore.revision, before + 1)
    }

    function test_unknown_product_does_not_bump_revision() {
        InventoryStore.products = [_product("P1", 5)]
        var before = InventoryStore.revision
        InventoryStore.applyRemoteStock("GHOST", 4)
        compare(InventoryStore.revision, before)
    }

    function test_setting_to_zero_is_a_valid_terminal_value() {
        InventoryStore.products = [_product("P1", 3)]
        var result = InventoryStore.applyRemoteStock("P1", 0)
        compare(result, 3)
        compare(InventoryStore.products[0].stock, 0)
    }

    function test_calling_twice_in_a_row_each_returns_the_immediately_prior_value() {
        InventoryStore.products = [_product("P1", 10)]
        compare(InventoryStore.applyRemoteStock("P1", 7), 10)
        compare(InventoryStore.applyRemoteStock("P1", 7), 7, "idempotent re-apply of the same value")
        compare(InventoryStore.products[0].stock, 7)
    }

    function test_never_sends_anything_to_the_outbox() {
        InventoryStore.products = [_product("P1", 5)]
        InventoryStore.applyRemoteStock("P1", 2)
        InventoryStore.applyRemoteStock("GHOST", 2)
        compare(OutboxStore.items.length, 0)
    }

    function test_other_fields_on_the_product_are_preserved() {
        InventoryStore.products = [_product("P1", 5)]
        InventoryStore.applyRemoteStock("P1", 2)
        compare(InventoryStore.products[0].name, "P1")
        compare(InventoryStore.products[0].price, 10)
        compare(InventoryStore.products[0].minStock, 0)
    }
}
