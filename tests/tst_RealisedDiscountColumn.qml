import QtQuick
import QtTest

// Reproduces: after an in-app discount EDIT, the Realised-profit DISCOUNT column
// under-reports. Totals (live orders, allocate) show discount 36; the by-dimension
// sections (event-sourced realisedProfitByDimension) show only 22 — the discount
// added by the edit (a price_adjust event with reason "discount") is netted into
// revenue/profit but NEVER added to the discount accumulator.
//
// This test mirrors realisedProfitByDimension's per-product aggregation for the
// ORD-003 scenario: an original sale event (no discount) plus a discount-edit
// price_adjust event of -14 revenue (discount went up 14). The by-product discount
// for the order must be 14 (the edit), not 0.
TestCase {
    name: "RealisedDiscountColumn"
    function _round2(x){ return Math.round(x*100)/100 }

    // Faithful mirror of the price_adjust per-line branch (field="productId")
    // PLUS the proposed discount accumulation.
    function _aggregate(events, withFix) {
        var out = {}
        for (var i = 0; i < events.length; ++i) {
            var e = events[i]
            if (e.kind === "sale") {
                var c = e.consumption || []
                var lineQty = 0
                for (var q = 0; q < c.length; ++q) lineQty += (c[q].qtyConsumed || 0)
                for (var ci = 0; ci < c.length; ++ci) {
                    var cc = c[ci]; var qty = cc.qtyConsumed || 0
                    if (!qty) continue
                    var frac = lineQty !== 0 ? qty/lineQty : 0
                    var key = e.productId
                    if (!out[key]) out[key] = { revenue:0, cogs:0, profit:0, discount:0 }
                    out[key].revenue += (e.net||0)*frac
                    out[key].cogs += qty*(cc.unitCost||0)
                    out[key].profit += (e.net||0)*frac - qty*(cc.unitCost||0)
                    out[key].discount += (e.discountShare||0)*frac
                }
            } else if (e.kind === "price_adjust") {
                var pk = e.productId || ""
                if (!out[pk]) out[pk] = { revenue:0, cogs:0, profit:0, discount:0 }
                out[pk].revenue += (e.total||0)
                out[pk].profit  += (e.total||0)
                // THE FIX: a discount edit's revenue drop IS discount.
                if (withFix && e.reason === "discount") out[pk].discount += -(e.total||0)
            }
        }
        return out
    }

    // ORD-003 Rida after edit: original sale net 54 (3@18) NO discount stamped,
    // then a discount edit price_adjust of -5 (flat ₹5 added). Final net 49, discount 5.
    function test_discount_edit_reflected_in_discount_column() {
        var events = [
            { kind:"sale", productId:"PRD-001", net:54, discountShare:0,
              consumption:[{ supplierId:"S1", qtyConsumed:3, unitCost:10 }] },
            { kind:"price_adjust", productId:"PRD-001", total:-5, reason:"discount" }
        ]
        var noFix = _aggregate(events, false)
        compare(_round2(noFix["PRD-001"].discount), 0, "BUG: without fix, discount column stays 0 (edit invisible)")
        compare(_round2(noFix["PRD-001"].revenue), 49, "revenue is correct even without fix")

        var withFix = _aggregate(events, true)
        compare(_round2(withFix["PRD-001"].discount), 5, "FIX: discount column reflects the ₹5 edit")
        compare(_round2(withFix["PRD-001"].revenue), 49, "revenue unchanged by the discount-column fix")
        compare(_round2(withFix["PRD-001"].profit), 19, "profit unchanged (49 net - 30 cogs)")
    }

    // A price MODIFY (reason "modify") must NOT add to the discount column.
    function test_price_modify_not_counted_as_discount() {
        var events = [
            { kind:"sale", productId:"PRD-002", net:200, discountShare:0,
              consumption:[{ supplierId:"S2", qtyConsumed:1, unitCost:100 }] },
            { kind:"price_adjust", productId:"PRD-002", total:-20, reason:"modify" }
        ]
        var withFix = _aggregate(events, true)
        compare(_round2(withFix["PRD-002"].discount), 0, "price modify is NOT discount")
        compare(_round2(withFix["PRD-002"].revenue), 180, "revenue reflects the modify")
    }
}
