import QtQuick
import QtTest
import "../qml/model"

// Regression coverage for the 2026-09-02 bug Taher reported: add a taxable
// product (sp 60, tax 5%), complete a 1-unit order (tax 3, total 63), then
// edit the order to add a 5% discount. Expected: net 57, tax 2.85 (5% of the
// DISCOUNTED net), total 59.85. The app showed tax still at 3 -- and a
// subsequent full return of the item (which correctly reverses at the LIVE
// discounted rate) left a phantom 0.15 of unreconciled revenue/tax sitting
// in the order.
//
// Root cause: TransactionStore.recordPriceAdjust books a price_adjust ledger
// event carrying ONLY a signed revenue delta (`total`) -- by design, per its
// old header comment, it had "NO tax field -> contributes 0 (revenue-only)".
// A discount or price edit on a TAXABLE completed-order line changes net
// without ever touching the immutable original sale event's stamped `tax`
// field, so TransactionStore.totalsForOrder (the authoritative tax/total
// source for a completed order -- see OrdersStore.applyAdjustment) stayed
// frozen at the pre-edit tax forever.
//
// Fix: recordPriceAdjust now takes an optional `taxRate` param and books a
// proportional signed tax delta (revenueDelta * taxRate/100) on the
// price_adjust event's new `tax` field; totalsForOrder sums it in. Both
// DataModel._tryAdjustOrder call sites (discount-edit scanner, price-modify
// block) now pass the line's own current taxable/taxPercent.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available. Written
// to convention (mirrors tst_TransactionStore_resetGuard.qml /
// tst_TransactionStore_syncRetry.qml's direct-singleton-call pattern); needs
// a local qmltestrunner pass before merge, same status as every other
// client-side test in this repo.
TestCase {
    name: "TransactionStore_priceAdjustTax"
    function _round2(x) { return Math.round(x * 100) / 100 }

    function init() {
        TransactionStore.entries = []
        TransactionStore.revision = 0
        Gateway.mode = "gateway"   // enqueue into OutboxStore instead of a real write
        OutboxStore.clear()
        AuthStore.idToken = ""             // keeps Gateway._send's guard closed — no real network
        AuthStore._settings.sessionJson = "" // see tst_Gateway.qml header / CHECKPOINT.md 2026-08-18
    }

    function _order() {
        return { orderId: "ORD-TAX-1", orderChannel: "", staffId: "",
                 products: [{ productId: "SKU-TAX-1", name: "Taxed Widget", price: 60, quantity: 1,
                              taxable: true, taxPercent: 5, discountType: "flat", discountValue: 0,
                              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] }] }
    }

    // ── recordPriceAdjust: the tax-delta itself ─────────────────────────────

    function test_books_proportional_tax_delta_for_taxable_line() {
        // Mirrors DataModel's discount-edit call: survivingQty=1, perUnitDelta
        // = discDelta (the "Factor as (1, discDelta)" trick).
        var res = TransactionStore.recordPriceAdjust(
            _order(), { productId: "SKU-TAX-1", name: "Taxed Widget" },
            1, 3 /* discDelta: 60 * 5% */, "discount", "discount 0->3", 5 /* taxRate */)

        compare(_round2(res.revenueDelta), -3, "revenue drops by the discount amount")
        compare(_round2(res.taxDelta), -0.15, "tax drops by 5% of the discount amount")
        compare(TransactionStore.entries.length, 1)
        var doc = TransactionStore.entries[0]
        compare(doc.kind, "price_adjust")
        compare(_round2(doc.total), -3, "ledger doc.total carries the revenue delta")
        compare(_round2(doc.tax), -0.15, "ledger doc.tax carries the new tax delta")
    }

    function test_zero_tax_when_taxRate_omitted() {
        var res = TransactionStore.recordPriceAdjust(
            _order(), { productId: "SKU-TAX-1", name: "Taxed Widget" },
            1, 3, "discount", "no rate passed")
        compare(res.taxDelta, 0, "omitted taxRate must not silently assume a rate")
        compare(TransactionStore.entries[0].tax, 0)
    }

    function test_zero_tax_when_line_not_taxable() {
        var res = TransactionStore.recordPriceAdjust(
            _order(), { productId: "SKU-TAX-1", name: "Taxed Widget" },
            1, 3, "discount", "explicit 0 rate", 0)
        compare(res.taxDelta, 0)
        compare(TransactionStore.entries[0].tax, 0)
    }

    function test_negative_taxRate_treated_as_zero() {
        // Defensive: a corrupt/negative taxPercent must never flip the sign
        // of the booked tax delta.
        var res = TransactionStore.recordPriceAdjust(
            _order(), { productId: "SKU-TAX-1", name: "Taxed Widget" },
            1, 3, "discount", "bad rate", -5)
        compare(res.taxDelta, 0)
    }

    function test_tax_delta_sign_flips_when_discount_decreases() {
        // Discount REDUCED (e.g. 5% -> 2%): discDelta is negative (net goes
        // UP), so the tax delta must go up too (more tax owed), matching the
        // revenue delta's own sign flip.
        var res = TransactionStore.recordPriceAdjust(
            _order(), { productId: "SKU-TAX-1", name: "Taxed Widget" },
            1, -1.8 /* discDelta: 60*2% - 60*5% */, "discount", "discount 3->1.2", 5)
        compare(_round2(res.revenueDelta), 1.8)
        compare(_round2(res.taxDelta), 0.09, "tax owed increases when discount shrinks")
    }

    function test_price_modify_call_shape_also_books_tax() {
        // Mirrors DataModel's price-modify call: survivingQty*perUnitDelta,
        // NOT the (1, discDelta) trick.
        var res = TransactionStore.recordPriceAdjust(
            _order(), { productId: "SKU-TAX-1", name: "Taxed Widget" },
            2 /* survivingQty */, 10 /* oldPrice-newPrice: price dropped 10 */,
            "modify", "price 70->60", 5)
        compare(_round2(res.revenueDelta), -20, "2 units * 10 price drop")
        compare(_round2(res.taxDelta), -1, "5% of the 20 revenue drop")
    }

    function test_no_write_when_perUnitDelta_zero() {
        var before = TransactionStore.entries.length
        var res = TransactionStore.recordPriceAdjust(
            _order(), { productId: "SKU-TAX-1", name: "Taxed Widget" }, 1, 0, "discount", "", 5)
        compare(TransactionStore.entries.length, before, "guard clause still short-circuits")
        compare(res.revenueDelta, 0)
        compare(res.taxDelta, 0)
    }

    function test_orderwide_adjustment_taxRate_still_optional() {
        // Backward-compat: order-wide adjustments (no productId) never passed
        // a tax rate before this fix and must keep working unchanged.
        var res = TransactionStore.recordPriceAdjust(
            _order(), { productId: "", name: "" }, 1, 2, "modify", "order-wide")
        compare(res.taxDelta, 0)
        compare(TransactionStore.entries[0].productId, "")
    }

    // ── totalsForOrder: the actual reported-bug reconciliation ─────────────

    // Reproduces the exact numbers from the bug report: cp 50 / sp 60 / tax
    // 5%, 1 unit, no discount at completion -> 60 net + 3 tax = 63 total.
    // Then a 5% discount edit is applied. Expected per the user's own math:
    // net 57, tax 2.85, total 59.85.
    function test_totalsForOrder_reproduces_the_reported_bug_numbers() {
        TransactionStore.entries = [{
            kind: "sale", orderId: "ORD-TAX-1", productId: "SKU-TAX-1",
            quantity: 1, net: 60, tax: 3, discountShare: 0, total: 60,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }]
        }]
        TransactionStore.recordPriceAdjust(
            _order(), { productId: "SKU-TAX-1", name: "Taxed Widget" },
            1, 3, "discount", "discount 0->3", 5)

        var t = TransactionStore.totalsForOrder("ORD-TAX-1")
        compare(_round2(t.net), 57, "net after 5% discount on 60")
        compare(_round2(t.tax), 2.85, "tax recomputed on the DISCOUNTED net, not stale at 3")
        compare(_round2(t.total), 59.85)
    }

    // Continues the scenario above: the (now-discounted) item is fully
    // returned. Before the fix this left a 0.15 phantom residual (the
    // return correctly reverses at the live 2.85 rate, but the sale event's
    // immutable stamped tax was still 3). After the fix everything nets to 0.
    function test_totalsForOrder_full_return_after_discount_edit_reconciles_to_zero() {
        TransactionStore.entries = [{
            kind: "sale", orderId: "ORD-TAX-1", productId: "SKU-TAX-1",
            quantity: 1, net: 60, tax: 3, discountShare: 0, total: 60,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }]
        }]
        TransactionStore.recordPriceAdjust(
            _order(), { productId: "SKU-TAX-1", name: "Taxed Widget" },
            1, 3, "discount", "discount 0->3", 5)
        // The return event, as recordReturn would stamp it: allocated from
        // the LIVE (post-discount) order via OrderMath.allocate, so its
        // net/tax already reflect the discounted rate (57, 2.85) -- this half
        // of the pipeline was already correct before this fix; unchanged here.
        TransactionStore.entries = TransactionStore.entries.concat([{
            kind: "return", orderId: "ORD-TAX-1", productId: "SKU-TAX-1",
            quantity: -1, net: -57, tax: -2.85, discountShare: -3, total: -60
        }])

        var t = TransactionStore.totalsForOrder("ORD-TAX-1")
        compare(_round2(t.net), 0, "no phantom net left in a fully-returned order")
        compare(_round2(t.tax), 0, "no phantom 0.15 tax left in a fully-returned order")
        compare(_round2(t.total), 0)
    }

    // Two sequential discount tweaks on the same completed order (5% -> 8%,
    // then 8% back down to 5%) must accumulate to the SAME final state as a
    // single 5% edit -- proves the fix is correctly additive across multiple
    // price_adjust events, not just a single-edit special case.
    function test_totalsForOrder_multiple_sequential_discount_edits_reconcile() {
        TransactionStore.entries = [{
            kind: "sale", orderId: "ORD-TAX-1", productId: "SKU-TAX-1",
            quantity: 1, net: 60, tax: 3, discountShare: 0, total: 60,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }]
        }]
        // 0% -> 8%: discDelta = 60*8% = 4.8
        TransactionStore.recordPriceAdjust(
            _order(), { productId: "SKU-TAX-1", name: "Taxed Widget" },
            1, 4.8, "discount", "discount 0->4.8", 5)
        // 8% -> 5%: discDelta = 60*5% - 60*8% = -1.8 (discount SHRANK)
        TransactionStore.recordPriceAdjust(
            _order(), { productId: "SKU-TAX-1", name: "Taxed Widget" },
            1, -1.8, "discount", "discount 4.8->3", 5)

        var t = TransactionStore.totalsForOrder("ORD-TAX-1")
        compare(_round2(t.net), 57, "net settles at the FINAL 5% discount regardless of path")
        compare(_round2(t.tax), 2.85, "tax settles at the FINAL 5% discount regardless of path")
    }
}
