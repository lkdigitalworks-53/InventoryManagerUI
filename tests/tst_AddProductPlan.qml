import QtQuick
import QtTest
import "../qml/helper/AddProductPlan.js" as AP
import "../qml/helper/OperationKeys.js" as OK

// Headless tests for the pure add-product planner (atomic-ops AP2). Pure JS, no singletons.
// Design: docs/superpowers/specs/2026-11-15-ap2-add-product-client-plan-design.md
// Test plan: docs/superpowers/test-plans/2026-11-15-ap2-add-product-client-plan-test-plan.md
// The same cases run in Node against the REAL server code in functions/test/addProductPlan.test.js
// (plan -> validateOperationRequest -> applyOperation -> reflect); this file is the qmltestrunner copy,
// so a QML-engine difference (number formatting, string handling, regex lookahead) cannot hide.
TestCase {
    name: "AddProductPlan"

    readonly property string nonce: "1781000000000-abcdefabcdef"
    readonly property string key: "addProduct:1781000000000-abcdefabcdef"
    readonly property string iso: "2026-06-15T12:00:00.000Z"

    function _input(over) {
        var base = { key: key, name: "  Tomato ", sku: "TO-2026-001", category: "Veg", description: "Red", price: 20, unit: "kg",
                     stock: 12, minStock: 2, sellingPrice: 30, taxable: true, taxPercent: 5, size: "1kg", unitCost: 18.5,
                     supplier: { newName: "  Acme Farms " }, now: iso, date: "2026-06-15" }
        for (var k in over) base[k] = over[k]
        return base
    }

    function _copy(v) { return JSON.parse(JSON.stringify(v)) }
    function _kinds(ops) { return ops.map(function(o) { return o.kind }) }

    // Every string of every created doc (a whole-doc JSON.stringify would also show the `}}` of nested objects).
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

    function _noStrayBraces(ops) {
        var all = _strings(ops)
        for (var i = 0; i < all.length; ++i) {
            var rest = all[i].replace(/\{\{(prd|sup|batch)\}\}/g, "")
            if (rest.indexOf("{{") >= 0 || rest.indexOf("}}") >= 0) return all[i]
        }
        return ""
    }

    // A server answer for the new-supplier plan, in the shape operationLogic.applyOperation returns.
    function _good() {
        return [
            { kind: "mint", bind: "prd", counter: "product", id: "PRD-007" },
            { kind: "mint", bind: "sup", counter: "supplier", id: "SUP-001" },
            { kind: "mint", bind: "batch", counter: "stock_batch", id: "BAT-2026-001" },
            { kind: "mutation", entity: "supplier", entityId: "SUP-001", action: "create",
              after: { supplierId: "SUP-001", name: "Acme Farms" } },
            { kind: "mutation", entity: "inventory", entityId: "PRD-007", action: "create",
              after: { productId: "PRD-007", name: "Tomato", stock: 12, supplierId: "SUP-001" } },
            { kind: "mutation", entity: "stock_batch", entityId: "BAT-2026-001", action: "create",
              after: { batchId: "BAT-2026-001", productId: "PRD-007", supplierId: "SUP-001", qtyReceived: 12, qtyRemaining: 12 } },
            { kind: "mutation", entity: "transaction", entityId: "tx-c-PRD-007-" + nonce, action: "create",
              after: { txId: "tx-c-PRD-007-" + nonce, kind: "created", productId: "PRD-007" } },
            { kind: "mutation", entity: "activity", entityId: "act-PRD-007-" + nonce, action: "create",
              after: { id: "act-PRD-007-" + nonce, kind: "product_added", entityId: "PRD-007", timestamp: iso } }
        ]
    }

    // ── shape ─────────────────────────────────────────────────────────────

    function test_B1_new_supplier_with_stock_has_eight_ops_mints_first_and_the_nonce_in_both_history_ids() {
        var p = AP.build(_input())
        verify(p.ok)
        compare(p.opType, "addProduct")
        compare(p.key, key)
        compare(JSON.stringify(_kinds(p.ops)), JSON.stringify(["mint", "mint", "mint", "mutation", "mutation", "mutation", "mutation", "mutation"]))
        compare(JSON.stringify(p.at), JSON.stringify({ productMint: 0, supplierMint: 1, batchMint: 2, supplierCreate: 3, productCreate: 4,
                                                       batchCreate: 5, created: 6, activity: 7 }))
        compare(p.ops[4].after.supplierId, "{{sup}}")
        compare(p.ops[4].after.name, "Tomato")
        compare(p.ops[5].after.qtyReceived, 12)
        compare(p.ops[6].entityId, "tx-c-{{prd}}-" + nonce)
        compare(p.ops[6].after.txId, "tx-c-{{prd}}-" + nonce)
        compare(p.ops[6].after.total, 222)
        compare(p.ops[7].entityId, "act-{{prd}}-" + nonce)
        compare(p.ops[7].after.title, "Product added: Tomato")
        compare(p.ops[7].after.subtitle, "TO-2026-001 \u00b7 stock 12")
        for (var i = 3; i < p.ops.length; ++i) {
            compare(p.ops[i].action, "create")
            compare(p.ops[i].before, null)
        }
    }

    function test_B2_known_supplier_has_no_supplier_mint_or_create() {
        var p = AP.build(_input({ supplier: { id: "SUP-009" } }))
        verify(p.ok)
        compare(p.at.supplierMint, -1)
        compare(p.at.supplierCreate, -1)
        compare(p.ops[p.at.productCreate].after.supplierId, "SUP-009")
        compare(p.ops[p.at.batchCreate].after.supplierId, "SUP-009")
        compare(p.ops[p.at.created].after.party, "SUP-009")
    }

    function test_B3_no_supplier_means_empty_ids_and_no_party_in_the_snapshot() {
        var list = [null, undefined]
        for (var i = 0; i < list.length; ++i) {
            var p = AP.build(_input({ supplier: list[i] }))
            verify(p.ok)
            compare(p.ops[p.at.productCreate].after.supplierId, "")
            compare(p.ops[p.at.created].after.party, "")
            verify(!p.ops[p.at.created].after.snapshot.hasOwnProperty("party"))
        }
    }

    function test_B4_stock_zero_has_no_batch_but_keeps_the_created_and_feed_rows() {
        var p = AP.build(_input({ stock: 0, supplier: null }))
        verify(p.ok)
        compare(p.at.batchMint, -1)
        compare(p.at.batchCreate, -1)
        compare(p.ops.length, 4)
        compare(p.ops[p.at.created].after.quantity, 0)
        compare(p.ops[p.at.activity].after.subtitle, "TO-2026-001 \u00b7 stock 0")
    }

    function test_B5_no_sku_gives_a_subtitle_with_just_the_stock() {
        compare(AP.build(_input({ sku: "   " })).ops[7].after.subtitle, "stock 12")
    }

    function test_B6_fractional_stock_and_rounded_total() {
        var p = AP.build(_input({ stock: 3, unitCost: 0.1, supplier: null }))
        compare(p.ops[p.at.created].after.total, 0.3)
        var f = AP.build(_input({ stock: 2.5, unitCost: 10, supplier: null }))
        compare(f.ops[f.at.created].after.quantity, 2.5)
        compare(f.ops[f.at.batchCreate].after.qtyRemaining, 2.5)
    }

    function test_B7_long_name_and_sku_are_cut_in_the_feed_row_only() {
        var p = AP.build(_input({ name: new Array(5001).join("n"), sku: new Array(5001).join("s"), supplier: null }))
        verify(p.ok)
        compare(p.ops[p.at.activity].after.title, "Product added: " + new Array(151).join("n"))
        compare(p.ops[p.at.activity].after.subtitle, new Array(101).join("s") + " \u00b7 stock 12")
        compare(p.ops[p.at.productCreate].after.name.length, 5000)
    }

    function test_B8_the_input_is_never_changed() {
        var inp = _input()
        var before = JSON.stringify(inp)
        AP.build(inp)
        compare(JSON.stringify(inp), before)
    }

    // ── refusals ──────────────────────────────────────────────────────────

    function test_R1_refusals_data() {
        return [
            { tag: "bad-key restock", reason: "bad-key", over: { key: "restock:x" } },
            { tag: "bad-key empty", reason: "bad-key", over: { key: "" } },
            { tag: "bad-name blank", reason: "bad-name", over: { name: "   " } },
            { tag: "bad-name number", reason: "bad-name", over: { name: 5 } },
            { tag: "bad-price negative", reason: "bad-price", over: { price: -1 } },
            { tag: "bad-price NaN", reason: "bad-price", over: { price: NaN } },
            { tag: "bad-price selling", reason: "bad-price", over: { sellingPrice: -0.01 } },
            { tag: "bad-tax over 100", reason: "bad-tax", over: { taxPercent: 100.01 } },
            { tag: "bad-tax text", reason: "bad-tax", over: { taxPercent: "5" } },
            { tag: "bad-tax taxable", reason: "bad-tax", over: { taxable: "yes" } },
            { tag: "bad-stock negative", reason: "bad-stock", over: { stock: -1 } },
            { tag: "bad-stock text", reason: "bad-stock", over: { stock: "12" } },
            { tag: "bad-stock min", reason: "bad-stock", over: { minStock: -1 } },
            { tag: "bad-cost negative", reason: "bad-cost", over: { unitCost: -1 } },
            { tag: "bad-cost overflow", reason: "bad-cost", over: { unitCost: 1e308, stock: 5 } },
            { tag: "bad-supplier text", reason: "bad-supplier", over: { supplier: "Acme" } },
            { tag: "bad-supplier blank new", reason: "bad-supplier", over: { supplier: { newName: "  " } } },
            { tag: "bad-supplier empty id", reason: "bad-supplier", over: { supplier: { id: "" } } },
            { tag: "bad-supplier braces", reason: "bad-supplier", over: { supplier: { id: "SUP-{{prd}}" } } },
            { tag: "bad-time now", reason: "bad-time", over: { now: "{{{" } },
            { tag: "bad-time date", reason: "bad-time", over: { date: "15/06/2026" } },
            // PR #201 sweep F1: the right shape is not a real instant. Month 13 and hour 25 are not a Date in any engine;
            // 31 February and 24:00 parse in some engines and roll over, so the planner compares the round trip.
            { tag: "bad-time month 13", reason: "bad-time", over: { now: "2026-13-45T10:00:00Z" } },
            { tag: "bad-time hour 25", reason: "bad-time", over: { now: "2026-06-15T25:61:61Z" } },
            { tag: "bad-time 24:00", reason: "bad-time", over: { now: "2026-06-15T24:00:00Z" } },
            { tag: "bad-time 31 Feb now", reason: "bad-time", over: { now: "2026-02-31T10:00:00Z" } },
            { tag: "bad-time zero now", reason: "bad-time", over: { now: "0000-00-00T00:00:00Z" } },
            { tag: "bad-time date month 13", reason: "bad-time", over: { date: "2026-13-45" } },
            { tag: "bad-time date 31 Feb", reason: "bad-time", over: { date: "2026-02-31" } },
            { tag: "bad-time date 29 Feb 2026", reason: "bad-time", over: { date: "2026-02-29" } },
            { tag: "bad-time date 1900 not leap", reason: "bad-time", over: { date: "1900-02-29" } },
            { tag: "bad-time date 31 April", reason: "bad-time", over: { date: "2026-04-31" } }
        ]
    }

    function test_R1_refusals(data) {
        var p = AP.build(_input(data.over))
        compare(p.ok, false)
        compare(p.reason, data.reason)
        compare(Object.keys(p).length, 2)
    }

    function test_R2_allowed_boundaries() {
        var list = [{ price: 0, sellingPrice: 0 }, { unitCost: 0 }, { minStock: 0 }, { taxPercent: 0 }, { taxPercent: 100 }, { stock: 1e-9 }, { taxable: false }]
        for (var i = 0; i < list.length; ++i)
            verify(AP.build(_input(list[i])).ok, JSON.stringify(list[i]))
    }

    function test_R2b_real_times_are_accepted_leap_days_year_ends_and_every_fraction_length() {
        var nows = ["2028-02-29T23:59:59Z", "2026-06-15T12:00:00.5Z", "2026-06-15T12:00:00.12Z", "2026-12-31T23:59:59.999Z", "1970-01-01T00:00:00Z"]
        for (var i = 0; i < nows.length; ++i)
            verify(AP.build(_input({ now: nows[i] })).ok, nows[i])
        var dates = ["2028-02-29", "2000-02-29", "2026-12-31", "2026-01-01", "2026-04-30", "2026-02-28"]
        for (var j = 0; j < dates.length; ++j)
            verify(AP.build(_input({ date: dates[j] })).ok, dates[j])
        // a local date near midnight differs from the UTC one: `date` need not agree with `now`
        verify(AP.build(_input({ now: "2026-06-15T23:30:00.000Z", date: "2026-06-16" })).ok)
    }

    function test_R3_not_an_object_is_refused_not_thrown() {
        var junk = [null, undefined, "x", 5, true, []]
        for (var i = 0; i < junk.length; ++i) {
            var p = AP.build(junk[i])
            compare(p.ok, false)
            compare(p.reason, "bad-key")
        }
    }

    function test_R4_a_doc_over_one_mebibyte_is_refused() {
        compare(AP.build(_input({ description: new Array(1100001).join("x") })).reason, "too-large")
        verify(AP.build(_input({ description: new Array(100001).join("x") })).ok)
    }

    // ── typed text (D-AP-12) ──────────────────────────────────────────────

    function test_N1_neutralise_puts_one_space_inside_every_touching_pair() {
        compare(AP.neutralisePlaceholders("{{prd}}"), "{ {prd} }")
        compare(AP.neutralisePlaceholders("{{$stock}}"), "{ {$stock} }")
        compare(AP.neutralisePlaceholders("}}{{"), "} }{ {")
        compare(AP.neutralisePlaceholders("{{{"), "{ { {")
        compare(AP.neutralisePlaceholders("}}}"), "} } }")
        var same = ["", "plain", "{", "}", "{ }", "} {", "a{b}c", "100% {ok}", "\u0928\u092e\u0938\u094d\u0924\u0947"]
        for (var i = 0; i < same.length; ++i)
            compare(AP.neutralisePlaceholders(same[i]), same[i])
        compare(AP.neutralisePlaceholders(undefined), "")
        compare(AP.neutralisePlaceholders(5), "")
    }

    function test_N2_typed_text_never_leaves_a_brace_pair_outside_the_planner_tokens() {
        var evil = "{{prd}}{{sup}}{{batch}}{{$stock}}}}{{"
        var p = AP.build(_input({ name: evil, sku: evil, category: evil, unit: evil, size: evil, description: evil, supplier: { newName: evil } }))
        verify(p.ok)
        compare(_noStrayBraces(p.ops), "")
    }

    function test_N3_a_single_brace_is_kept() {
        var p = AP.build(_input({ name: "Rod {10mm}", supplier: null }))
        compare(p.ops[p.at.productCreate].after.name, "Rod {10mm}")
    }

    // ── reflect ───────────────────────────────────────────────────────────

    function test_F1_reflect_reads_a_good_answer() {
        var x = AP.reflect(_good())
        verify(x.ok)
        compare(x.productId, "PRD-007")
        compare(x.stock, 12)
        compare(x.batchId, "BAT-2026-001")
        compare(x.supplierId, "SUP-001")
        compare(x.created.txId, "tx-c-PRD-007-" + nonce)
        compare(x.activity.id, "act-PRD-007-" + nonce)
        compare(x.supplier.name, "Acme Farms")
    }

    function test_F2_reflect_without_a_supplier_and_with_stock_zero() {
        var g = _good().filter(function(r) { return r.bind !== "sup" && r.entity !== "supplier" })
        g[2].after.supplierId = ""
        g[3].after.supplierId = ""
        var x = AP.reflect(g)
        verify(x.ok)
        compare(x.supplierId, "")
        compare(x.supplier, null)
        var z = _good().filter(function(r) { return r.bind !== "sup" && r.entity !== "supplier" && r.bind !== "batch" && r.entity !== "stock_batch" })
        z[1].after.stock = 0
        z[1].after.supplierId = ""
        var y = AP.reflect(z)
        verify(y.ok)
        compare(y.batchId, "")
        compare(y.batch, null)
    }

    function test_F3_reflect_refuses_damaged_answers_data() {
        var out = []
        var mutate = {
            "no product mint": function(r) { r.splice(0, 1) },
            "mint twice": function(r) { r.unshift(_copy(r[0])) },
            "two inventory docs": function(r) { r.push(_copy(r[4])) },
            "no feed row": function(r) { r.pop() },
            "two feed rows": function(r) { r.push(_copy(r[7])) },
            "no created row": function(r) { r.splice(6, 1) },
            "product id differs": function(r) { r[4].after.productId = "PRD-999" },
            "stock not a number": function(r) { r[4].after.stock = "12" },
            "no batch doc": function(r) { r.splice(5, 1) },
            "batch qty differs": function(r) { r[5].after.qtyReceived = 11 },
            "supplier doc id differs": function(r) { r[3].after.supplierId = "SUP-999" },
            "product lacks the supplier": function(r) { r[4].after.supplierId = "" },
            "created id without product": function(r) { r[6].after.txId = "tx-c-PRD-999-n" },
            "feed kind differs": function(r) { r[7].after.kind = "product_restocked" },
            "feed without timestamp": function(r) { delete r[7].after.timestamp },
            "nonces differ": function(r) { r[7].after.id = r[7].after.id + "x" },
            "a delta": function(r) { r.push({ kind: "delta", entity: "inventory", entityId: "p", after: { stock: 1 } }) },
            "null entry": function(r) { r[1] = null }
        }
        for (var name in mutate)
            out.push({ tag: name, name: name, fn: mutate[name] })
        return out
    }

    function test_F3_reflect_refuses_damaged_answers(data) {
        var r = _copy(_good())
        data.fn(r)
        var x = AP.reflect(r)
        compare(x.ok, false)
        compare(x.reason, "malformed-results")
        verify(typeof x.detail === "string")
    }

    function test_F4_reflect_refuses_what_is_not_a_list() {
        var junk = [undefined, null, 5, "x", {}]
        for (var i = 0; i < junk.length; ++i)
            compare(AP.reflect(junk[i]).ok, false)
    }

    // ── monkey (seeded) ───────────────────────────────────────────────────

    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    function test_M1_build_never_throws_and_refuses_with_a_known_reason() {
        var rnd = _rng(20261115)
        var junk = [undefined, null, "", " ", "x", "{{prd}}", "}}{{", "{{{", "\u00e9", 0, -1, 1, 2.5, 1e308, NaN, Infinity, true, false, {}, [], { id: "S" }, { newName: "N" }]
        var reasons = ["bad-key", "bad-name", "bad-price", "bad-tax", "bad-stock", "bad-cost", "bad-supplier", "bad-time", "too-large"]
        var accepted = 0
        var refused = 0
        for (var i = 0; i < 1500; ++i) {
            var inp = _input()
            for (var k in inp)
                if (rnd() < 0.3) inp[k] = junk[Math.floor(rnd() * junk.length)]
            var p = AP.build(inp)
            if (p.ok) {
                accepted++
                compare(_noStrayBraces(p.ops), "")
            } else {
                refused++
                verify(reasons.indexOf(p.reason) >= 0, JSON.stringify(p))
            }
        }
        verify(accepted > 20 && refused > 20, accepted + "/" + refused)
    }
}
