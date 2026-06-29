import QtQuick
import QtTest
import "../qml/helper/OrderMath.js" as OM
import "../qml/helper/OrderAdjust.js" as OA

// Locks the time-of-supply tax rule for editing a COMPLETED order.
//
// Bug: product added at 0% tax → order completed (sale event booked tax 0) →
// product edited to 10% tax → completed order edited, line removed & re-added via
// picker (same qty/price). The picker re-seeded the line at the product's CURRENT
// 10%, so the order TOTAL showed tax — but the immutable sale ledger (and reports)
// kept tax 0. Per time-of-supply, already-supplied units keep their booked rate;
// the FIX seeds a re-added completed-order line from the BOOKED original line, so
// the total reconciles with the ledger. Only genuinely-added units get current tax.
//
// OrderDetailDialog/OrdersStore can't load under qmltestrunner, so this mirrors
// the seed decision (the dialog's picker-append branch) and computes tax via the
// REAL OrderMath.allocate — the same allocator recordSaleFromOrder uses for the
// ledger, so "total tax == ledger tax" is exactly what we assert.
TestCase {
    name: "CompletedOrderTaxTimeOfSupply"
    function _round2(x){ return Math.round(x * 100) / 100 }

    // Booked snapshot: the line as completed (tax 0%).
    function _originalLines() {
        return [{ productId: "PRD-001", name: "Rida", price: 20, quantity: 1,
                  discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }]
    }
    // The product's CURRENT catalog entry — tax was raised to 10% after completion.
    function _catalogEntry() {
        return { productId: "PRD-001", name: "Rida", price: 20, taxable: true, taxPercent: 10 }
    }
    function _findOriginal(lines, productId) {
        for (var i = 0; i < lines.length; ++i)
            if (lines[i].productId === productId) return lines[i]
        return null
    }
    // Faithful mirror of the FIXED picker-append seed decision.
    function _seedReAddedLine(orderStatus, original, catalog) {
        var booked = orderStatus === "completed" ? _findOriginal(original, catalog.productId) : null
        return { productId: catalog.productId, name: catalog.name, price: catalog.price, quantity: 1,
                 discountType: "flat", discountValue: 0,
                 taxable: booked ? !!booked.taxable : !!catalog.taxable,
                 taxPercent: booked ? (booked.taxPercent || 0) : (catalog.taxPercent || 0) }
    }

    // FIX: re-adding a booked product on a completed order keeps booked 0% tax,
    // so the order total reconciles with the immutable ledger (tax 0).
    function test_readd_completed_keeps_booked_tax() {
        var line = _seedReAddedLine("completed", _originalLines(), _catalogEntry())
        compare(line.taxable, false, "re-added completed line inherits booked taxable=false")
        var alloc = OM.allocate({ products: [line] })
        compare(_round2(alloc.totals.tax), 0, "order total tax == ledger tax (0) — time-of-supply")
        compare(_round2(alloc.totals.total), 20, "total is the booked 20, not 22")
    }

    // A genuinely NEW product (no booked line) on a completed order gets current tax.
    function test_new_product_completed_gets_current_tax() {
        var newCat = { productId: "PRD-NEW", name: "Bag", price: 100, taxable: true, taxPercent: 10 }
        var line = _seedReAddedLine("completed", _originalLines(), newCat)
        compare(line.taxable, true, "new product on completed order uses current rate")
        var alloc = OM.allocate({ products: [line] })
        compare(_round2(alloc.totals.tax), 10, "new supply taxed at current 10%")
    }

    // Pending order always uses the current catalog rate (not yet supplied).
    function test_pending_uses_current_tax() {
        var line = _seedReAddedLine("pending", _originalLines(), _catalogEntry())
        compare(line.taxable, true, "pending order line uses current catalog tax")
        compare(_round2(OM.allocate({ products: [line] }).totals.tax), 2, "pending taxed at 10%")
    }

    // The diff is still "no change" for a pure re-add — the fix works WITHOUT
    // making diffLines tax-aware; the total is ledger-consistent so nothing to adjust.
    function test_diff_sees_no_change_on_pure_readd() {
        var reAdded = [_seedReAddedLine("completed", _originalLines(), _catalogEntry())]
        var d = OA.diffLines(_originalLines(), reAdded)
        compare(d.length, 0, "pure re-add at booked tax is a no-op diff (no spurious adjustment)")
    }

    // ── Persisted total reconciles with the ledger (TransactionStore.totalsForOrder) ──
    // Mirror of totalsForOrder: tax = Σ sale/return e.tax; net = Σ sale/return e.net
    // + Σ price_adjust e.total; total = net + tax. (TransactionStore can't load
    // headlessly.) Scenario: qty raised 1→2 after a 0%→10% tax change — the
    // original sale event booked tax 0, the ADDED unit's sale event booked tax 2.
    function _totalsForOrder(events) {
        var net = 0, tax = 0
        for (var i = 0; i < events.length; ++i) {
            var e = events[i]
            if (e.kind === "sale" || e.kind === "return") {
                net += (e.net !== undefined && e.net !== null) ? e.net : 0
                tax += (e.tax !== undefined && e.tax !== null) ? e.tax : 0
            } else if (e.kind === "price_adjust") {
                net += (e.total || 0)
            }
        }
        net = _round2(net); tax = _round2(tax)
        return { net: net, tax: tax, total: _round2(net + tax) }
    }

    function test_ledger_total_includes_added_unit_tax() {
        var events = [
            // original unit, booked tax-free at completion.
            { kind:"sale", orderId:"ORD-1", productId:"PRD-001", net:20, tax:0 },
            // unit added after the tax change → its own sale event at 10%.
            { kind:"sale", orderId:"ORD-1", productId:"PRD-001", net:20, tax:2 }
        ]
        var t = _totalsForOrder(events)
        compare(t.tax, 2, "ledger tax = 0 (original) + 2 (added unit) — order must show this")
        compare(t.net, 40, "ledger net = 40")
        compare(t.total, 42, "order total reconciles with ledger/reports (42), not 40")
    }

    // The live PREVIEW (per-line vintage split) must forecast the same 42 before
    // Save — original 1 unit @0% + added 1 unit @10% on a 20-each line.
    function test_preview_vintage_split_matches_ledger() {
        var line = { productId:"PRD-001", name:"Rida", price:20, quantity:2,
                     discountType:"flat", discountValue:0, taxable:true, taxPercent:10 }
        var previewTax = OM.lineTax(line, { originalQty: 1, bookedRate: 0 })
        compare(_round2(previewTax), 2, "preview forecasts added-unit tax (2) == ledger tax")
        var subtotalLessDisc = 40
        compare(_round2(subtotalLessDisc + previewTax), 42, "preview total == ledger total (42)")
    }

    // A price_adjust (revenue-only, no tax field) folds its delta into net so the
    // order total doesn't drop a discount/price edit.
    function test_ledger_total_folds_price_adjust_into_net() {
        var events = [
            { kind:"sale", orderId:"ORD-2", productId:"PRD-001", net:20, tax:2 },
            { kind:"price_adjust", orderId:"ORD-2", productId:"PRD-001", total:-5, reason:"discount" }
        ]
        var t = _totalsForOrder(events)
        compare(t.net, 15, "price_adjust -5 folds into net (20-5)")
        compare(t.tax, 2, "price_adjust has no tax field → tax unchanged")
        compare(t.total, 17, "total = 15 + 2")
    }

    // ── Live preview (recomputeSubtotal) — the screenshot scenario ──
    // Completed order: line booked at 0% (re-add seeds booked rate), product's
    // CURRENT rate now 10%, qty raised 1→2, flat discount 2. The preview must
    // resolve the current rate (not the line's booked 0%), forecast tax on the
    // added unit, AND build a Tax breakdown row so it renders. Mirrors
    // recomputeSubtotal's completed-order branch (InventoryStore can't load here,
    // so the current rate is injected the way the dialog reads it from inventory).
    function _previewCompleted(lineArr, originalLines, currentRateByPid) {
        var vintageTax = 0, dominantRate = 0
        for (var i = 0; i < lineArr.length; ++i) {
            var ln = lineArr[i]
            var booked = null
            for (var b = 0; b < originalLines.length; ++b)
                if (originalLines[b].productId === ln.productId) { booked = originalLines[b]; break }
            var curRate = currentRateByPid[ln.productId] || 0
            vintageTax += OM.lineTax(ln, {
                    originalQty: booked ? (booked.quantity || 0) : 0,
                    bookedRate: (booked && booked.taxable) ? (booked.taxPercent || 0) : 0,
                    currentRate: curRate })
            if (curRate > dominantRate) dominantRate = curRate
        }
        vintageTax = _round2(vintageTax)
        return { tax: vintageTax,
                 breakdown: vintageTax > 0 ? [{ rate: dominantRate, amount: vintageTax }] : [],
                 dominantRate: dominantRate }
    }

    function test_preview_shows_tax_row_for_added_unit() {
        // Re-added line carries BOOKED tax (false/0%); qty 2; flat discount 2.
        var lineArr = [{ productId: "PRD-001", name: "Rida", price: 20, quantity: 2,
                         discountType: "flat", discountValue: 2, taxable: false, taxPercent: 0 }]
        var originalLines = [{ productId: "PRD-001", name: "Rida", quantity: 1,
                               taxable: false, taxPercent: 0 }]
        var current = { "PRD-001": 10 }   // product's current rate after the change
        var p = _previewCompleted(lineArr, originalLines, current)
        // net 38, per-unit 19; original 1 @0% + added 1 @10% = 1.9.
        compare(_round2(p.tax), 1.9, "preview forecasts tax on the added unit (was 0 — the screenshot bug)")
        compare(p.breakdown.length, 1, "a Tax row is produced so it renders")
        compare(p.breakdown[0].rate, 10, "row labelled with the current rate")
        compare(_round2(p.breakdown[0].amount), 1.9, "row amount == forecast tax")
    }

    function test_preview_no_tax_row_when_zero() {
        // No tax anywhere → no row (stays hidden).
        var lineArr = [{ productId: "PRD-001", name: "Rida", price: 20, quantity: 2,
                         discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }]
        var originalLines = [{ productId: "PRD-001", name: "Rida", quantity: 1,
                               taxable: false, taxPercent: 0 }]
        var p = _previewCompleted(lineArr, originalLines, { "PRD-001": 0 })
        compare(_round2(p.tax), 0)
        compare(p.breakdown.length, 0, "no Tax row when forecast is 0")
    }
}
