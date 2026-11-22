import QtQuick
import QtTest
import "../qml/helper/OrderPlan.js" as OP
import "../qml/helper/OperationKeys.js" as OK

// Headless tests for the pure create-order planner (atomic-ops NO2). Pure JS, no singletons.
// Design: docs/superpowers/specs/2026-11-22-no2-create-order-client-plan-design.md
// Test plan: docs/superpowers/test-plans/2026-11-22-no2-create-order-client-plan-test-plan.md
// The same cases run in Node against the REAL server code and the REAL OrdersStore normaliser in
// functions/test/createOrderPlan.test.js (plan -> validateOperationRequest -> applyOperation -> reflect); this file is the
// qmltestrunner copy, so a QML-engine difference (number formatting, string handling, regex) cannot hide.
TestCase {
    name: "OrderPlan"

    readonly property string key: "createOrder:1781000000000-abcdefabcdef"
    readonly property string iso: "2026-06-15T12:00:00.000Z"

    // The doc OrdersStore._normalizeOrder makes for 3 x Tomato at 19.99, taxable 5 %, customer "  Asha ".
    function _order() {
        return { orderId: "ORD-OLD", customer: "  Asha ", email: " a@b.c ", phone: "123", items: 3, subtotal: 59.97, discount: 0, tax: 3,
                 taxBreakdown: [{ rate: 5, amount: 2.9985 }], total: 62.97, status: "pending", date: "2026-06-15", updatedAt: iso,
                 notes: "", orderChannel: "Online", staffId: "S-1", adjustments: [], completionEpoch: 0,
                 products: [{ productId: "PRD-001", name: "Tomato", price: 19.99, quantity: 3, taxable: true, taxPercent: 5,
                              discountType: "flat", discountValue: 0, consumption: [] }] }
    }
    function _copy(v) { return JSON.parse(JSON.stringify(v)) }
    function _build(f) { var o = _order(); if (f) f(o); return OP.build({ key: key, order: o }) }
    function _strings(ops) {
        var out = []
        var walk = function(v) {
            if (typeof v === "string") out.push(v)
            else if (Array.isArray(v)) v.forEach(walk)
            else if (v && typeof v === "object") Object.keys(v).forEach(function(k) { walk(v[k]) })
        }
        ops.filter(function(o) { return o.kind === "mutation" }).forEach(function(o) { walk(o.after) })
        return out
    }
    function _good() {
        var d = _order(); d.orderId = "ORD-009"
        return [{ kind: "mint", bind: "ord", counter: "order", id: "ORD-009" },
                { kind: "mutation", entity: "order", entityId: "ORD-009", action: "create", after: d }]
    }
    function _cents(x) { return Math.round(x * 100) / 100 }

    function test_build_is_a_mint_then_one_create_with_the_bare_token() {
        var p = _build()
        verify(p.ok)
        compare(p.key, key)
        compare(p.opType, "createOrder")
        compare(p.at.mint, 0)
        compare(p.at.create, 1)
        compare(p.ops.length, 2)
        compare(JSON.stringify(p.ops[0]), JSON.stringify({ kind: "mint", counter: "order", bind: "ord" }))
        var c = p.ops[1]
        compare(c.kind, "mutation"); compare(c.entity, "order"); compare(c.entityId, "{{ord}}"); compare(c.action, "create")
        compare(c.before, null); compare(c.after.orderId, "{{ord}}")
    }

    function test_build_keeps_the_store_totals_and_trims_the_text() {
        var a = _build().ops[1].after
        compare(a.customer, "Asha"); compare(a.email, "a@b.c"); compare(a.phone, "123")
        compare(a.items, 3); compare(a.subtotal, 59.97); compare(a.discount, 0); compare(a.tax, 3); compare(a.total, 62.97)
        compare(a.status, "pending"); compare(a.date, "2026-06-15"); compare(a.updatedAt, iso)
        compare(JSON.stringify(a.taxBreakdown), JSON.stringify([{ rate: 5, amount: 2.9985 }]))
        compare(JSON.stringify(a.adjustments), "[]"); compare(a.completionEpoch, 0)
        compare(JSON.stringify(a.products[0]), JSON.stringify({ productId: "PRD-001", name: "Tomato", price: 19.99, quantity: 3, taxable: true,
                                                                 taxPercent: 5, discountType: "flat", discountValue: 0, consumption: [] }))
    }

    function test_build_never_changes_the_input_and_drops_extra_keys() {
        var o = _order(); o.hack = "x"; o.products[0].extra = 1; o.taxBreakdown[0].more = 2
        var copy = JSON.stringify(o)
        var a = OP.build({ key: key, order: o }).ops[1].after
        compare(JSON.stringify(o), copy)
        compare(a.hack, undefined); compare(a.products[0].extra, undefined); compare(a.taxBreakdown[0].more, undefined)
    }

    function test_build_fills_what_an_old_doc_leaves_out() {
        var a = _build(function(o) { delete o.completionEpoch; delete o.adjustments; delete o.products[0].consumption }).ops[1].after
        compare(JSON.stringify(a.adjustments), "[]"); compare(a.completionEpoch, 0); compare(JSON.stringify(a.products[0].consumption), "[]")
    }

    function test_typed_braces_are_neutralised_in_every_string() {
        var h = "{{ord}} {{$stock}} }}{{ {{{"
        var p = _build(function(o) { o.customer = h; o.email = h; o.phone = h; o.notes = h; o.orderChannel = h; o.staffId = h
            o.products[0].name = h; o.products[0].productId = h })
        verify(p.ok)
        compare(p.ops[1].after.customer, "{ {ord} } { {$stock} } } }{ { { { {")
        var all = _strings(p.ops)
        for (var i = 0; i < all.length; ++i) {
            var rest = all[i].replace(/\{\{ord\}\}/g, "")
            verify(rest.indexOf("{{") < 0 && rest.indexOf("}}") < 0, all[i])
        }
        compare(_build(function(o) { o.customer = "Joe {Bakery} \u00e9" }).ops[1].after.customer, "Joe {Bakery} \u00e9")
    }

    function test_every_refusal_reason() {
        var table = [
            ["bad-key", function(o) {}, "restock:1781000000000-abcdefabcdef"],
            ["bad-customer", function(o) { o.customer = "  \t " }],
            ["bad-customer", function(o) { o.customer = 5 }],
            ["bad-status", function(o) { o.status = "completed" }],
            ["bad-status", function(o) { o.completionEpoch = 1 }],
            ["bad-status", function(o) { o.adjustments = [{ x: 1 }] }],
            ["bad-time", function(o) { o.date = "2026-02-31" }],
            ["bad-time", function(o) { o.updatedAt = "2026-13-45T10:00:00Z" }],
            ["bad-line", function(o) { o.products = [] }],
            ["bad-line", function(o) { o.products[0].name = " " }],
            ["bad-line", function(o) { o.products[0].price = -1 }],
            ["bad-line", function(o) { o.products[0].quantity = 0 }],
            ["bad-line", function(o) { o.products[0].quantity = 1.5 }],
            ["bad-line", function(o) { o.products[0].taxPercent = 101 }],
            ["bad-line", function(o) { o.products[0].taxPercent = -1 }],
            ["bad-line", function(o) { o.products[0].discountType = "half" }],
            ["bad-line", function(o) { o.products[0].consumption = [{ batchId: "B" }] }],
            ["bad-totals", function(o) { o.items = 4 }],
            ["bad-totals", function(o) { o.subtotal = 60 }],
            ["bad-totals", function(o) { o.total = 62.98 }],
            ["bad-totals", function(o) { o.discount = -5; o.total = _cents(o.subtotal - o.discount + o.tax) }],
            ["bad-totals", function(o) { o.discount = o.subtotal + 5; o.total = _cents(o.subtotal - o.discount + o.tax) }],
            ["bad-totals", function(o) { o.tax = -3; o.total = _cents(o.subtotal - o.discount + o.tax) }],
            ["bad-totals", function(o) { o.taxBreakdown = {} }],
            ["bad-totals", function(o) { o.taxBreakdown = [{ rate: -1, amount: 1 }] }],
            ["bad-totals", function(o) { o.taxBreakdown = [{ rate: 5, amount: -1 }] }],
            ["bad-totals", function(o) { o.products[0].price = 1e308; o.products[0].quantity = 5 }]
        ]
        for (var i = 0; i < table.length; ++i) {
            var o = _order(); table[i][1](o)
            var p = OP.build({ key: table[i].length > 2 ? table[i][2] : key, order: o })
            verify(!p.ok, "case " + i)
            compare(p.reason, table[i][0], "case " + i)
            compare(p.ops, undefined)
        }
    }

    function test_bad_line_names_its_index() {
        var o = _order(); o.products.push(_copy(o.products[0])); o.products[1].quantity = 0
        var p = OP.build({ key: key, order: o })
        compare(p.reason, "bad-line"); compare(p.index, 1)
        o.products = []
        compare(OP.build({ key: key, order: o }).index, -1)
    }

    function test_not_an_object_is_refused_never_thrown() {
        var bad = [undefined, null, 0, "x", [], true]
        for (var i = 0; i < bad.length; ++i) compare(OP.build(bad[i]).reason, "bad-key")
        compare(OP.build({ key: key, order: null }).reason, "bad-order")
        compare(OP.build({ key: key, order: [] }).reason, "bad-order")
    }

    function test_boundaries_that_are_allowed() {
        var lines = [{ price: 0 }, { taxPercent: 0, taxable: false }, { taxPercent: 100 }, { discountType: "percent", discountValue: 150 },
                     { discountType: "flat", discountValue: 1e6 }]
        for (var i = 0; i < lines.length; ++i) {
            // the totals of these lines are the store's; only the planner's bounds are under test, so the doc is rebuilt consistently
            var o = _order()
            for (var k in lines[i]) o.products[0][k] = lines[i][k]
            o.products[0].quantity = 1
            o.items = 1; o.subtotal = _cents(o.products[0].price); o.discount = 0; o.tax = 0; o.taxBreakdown = []; o.total = o.subtotal
            verify(OP.build({ key: key, order: o }).ok, JSON.stringify(lines[i]))
        }
    }

    function test_a_doc_over_one_mebibyte_is_refused() {
        var big = _build(function(o) { o.notes = new Array(1100001).join("n") })
        compare(big.reason, "too-large")
        verify(_build(function(o) { o.notes = new Array(900001).join("n") }).ok)
    }

    function test_reflect_reads_the_good_answer_in_either_order() {
        var r = OP.reflect(_good())
        verify(r.ok); compare(r.orderId, "ORD-009"); compare(r.order.orderId, "ORD-009"); compare(r.order.status, "pending")
        verify(OP.reflect(_good().reverse()).ok)
    }

    function test_reflect_refuses_everything_else() {
        var g = _good()
        var cases = [
            [undefined, "not-a-list"], [null, "not-a-list"], ["x", "not-a-list"], [{}, "not-a-list"],
            [[], "shape"], [[g[0]], "shape"], [[g[1]], "shape"], [[g[0], g[0]], "shape"], [[g[1], g[1]], "shape"],
            [[null, g[1]], "entry-0"], [[g[0], { kind: "delta" }], "kind-1"],
            [[{ kind: "mint", bind: "ord", id: 7 }, g[1]], "mint-id"], [[{ kind: "mint", bind: "prd", id: "ORD-009" }, g[1]], "mint-id"],
            [[g[0], { kind: "mutation", entity: "inventory", after: {} }], "mutation"],
            [[g[0], { kind: "mutation", entity: "order", after: [] }], "mutation"],
            [[{ kind: "mint", bind: "ord", id: "ORD-9" }, g[1]], "order-id"], [[{ kind: "mint", bind: "ord", id: "xORD-009" }, g[1]], "order-id"],
            [[{ kind: "mint", bind: "ord", id: "ORD-009x" }, g[1]], "order-id"]
        ]
        for (var i = 0; i < cases.length; ++i) {
            var r = OP.reflect(cases[i][0])
            verify(!r.ok, "case " + i); compare(r.reason, "malformed-results"); compare(r.detail, cases[i][1], "case " + i)
        }
    }

    function test_reflect_refuses_a_doc_that_disagrees_with_its_mint() {
        var muts = [function(m) { m.after.orderId = "ORD-010" }, function(m) { m.entityId = "ORD-010" }, function(m) { m.entityId = undefined },
                    function(m) { m.after.status = "completed" }, function(m) { m.after.customer = 5 },
                    function(m) { m.after.products = [] }, function(m) { m.after.products = "x" }]
        for (var i = 0; i < muts.length; ++i) {
            var g = _good(); muts[i](g[1])
            compare(OP.reflect(g).detail, "order-doc", "case " + i)
        }
    }
}
