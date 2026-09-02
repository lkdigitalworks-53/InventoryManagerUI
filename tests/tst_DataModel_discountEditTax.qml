import QtQuick
import QtTest
import "../qml/model"

// End-to-end reproduction of the 2026-09-02 bug, driven through the REAL
// DataModel._tryAdjustOrder orchestration (not the hand-derived-formula
// style of tst_AdjustDiscountRepro.qml / the isolated function-level tests
// in tst_TransactionStore_priceAdjustTax.qml). This is the closest possible
// test to how Taher actually reproduced it in the app:
//   1. Product cp 50 / sp 60 / tax 5%. Complete a 1-unit order.
//      -> tax 3, total 63.
//   2. Edit the order to add a 5% discount, no quantity change.
//      -> expected tax 2.85, total 59.85 (app showed tax still 3).
//   3. Return the item.
//      -> expected the order nets to exactly 0 (app left a 0.15 residual).
// See TransactionStore.recordPriceAdjust / totalsForOrder for the fix.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available. Written
// to convention (mirrors tst_DataModel_adjustOrderSyncGuard.qml's
// direct-child-item DataModel instantiation and fixture shape); needs a
// local qmltestrunner pass before merge, same status as every other
// client-side test in this repo.
TestCase {
    name: "DataModel_discountEditTax"

    DataModel { id: dm }

    function _round2(x) { return Math.round(x * 100) / 100 }

    function init() {
        OrdersStore.orders = []
        TransactionStore.entries = []
        TransactionStore.revision = 0
        TransactionStore.hasMore = false // fully synced -- see tst_DataModel_adjustOrderSyncGuard.qml
        InventoryStore.products = [{
            productId: "SKU-TAX-E2E", name: "Taxed Widget", sku: "TW1", category: "",
            description: "", unit: "pc", price: 50, sellingPrice: 60,
            taxable: true, taxPercent: 5, size: "", stock: 10, minStock: 0
        }]
        StockBatchStore.batches = [{
            batchId: "B1", productId: "SKU-TAX-E2E", supplierId: "S1",
            qtyReceived: 1, qtyRemaining: 0, unitCost: 50,
            receivedDate: "2026-09-01T00:00:00.000Z", poId: "", note: "",
            createdAt: "2026-09-01T00:00:00.000Z", updatedAt: "2026-09-01T00:00:00.000Z"
        }]
        Gateway.mode = "gateway"
        OutboxStore.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = "" // see tst_Gateway.qml header / CHECKPOINT.md 2026-08-18
        dm.stockErrorMsg = ""
    }

    // The completed order exactly as it would exist right after checkout:
    // no discount yet, tax booked on the full 60.
    function _completedOrderNoDiscount() {
        return {
            orderId: "ORD-TAX-E2E", customer: "Test Customer", status: "completed",
            date: "2026-09-02", email: "", phone: "", notes: "",
            orderChannel: "", staffId: "", adjustments: [],
            products: [{ productId: "SKU-TAX-E2E", name: "Taxed Widget", price: 60, quantity: 1,
                         taxable: true, taxPercent: 5, discountType: "flat", discountValue: 0,
                         consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] }]
        }
    }

    // The stamped sale event TransactionStore.recordSaleFromOrder would have
    // written at original checkout time -- seeded directly rather than
    // produced via a real checkout call, since _tryAdjustOrder is for
    // ADJUSTING an already-completed order and expects this to pre-exist.
    function _originalSaleEvent() {
        return {
            kind: "sale", orderId: "ORD-TAX-E2E", productId: "SKU-TAX-E2E",
            productName: "Taxed Widget", quantity: 1, unitPrice: 60,
            net: 60, tax: 3, discountShare: 0, total: 60,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }]
        }
    }

    function _withFivePercentDiscount() {
        return [{ productId: "SKU-TAX-E2E", name: "Taxed Widget", price: 60, quantity: 1,
                   taxable: true, taxPercent: 5, discountType: "percent", discountValue: 5 }]
    }

    // ── step 2 of the repro: the discount edit itself ───────────────────────

    function test_discount_edit_on_completed_taxable_order_recomputes_tax_correctly() {
        OrdersStore.orders = [_completedOrderNoDiscount()]
        TransactionStore.entries = [_originalSaleEvent()]

        var result = null
        dm._tryAdjustOrder("ORD-TAX-E2E", _withFivePercentDiscount(), "discount", "", "",
                            function(ok) { result = ok })

        compare(result, true, "a pure discount-rate edit (no qty change) must succeed synchronously")
        compare(dm.stockErrorMsg, "")

        var o = OrdersStore.orders[0]
        compare(o.orderId, "ORD-TAX-E2E")
        compare(_round2(o.subtotal), 60, "subtotal is the undiscounted gross, unaffected by tax fix")
        compare(_round2(o.discount), 3, "5% of 60")
        compare(_round2(o.tax), 2.85, "THE bug: tax must move off the stale 3 to the discounted 5%")
        compare(_round2(o.total), 59.85, "total = 57 net + 2.85 tax, matching Taher's own expected math")

        // The order's own line data reflects the new discount (used by any
        // SUBSEQUENT adjustment's live-order allocation, e.g. a later return).
        compare(o.products[0].discountValue, 5)
        compare(o.products[0].discountType, "percent")
    }

    function test_discount_edit_books_a_reconciling_ledger_entry() {
        OrdersStore.orders = [_completedOrderNoDiscount()]
        TransactionStore.entries = [_originalSaleEvent()]

        dm._tryAdjustOrder("ORD-TAX-E2E", _withFivePercentDiscount(), "discount", "", "",
                            function(ok) {})

        var priceAdjustEvents = TransactionStore.entries.filter(function(e) {
            return e.kind === "price_adjust" && e.orderId === "ORD-TAX-E2E"
        })
        compare(priceAdjustEvents.length, 1, "exactly one price_adjust event for this discount edit")
        compare(_round2(priceAdjustEvents[0].total), -3, "revenue delta: discount reduces net by 3")
        compare(_round2(priceAdjustEvents[0].tax), -0.15, "tax delta: 5% of the 3 discount")
    }

    // ── step 3 of the repro: return the (now-discounted) item afterward ────

    function test_full_return_after_discount_edit_leaves_no_residual() {
        OrdersStore.orders = [_completedOrderNoDiscount()]
        TransactionStore.entries = [_originalSaleEvent()]

        // Step 2: apply the 5% discount (as in the test above).
        var discountResult = null
        dm._tryAdjustOrder("ORD-TAX-E2E", _withFivePercentDiscount(), "discount", "", "",
                            function(ok) { discountResult = ok })
        compare(discountResult, true, "precondition: the discount edit must itself succeed")

        // Step 3: return the single unit entirely (empty product line -> full return).
        var returnResult = null
        dm._tryAdjustOrder("ORD-TAX-E2E", [], "return", "resellable", "",
                            function(ok) { returnResult = ok })

        compare(returnResult, true, "the return itself must succeed")
        compare(dm.stockErrorMsg, "")

        var o = OrdersStore.orders[0]
        compare(_round2(o.subtotal), 0, "no lines remain")
        compare(_round2(o.tax), 0, "THE bug: must be exactly 0, not a 0.15 phantom residual")
        compare(_round2(o.total), 0, "order fully reconciles to zero after a full return")
    }
}
