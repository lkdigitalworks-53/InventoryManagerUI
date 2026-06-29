import QtQuick
import QtTest
import "../qml/helper/OrderMath.js" as OM

TestCase {
    name: "OrderMath"

    function _order(lines, dType, dVal) {
        return { products: lines, discountType: dType || "flat", discountValue: dVal || 0 }
    }

    function _round2(x) { return Math.round(x * 100) / 100 }

    // Flat per-line discount: line A ₹100×2 −₹10; line B ₹50×1 −₹0.
    function test_flat_per_line_discount() {
        var order = { products: [
            { productId: "A", name: "A", quantity: 2, price: 100,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 10 },
            { productId: "B", name: "B", quantity: 1, price: 50,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }
        ] }
        var a = OM.allocate(order)
        compare(a.totals.gross, 250, "gross = 200 + 50")
        compare(a.totals.discount, 10, "discount = sum of line discounts")
        compare(a.totals.net, 240, "net = gross - discount")
        compare(a.perLine[0].discountShare, 10, "line A keeps its own ₹10")
        compare(a.perLine[1].discountShare, 0, "line B has no discount")
    }

    // Percent per-line discount: line A ₹100×2 −10% = −₹20.
    function test_percent_per_line_discount() {
        var order = { products: [
            { productId: "A", name: "A", quantity: 2, price: 100,
              taxable: false, taxPercent: 0, discountType: "percent", discountValue: 10 }
        ] }
        var a = OM.allocate(order)
        compare(a.totals.discount, 20, "10% of 200")
        compare(a.totals.net, 180, "net = 200 - 20")
    }

    // Tax is on the discounted net, and excluded from net/revenue.
    function test_tax_on_net_excluded_from_revenue() {
        var order = { products: [
            { productId: "A", name: "A", quantity: 1, price: 100,
              taxable: true, taxPercent: 18, discountType: "flat", discountValue: 10 }
        ] }
        var a = OM.allocate(order)
        compare(a.totals.net, 90, "net excludes tax")
        compare(_round2(a.totals.tax), 16.2, "tax = 18% of 90")
        compare(_round2(a.totals.total), 106.2, "total = net + tax")
    }

    // Reconciliation invariant: sum of line nets + sum of line discounts == gross.
    function test_reconciliation() {
        var order = { products: [
            { productId: "A", name: "A", quantity: 3, price: 33,
              taxable: true, taxPercent: 5, discountType: "percent", discountValue: 7 },
            { productId: "B", name: "B", quantity: 2, price: 49.5,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 4.5 }
        ] }
        var a = OM.allocate(order)
        var sumNet = 0, sumDisc = 0
        for (var i = 0; i < a.perLine.length; ++i) {
            sumNet += a.perLine[i].net
            sumDisc += a.perLine[i].discountShare
        }
        compare(_round2(sumNet + sumDisc), a.totals.gross, "nets + discounts reconcile to gross")
    }

    // A flat line discount never exceeds the line gross (clamp).
    function test_flat_discount_clamped_to_line_gross() {
        var order = { products: [
            { productId: "A", name: "A", quantity: 1, price: 30,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 100 }
        ] }
        var a = OM.allocate(order)
        compare(a.totals.discount, 30, "clamped to line gross")
        compare(a.totals.net, 0, "net floored at 0")
    }

    // allocate().totals equals computeOrderTotals for the same input (oracle check
    // is added in tst against OrdersStore is impossible headless; assert internal
    // consistency of total = net + tax instead).
    function test_total_equals_net_plus_tax() {
        var o = _order([{ productId: "P1", name: "A", price: 100, quantity: 2, taxable: true, taxPercent: 18, discountType: "flat", discountValue: 50 }])
        var a = OM.allocate(o)
        fuzzyCompare(a.totals.total, a.totals.net + a.totals.tax, 0.001)
    }

    // Multi-supplier consumption: per-consumption net sums to line net; cogs per batch.
    function test_consumption_split_multi_supplier() {
        var o = _order([{
            productId: "P1", name: "A", price: 100, quantity: 5, taxable: true, taxPercent: 10,
            discountType: "flat", discountValue: 50,
            consumption: [
                { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 40 },
                { batchId: "B2", supplierId: "S2", qtyConsumed: 3, unitCost: 50 }
            ]
        }])
        var a = OM.allocate(o)
        var line = a.perLine[0]
        // line: gross 500, discount 50, net 450, tax 45.
        compare(line.net, 450)
        var sumNet = 0, sumCogs = 0
        for (var i = 0; i < line.perConsumption.length; ++i) {
            sumNet += line.perConsumption[i].net
            sumCogs += line.perConsumption[i].cogs
        }
        fuzzyCompare(sumNet, line.net, 0.0001)        // children re-sum to parent
        compare(sumCogs, 2 * 40 + 3 * 50)             // 80 + 150 = 230
        compare(a.totals.cogs, 230)
        fuzzyCompare(a.totals.profit, 450 - 230, 0.011)
    }

    // Pre-FIFO line (no consumption): perConsumption empty, totals still balance, cogs 0.
    function test_consumption_pre_fifo_empty() {
        var o = _order([{ productId: "P1", name: "A", price: 100, quantity: 2, taxable: false, taxPercent: 0 }])
        var a = OM.allocate(o)
        compare(a.perLine[0].perConsumption.length, 0)
        compare(a.totals.cogs, 0)
        compare(a.totals.net, 200)
        compare(a.totals.profit, 200)  // no cogs known
    }

    // Odd 3-way split: remainder lands on the largest row; children re-sum exactly.
    function test_consumption_rounding_remainder() {
        var o = _order([{
            productId: "P1", name: "A", price: 10, quantity: 3, taxable: false, taxPercent: 0,
            discountType: "flat", discountValue: 1,
            consumption: [
                { batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 1 },
                { batchId: "B2", supplierId: "S2", qtyConsumed: 1, unitCost: 1 },
                { batchId: "B3", supplierId: "S3", qtyConsumed: 1, unitCost: 1 }
            ]
        }])  // net 29 over 3 units → 9.67/9.67/9.66 style split
        var a = OM.allocate(o)
        var line = a.perLine[0]
        var sumNet = 0
        for (var i = 0; i < line.perConsumption.length; ++i) sumNet += line.perConsumption[i].net
        fuzzyCompare(sumNet, line.net, 0.0001)  // exact re-sum after remainder assignment
    }

    // Partial fulfillment: only consumed portion attributed; unconsumed stays unallocated.
    function test_consumption_partial_fulfillment() {
        var o = _order([{
            productId: "P1", name: "A", price: 100, quantity: 5, taxable: false, taxPercent: 0,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 3, unitCost: 40 }]
        }], "flat", 0)
        var a = OM.allocate(o)
        var line = a.perLine[0]
        compare(line.net, 500)                       // 5 * 100
        compare(line.perConsumption[0].net, 300)     // 3/5 * 500
        compare(line.perConsumption[0].cogs, 120)    // 3 * 40
    }

    // Realised-profit building blocks: a sale event's net/cogs/profit equal the
    // allocated per-consumption values the store will sum.
    function test_event_allocation_reconciles_for_profit() {
        var o = _order([{
            productId: "P1", name: "A", price: 100, quantity: 4, taxable: true, taxPercent: 5,
            discountType: "flat", discountValue: 20,
            consumption: [
                { batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 60 }
            ]
        }])
        var a = OM.allocate(o)
        var pc = a.perLine[0].perConsumption[0]
        // net 80, cogs 240? no: gross 400, disc 20, net 380, cogs 240, profit 140.
        compare(a.perLine[0].net, 380)
        compare(pc.cogs, 240)
        fuzzyCompare(pc.profit, 140, 0.001)
        fuzzyCompare(pc.tax, 19, 0.001)   // 380 * 5%
    }

    // Refund for returned units = their net + tax (what the customer paid).
    function test_refund_includes_tax_and_discount() {
        var o = _order([{ productId:"P1", name:"A", price:100, quantity:4, taxable:true, taxPercent:10,
                          discountType:"flat", discountValue:40,
                          consumption:[{batchId:"B1",supplierId:"S1",qtyConsumed:4,unitCost:50}] }])
        var a = OM.allocate(o)
        // line: gross 400, disc 40, net 360, tax 36. Per unit: net 90, tax 9.
        // Return 2 units → refund = 2*(90+9) = 198.
        var pl = a.perLine[0]
        var perUnitNet = pl.net / pl.qty
        var perUnitTax = pl.tax / pl.qty
        fuzzyCompare((perUnitNet + perUnitTax) * 2, 198, 0.001)
    }

    // The line-level net/tax/discount a sale event stamps for a whole line.
    function test_sale_event_line_stamp() {
        var o = _order([
            { productId: "P1", name: "A", price: 100, quantity: 2, taxable: true, taxPercent: 10,
              discountType: "percent", discountValue: 10,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 50 }] }
        ])
        var a = OM.allocate(o)
        // gross 200, disc 20, net 180, tax 18.
        compare(a.perLine[0].net, 180)
        fuzzyCompare(a.perLine[0].tax, 18, 0.001)
        compare(a.perLine[0].discountShare, 20)
    }

    // Bug 3: units ADDED to a completed order after the product's tax changed
    // are booked as a SEPARATE sale event carrying the product's CURRENT tax.
    // That event (a one-line synthetic order) must allocate the new tax — the
    // old code passed no tax fields, so allocate booked tax 0 ("tax not
    // applied"). Originals keep their own immutable event, unchanged.
    function test_added_units_event_uses_current_tax() {
        // Product became taxable @ 18% AFTER completion; 2 units added @ ₹100.
        var addedEvent = _order([
            { productId: "P1", name: "A", price: 100, quantity: 2, taxable: true, taxPercent: 18,
              consumption: [{ batchId: "B9", supplierId: "S1", qtyConsumed: 2, unitCost: 60 }] }
        ], "flat", 0)
        var a = OM.allocate(addedEvent)
        compare(a.perLine[0].net, 200)              // 2 × 100, no discount
        fuzzyCompare(a.perLine[0].tax, 36, 0.001)   // 200 × 18% — NOT 0
        fuzzyCompare(a.totals.tax, 36, 0.001)
        // Counterproof: if tax fields were omitted (the old bug), tax is 0.
        var untaxed = _order([
            { productId: "P1", name: "A", price: 100, quantity: 2,
              consumption: [{ batchId: "B9", supplierId: "S1", qtyConsumed: 2, unitCost: 60 }] }
        ], "flat", 0)
        compare(OM.allocate(untaxed).totals.tax, 0)
    }

    // OrderMath.eventProfit must read STAMPED event fields (net + per-row
    // qtyConsumed/unitCost) and yield the SAME profit InventoryStore sums —
    // without ever re-allocating the (possibly mutated) parent order. A sale
    // and its matching full return must cancel to exactly 0.
    function test_event_profit_reconciles() {
        // Sale: 4 units @ stamped net 380, consumption 4 @ cost 60.
        //   cogs = 4*60 = 240 ; profit = 380 - 240 = 140.
        var sale = {
            kind: "sale", productId: "P1", quantity: 4, unitPrice: 100, net: 380,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 60 }]
        }
        fuzzyCompare(OM.eventProfit(sale, ""), 140, 0.001)

        // Matching FULL return: negative qty, negative net, negative qtyConsumed.
        //   lineQty = -4 ; frac per row = -4/-4 = 1 ; rowNet = -380 ;
        //   rowCogs = -4*60 = -240 ; profit = -380 - (-240) = -140.
        var ret = {
            kind: "return", productId: "P1", quantity: -4, unitPrice: 100, net: -380,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: -4, unitCost: 60 }]
        }
        fuzzyCompare(OM.eventProfit(ret, ""), -140, 0.001)

        // Full reversal: sale + return == 0.
        fuzzyCompare(OM.eventProfit(sale, "") + OM.eventProfit(ret, ""), 0, 0.001)

        // Supplier filter: a single sale event whose consumption spans two
        // suppliers. lineQty = 4, stamped net 400.
        //   S1: 3 units @ cost 50 → rowNet = 400*(3/4) = 300 ; cogs = 3*50 = 150 ; profit 150.
        //   S2: 1 unit  @ cost 50 → rowNet = 400*(1/4) = 100 ; cogs = 1*50 = 50  ; profit  50.
        //   full (no filter) = 150 + 50 = 200.
        var split = {
            kind: "sale", productId: "P2", quantity: 4, unitPrice: 100, net: 400,
            consumption: [
                { batchId: "BA", supplierId: "S1", qtyConsumed: 3, unitCost: 50 },
                { batchId: "BB", supplierId: "S2", qtyConsumed: 1, unitCost: 50 }
            ]
        }
        fuzzyCompare(OM.eventProfit(split, "S1"), 150, 0.001)
        fuzzyCompare(OM.eventProfit(split, "S2"), 50, 0.001)
        fuzzyCompare(OM.eventProfit(split, ""), 200, 0.001)
        // Sum of supplier-filtered slices == full event profit.
        fuzzyCompare(OM.eventProfit(split, "S1") + OM.eventProfit(split, "S2"),
                     OM.eventProfit(split, ""), 0.001)

        // Unstamped (legacy) event: net absent → falls back to lineQty*unitPrice.
        //   lineQty = 2, unitPrice 100 → rowNet = 200 ; cogs = 2*40 = 80 ; profit 120.
        var legacy = {
            kind: "sale", productId: "P3", quantity: 2, unitPrice: 100,
            consumption: [{ batchId: "BC", supplierId: "S1", qtyConsumed: 2, unitCost: 40 }]
        }
        fuzzyCompare(OM.eventProfit(legacy, ""), 120, 0.001)
    }

    // Oracle: replicate InventoryStore.realisedProfitByDimension's inner
    // sale/return profit accumulation and assert it equals OM.eventProfit for
    // the SAME event — locking the two profit formulas together even though
    // the store wasn't refactored to call the helper (it also breaks out
    // revenue/cogs/tax/discount per dimension key, which eventProfit does not).
    function _storeProfit(e, supplierId) {
        // Mirrors InventoryStore.realisedProfitByDimension's sale/return loop
        // (profit portion only) VERBATIM — the frac guard is `lineQty !== 0`,
        // matching the fixed store, so a return (negative lineQty) reverses the
        // booked profit instead of zeroing the revenue and adding +cogs.
        var c = e.consumption || []
        var lineQty = 0
        for (var q = 0; q < c.length; ++q) lineQty += (c[q].qtyConsumed || 0)
        var evNet = (e.net !== undefined) ? e.net : (lineQty * (e.unitPrice || 0))
        var profit = 0
        for (var ci = 0; ci < c.length; ++ci) {
            var cc = c[ci]
            var qty = cc.qtyConsumed || 0
            if (qty === 0) continue
            if (supplierId && (cc.supplierId || "") !== supplierId) continue
            var frac = lineQty !== 0 ? (qty / lineQty) : 0
            var revenue = evNet * frac
            var cogs = qty * (cc.unitCost || 0)
            profit += (revenue - cogs)
        }
        return profit
    }
    function test_eventProfit_matches_store_formula() {
        var cases = [
            { kind:"sale", net:380, unitPrice:100,
              consumption:[{supplierId:"S1",qtyConsumed:4,unitCost:60}] },
            { kind:"return", net:-380, unitPrice:100,
              consumption:[{supplierId:"S1",qtyConsumed:-4,unitCost:60}] },
            { kind:"sale", net:400, unitPrice:100,
              consumption:[{supplierId:"S1",qtyConsumed:3,unitCost:50},
                           {supplierId:"S2",qtyConsumed:1,unitCost:50}] },
            { kind:"sale", unitPrice:100,   // legacy, net absent
              consumption:[{supplierId:"S1",qtyConsumed:2,unitCost:40}] }
        ]
        for (var i = 0; i < cases.length; ++i) {
            fuzzyCompare(OM.eventProfit(cases[i], ""), _storeProfit(cases[i], ""), 0.001)
            fuzzyCompare(OM.eventProfit(cases[i], "S1"), _storeProfit(cases[i], "S1"), 0.001)
            fuzzyCompare(OM.eventProfit(cases[i], "S2"), _storeProfit(cases[i], "S2"), 0.001)
        }
    }

    // Behavioral guard (independent of the oracle): a full return must REVERSE
    // the sale's profit — not add to it. This is the production bug the frac
    // guard caused; eventProfit and the fixed store both yield -140 on the
    // return so sale + return nets to exactly 0.
    function test_return_reverses_profit() {
        var sale = {
            kind: "sale", productId: "P1", quantity: 4, unitPrice: 100, net: 380,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 60 }]
        }
        var ret = {
            kind: "return", productId: "P1", quantity: -4, unitPrice: 100, net: -380,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: -4, unitCost: 60 }]
        }
        fuzzyCompare(OM.eventProfit(ret, ""), -140, 0.001)               // reverses, not +240
        fuzzyCompare(OM.eventProfit(sale, "") + OM.eventProfit(ret, ""), 0, 0.001)
    }

    function test_totals_block_aggregation() {
        var orders = [
            _order([{ productId:"P1", name:"A", price:100, quantity:2, taxable:true, taxPercent:10,
                      discountType:"flat", discountValue:20,
                      consumption:[{batchId:"B1",supplierId:"S1",qtyConsumed:2,unitCost:60}] }]),
            _order([{ productId:"P2", name:"B", price:50, quantity:4, taxable:false, taxPercent:0,
                      consumption:[{batchId:"B2",supplierId:"S2",qtyConsumed:4,unitCost:30}] }])
        ]
        var gross=0, disc=0, net=0, tax=0, cogs=0, profit=0
        for (var i=0;i<orders.length;++i) {
            var a = OM.allocate(orders[i])
            gross+=a.totals.gross; disc+=a.totals.discount; net+=a.totals.net
            tax+=a.totals.tax; cogs+=a.totals.cogs; profit+=a.totals.profit
        }
        compare(gross, 200 + 200)          // 400
        compare(disc, 20)
        compare(net, 380)                  // 180 + 200
        fuzzyCompare(tax, 18, 0.001)       // first order: net 180 *10%
        compare(cogs, 120 + 120)           // 240
        fuzzyCompare(profit, 380 - 240, 0.001)
    }

    // Profile/Dashboard KPIs (SalesStore): totalOrders = COUNT of completed
    // orders, totalRevenue = Σ allocate().totals.net (tax EXCLUDED) over the
    // SAME completed set. This mirrors SalesStore._rebuildDerivedData's loop so
    // the definition is locked: re-completing an order must not inflate the
    // count, and revenue must be net (matching Analysis/Dashboard), not o.total.
    function _kpis(orders) {
        var rev = 0, count = 0
        for (var i = 0; i < orders.length; ++i) {
            if (orders[i].status !== "completed") continue
            rev += OM.allocate(orders[i]).totals.net
            count += 1
        }
        return { totalOrders: count, totalRevenue: rev }
    }
    function test_sales_kpis_completed_only_and_net() {
        function ord(lines, status) {
            var o = { products: lines }; o.status = status; return o
        }
        var orders = [
            // Completed, taxable: gross 200, disc 20, net 180 (tax 18 EXCLUDED).
            ord([{ productId:"P1", name:"A", price:100, quantity:2, taxable:true, taxPercent:10, discountType:"flat", discountValue:20 }], "completed"),
            // Completed, no tax: net 200.
            ord([{ productId:"P2", name:"B", price:50, quantity:4, taxable:false, taxPercent:0 }], "completed"),
            // Pending — must be EXCLUDED from both count and revenue.
            ord([{ productId:"P3", name:"C", price:999, quantity:9, taxable:false, taxPercent:0 }], "pending")
        ]
        var k = _kpis(orders)
        compare(k.totalOrders, 2)                 // only the 2 completed
        fuzzyCompare(k.totalRevenue, 380, 0.001)  // 180 + 200, tax excluded
    }

    // Bug 14 (exchange): after an exchange, DataModel stamps the order line with
    // MERGED consumption — surviving original units + the added replacement
    // units' FIFO lineage (possibly a different batch/supplier). allocate() must
    // still reconcile: Σ perConsumption.net == line.net and COGS counts ALL
    // consumed units (including the replacement), so order-sourced profit is right.
    function test_exchange_merged_consumption_reconciles() {
        // A line of 4 units: 2 original (S1 @ 60) + 2 added replacement (S2 @ 70).
        var o = _order([{
            productId: "P1", name: "A", price: 100, quantity: 4, taxable: false, taxPercent: 0,
            consumption: [
                { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 60 },
                { batchId: "B2", supplierId: "S2", qtyConsumed: 2, unitCost: 70 }
            ]
        }], "flat", 0)
        var a = OM.allocate(o)
        var line = a.perLine[0]
        compare(line.net, 400)                     // 4 * 100, no discount
        var sumNet = 0, sumCogs = 0
        for (var i = 0; i < line.perConsumption.length; ++i) {
            sumNet += line.perConsumption[i].net
            sumCogs += line.perConsumption[i].cogs
        }
        fuzzyCompare(sumNet, line.net, 0.0001)     // children re-sum to parent
        compare(sumCogs, 2 * 60 + 2 * 70)          // 120 + 140 = 260 — replacement COGS counted
        compare(a.totals.cogs, 260)
        fuzzyCompare(a.totals.profit, 400 - 260, 0.001)   // 140 — not overstated
    }

    // Bug 15: an order-wide discount delta (price_adjust, productId "") must
    // spread across the order's REAL products/categories/suppliers pro-rata,
    // not land in a single "(uncategorised)" / "" bucket. spreadOrderDelta is
    // the pure helper the profit report uses.
    function test_spread_order_delta_by_product() {
        // Order: P1 gross 200 (Drinks), P2 gross 100 (Snacks). Discount delta −15.
        var o = _order([
            { productId: "P1", name: "A", price: 100, quantity: 2, taxable: false, taxPercent: 0 },
            { productId: "P2", name: "B", price: 100, quantity: 1, taxable: false, taxPercent: 0 }
        ], "flat", 0)
        var slices = OM.spreadOrderDelta(o, -15, "productId", null)
        // P1 gets 2/3 of −15 = −10 ; P2 gets 1/3 = −5. Sum = −15.
        var byKey = {}
        var sum = 0
        for (var i = 0; i < slices.length; ++i) { byKey[slices[i].key] = slices[i].amount; sum += slices[i].amount }
        fuzzyCompare(byKey["P1"], -10, 0.001)
        fuzzyCompare(byKey["P2"], -5, 0.001)
        fuzzyCompare(sum, -15, 0.001)            // reconciles to the whole delta
        // No bogus empty / "(uncategorised)" bucket.
        verify(byKey[""] === undefined)
    }

    function test_spread_order_delta_by_category() {
        var o = _order([
            { productId: "P1", name: "A", price: 100, quantity: 2, taxable: false, taxPercent: 0 },
            { productId: "P2", name: "B", price: 100, quantity: 1, taxable: false, taxPercent: 0 }
        ], "flat", 0)
        var cat = { P1: "Drinks", P2: "Snacks" }
        var slices = OM.spreadOrderDelta(o, -15, "category", function(pid) { return cat[pid] })
        var byKey = {}, sum = 0
        for (var i = 0; i < slices.length; ++i) { byKey[slices[i].key] = (byKey[slices[i].key]||0) + slices[i].amount; sum += slices[i].amount }
        fuzzyCompare(byKey["Drinks"], -10, 0.001)
        fuzzyCompare(byKey["Snacks"], -5, 0.001)
        fuzzyCompare(sum, -15, 0.001)
    }

    function test_spread_order_delta_by_supplier() {
        // Single line, 3 units split across two suppliers' consumption.
        var o = _order([{
            productId: "P1", name: "A", price: 100, quantity: 3, taxable: false, taxPercent: 0,
            consumption: [
                { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 40 },
                { batchId: "B2", supplierId: "S2", qtyConsumed: 1, unitCost: 40 }
            ]
        }], "flat", 0)
        // Use the SAME dim string the production caller passes ("supplierId").
        var slices = OM.spreadOrderDelta(o, -30, "supplierId", null)
        var byKey = {}, sum = 0
        for (var i = 0; i < slices.length; ++i) { byKey[slices[i].key] = (byKey[slices[i].key]||0) + slices[i].amount; sum += slices[i].amount }
        fuzzyCompare(byKey["S1"], -20, 0.001)    // 2/3 of −30
        fuzzyCompare(byKey["S2"], -10, 0.001)    // 1/3 of −30
        fuzzyCompare(sum, -30, 0.001)
        // The legacy "supplier" spelling must still work (alias).
        var slices2 = OM.spreadOrderDelta(o, -30, "supplier", null)
        var sum2 = 0
        for (var j = 0; j < slices2.length; ++j) sum2 += slices2[j].amount
        fuzzyCompare(sum2, -30, 0.001)
    }

    // Per-line price modify: a price_adjust on ONE product (real productId, no
    // own consumption) must spread its delta across THAT line's supplier
    // consumption, not dump into a bogus "Unknown" row (the chart/export bug).
    function test_spread_line_delta_by_supplier() {
        // Order: P1 across two suppliers (S1:2, S2:1); P2 single supplier.
        var o = _order([
            { productId: "P1", name: "A", price: 100, quantity: 3, taxable: false, taxPercent: 0,
              consumption: [
                  { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 40 },
                  { batchId: "B2", supplierId: "S2", qtyConsumed: 1, unitCost: 40 }
              ] },
            { productId: "P2", name: "B", price: 50, quantity: 2, taxable: false, taxPercent: 0,
              consumption: [{ batchId: "B3", supplierId: "S3", qtyConsumed: 2, unitCost: 20 }] }
        ], "flat", 0)
        // Price modify on P1 only: −30 revenue delta.
        var slices = OM.spreadLineDeltaBySupplier(o, "P1", -30)
        var byKey = {}, sum = 0
        for (var i = 0; i < slices.length; ++i) { byKey[slices[i].key] = (byKey[slices[i].key]||0) + slices[i].amount; sum += slices[i].amount }
        fuzzyCompare(byKey["S1"], -20, 0.001)    // 2/3 of −30 (P1's split)
        fuzzyCompare(byKey["S2"], -10, 0.001)    // 1/3 of −30
        verify(byKey["S3"] === undefined)        // P2's supplier untouched
        verify(byKey[""] === undefined)          // no "Unknown" bucket
        fuzzyCompare(sum, -30, 0.001)            // reconciles to the whole delta
    }

    // Pre-FIFO line (no consumption) → helper returns empty so the caller
    // falls back to the "Unknown" bucket (best-effort, documented).
    function test_spread_line_delta_pre_fifo_empty() {
        var o = _order([{ productId: "P1", name: "A", price: 100, quantity: 2, taxable: false, taxPercent: 0 }], "flat", 0)
        var slices = OM.spreadLineDeltaBySupplier(o, "P1", -10)
        compare(slices.length, 0)
    }

    // SITE 6: refund per-unit must come from the ORIGINAL sale event's stamped
    // net+tax, so a 2nd adjustment (return) refunds at the original-sale rate,
    // not a live order already discounted by adjustment #1.
    function test_refund_per_unit_from_original_sale_event() {
        // Original sale: 4 units, line net 360 (after a ₹40 discount), tax 36.
        // Per-unit refund the customer is owed = (360 + 36)/4 = 99.
        var saleEvent = { kind: "sale", productId: "P1", quantity: 4, net: 360, tax: 36,
                          consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 50 }] }
        fuzzyCompare(OM.refundPerUnit(saleEvent), 99, 0.001, "refund/unit = (net+tax)/qty of ORIGINAL sale")

        // Counterproof: the LIVE order after adjustment #1 added a deeper discount
        // (net now 320). Allocating it would refund at 320/4 = 80 — the wrong,
        // post-edit rate. refundPerUnit ignores the live order entirely.
        var liveAfterAdjust1 = _order([{ productId: "P1", name: "A", price: 100, quantity: 4,
              taxable: true, taxPercent: 10, discountType: "flat", discountValue: 80,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 50 }] }])
        var liveAlloc = OM.allocate(liveAfterAdjust1).perLine[0]
        var liveRate = (liveAlloc.net + liveAlloc.tax) / liveAlloc.qty
        verify(Math.abs(liveRate - OM.refundPerUnit(saleEvent)) > 1)  // they DIFFER — proves SITE 6 matters
    }

    // Guards: zero/empty qty → 0 (caller falls back to its old per-unit price).
    function test_refund_per_unit_guards() {
        compare(OM.refundPerUnit(null), 0)
        compare(OM.refundPerUnit({ quantity: 0, net: 100, tax: 0 }), 0)
        compare(OM.refundPerUnit({ quantity: 2 }), 0)   // no net/tax stamped → 0
    }

    // ── lineTax: single-rate (no opts) == legacy per-line tax (regression guard) ──
    function test_lineTax_single_rate_matches_legacy() {
        var ln = { quantity: 2, price: 20, taxable: true, taxPercent: 10,
                   discountType: "flat", discountValue: 0 }
        fuzzyCompare(OM.lineTax(ln), 4, 0.001, "net 40 * 10% = 4")
        compare(OM.lineTax({ quantity: 2, price: 20, taxable: false, taxPercent: 10 }), 0)
        fuzzyCompare(OM.lineTax({ quantity: 2, price: 20, taxable: true, taxPercent: 10,
                                  discountType: "flat", discountValue: 5 }), 3.5, 0.001,
                     "discounted net 35 * 10% = 3.5")
    }

    // ── lineTax: vintage split (completed order, mid-life tax change) ──
    function test_lineTax_vintage_split() {
        var ln = { quantity: 2, price: 20, taxable: true, taxPercent: 10,
                   discountType: "flat", discountValue: 0 }
        // 1 unit booked @0% + 1 unit added @10% (per-unit net 20) → 2.
        fuzzyCompare(OM.lineTax(ln, { originalQty: 1, bookedRate: 0 }), 2, 0.001)
        // No added units → all at booked 0% → 0.
        fuzzyCompare(OM.lineTax(ln, { originalQty: 2, bookedRate: 0 }), 0, 0.001)
        // originalQty > qty clamps (return) → all booked.
        fuzzyCompare(OM.lineTax(ln, { originalQty: 5, bookedRate: 0 }), 0, 0.001)
        // Non-zero booked rate: orig 1@5% (=1) + added 1@10% (=2) → 3.
        fuzzyCompare(OM.lineTax(ln, { originalQty: 1, bookedRate: 5 }), 3, 0.001)
        // Discount per vintage: net (40-10)=30, per-unit 15 → orig 0 + added 1.5.
        fuzzyCompare(OM.lineTax({ quantity: 2, price: 20, taxable: true, taxPercent: 10,
                                  discountType: "flat", discountValue: 10 },
                                { originalQty: 1, bookedRate: 0 }), 1.5, 0.001)
    }

    function test_lineTax_zero_qty_guard() {
        compare(OM.lineTax({ quantity: 0, price: 20, taxable: true, taxPercent: 10 },
                           { originalQty: 0, bookedRate: 0 }), 0)
    }

    // ── lineTax: explicit currentRate (re-added booked line stores BOOKED rate) ──
    // The defect: a re-added completed-order line is seeded with the BOOKED rate
    // (taxable:false/0%), so reading line.taxPercent for added units yields 0.
    // currentRate supplies the product's current rate for the added vintage.
    function test_lineTax_explicit_current_rate() {
        // Line stores booked 0% (taxable false), qty 2, 1 original + 1 added.
        var bookedSeeded = { quantity: 2, price: 20, taxable: false, taxPercent: 0,
                             discountType: "flat", discountValue: 0 }
        // WITHOUT currentRate: added unit falls back to line rate (0) → 0 (the bug).
        fuzzyCompare(OM.lineTax(bookedSeeded, { originalQty: 1, bookedRate: 0 }), 0, 0.001,
                     "booked-seeded line with no currentRate forecasts 0 (the reported bug)")
        // WITH currentRate 10: added 1 unit @10% on per-unit net 20 → 2.
        fuzzyCompare(OM.lineTax(bookedSeeded, { originalQty: 1, bookedRate: 0, currentRate: 10 }), 2, 0.001,
                     "currentRate taxes the added unit even though the line stores booked 0%")
        // currentRate 0 explicitly → 0 (e.g. product now non-taxable).
        fuzzyCompare(OM.lineTax(bookedSeeded, { originalQty: 1, bookedRate: 0, currentRate: 0 }), 0, 0.001)
        // With a flat discount 2: net 38, per-unit 19; added 1 @10% = 1.9.
        fuzzyCompare(OM.lineTax({ quantity: 2, price: 20, taxable: false, taxPercent: 0,
                                  discountType: "flat", discountValue: 2 },
                                { originalQty: 1, bookedRate: 0, currentRate: 10 }), 1.9, 0.001,
                     "matches the screenshot scenario (qty 1->2, discount 2, tax 10%)")
    }
}
