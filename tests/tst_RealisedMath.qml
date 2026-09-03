import QtQuick
import QtTest
import "../qml/helper/RealisedMath.js" as RM
import "../qml/helper/OrderMath.js" as OM

// Real tests over the extracted event-log aggregator. These are NOT formula
// mirrors — they call the production RealisedMath functions directly. Covers:
//   A      — scope-filtered by-dimension reconciles to scope-filtered totals
//   C      — multi-batch FIFO split is cent-exact (remainder-to-largest)
//   D      — supplier-filtered gross == net + discount to the cent
//   SITE 4 — a no-`net` event fails closed to 0 (never re-allocates)
//   SITE 5 — Revenue (bucketWalk net) == totals.net == Σ byDimension net
//   SITE 7 — bucketWalk("net") distributes stamped net, not gross qty*unitPrice
//   plus the reconciliation invariant and nameMerge.
TestCase {
    name: "RealisedMath"
    function _round2(x) { return Math.round(x * 100) / 100 }

    // Build a stamped sale event from an order line (mirror of
    // TransactionStore.recordSaleFromOrder via OrderMath.allocate).
    function _saleEvents(order, ts) {
        var a = OM.allocate(order)
        var byPid = {}
        for (var i = 0; i < a.perLine.length; ++i) byPid[a.perLine[i].productId] = a.perLine[i]
        var out = []
        for (var j = 0; j < order.products.length; ++j) {
            var p = order.products[j]
            if (!(p.quantity || 0)) continue
            var al = byPid[p.productId]
            out.push({
                kind: "sale", timestamp: ts || "2026-06-20T10:00:00Z",
                productId: p.productId, quantity: p.quantity, unitPrice: p.price,
                net: al.net, tax: al.tax, discountShare: al.discountShare,
                orderChannel: order.orderChannel || "", staffId: order.staffId || "",
                consumption: (p.consumption || []).slice()
            })
        }
        return out
    }

    function _sumField(map, f) {
        var s = 0, ks = Object.keys(map)
        for (var i = 0; i < ks.length; ++i) s += (map[ks[i]][f] || 0)
        return s
    }

    // ── Reconciliation invariant (no filter) ───────────────────────────────
    function test_bydimension_reconciles_to_totals() {
        var order = { orderChannel: "online", staffId: "ST1", products: [
            { productId: "P1", name: "A", price: 100, quantity: 2, taxable: true, taxPercent: 10,
              discountType: "flat", discountValue: 20,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 60 }] },
            { productId: "P2", name: "B", price: 50, quantity: 4, taxable: false, taxPercent: 0,
              consumption: [{ batchId: "B2", supplierId: "S2", qtyConsumed: 4, unitCost: 30 }] }
        ] }
        var ev = _saleEvents(order)
        var cat = { P1: "Drinks", P2: "Snacks" }
        var lookups = { categoryOf: function(pid) { return cat[pid] || "" } }
        var t = RM.totals(ev, null, lookups)
        compare(_round2(t.net), 380, "totals net = 180 + 200")
        compare(_round2(t.discount), 20)
        compare(_round2(t.cogs), 240)         // 120 + 120
        // Every dimension's Σ net/profit equals the totals block.
        var fields = ["productId", "supplierId", "category", "channel", "staffId"]
        for (var f = 0; f < fields.length; ++f) {
            var m = RM.byDimension(fields[f], ev, null, lookups)
            fuzzyCompare(_sumField(m, "revenue"), t.net, 0.011, "Σ net for " + fields[f])
            fuzzyCompare(_sumField(m, "profit"), t.profit, 0.011, "Σ profit for " + fields[f])
            fuzzyCompare(_sumField(m, "cogs"), t.cogs, 0.011, "Σ cogs for " + fields[f])
        }
    }

    // ── A: scope filter reaches the by-dimension sections ───────────────────
    function test_scope_filter_applies_to_bydimension() {
        var ev = [].concat(
            _saleEvents({ orderChannel: "online", staffId: "ST1", products: [
                { productId: "P1", name: "A", price: 100, quantity: 1, taxable: false, taxPercent: 0,
                  consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 60 }] }
            ] }, "2026-06-20T10:00:00Z"),
            _saleEvents({ orderChannel: "store", staffId: "ST2", products: [
                { productId: "P2", name: "B", price: 50, quantity: 2, taxable: false, taxPercent: 0,
                  consumption: [{ batchId: "B2", supplierId: "S2", qtyConsumed: 2, unitCost: 30 }] }
            ] }, "2026-06-20T11:00:00Z")
        )
        var lookups = { categoryOf: function() { return "" } }
        // Filter to channel "online" → only P1's 100 net.
        var scope = { channel: "online" }
        var t = RM.totals(ev, scope, lookups)
        compare(_round2(t.net), 100, "only the online order's net")
        var m = RM.byDimension("productId", ev, scope, lookups)
        verify(m["P1"] !== undefined)
        verify(m["P2"] === undefined)        // store order excluded
        fuzzyCompare(_sumField(m, "revenue"), t.net, 0.011, "Σ by-product == filtered totals")
    }

    // ── C: multi-batch FIFO split is cent-exact ─────────────────────────────
    function test_multibatch_rounding_reconciles() {
        // 3 units @ ₹10 with ₹1 flat discount → net 29 over a 1/1/1 supplier split.
        var order = { products: [{
            productId: "P1", name: "A", price: 10, quantity: 3, taxable: false, taxPercent: 0,
            discountType: "flat", discountValue: 1,
            consumption: [
                { batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 1 },
                { batchId: "B2", supplierId: "S2", qtyConsumed: 1, unitCost: 1 },
                { batchId: "B3", supplierId: "S3", qtyConsumed: 1, unitCost: 1 }
            ]
        }] }
        var ev = _saleEvents(order)
        var m = RM.byDimension("supplierId", ev, null, {})
        // Σ per-supplier net must equal the stamped line net (29) to the cent.
        compare(_round2(_sumField(m, "revenue")), 29, "supplier net sums to line net exactly")
    }

    // ── D: supplier-filtered gross == net + discount (single round) ─────────
    function test_supplier_filtered_gross() {
        var order = { products: [{
            productId: "P1", name: "A", price: 10, quantity: 3, taxable: false, taxPercent: 0,
            discountType: "flat", discountValue: 1,
            consumption: [
                { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 1 },
                { batchId: "B2", supplierId: "S2", qtyConsumed: 1, unitCost: 1 }
            ]
        }] }
        var ev = _saleEvents(order)
        var scope = { supplierId: "S1" }
        var t = RM.totals(ev, scope, {})
        // S1 = 2/3 of net 29 = 19.33; discount 2/3 of 1 = 0.67; gross = 20.00.
        compare(_round2(t.gross), _round2(t.net + t.discount), "gross == net + discount, one round")
    }

    // ── SITE 4: no-`net` event fails closed to 0 ────────────────────────────
    function test_no_net_fails_closed() {
        var ev = [{
            kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 2,
            unitPrice: 100,   // net DELIBERATELY absent (legacy/un-stamped)
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 40 }]
        }]
        var m = RM.byDimension("supplierId", ev, null, {})
        // Revenue must be 0 (fail-closed), NOT re-derived 200. COGS still counts.
        compare(_round2(m["S1"].revenue), 0, "missing net → 0 revenue (no re-allocation)")
        compare(_round2(m["S1"].cogs), 80, "cogs still booked from consumption")
    }

    // ── SITE 5 + SITE 7: bucketWalk(net) == totals.net == Σ byDimension net ──
    function test_revenue_and_profit_reconcile_one_source() {
        var order = { products: [{
            productId: "P1", name: "A", price: 100, quantity: 2, taxable: false, taxPercent: 0,
            discountType: "flat", discountValue: 30,    // net 170, NOT gross 200
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 50 }]
        }] }
        var ev = _saleEvents(order, "2026-06-20T10:00:00Z")
        var now = new Date(2026, 5, 20, 12, 0, 0)   // same day → period 0 catches it
        var t = RM.totals(ev, null, {})
        compare(_round2(t.net), 170, "net reflects discount")
        // SITE 7: bucketWalk distributes stamped net (170), not gross 200.
        var bins = RM.bucketWalk("net", 0, ev, null, now, {})
        var binSum = 0
        for (var i = 0; i < bins.length; ++i) binSum += bins[i].value
        compare(_round2(binSum), 170, "revenue bins sum to stamped net, not gross")
        // SITE 5: all three surfaces agree.
        var m = RM.byDimension("productId", ev, null, {})
        fuzzyCompare(_sumField(m, "revenue"), t.net, 0.011, "Σ byDimension net == totals net")
        fuzzyCompare(binSum, t.net, 0.011, "bucketWalk net == totals net")
        // Profit bins reconcile to totals.profit too.
        var pbins = RM.bucketWalk("profit", 0, ev, null, now, {})
        var pSum = 0
        for (var j = 0; j < pbins.length; ++j) pSum += pbins[j].value
        fuzzyCompare(pSum, t.profit, 0.011, "profit bins == totals profit (170 - 100)")
    }

    // ── SITE 5: adjusted+returned order — sale + return nets correctly ───────
    function test_sale_plus_return_nets_down() {
        var sale = {
            kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 4,
            unitPrice: 100, net: 400, tax: 0, discountShare: 0,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 60 }]
        }
        var ret = {  // return 1 unit
            kind: "return", timestamp: "2026-06-21T10:00:00Z", productId: "P1", quantity: -1,
            unitPrice: 100, net: -100, tax: 0, discountShare: 0,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: -1, unitCost: 60 }]
        }
        var ev = [sale, ret]
        var t = RM.totals(ev, null, {})
        compare(_round2(t.net), 300, "net = 400 - 100")
        compare(_round2(t.cogs), 180, "cogs = 240 - 60")
        compare(_round2(t.profit), 120, "profit = 300 - 180")
        var m = RM.byDimension("supplierId", ev, null, {})
        fuzzyCompare(m["S1"].revenue, 300, 0.011, "supplier net nets the return")
        fuzzyCompare(m["S1"].profit, 120, 0.011)
    }

    // ── nameMerge: id→name merge, dup-sum, fallback, margin recompute ───────
    function test_name_merge() {
        var rows = {
            "S1": { revenue: 100, cogs: 60, profit: 40, tax: 0, discount: 0, margin: 0 },
            "S2": { revenue: 50,  cogs: 40, profit: 10, tax: 0, discount: 0, margin: 0 },
            "":   { revenue: 30,  cogs: 0,  profit: 30, tax: 0, discount: 0, margin: 0 }
        }
        // S1 and S2 both resolve to "Acme" → must sum.
        var nameOf = function(k) { return (k === "S1" || k === "S2") ? "Acme" : "" }
        var merged = RM.nameMerge(rows, nameOf, "Unknown")
        compare(_round2(merged["Acme"].revenue), 150, "Acme sums S1 + S2")
        compare(_round2(merged["Acme"].cogs), 100)
        fuzzyCompare(merged["Acme"].margin, 50, 0.01, "margin = 50/100 *100")
        verify(merged["Unknown"] !== undefined)       // empty key → fallback
        compare(_round2(merged["Unknown"].revenue), 30)
    }

    // Under a supplier filter, a price_adjust IS attributed via its stamped
    // supplierSlices matching that supplier (the adjustment has lineage), and is
    // included in BOTH totals and bucketWalk so totals == Σ bucketWalk stays exact.
    function test_supplier_filter_includes_stamped_price_adjust() {
        var ev = [
            { kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 2,
              unitPrice: 100, net: 200, tax: 0, discountShare: 0, orderChannel: "online",
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 60 }] },
            { kind: "price_adjust", timestamp: "2026-06-20T11:00:00Z", productId: "P1",
              total: -20, reason: "discount", orderChannel: "online",
              supplierSlices: [{ key: "S1", amount: -20 }] }
        ]
        var now = new Date(2026, 5, 20, 12, 0, 0)
        var scope = { supplierId: "S1" }
        var t = RM.totals(ev, scope, {})
        // Sale net 200 + the S1-stamped -20 adjustment = 180.
        compare(_round2(t.net), 180, "supplier-filtered totals include the S1 price_adjust")
        compare(_round2(t.discount), 20, "and the discount column shows the +20")
        var bins = RM.bucketWalk("net", 0, ev, scope, now, {})
        var binSum = 0
        for (var i = 0; i < bins.length; ++i) binSum += bins[i].value
        compare(_round2(binSum), 180, "supplier-filtered bucketWalk includes the price_adjust too")
        fuzzyCompare(binSum, t.net, 0.011, "totals == Σ bucketWalk under a supplier filter")
        // A DIFFERENT supplier filter sees neither the sale nor the adjustment.
        compare(_round2(RM.totals(ev, { supplierId: "S2" }, {}).net), 0, "unrelated supplier → 0")
        // Counterproof: NO supplier filter → the -20 IS attributed (nets to 180).
        compare(_round2(RM.totals(ev, null, {}).net), 180, "unfiltered nets the discount edit")
    }

    // price_adjust discount edit (per-line, real productId) surfaces in the
    // discount column and nets revenue down — carried over from the store.
    function test_price_adjust_discount_column() {
        var ev = [
            { kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 2,
              unitPrice: 100, net: 200, tax: 0, discountShare: 0,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 60 }] },
            { kind: "price_adjust", timestamp: "2026-06-20T11:00:00Z", productId: "P1",
              total: -20, reason: "discount",
              supplierSlices: [{ key: "S1", amount: -20 }] }
        ]
        var m = RM.byDimension("supplierId", ev, null, {})
        compare(_round2(m["S1"].revenue), 180, "net after discount edit = 200 - 20")
        compare(_round2(m["S1"].discount), 20, "discount column reflects the edit")
    }

    // ── 2026-09-02 fix (SKILLS Skill 57): price_adjust events must carry a
    // proportional tax delta, not just revenue. Reproduces Taher's own bug
    // numbers: cp 50 / sp 60 / tax 5%, 1 unit sold (net 60, tax 3), then a 5%
    // discount edit (price_adjust total -3, tax -0.15) — expected net 57,
    // tax 2.85. See TransactionStore.recordPriceAdjust for where the event's
    // tax field itself gets stamped; this file only proves the aggregator
    // folds it in correctly once stamped. ───────────────────────────────────

    function test_price_adjust_tax_share_no_scope_supplier_dimension() {
        var ev = [
            { kind: "sale", timestamp: "2026-09-02T10:00:00Z", productId: "P1", quantity: 1,
              unitPrice: 60, net: 60, tax: 3, discountShare: 0,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] },
            { kind: "price_adjust", timestamp: "2026-09-02T11:00:00Z", productId: "P1",
              total: -3, tax: -0.15, reason: "discount",
              supplierSlices: [{ key: "S1", amount: -3 }] }
        ]
        var t = RM.totals(ev, null, {})
        compare(_round2(t.net), 57, "net settles at the discounted 57")
        compare(_round2(t.tax), 2.85, "THE bug: tax must move off the stale 3, not stay frozen")

        var m = RM.byDimension("supplierId", ev, null, {})
        compare(_round2(m["S1"].revenue), 57)
        compare(_round2(m["S1"].tax), 2.85, "supplier dimension row also carries the tax share")
        compare(_round2(m["S1"].discount), 3)
    }

    // Same scenario, filtered by the supplier — exercises byDimension's OWN
    // scope-filtered price_adjust branch (_priceAdjustSupplierAmount +
    // _priceAdjustTaxShare), a DIFFERENT code path from _accumulatePriceAdjust
    // the test above exercises.
    function test_price_adjust_tax_share_supplier_filtered() {
        var ev = [
            { kind: "sale", timestamp: "2026-09-02T10:00:00Z", productId: "P1", quantity: 1,
              unitPrice: 60, net: 60, tax: 3, discountShare: 0, orderChannel: "online",
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] },
            { kind: "price_adjust", timestamp: "2026-09-02T11:00:00Z", productId: "P1",
              total: -3, tax: -0.15, reason: "discount", orderChannel: "online",
              supplierSlices: [{ key: "S1", amount: -3 }] }
        ]
        var tS1 = RM.totals(ev, { supplierId: "S1" }, {})
        compare(_round2(tS1.net), 57)
        compare(_round2(tS1.tax), 2.85, "scope-filtered path must also fold in tax")

        var tS2 = RM.totals(ev, { supplierId: "S2" }, {})
        compare(_round2(tS2.net), 0, "unrelated supplier sees neither the sale nor the adjustment")
        compare(_round2(tS2.tax), 0)
    }

    // No supplierSlices AND no orderLookup match (legacy/pre-FIFO event) ->
    // falls to the "Unknown" ("") bucket, which assigns the WHOLE e.tax
    // unsplit — structurally different from the two sliced cases above.
    function test_price_adjust_tax_no_lineage_unknown_bucket() {
        var ev = [
            { kind: "sale", timestamp: "2026-09-02T10:00:00Z", productId: "P1", quantity: 1,
              unitPrice: 60, net: 60, tax: 3, discountShare: 0,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] },
            { kind: "price_adjust", timestamp: "2026-09-02T11:00:00Z", productId: "P1",
              total: -3, tax: -0.15, reason: "discount" }
              // no supplierSlices, no orderLookup (lookups: {}) -> no lineage
        ]
        var m = RM.byDimension("supplierId", ev, null, {})
        verify(m[""] !== undefined, "no-lineage adjustment lands in the Unknown bucket")
        compare(_round2(m[""].revenue), -3)
        compare(_round2(m[""].tax), -0.15)
    }

    // The reconciliation invariant must still hold with tax now flowing
    // through price_adjust events too — proves the fix didn't just move the
    // number somewhere convenient, it kept byDimension summing to totals.
    function test_price_adjust_tax_share_invariant_sum_equals_totals() {
        var ev = [
            { kind: "sale", timestamp: "2026-09-02T10:00:00Z", productId: "P1", quantity: 1,
              unitPrice: 60, net: 60, tax: 3, discountShare: 0,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] },
            { kind: "price_adjust", timestamp: "2026-09-02T11:00:00Z", productId: "P1",
              total: -3, tax: -0.15, reason: "discount",
              supplierSlices: [{ key: "S1", amount: -3 }] }
        ]
        var t = RM.totals(ev, null, {})
        var fields = ["productId", "supplierId", "category", "channel", "staffId"]
        for (var f = 0; f < fields.length; ++f) {
            var m = RM.byDimension(fields[f], ev, null, {})
            var sumTax = 0
            var keys = Object.keys(m)
            for (var k = 0; k < keys.length; ++k) sumTax += m[keys[k]].tax
            fuzzyCompare(sumTax, t.tax, 0.011, "field=" + fields[f] + " tax")
        }
    }
}
