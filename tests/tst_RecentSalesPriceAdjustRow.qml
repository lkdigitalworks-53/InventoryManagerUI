import QtQuick
import QtTest

// Reproduces: in the Analysis → Revenue → "Recent sales" list, rows for
// price_adjust events (a discount EDIT or a price MODIFY) render without a SKU
// and with a flat, undifferentiated "Price adjusted" label — so the user can't
// tell a discount change from a price change, and the SKU that every sale /
// return row shows is missing.
//
// Root cause (SalesPage.qml _txSubtitle):
//   • the SKU tail is gated to kind === "sale" || "return" — price_adjust is
//     excluded, so its row never resolves a SKU.
//   • the head is the constant "Price adjusted" for every price_adjust, never
//     distinguishing reason === "discount" from a price modify.
//
// This mirrors _txSubtitle / _txTitle pure logic (the real functions call
// InventoryStore.getById, which can't load under qmltestrunner) with a
// `withFix` flag and an injected SKU lookup, exactly like tst_RealisedDiscountColumn.
TestCase {
    name: "RecentSalesPriceAdjustRow"

    // SKU lookup stub — stands in for InventoryStore.getById(productId).sku.
    property var _skuByProduct: ({ "PRD-001": "SKU-AAA", "PRD-002": "SKU-BBB" })
    function _skuOf(productId) { return _skuByProduct[productId] || "" }

    // Faithful mirror of SalesPage._txTitle.
    function _txTitle(d) {
        var name = d.productName || "(unknown)"
        if (d.orderId && (d.kind === "sale" || d.kind === "return" || d.kind === "price_adjust"))
            return name + "  ·  #" + d.orderId
        return name
    }

    // Faithful mirror of SalesPage._txSubtitle, parameterised by `withFix`.
    function _txSubtitle(d, withFix) {
        var head
        if (d.kind === "purchase")          head = "Restocked +" + (d.quantity || 0)
        else if (d.kind === "created")      head = (d.quantity > 0) ? ("Created with " + d.quantity) : "Created"
        else if (d.kind === "return")       head = "Returned " + Math.abs(d.quantity || 0)
        else if (d.kind === "price_adjust") {
            if (withFix)
                head = (d.reason === "discount") ? "Discount changed" : "Price adjusted"
            else
                head = "Price adjusted"
        }
        else if (d.kind === "sale")         head = "Sold " + (d.quantity || 0)
        else                                head = ""

        var skuTail = ""
        var skuApplies = withFix
            ? (d.kind === "sale" || d.kind === "return" || d.kind === "price_adjust")
            : (d.kind === "sale" || d.kind === "return")
        if (d.productId && skuApplies) {
            var sku = _skuOf(d.productId)
            if (sku) skuTail = "  ·  " + "SKU " + sku
        }
        var party = d.party || (d.snapshot ? d.snapshot.party || "" : "")
        var partyTail = party ? "  ·  " + "from " + party : ""
        return head + skuTail + partyTail + (d.date ? "  ·  " + d.date : "")
    }

    // ── Bug: discount-edit price_adjust row is missing SKU + a meaningful label ──
    function test_discount_event_shows_sku_and_label() {
        var d = { kind: "price_adjust", reason: "discount", productId: "PRD-001",
                  productName: "Widget", orderId: "ORD-003", total: -5, date: "2026-06-25" }

        var before = _txSubtitle(d, false)
        verify(before.indexOf("SKU-AAA") < 0, "BUG: no SKU shown before fix")
        verify(before.indexOf("Discount changed") < 0, "BUG: discount not distinguished before fix")

        var after = _txSubtitle(d, true)
        verify(after.indexOf("SKU SKU-AAA") >= 0, "FIX: discount row now shows the SKU")
        verify(after.indexOf("Discount changed") >= 0, "FIX: discount row labelled 'Discount changed'")
    }

    // ── Bug: price-modify price_adjust row is missing SKU ──
    function test_price_modify_shows_sku_and_label() {
        var d = { kind: "price_adjust", reason: "modify", productId: "PRD-002",
                  productName: "Gadget", orderId: "ORD-004", total: -20, date: "2026-06-25" }

        var before = _txSubtitle(d, false)
        verify(before.indexOf("SKU-BBB") < 0, "BUG: no SKU shown before fix")

        var after = _txSubtitle(d, true)
        verify(after.indexOf("SKU SKU-BBB") >= 0, "FIX: price-modify row now shows the SKU")
        verify(after.indexOf("Price adjusted") >= 0, "FIX: price modify keeps 'Price adjusted' label")
        verify(after.indexOf("Discount changed") < 0, "a price modify is NOT a discount change")
    }

    // ── Title ties the row back to its order for price_adjust (already works) ──
    function test_title_includes_order_for_price_adjust() {
        var d = { kind: "price_adjust", reason: "discount", productId: "PRD-001",
                  productName: "Widget", orderId: "ORD-003" }
        compare(_txTitle(d), "Widget  ·  #ORD-003")
    }

    // ── Regression: sale/return rows keep their SKU after the fix ──
    function test_sale_row_keeps_sku() {
        var d = { kind: "sale", productId: "PRD-001", productName: "Widget",
                  orderId: "ORD-001", quantity: 3, date: "2026-06-25" }
        verify(_txSubtitle(d, true).indexOf("SKU SKU-AAA") >= 0, "sale row still shows SKU")
        verify(_txSubtitle(d, true).indexOf("Sold 3") >= 0, "sale row still shows qty")
    }
}
