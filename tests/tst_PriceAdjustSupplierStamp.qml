import QtQuick
import QtTest
import "../qml/helper/OrderMath.js" as OM
import "../qml/helper/RealisedMath.js" as RM
import "../qml/helper/BreakdownMath.js" as BM

// SITE 2/3 root cause: a price_adjust event's SUPPLIER attribution is re-derived
// at REPORT time from the LIVE order's consumption (spreadLineDeltaBySupplier).
// After a full return empties that consumption, the live order yields [] and the
// delta dumps into an "Unknown" supplier bucket — residue (-38 rev / +14 disc),
// real suppliers carry negative discounts.
//
// FIX: stamp the supplier slices on the price_adjust event AT WRITE TIME (while
// the order still has consumption), then realisedProfitByDimension reads the
// stamped slices — stable regardless of later mutation.
//
// This test mirrors both the write-time stamping (real OM.spreadLineDeltaBySupplier
// against the intact order) and the report-time supplier aggregation (reads
// stamped slices when present; falls back to live-spread when absent).
TestCase {
    name: "PriceAdjustSupplierStamp"
    function _round2(x){ return Math.round(x*100)/100 }

    // The order at the moment the discount edit fires (still has FIFO lineage).
    function _orderAtEditTime() {
        return { orderId: "ORD-003", products: [
            { productId: "PRD-001", name: "Rida", price: 18, quantity: 3,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 5,
              consumption: [{ batchId: "B1", supplierId: "S-RIDA", qtyConsumed: 3, unitCost: 10 }] }
        ] }
    }

    // The SAME order after a full return — consumption emptied (what realisedProfit
    // sees at report time today).
    function _orderAfterReturn() {
        return { orderId: "ORD-003", products: [
            { productId: "PRD-001", name: "Rida", price: 18, quantity: 0,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 5,
              consumption: [] }
        ] }
    }

    // Mirror of recordPriceAdjust stamping: capture supplier slices NOW.
    function _stampSlices(orderAtWrite, productId, revenueDelta) {
        return OM.spreadLineDeltaBySupplier(orderAtWrite, productId, revenueDelta)
    }

    // Mirror of realisedProfitByDimension supplierId branch (proposed: prefer
    // stamped slices, fall back to live spread).
    function _supplierAttribution(e, liveOrder) {
        var out = {}
        var slices = (Array.isArray(e.supplierSlices) && e.supplierSlices.length > 0)
                ? e.supplierSlices
                : OM.spreadLineDeltaBySupplier(liveOrder, e.productId, e.total)
        var isDisc = (e.reason === "discount")
        if (slices.length === 0) {
            // fallback dumps to "Unknown"
            out[""] = { revenue: (e.total||0), discount: isDisc ? -(e.total||0) : 0 }
            return out
        }
        for (var i = 0; i < slices.length; ++i) {
            var k = slices[i].key
            if (!out[k]) out[k] = { revenue: 0, discount: 0 }
            out[k].revenue += slices[i].amount
            if (isDisc) out[k].discount += -(slices[i].amount)
        }
        return out
    }

    // BUG (today): no stamped slices → after return, attribution dumps to "Unknown".
    function test_without_stamp_dumps_to_unknown_after_return() {
        var e = { kind:"price_adjust", productId:"PRD-001", total:-5, reason:"discount" }  // no supplierSlices
        var attr = _supplierAttribution(e, _orderAfterReturn())
        verify(attr["S-RIDA"] === undefined)   // real supplier got nothing
        verify(attr[""] !== undefined)          // dumped into Unknown
        compare(_round2(attr[""].discount), 5, "Unknown wrongly carries the +5 discount")
    }

    // FIX: stamp slices at edit time → attribution survives the return.
    function test_with_stamp_attributes_to_real_supplier_after_return() {
        var slices = _stampSlices(_orderAtEditTime(), "PRD-001", -5)
        var e = { kind:"price_adjust", productId:"PRD-001", total:-5, reason:"discount",
                  supplierSlices: slices }
        var attr = _supplierAttribution(e, _orderAfterReturn())   // live order emptied — must be IGNORED
        verify(attr["S-RIDA"] !== undefined)    // real supplier credited
        compare(_round2(attr["S-RIDA"].revenue), -5, "real supplier gets the -5 revenue delta")
        compare(_round2(attr["S-RIDA"].discount), 5, "real supplier gets the +5 discount")
        verify(attr[""] === undefined)          // NO Unknown residue
    }

    // ── Supplier filter must INCLUDE stamped price_adjusts (the reported bug) ──
    // Two SUP-001 adjusts (the live-Firestore shape): a -5 discount edit and a
    // -2 price modify. Filtering by SUP-001 previously skipped both (net 0 /
    // discount 0); now byDimension/totals/bucketWalk read the stamped slices.
    function _adjusts() {
        return [
            { kind:"price_adjust", date:"2026-06-25", timestamp:"2026-06-25T04:55:42.374Z",
              reason:"discount", total:-5, productId:"PRD-001", orderId:"ORD-002",
              consumption:[], supplierSlices:[{ key:"SUP-001", amount:-5 }] },
            { kind:"price_adjust", date:"2026-06-25", timestamp:"2026-06-25T04:58:33.378Z",
              reason:"modify", total:-2, productId:"PRD-001", orderId:"ORD-001",
              consumption:[], supplierSlices:[{ key:"SUP-001", amount:-2 }] }
        ]
    }
    function _monthScope(supplierId) {
        var now = new Date(2026, 5, 25, 12, 0, 0)
        return { window: BM.periodWindow(2, now), supplierId: supplierId || "" }
    }

    function test_supplier_filter_includes_price_and_discount() {
        var t = RM.totals(_adjusts(), _monthScope("SUP-001"), {})
        compare(_round2(t.net), -7, "SUP-001 net includes -5 discount + -2 price")
        compare(_round2(t.discount), 5, "SUP-001 discount column shows the +5")
        var bySup = RM.byDimension("supplierId", _adjusts(), _monthScope("SUP-001"), {})
        verify(bySup["SUP-001"] !== undefined)
        compare(_round2(bySup["SUP-001"].revenue), -7, "by-supplier revenue = -7")
        compare(_round2(bySup["SUP-001"].discount), 5, "by-supplier discount = 5")
    }

    function test_other_supplier_filter_excludes() {
        var t = RM.totals(_adjusts(), _monthScope("SUP-999"), {})
        compare(_round2(t.net), 0, "an unrelated supplier sees none of SUP-001's adjusts")
        compare(_round2(t.discount), 0, "no discount leaks to the wrong supplier")
    }

    // Reconciliation invariant must survive the fix: totals.net == Σ bucketWalk.
    function test_filtered_totals_reconcile_with_bucketwalk() {
        var now = new Date(2026, 5, 25, 12, 0, 0)
        var scope = _monthScope("SUP-001")
        var t = RM.totals(_adjusts(), scope, {})
        var bins = RM.bucketWalk("net", 2, _adjusts(), scope, now, {})
        var sum = 0; for (var i = 0; i < bins.length; ++i) sum += bins[i].value
        compare(_round2(sum), _round2(t.net), "Σ bucketWalk == totals.net under the supplier filter")
        compare(_round2(sum), -7, "and equals the expected -7")
    }

    // ── Profit hero now uses bucketWalk("profit") — the path the deleted
    // SalesPage._profitBucketWalk used to (mis)handle. D-1: supplier-filtered
    // price_adjust must be INCLUDED in the profit bins (these adjusts have empty
    // consumption so profit delta == revenue delta == -7).
    function test_profit_bucketwalk_includes_supplier_filtered_adjust() {
        var now = new Date(2026, 5, 25, 12, 0, 0)
        var scope = _monthScope("SUP-001")
        var bins = RM.bucketWalk("profit", 2, _adjusts(), scope, now, {})
        var sum = 0; for (var i = 0; i < bins.length; ++i) sum += bins[i].value
        compare(_round2(sum), -7, "profit hero (bucketWalk) includes the SUP-001 adjusts (-7)")
        // Reconciles with totals.profit over the same scope (hero == Σ by-dimension).
        compare(_round2(sum), _round2(RM.totals(_adjusts(), scope, {}).profit),
                "Σ profit bucketWalk == totals.profit under the supplier filter")
        // A different supplier sees none of it.
        var binsOther = RM.bucketWalk("profit", 2, _adjusts(), _monthScope("SUP-999"), now, {})
        var sumOther = 0; for (var j = 0; j < binsOther.length; ++j) sumOther += binsOther[j].value
        compare(_round2(sumOther), 0, "unrelated supplier → profit 0")
    }

    // D-2: hero bins use the SAME period∩date window as the by-dimension cards.
    // Both totals and bucketWalk take the identical scope.window, so a custom
    // date ∩ period window can't make hero and Σ by-dimension diverge.
    function test_profit_bucketwalk_reconciles_under_intersected_window() {
        var now = new Date(2026, 5, 25, 12, 0, 0)
        // period(Month) ∩ custom date [Jun 25, Jun 25] → the single day.
        var dayStart = new Date(2026, 5, 25)
        var dayEnd = new Date(2026, 5, 26)
        var scope = { window: { from: dayStart, to: dayEnd }, supplierId: "SUP-001" }
        var t = RM.totals(_adjusts(), scope, {})
        var bins = RM.bucketWalk("profit", 2, _adjusts(), scope, now, {})
        var sum = 0; for (var i = 0; i < bins.length; ++i) sum += bins[i].value
        compare(_round2(sum), _round2(t.profit),
                "profit bucketWalk == totals.profit over the same intersected window")
        compare(_round2(sum), -7, "and both equal -7 for Jun 25")
    }
}
