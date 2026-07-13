import QtQuick
import QtTest
import "../qml/helper/BreakdownMath.js" as BM
import "../qml/helper/OrderMath.js" as OM

TestCase {
    name: "BreakdownMath"

    // ── periodWindow ────────────────────────────────────────────────
    function test_periodWindow_day() {
        var now = new Date(2026, 5, 15, 13, 0, 0) // 15 Jun 2026, 1pm
        var w = BM.periodWindow(0, now)
        compare(w.from.getTime(), new Date(2026, 5, 15, 0, 0, 0).getTime())
        compare(w.to.getTime(),   new Date(2026, 5, 16, 0, 0, 0).getTime())
    }
    function test_periodWindow_week() {
        var now = new Date(2026, 5, 17) // Wed 17 Jun 2026
        var w = BM.periodWindow(1, now)
        compare(w.from.getTime(), new Date(2026, 5, 15, 0, 0, 0).getTime()) // Mon
        compare(w.to.getTime(),   new Date(2026, 5, 22, 0, 0, 0).getTime()) // next Mon
    }
    function test_periodWindow_month() {
        var now = new Date(2026, 5, 17)
        var w = BM.periodWindow(2, now)
        compare(w.from.getTime(), new Date(2026, 5, 1).getTime())
        compare(w.to.getTime(),   new Date(2026, 6, 1).getTime())
    }
    function test_periodWindow_year() {
        var now = new Date(2026, 5, 15)
        var w = BM.periodWindow(3, now)
        compare(w.from.getTime(), new Date(2026, 0, 1).getTime())
        compare(w.to.getTime(),   new Date(2027, 0, 1).getTime())
    }

    // ── intersect ───────────────────────────────────────────────────
    function test_intersect_nulls() {
        var a = { from: new Date(2026,0,1), to: new Date(2026,1,1) }
        compare(BM.intersect(null, null), null)
        compare(BM.intersect(a, null), a)
        compare(BM.intersect(null, a), a)
    }
    function test_intersect_overlap() {
        var a = { from: new Date(2026,0,1), to: new Date(2026,5,1) }
        var b = { from: new Date(2026,3,1), to: new Date(2026,8,1) }
        var r = BM.intersect(a, b)
        compare(r.from.getTime(), new Date(2026,3,1).getTime())
        compare(r.to.getTime(),   new Date(2026,5,1).getTime())
    }

    // Shared fixtures ----------------------------------------------------
    function _productCategory() { return { "P1": "Drinks", "P2": "Snacks", "P3": "" } }
    function _supplierName()    { return { "S1": "Acme", "S2": "Beta" } }
    function _productName()     { return { "P1": "Cola", "P2": "Chips", "P3": "Cola" } }

    // ── PURCHASED ───────────────────────────────────────────────────
    function test_purchased_by_category_and_supplier_sum_equal() {
        var entries = [
            { kind:"purchase", timestamp:"2026-06-15T10:00:00", productId:"P1", party:"S1", quantity:10 },
            { kind:"created",  timestamp:"2026-06-15T11:00:00", productId:"P2", party:"S2", quantity:5 },
            { kind:"purchase", timestamp:"2026-06-15T12:00:00", productId:"P3", party:"",   quantity:3 },
            { kind:"sale",     timestamp:"2026-06-15T12:30:00", productId:"P1", quantity:99 } // ignored
        ]
        var opts = {
            metric:"purchased", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName(),
            productName:_productName()
        }
        var byCat = BM.breakdown(Object.assign({}, opts, { dim:"category" }))
        var bySup = BM.breakdown(Object.assign({}, opts, { dim:"supplier" }))
        compare(byCat["Drinks"], 10)
        compare(byCat["Snacks"], 5)
        compare(byCat["(uncategorised)"], 3)
        compare(bySup["Acme"], 10)
        compare(bySup["Beta"], 5)
        compare(bySup["Unknown"], 3)   // empty supplierId rolls up to "Unknown"
        compare(_sum(byCat), _sum(bySup)) // 18 == 18
        var byName = BM.breakdown(Object.assign({}, opts, { dim:"name" }))
        compare(byName["Cola"], 13)  // P1(10) + P3(3), both resolve to "Cola"
        compare(byName["Chips"], 5)
        compare(_sum(byName), _sum(byCat)) // reconciliation invariant: 18 == 18
    }

    // ── SOLD (FIFO consumption) ─────────────────────────────────────
    function test_sold_supplier_split_and_category_total() {
        var entries = [
            { kind:"sale", timestamp:"2026-06-15T10:00:00", productId:"P1", quantity:12,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:10}, {supplierId:"S2", qtyConsumed:2} ] }
        ]
        var opts = {
            metric:"sold", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName()
        }
        var byCat = BM.breakdown(Object.assign({}, opts, { dim:"category" }))
        var bySup = BM.breakdown(Object.assign({}, opts, { dim:"supplier" }))
        compare(byCat["Drinks"], 12)
        compare(bySup["Acme"], 10)
        compare(bySup["Beta"], 2)
        compare(_sum(byCat), _sum(bySup)) // 12 == 12
    }
    function test_sold_supplier_filter_partial_attribution() {
        var entries = [
            { kind:"sale", timestamp:"2026-06-15T10:00:00", productId:"P1", quantity:12,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:10}, {supplierId:"S2", qtyConsumed:2} ] }
        ]
        var bySup = BM.breakdown({
            metric:"sold", dim:"supplier", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"S1",
            productCategory:_productCategory(), supplierName:_supplierName()
        })
        compare(bySup["Acme"], 10) // only Acme's 10 units, not 12
        verify(bySup["Beta"] === undefined)
    }
    function test_sold_nets_returns_by_category() {
        // A sale of 5 (P1=Drinks) then a return of 2 → net 3 sold.
        var entries = [
            { kind:"sale", timestamp:"2026-06-15T10:00:00", productId:"P1", quantity:5,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:5} ] },
            { kind:"return", timestamp:"2026-06-15T11:00:00", productId:"P1", quantity:-2,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:-2} ] }
        ]
        var byCat = BM.breakdown({
            metric:"sold", dim:"category", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName()
        })
        compare(byCat["Drinks"], 3)
        var bySup = BM.breakdown({
            metric:"sold", dim:"supplier", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName()
        })
        compare(bySup["Acme"], 3)
    }

    // ── SOLD / PURCHASED — by-name (product) dim ────────────────────
    function test_sold_by_name_collapses_multi_sku_and_reconciles() {
        var entries = [
            { kind:"sale", timestamp:"2026-06-15T10:00:00", productId:"P1", quantity:5,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:5} ] },
            { kind:"sale", timestamp:"2026-06-15T11:00:00", productId:"P3", quantity:2,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:2} ] }
        ]
        var opts = {
            metric:"sold", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName(),
            productName:_productName()
        }
        var byName = BM.breakdown(Object.assign({}, opts, { dim:"name" }))
        var byCat  = BM.breakdown(Object.assign({}, opts, { dim:"category" }))
        compare(byName["Cola"], 7)          // P1(5) + P3(2), both resolve to "Cola"
        compare(_sum(byName), _sum(byCat))  // reconciliation invariant: 7 == 7
    }

    function test_sold_name_dim_with_supplier_filter() {
        var entries = [
            { kind:"sale", timestamp:"2026-06-15T10:00:00", productId:"P1", quantity:12,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:10}, {supplierId:"S2", qtyConsumed:2} ] }
        ]
        var byName = BM.breakdown({
            metric:"sold", dim:"name", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"S1",
            productCategory:_productCategory(), supplierName:_supplierName(),
            productName:_productName()
        })
        compare(byName["Cola"], 10) // only S1's 10 units, not the full 12
    }

    function test_purchased_by_name_unresolved_product_falls_back() {
        var entries = [
            { kind:"purchase", timestamp:"2026-06-15T10:00:00", productId:"P9", party:"S1", quantity:4 }
        ]
        var byName = BM.breakdown({
            metric:"purchased", dim:"name", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName(),
            productName:_productName()
        })
        compare(byName["(unnamed)"], 4) // P9 isn't in the productName map
    }

    // ── REVENUE ─────────────────────────────────────────────────────
    function test_revenue_category_total_equals_lines() {
        var orders = [
            { status:"completed", date:"2026-06-15", orderChannel:"", staffId:"",
              products:[
                { productId:"P1", price:100, quantity:2,
                  consumption:[ {supplierId:"S1", qtyConsumed:2} ] },
                { productId:"P2", price:50, quantity:3,
                  consumption:[ {supplierId:"S2", qtyConsumed:3} ] }
              ] },
            { status:"pending", date:"2026-06-15", products:[ { productId:"P1", price:100, quantity:9 } ] } // ignored
        ]
        var opts = {
            metric:"revenue", entries:[], orders:orders,
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName(),
            allocate: OM.allocate
        }
        var byCat = BM.breakdown(Object.assign({}, opts, { dim:"category" }))
        var bySup = BM.breakdown(Object.assign({}, opts, { dim:"supplier" }))
        compare(byCat["Drinks"], 200) // 2 * 100
        compare(byCat["Snacks"], 150) // 3 * 50
        compare(bySup["Acme"], 200)
        compare(bySup["Beta"], 150)
        compare(_sum(byCat), 350)
        compare(_sum(byCat), _sum(bySup))
    }

    // ── WINDOW FILTERING ────────────────────────────────────────────
    function test_window_filters_out_of_range() {
        var entries = [
            { kind:"purchase", timestamp:"2026-06-10T10:00:00", productId:"P1", party:"S1", quantity:7 },
            { kind:"purchase", timestamp:"2026-05-10T10:00:00", productId:"P1", party:"S1", quantity:99 } // out of window
        ]
        var win = { from: new Date(2026,5,1), to: new Date(2026,6,1) } // June only
        var byCat = BM.breakdown({
            metric:"purchased", dim:"category", entries:entries, orders:[],
            window:win, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName()
        })
        compare(byCat["Drinks"], 7) // the May 99 is excluded
        verify(_sum(byCat) === 7)
    }

    // ── REVENUE supplier dim + supplier filter ──────────────────────
    function test_revenue_supplier_dim_and_filter() {
        var orders = [
            { status:"completed", date:"2026-06-15", orderChannel:"", staffId:"",
              products:[
                { productId:"P1", price:100, quantity:12,
                  consumption:[ {supplierId:"S1", qtyConsumed:10}, {supplierId:"S2", qtyConsumed:2} ] }
              ] }
        ]
        var base = {
            metric:"revenue", entries:[], orders:orders,
            window:null, channel:"", staffId:"", category:"",
            productCategory:_productCategory(), supplierName:_supplierName(),
            allocate: OM.allocate
        }
        // supplier dim, no filter: Acme 1000 (10*100), Beta 200 (2*100)
        var bySup = BM.breakdown(Object.assign({}, base, { dim:"supplier", supplierId:"" }))
        compare(bySup["Acme"], 1000)
        compare(bySup["Beta"], 200)
        // category dim with supplier filter S1: only Acme's 10 units * 100 = 1000
        var byCat = BM.breakdown(Object.assign({}, base, { dim:"category", supplierId:"S1" }))
        compare(byCat["Drinks"], 1000)
    }

    function _sum(map) {
        var t = 0, ks = Object.keys(map)
        for (var i = 0; i < ks.length; ++i) t += map[ks[i]]
        return t
    }

    // ── REVENUE NET ALLOCATION (Task 3) ─────────────────────────────
    // Revenue is now NET (subtotal - discount), not gross qty*price.
    function test_revenue_is_net_of_discount() {
        var orders = [{
            status: "completed", date: "2026-06-15T10:00:00", orderChannel: "", staffId: "",
            products: [{ productId: "P1", price: 100, quantity: 2, taxable: false, taxPercent: 0,
                         discountType: "flat", discountValue: 40 }]
        }]
        var out = BM.breakdown({
            metric: "revenue", dim: "category",
            orders: orders, window: null,
            productCategory: { "P1": "Drinks" }, supplierName: {},
            allocate: OM.allocate
        })
        // gross 200, per-line discount 40 → net 160 attributed to Drinks.
        fuzzyCompare(out["Drinks"], 160, 0.001)
    }

    function test_revenue_tax_metric() {
        var orders = [{
            status: "completed", date: "2026-06-15T10:00:00", orderChannel: "", staffId: "",
            discountType: "flat", discountValue: 0,
            products: [
                { productId: "P1", price: 100, quantity: 2, taxable: true, taxPercent: 10 },
                { productId: "P2", price: 50, quantity: 1, taxable: true, taxPercent: 10 }
            ]
        }]
        var out = BM.breakdown({
            metric: "tax", dim: "category",
            orders: orders, window: null,
            productCategory: { "P1": "Drinks", "P2": "Snacks" }, supplierName: {},
            allocate: OM.allocate
        })
        // P1: net=200, tax=20; P2: net=50, tax=5
        fuzzyCompare(out["Drinks"], 20, 0.001)
        fuzzyCompare(out["Snacks"], 5, 0.001)
    }

    function test_revenue_discount_metric() {
        var orders = [{
            status: "completed", date: "2026-06-15T10:00:00", orderChannel: "", staffId: "",
            products: [
                { productId: "P1", price: 100, quantity: 2, taxable: false, taxPercent: 0,
                  discountType: "percent", discountValue: 20 },
                { productId: "P2", price: 100, quantity: 1, taxable: false, taxPercent: 0,
                  discountType: "percent", discountValue: 20 }
            ]
        }]
        var out = BM.breakdown({
            metric: "discount", dim: "category",
            orders: orders, window: null,
            productCategory: { "P1": "Drinks", "P2": "Snacks" }, supplierName: {},
            allocate: OM.allocate
        })
        // per-line 20%: P1 gross 200 → disc 40; P2 gross 100 → disc 20.
        fuzzyCompare(out["Drinks"], 40, 0.001)
        fuzzyCompare(out["Snacks"], 20, 0.001)
    }

    function test_revenue_supplier_filtered_is_net() {
        var orders = [{
            status: "completed", date: "2026-06-15T10:00:00", orderChannel: "", staffId: "",
            products: [{ productId: "P1", price: 100, quantity: 4, taxable: false, taxPercent: 0,
                         discountType: "flat", discountValue: 100,
                         consumption: [{ batchId:"B1", supplierId:"S1", qtyConsumed:4, unitCost:60 }] }]
        }]
        var out = BM.breakdown({
            metric: "revenue", dim: "supplier",
            orders: orders, window: null, supplierId: "S1",
            productCategory: { "P1": "Drinks" }, supplierName: { "S1": "Acme" },
            allocate: OM.allocate
        })
        // gross 400, per-line disc 100 → net 300 attributed to Acme.
        fuzzyCompare(out["Acme"], 300, 0.5)
    }
}
