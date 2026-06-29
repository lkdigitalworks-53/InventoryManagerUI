import QtQuick
import QtTest
import "../qml/helper/OrderMath.js" as OM

// Reproduction of the exported Realised-profit "Rida = 68.67 / discount 0"
// discrepancy using the REAL order data from orders_20260623_174420.xlsx.
// Replicates the production pipeline with CURRENT code:
//   1. OrderMath.allocate(order)  → per-line net / discountShare
//   2. recordSaleFromOrder stamps each sale event: net = perLine.net,
//      discountShare = perLine.discountShare, consumption = line.consumption
//   3. realisedProfitByDimension reads e.net and scales per consumption row
//      by qtyConsumed / lineQty; discount = e.discountShare * frac.
// Ground truth (Rida, unit cost 10):
//   ORD-001: qty1 @20 flat 2 → net 18, profit 8
//   ORD-003: qty3 @18 flat 5 → net 49, profit 19
//   ⇒ Rida net 67, discount 7, profit 27
TestCase {
    name: "RealisedProfitRepro"

    function _round2(x) { return Math.round(x * 100) / 100 }

    // Mirror TransactionStore.recordSaleFromOrder's stamping.
    function _stampEvents(order) {
        var alloc = OM.allocate(order)
        var byPid = {}
        for (var a = 0; a < alloc.perLine.length; ++a) byPid[alloc.perLine[a].productId] = alloc.perLine[a]
        var events = []
        for (var i = 0; i < order.products.length; ++i) {
            var p = order.products[i]
            var qty = p.quantity || 0
            if (!qty) continue
            var al = byPid[p.productId] || { net: qty * (p.price || 0), tax: 0, discountShare: 0 }
            events.push({
                kind: "sale", productId: p.productId,
                net: al.net, tax: al.tax, discountShare: al.discountShare,
                consumption: (p.consumption || []).slice()
            })
        }
        return events
    }

    // Mirror InventoryStore.realisedProfitByDimension's per-product aggregation
    // (the consumption-scaling branch).
    function _realisedByProduct(events) {
        var out = {}
        for (var i = 0; i < events.length; ++i) {
            var e = events[i]
            var c = e.consumption || []
            var lineQty = 0
            for (var q = 0; q < c.length; ++q) lineQty += (c[q].qtyConsumed || 0)
            var evNet = e.net, evDisc = e.discountShare
            for (var ci = 0; ci < c.length; ++ci) {
                var cc = c[ci]
                var qty = cc.qtyConsumed || 0
                if (qty === 0) continue
                var frac = lineQty !== 0 ? (qty / lineQty) : 0
                var revenue = evNet * frac
                var cogs = qty * (cc.unitCost || 0)
                var discAmt = (evDisc || 0) * frac
                var key = e.productId
                if (!out[key]) out[key] = { revenue: 0, cogs: 0, profit: 0, discount: 0 }
                out[key].revenue += revenue
                out[key].cogs += cogs
                out[key].profit += (revenue - cogs)
                out[key].discount += discAmt
            }
        }
        return out
    }

    // Order-sourced Totals (mirrors _exportTotalsBlock no-filter path): sum
    // allocate().totals over completed orders.
    function _totalsBlock(orders) {
        var net = 0, disc = 0, cogs = 0, profit = 0
        for (var i = 0; i < orders.length; ++i) {
            var a = OM.allocate(orders[i])
            net += a.totals.net; disc += a.totals.discount
            cogs += a.totals.cogs; profit += a.totals.profit
        }
        return { net: net, disc: disc, cogs: cogs, profit: profit }
    }

    // Event-sourced profit (mirrors _profitBucketWalk via eventProfit).
    function _eventProfitTotal(events) {
        var p = 0
        for (var i = 0; i < events.length; ++i) p += OM.eventProfit(events[i], "")
        return p
    }

    // The three full orders, exactly as the export ground truth.
    function _allOrders() {
        return [
            { orderId: "ORD-001", products: [
                { productId: "PRD-001", name: "Rida", price: 20, quantity: 1,
                  taxable: false, taxPercent: 0, discountType: "flat", discountValue: 2,
                  consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 10 }] }
            ] },
            { orderId: "ORD-002", products: [
                { productId: "PRD-002", name: "Bag", price: 200, quantity: 1,
                  taxable: false, taxPercent: 0, discountType: "percent", discountValue: 10,
                  consumption: [{ batchId: "B2", supplierId: "S2", qtyConsumed: 1, unitCost: 100 }] }
            ] },
            { orderId: "ORD-003", products: [
                { productId: "PRD-001", name: "Rida", price: 18, quantity: 3,
                  taxable: false, taxPercent: 0, discountType: "flat", discountValue: 5,
                  consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 3, unitCost: 10 }] },
                { productId: "PRD-002", name: "Bag", price: 180, quantity: 1,
                  taxable: false, taxPercent: 0, discountType: "percent", discountValue: 5,
                  consumption: [{ batchId: "B2", supplierId: "S2", qtyConsumed: 1, unitCost: 100 }] }
            ] }
        ]
    }

    // All three current-code paths must agree (no 178-vs-179.67 split).
    function test_all_paths_reconcile() {
        var orders = _allOrders()
        var events = []
        for (var i = 0; i < orders.length; ++i) events = events.concat(_stampEvents(orders[i]))

        var tb = _totalsBlock(orders)
        compare(_round2(tb.net), 418, "Totals net = 418")
        compare(_round2(tb.disc), 36, "Totals discount = 36")
        compare(_round2(tb.profit), 178, "Totals profit = 178")

        // Event-sourced profit must equal the order-sourced Totals profit.
        compare(_round2(_eventProfitTotal(events)), 178, "eventProfit total = Totals profit (178), NOT 179.67")

        // Realised-by-product must reconcile too.
        var byProd = _realisedByProduct(events)
        var sumNet = 0, sumDisc = 0, sumProfit = 0
        var keys = Object.keys(byProd)
        for (var k = 0; k < keys.length; ++k) { sumNet += byProd[keys[k]].revenue; sumDisc += byProd[keys[k]].discount; sumProfit += byProd[keys[k]].profit }
        compare(_round2(sumNet), 418, "realised by-product net total = 418")
        compare(_round2(sumDisc), 36, "realised by-product discount total = 36 (NOT 0)")
        compare(_round2(sumProfit), 178, "realised by-product profit total = 178 (NOT 179.67)")
    }

    // Rida line carries FIFO consumption summing to its qty, unit cost 10.
    function test_rida_realised_reconciles_to_67() {
        var ord1 = { orderId: "ORD-001", products: [
            { productId: "PRD-001", name: "Rida", price: 20, quantity: 1,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 2,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 10 }] }
        ] }
        var ord3 = { orderId: "ORD-003", products: [
            { productId: "PRD-001", name: "Rida", price: 18, quantity: 3,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 5,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 3, unitCost: 10 }] },
            { productId: "PRD-002", name: "Bag", price: 180, quantity: 1,
              taxable: false, taxPercent: 0, discountType: "percent", discountValue: 5,
              consumption: [{ batchId: "B2", supplierId: "S2", qtyConsumed: 1, unitCost: 100 }] }
        ] }
        var events = _stampEvents(ord1).concat(_stampEvents(ord3))
        var byProd = _realisedByProduct(events)
        var rida = byProd["PRD-001"]
        compare(_round2(rida.revenue), 67, "Rida realised net revenue must be 67 (18+49)")
        compare(_round2(rida.discount), 7, "Rida realised discount must be 7 (2+5)")
        compare(_round2(rida.profit), 27, "Rida realised profit must be 27 (8+19)")
    }
}
