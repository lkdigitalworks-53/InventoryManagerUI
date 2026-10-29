import QtQuick
import QtTest
import "../qml/model"

// P1 S2d-1: the three InventoryStore stock-delta paths now describe themselves to the ledger:
// restock -> `receipt`, deductStock(kind) -> e.g. `sale`, creditStockNoBatch(kind) -> `sales_return`.
// They only QUEUE the delta here (AuthStore.idToken empty keeps the network shut), so every assertion
// reads the outbox item the call produced. Clamp mode must NEVER carry explicit movements: the server
// cannot match a row to a clamped quantity and would reject the deduction outright.
// NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "InventoryStore_movementKinds"

    function init() {
        OutboxStore.clear()
        Gateway.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = ""
        AuthStore.isAuthenticated = false
        AuthService.isOnline = true
        ActivityLog.clear()
        InventoryStore._pendingDeletes = ({})
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        StockBatchStore.batches = []
        StockBatchStore._pendingMints = []
        AuthStore.role = "owner"
    }
    function cleanup() { OutboxStore.clear(); StockBatchStore._pendingMints = [] }

    function _product(id) {
        return { productId: id, name: "Widget " + id, category: "Widgets", sku: "", unit: "pc",
                 price: 100, sellingPrice: 100, stock: 5, minStock: 0 }
    }
    function _inv(id) {
        return OutboxStore.items.filter(function(i) { return i.entity === "inventory" && i.entityId === id && i.deltas })
    }

    // ── restock -> receipt ───────────────────────────────────────────────
    function test_restock_queues_a_receipt_movement_with_the_reason() {
        InventoryStore.restock("SKU-1", 3, "", 10, "  box 7  ", function() {})
        var items = _inv("SKU-1")
        compare(items.length, 1)
        compare(items[0].deltas.stock, 3)
        compare(items[0].movements.length, 1)
        compare(items[0].movements[0].kind, "receipt")
        compare(items[0].movements[0].qty, 3)
        compare(items[0].movements[0].reason, "box 7")
        compare(items[0].movements[0].valueAtCost, undefined)
    }
    function test_restock_default_quantity_is_ten_and_still_a_receipt() {
        InventoryStore.restock("SKU-1", 0, "", 10, "", function() {})
        var it = _inv("SKU-1")[0]
        compare(it.deltas.stock, 10)
        compare(it.movements[0].qty, 10)
    }
    function test_restock_a_fractional_quantity_is_a_valid_receipt() {
        InventoryStore.restock("SKU-1", 2.5, "", 10, "", function() {})
        compare(_inv("SKU-1")[0].movements[0].qty, 2.5)
    }
    function test_restock_with_a_very_long_reason_still_queues_a_valid_row() {
        InventoryStore.restock("SKU-1", 3, "", 10, new Array(901).join("x"), function() {})
        var it = _inv("SKU-1")[0]
        compare(it.movements[0].reason.length, 500)
    }
    function test_two_restocks_coalesce_into_one_item_with_two_receipts() {
        InventoryStore.restock("SKU-1", 3, "", 10, "a", function() {})
        InventoryStore.restock("SKU-1", 4, "", 10, "b", function() {})
        var items = _inv("SKU-1")
        compare(items.length, 1)
        compare(items[0].deltas.stock, 7)
        compare(items[0].movements.length, 2)
        compare(items[0].movements[0].reason, "a")
        compare(items[0].movements[1].reason, "b")
    }
    function test_a_negative_restock_is_refused_before_any_side_effect() {
        var out = { ok: null, calls: 0 }
        InventoryStore.restock("SKU-1", -3, "", 10, "", function(ok) { out.calls++; out.ok = ok })
        compare(out.calls, 1)
        compare(out.ok, false)
        compare(OutboxStore.pendingCount, 0, "no delta and no batch write")
        compare(StockBatchStore.batches.length, 0)
        compare(StockBatchStore._pendingMints.length, 0, "no batch mint was started")
    }
    function test_a_non_finite_restock_is_refused() {
        var out = { calls: 0, ok: null }
        InventoryStore.restock("SKU-1", Infinity, "", 10, "", function(ok) { out.calls++; out.ok = ok })
        compare(out.ok, false)
        compare(OutboxStore.pendingCount, 0)
    }
    function test_a_refused_restock_without_a_callback_is_silent() {
        InventoryStore.restock("SKU-1", -1, "", 10, "")
        compare(OutboxStore.pendingCount, 0)
    }
    function test_restock_of_an_unknown_product_still_answers_false() {
        var out = { ok: null }
        InventoryStore.restock("nope", 3, "", 10, "", function(ok) { out.ok = ok })
        compare(out.ok, false)
        compare(OutboxStore.pendingCount, 0)
    }

    // ── deductStock(kind) ────────────────────────────────────────────────
    function test_deductStock_with_a_kind_in_reject_mode_queues_a_negative_sale_with_a_floor() {
        InventoryStore.deductStock("SKU-1", 2, function() {}, false, "sale", "Exchange - order O1")
        var it = _inv("SKU-1")[0]
        compare(it.deltas.stock, -2)
        compare(it.floors.stock, 0)
        compare(it.movements.length, 1)
        compare(it.movements[0].kind, "sale")
        compare(it.movements[0].qty, -2)
        compare(it.movements[0].reason, "Exchange - order O1")
    }
    function test_deductStock_without_a_kind_stays_derived() {
        InventoryStore.deductStock("SKU-1", 2, function() {}, false)
        compare(_inv("SKU-1")[0].movements, undefined)
    }
    function test_deductStock_in_clamp_mode_ignores_a_kind() {
        InventoryStore.deductStock("SKU-1", 2, function() {}, true, "sale", "x")
        var it = _inv("SKU-1")[0]
        compare(it.clamps.stock, 0)
        compare(it.movements, undefined, "an explicit row next to a clamp would be rejected by the server")
    }
    function test_deductStock_with_a_zero_or_non_finite_qty_never_builds_movements() {
        InventoryStore.deductStock("SKU-1", 0, function() {}, false, "sale", "x")
        compare(_inv("SKU-1")[0].movements, undefined)
        OutboxStore.clear()
        InventoryStore.deductStock("SKU-1", Infinity, function() {}, false, "sale", "x")
        compare(_inv("SKU-1").length === 0 || _inv("SKU-1")[0].movements === undefined, true)
    }
    function test_deductStock_of_an_unknown_product_answers_not_found() {
        var out = { r: null }
        InventoryStore.deductStock("nope", 1, function(r) { out.r = r }, false, "sale", "x")
        compare(out.r.error, "not-found")
        compare(OutboxStore.pendingCount, 0)
    }
    function test_a_restock_then_a_floored_sale_deduction_queue_as_two_items() {
        // One merged item keeps ONE floor map: the sale's `stock >= 0` floor would be dropped
        // (stock could go negative) or the restock rejected together with the sale.
        InventoryStore.restock("SKU-1", 10, "", 10, "", function() {})
        InventoryStore.deductStock("SKU-1", 3, function() {}, false, "sale", "o")
        var items = _inv("SKU-1")
        compare(items.length, 2)
        compare(items[0].deltas.stock, 10)
        compare(items[0].floors.stock, undefined)
        compare(items[0].movements.length, 1)
        compare(items[0].movements[0].kind, "receipt")
        compare(items[1].deltas.stock, -3)
        compare(items[1].floors.stock, 0)
        compare(items[1].movements.length, 1)
        compare(items[1].movements[0].kind, "sale")
    }
    function test_two_restocks_around_a_failed_send_never_share_an_item() {
        InventoryStore.restock("SKU-1", 3, "", 10, "a", function() {})
        OutboxStore.markFailed(_inv("SKU-1")[0].requestId)   // sent once, reply may have been lost
        InventoryStore.restock("SKU-1", 4, "", 10, "b", function() {})
        var items = _inv("SKU-1")
        compare(items.length, 2)
        compare(items[0].deltas.stock, 3)
        compare(items[0].movements.length, 1)
        compare(items[1].deltas.stock, 4)
        compare(items[1].movements[0].reason, "b")
    }
    function test_a_clamped_deduction_queues_next_to_an_explicit_restock_not_into_it() {
        InventoryStore.restock("SKU-1", 10, "", 10, "", function() {})
        InventoryStore.deductStock("SKU-1", 3, function() {}, true)
        var items = _inv("SKU-1")
        compare(items.length, 2)
        compare(items[0].movements.length, 1)
        compare(items[1].movements, undefined)
    }

    // ── creditStockNoBatch(kind) ─────────────────────────────────────────
    function test_credit_with_a_kind_queues_a_sales_return() {
        InventoryStore.creditStockNoBatch("SKU-1", 2, "sales_return", "Return - order O1")
        var it = _inv("SKU-1")[0]
        compare(it.deltas.stock, 2)
        compare(it.movements[0].kind, "sales_return")
        compare(it.movements[0].qty, 2)
        compare(it.movements[0].reason, "Return - order O1")
    }
    function test_credit_without_a_kind_stays_derived() {
        InventoryStore.creditStockNoBatch("SKU-1", 2)
        compare(_inv("SKU-1")[0].movements, undefined)
    }
    function test_credit_ignores_a_zero_negative_or_missing_qty() {
        InventoryStore.creditStockNoBatch("SKU-1", 0, "sales_return", "x")
        InventoryStore.creditStockNoBatch("SKU-1", -1, "sales_return", "x")
        InventoryStore.creditStockNoBatch("SKU-1", undefined, "sales_return", "x")
        compare(OutboxStore.pendingCount, 0)
    }
    function test_credit_of_an_unknown_product_queues_nothing() {
        InventoryStore.creditStockNoBatch("nope", 2, "sales_return", "x")
        compare(OutboxStore.pendingCount, 0)
    }
    function test_credit_with_a_kind_and_a_non_finite_qty_stays_derived() {
        InventoryStore.creditStockNoBatch("SKU-1", Infinity, "sales_return", "x")
        var items = _inv("SKU-1")
        compare(items.length === 0 || items[0].movements === undefined, true)
    }
    function test_a_sale_and_its_rollback_return_queue_as_two_rows_that_net_to_zero() {
        InventoryStore.deductStock("SKU-1", 2, function() {}, false, "sale", "Exchange - order O1")
        InventoryStore.creditStockNoBatch("SKU-1", 2, "sales_return", "Rollback - order edit failed - order O1")
        var items = _inv("SKU-1")
        compare(items.length, 2, "floored sale and unfloored credit do not share an item")
        compare(items[0].movements.length, 1)
        compare(items[1].movements.length, 1)
        compare(items[0].deltas.stock + items[1].deltas.stock, 0)
        compare(items[0].movements[0].qty + items[1].movements[0].qty, 0)
        compare(items[0].movements[0].kind, "sale")
        compare(items[1].movements[0].kind, "sales_return")
    }

    // ── the label may degrade, the stock change may not ──────────────────
    function test_movementsFor_builds_one_valid_row() {
        var m = InventoryStore._movementsFor("sales_return", 2, "  r  ")
        compare(m.length, 1)
        compare(m[0].kind, "sales_return")
        compare(m[0].qty, 2)
        compare(m[0].reason, "r")
    }
    function test_movementsFor_without_a_kind_is_undefined() {
        compare(InventoryStore._movementsFor(undefined, 2, "x"), undefined)
        compare(InventoryStore._movementsFor("", 2, "x"), undefined)
        compare(InventoryStore._movementsFor(null, 2, "x"), undefined)
    }
    function test_movementsFor_drops_an_unknown_kind_a_wrong_direction_and_a_bad_qty() {
        compare(InventoryStore._movementsFor("bogus", 2, "x"), undefined)
        compare(InventoryStore._movementsFor("toString", 2, "x"), undefined)
        compare(InventoryStore._movementsFor("sale", 2, "x"), undefined, "a sale cannot add stock")
        compare(InventoryStore._movementsFor("sales_return", -2, "x"), undefined, "a return cannot remove stock")
        compare(InventoryStore._movementsFor("receipt", 0, "x"), undefined)
        compare(InventoryStore._movementsFor("receipt", NaN, "x"), undefined)
        compare(InventoryStore._movementsFor("receipt", Infinity, "x"), undefined)
    }
    function test_movementsFor_accepts_an_adjustment_in_either_direction() {
        compare(InventoryStore._movementsFor("adjustment", 3, "x").length, 1)
        compare(InventoryStore._movementsFor("adjustment", -3, "x").length, 1)
    }
    function test_a_credit_with_an_unknown_kind_still_queues_the_stock_change_as_a_derived_row() {
        InventoryStore.creditStockNoBatch("SKU-1", 2, "bogus", "x")
        var items = _inv("SKU-1")
        compare(items.length, 1, "the return must not be lost because its label is wrong")
        compare(items[0].deltas.stock, 2)
        compare(items[0].movements, undefined)
    }
    function test_a_credit_with_a_decreasing_kind_still_queues_the_stock_change() {
        InventoryStore.creditStockNoBatch("SKU-1", 2, "sale", "x")
        var items = _inv("SKU-1")
        compare(items.length, 1)
        compare(items[0].deltas.stock, 2)
        compare(items[0].movements, undefined)
    }
    function test_a_deduction_with_an_unknown_kind_still_queues_with_its_floor() {
        InventoryStore.deductStock("SKU-1", 2, function() {}, false, "bogus", "x")
        var items = _inv("SKU-1")
        compare(items.length, 1)
        compare(items[0].deltas.stock, -2)
        compare(items[0].floors.stock, 0, "reject mode keeps its floor")
        compare(items[0].movements, undefined)
    }
    function test_a_deduction_with_an_increasing_kind_still_queues_the_stock_change() {
        InventoryStore.deductStock("SKU-1", 2, function() {}, false, "receipt", "x")
        var items = _inv("SKU-1")
        compare(items.length, 1)
        compare(items[0].deltas.stock, -2)
        compare(items[0].movements, undefined)
    }

    // ── restock refusal tells the user why ───────────────────────────────
    function test_a_refused_restock_answers_with_the_quantity_message_not_try_again() {
        var out = { ok: null, supplierFailed: null, refusal: null }
        InventoryStore.restock("SKU-1", -3, "", 10, "", function(ok, sf, refusal) { out.ok = ok; out.supplierFailed = sf; out.refusal = refusal })
        compare(out.ok, false)
        compare(out.supplierFailed, false)
        compare(out.refusal, "Quantity must be greater than zero")
        compare(out.refusal, InventoryStore.restockQtyRefusal)
    }
    function test_a_text_quantity_is_refused_with_the_same_message_and_no_side_effect() {
        var out = { ok: null, refusal: null }
        InventoryStore.restock("SKU-1", "5", "", 10, "", function(ok, sf, refusal) { out.ok = ok; out.refusal = refusal })
        compare(out.ok, false)
        compare(out.refusal, InventoryStore.restockQtyRefusal)
        compare(OutboxStore.pendingCount, 0)
        compare(StockBatchStore._pendingMints.length, 0)
    }
    function test_a_nan_quantity_falls_back_to_the_default_ten_like_before() {
        InventoryStore.restock("SKU-1", NaN, "", 10, "", function() {})
        compare(_inv("SKU-1")[0].deltas.stock, 10)
        compare(_inv("SKU-1")[0].movements[0].qty, 10)
    }
}
