import QtQuick
import QtTest
import "../qml/helper/RestockPlan.js" as RP
import "../qml/helper/OperationKeys.js" as OK
import "../qml/helper/DocLimits.js" as DL

// Headless tests for the pure restock planner (atomic-ops R3). Pure JS, no singletons.
// Design: docs/superpowers/specs/2026-11-01-r3-restock-plan-design.md
// Test plan: docs/superpowers/test-plans/2026-11-01-r3-restock-plan-test-plan.md
// The same cases run in Node against the REAL server code in functions/test/restockPlan.test.js
// (plan -> validateOperationRequest -> applyOperation -> reflect); this file is the qmltestrunner
// copy, so a QML-engine difference (number formatting, string handling) cannot hide.
TestCase {
    name: "RestockPlan"

    readonly property string key: "restock:1781000000000-abc"
    readonly property string iso: "2026-06-15T12:00:00.000Z"

    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    function _input(over) {
        var base = { key: key, productId: "p1", productName: "Tomato", category: "Veg", qty: 5, unitCost: 12.5,
                     reason: "  weekly  ", now: iso, date: "2026-06-15", supplier: { newName: "  Acme Farms " } }
        for (var k in over) base[k] = over[k]
        return base
    }

    function _kinds(ops) { return ops.map(function(o) { return o.kind }) }

    // A server answer for the new-supplier plan, in the shape operationLogic.applyOperation returns.
    function _good() {
        return [
            { kind: "mint", bind: "sup", counter: "supplier", id: "SUP-001" },
            { kind: "mint", bind: "batch", counter: "stock_batch", id: "BAT-2026-001" },
            { kind: "mutation", entity: "supplier", entityId: "SUP-001", action: "create",
              after: { supplierId: "SUP-001", name: "Acme Farms" } },
            { kind: "mutation", entity: "stock_batch", entityId: "BAT-2026-001", action: "create",
              after: { batchId: "BAT-2026-001", productId: "p1", supplierId: "SUP-001", qtyRemaining: 5 } },
            { kind: "delta", entity: "inventory", entityId: "p1", after: { stock: 15 } },
            { kind: "mutation", entity: "transaction", entityId: "tx-p-BAT-2026-001", action: "create",
              after: { txId: "tx-p-BAT-2026-001", kind: "purchase" } }
        ]
    }

    function _copy(v) { return JSON.parse(JSON.stringify(v)) }

    // ── keys ──────────────────────────────────────────────────────────────

    function test_K1_nonce_is_time_plus_two_padded_draws() {
        var zero = function() { return 0 }
        compare(OK.restockNonce(1700000000123, zero), "1700000000123-000000000000")
        compare(OK.restockNonce(1700000000123.9, zero), "1700000000123-000000000000")
        var a = OK.restockNonce(1, function() { return 0.1 })
        var b = OK.restockNonce(1, _rng(7))
        verify(a !== b)
    }

    function test_K2_restockKey_accepts_a_plain_token_only() {
        compare(OK.restockKey("a-b_c.1"), "restock:a-b_c.1")
        compare(OK.restockKey(new Array(101).join("x")), "restock:" + new Array(101).join("x"))
        var bad = ["", new Array(102).join("x"), "a/b", "a~b", "a b", "a:b", "é", "a\n", null, undefined, 5, {}, []]
        for (var i = 0; i < bad.length; ++i)
            compare(OK.restockKey(bad[i]), "", "token " + JSON.stringify(bad[i]))
    }

    function test_K3_isRestockKey_only_for_a_well_formed_restock_key() {
        verify(OK.isRestockKey(OK.restockKey("n1")))
        var bad = ["restock:", "restock:a/b", "restock:a~1", "completeOrder:o1:1", "Restock:x", " restock:x", "", null, undefined, 7]
        for (var i = 0; i < bad.length; ++i)
            verify(!OK.isRestockKey(bad[i]), String(bad[i]))
    }

    function test_K4_purchaseTxId_prefix() {
        compare(OK.purchaseTxId("BAT-2026-038"), "tx-p-BAT-2026-038")
        compare(OK.purchaseTxId("{{batch}}"), "tx-p-{{batch}}")
    }

    // ── build: shape ──────────────────────────────────────────────────────

    function test_B1_new_supplier_six_ops_mints_first() {
        var p = RP.build(_input())
        verify(p.ok)
        compare(p.key, key)
        compare(p.opType, "restock")
        compare(JSON.stringify(p.at), JSON.stringify({ supplierMint: 0, batchMint: 1, supplierCreate: 2, batchCreate: 3, delta: 4, purchase: 5 }))
        compare(_kinds(p.ops).join(","), "mint,mint,mutation,mutation,delta,mutation")
        compare(p.ops[0].counter, "supplier"); compare(p.ops[0].bind, "sup")
        compare(p.ops[1].counter, "stock_batch"); compare(p.ops[1].bind, "batch")
        compare(p.ops[2].entityId, "{{sup}}"); compare(p.ops[2].after.name, "Acme Farms")
        compare(p.ops[3].entityId, "{{batch}}"); compare(p.ops[3].after.supplierId, "{{sup}}")
        compare(p.ops[4].entityId, "p1"); compare(p.ops[4].deltas.stock, 5)
        compare(p.ops[4].movements.length, 1)
        compare(p.ops[4].movements[0].kind, "receipt")
        compare(p.ops[4].movements[0].qty, 5)
        compare(p.ops[4].movements[0].reason, "weekly")
        compare(p.ops[5].entityId, "tx-p-{{batch}}"); compare(p.ops[5].after.party, "{{sup}}")
        var creates = [2, 3, 5]
        for (var i = 0; i < creates.length; ++i) {
            compare(p.ops[creates[i]].action, "create")
            verify(p.ops[creates[i]].before === null)
        }
    }

    function test_B2_known_supplier_four_ops() {
        var p = RP.build(_input({ supplier: { id: "SUP-009" } }))
        compare(_kinds(p.ops).join(","), "mint,mutation,delta,mutation")
        compare(JSON.stringify(p.at), JSON.stringify({ supplierMint: -1, batchMint: 0, supplierCreate: -1, batchCreate: 1, delta: 2, purchase: 3 }))
        compare(p.ops[1].after.supplierId, "SUP-009")
        compare(p.ops[3].after.party, "SUP-009")
    }

    function test_B3_no_supplier_has_empty_supplierId_and_party() {
        var list = [null, undefined]
        for (var i = 0; i < list.length; ++i) {
            var p = RP.build(_input({ supplier: list[i] }))
            verify(p.ok)
            compare(p.ops.length, 4)
            compare(p.ops[1].after.supplierId, "")
            compare(p.ops[3].after.party, "")
        }
    }

    function test_B4_docs_carry_every_field_of_the_qml_builders() {
        var p = RP.build(_input())
        compare(JSON.stringify(p.ops[2].after), JSON.stringify({ supplierId: "{{sup}}", name: "Acme Farms", contact: "", leadTimeDays: 0,
                terms: "", notes: "", createdAt: iso, updatedAt: iso }))
        compare(JSON.stringify(p.ops[3].after), JSON.stringify({ batchId: "{{batch}}", productId: "p1", supplierId: "{{sup}}",
                qtyReceived: 5, qtyRemaining: 5, unitCost: 12.5, receivedDate: iso, poId: "", note: "weekly", createdAt: iso, updatedAt: iso }))
        compare(JSON.stringify(p.ops[5].after), JSON.stringify({ txId: "tx-p-{{batch}}", kind: "purchase", timestamp: iso, date: "2026-06-15",
                productId: "p1", productName: "Tomato", category: "Veg", party: "{{sup}}", quantity: 5, unitCost: 12.5, unitPrice: 0,
                total: 62.5, orderId: "", reason: "weekly" }))
    }

    function test_B5_free_cost_fractional_qty_empty_text_still_build() {
        var p = RP.build(_input({ unitCost: 0, qty: 2.5, reason: undefined, productName: undefined, category: 5 }))
        verify(p.ok)
        compare(p.ops[5].after.total, 0)
        compare(p.ops[5].after.productName, "")
        compare(p.ops[5].after.category, "")
        compare(p.ops[5].after.reason, "")
        compare(p.ops[4].movements[0].qty, 2.5)
    }

    function test_B6_long_reason_is_cut_for_the_ledger_row_only() {
        var text = new Array(601).join("r")
        var p = RP.build(_input({ reason: text }))
        verify(p.ok)
        compare(p.ops[4].movements[0].reason.length, 500)
        compare(p.ops[3].after.note.length, 600)
    }

    function test_B7_pure_input_untouched_and_repeatable() {
        var inp = _input()
        var snap = JSON.stringify(inp)
        var a = JSON.stringify(RP.build(inp))
        var b = JSON.stringify(RP.build(inp))
        compare(JSON.stringify(inp), snap)
        compare(a, b)
    }

    // ── build: refusals ───────────────────────────────────────────────────

    function test_R1_refusal_reasons_data() {
        return [
            { tag: "key empty", reason: "bad-key", over: { key: "" } },
            { tag: "key undefined", reason: "bad-key", over: { key: undefined } },
            { tag: "key completeOrder", reason: "bad-key", over: { key: "completeOrder:o:1" } },
            { tag: "key slash", reason: "bad-key", over: { key: "restock:a/b" } },
            { tag: "product empty", reason: "bad-product", over: { productId: "" } },
            { tag: "product number", reason: "bad-product", over: { productId: 7 } },
            { tag: "qty 0", reason: "bad-quantity", over: { qty: 0 } },
            { tag: "qty negative", reason: "bad-quantity", over: { qty: -1 } },
            { tag: "qty NaN", reason: "bad-quantity", over: { qty: NaN } },
            { tag: "qty Infinity", reason: "bad-quantity", over: { qty: Infinity } },
            { tag: "qty string", reason: "bad-quantity", over: { qty: "5" } },
            { tag: "qty undefined", reason: "bad-quantity", over: { qty: undefined } },
            { tag: "cost negative", reason: "bad-cost", over: { unitCost: -0.01 } },
            { tag: "cost NaN", reason: "bad-cost", over: { unitCost: NaN } },
            { tag: "cost string", reason: "bad-cost", over: { unitCost: "1" } },
            { tag: "cost undefined", reason: "bad-cost", over: { unitCost: undefined } },
            { tag: "cost overflows the total", reason: "bad-cost", over: { unitCost: 1e308 } },
            { tag: "qty overflows the total", reason: "bad-cost", over: { qty: 1e308, unitCost: 5 } },
            { tag: "both huge", reason: "bad-cost", over: { qty: 1e200, unitCost: 1e200 } },
            { tag: "now empty", reason: "bad-time", over: { now: "" } },
            { tag: "now undefined", reason: "bad-time", over: { now: undefined } },
            { tag: "date short", reason: "bad-time", over: { date: "2026-6-1" } },
            { tag: "date dmy", reason: "bad-time", over: { date: "15/06/2026" } },
            { tag: "date undefined", reason: "bad-time", over: { date: undefined } },
            { tag: "supplier empty obj", reason: "bad-supplier", over: { supplier: {} } },
            { tag: "supplier blank name", reason: "bad-supplier", over: { supplier: { newName: "   " } } },
            { tag: "supplier empty id", reason: "bad-supplier", over: { supplier: { id: "" } } },
            { tag: "supplier string", reason: "bad-supplier", over: { supplier: "SUP-1" } },
            { tag: "supplier number", reason: "bad-supplier", over: { supplier: 5 } },
            { tag: "supplier numeric id", reason: "bad-supplier", over: { supplier: { id: 5 } } }
        ]
    }

    function test_R1_refusal_reasons(data) {
        var p = RP.build(_input(data.over))
        compare(p.ok, false)
        compare(p.reason, data.reason)
        verify(p.ops === undefined, "a refused input builds no ops")
    }

    function test_R1b_non_object_input_is_refused() {
        var bad = [null, undefined, 5, "x", []]
        for (var i = 0; i < bad.length; ++i)
            compare(RP.build(bad[i]).ok, false, "input " + String(bad[i]))
    }

    function test_R2_text_equal_to_a_bound_token_is_refused_everywhere() {
        var toks = ["{{sup}}", "{{batch}}"]
        for (var t = 0; t < toks.length; ++t) {
            var tok = toks[t]
            var overs = [{ productName: "A" + tok }, { category: tok }, { reason: "x " + tok + " y" },
                         { supplier: { newName: tok } }, { supplier: { id: tok } }]
            for (var i = 0; i < overs.length; ++i) {
                var p = RP.build(_input(overs[i]))
                compare(p.ok, false, JSON.stringify(overs[i]))
                compare(p.reason, "reserved-text")
            }
        }
        verify(RP.build(_input({ reason: "{{other}} and {single}" })).ok, "other brace text is left alone")
    }

    // PR #181 sweep F1 (design T12): a total that overflows is refused, the biggest honest one is not.
    function test_R4_overflowing_total_is_refused_but_a_large_finite_one_builds() {
        var p = RP.build(_input({ qty: 1e6, unitCost: 1e9 }))
        verify(p.ok)
        compare(p.ops[p.at.purchase].after.total, 1e15)
        verify(RP.build(_input({ qty: 1e300, unitCost: 0 })).ok, "zero cost: the total is 0, finite")
        compare(RP.build(_input({ unitCost: 0.1 + 0.2 })).ok, true)
    }

    // PR #181 sweep F2 (design T11): a doc over the Firestore size limit is refused before it is queued.
    function test_R5_oversize_text_is_refused_in_every_typed_field() {
        var big = "x".repeat(1100000)
        var overs = [{ reason: big }, { productName: big }, { category: big }, { supplier: { newName: big } }, { supplier: { id: big } }]
        for (var i = 0; i < overs.length; ++i) {
            var p = RP.build(_input(overs[i]))
            compare(p.ok, false, Object.keys(overs[i])[0])
            compare(p.reason, "too-large")
            verify(p.ops === undefined)
        }
    }

    function test_R6_size_edge_is_exactly_the_shared_doc_limit() {
        var p0 = RP.build(_input({ reason: "", supplier: null }))
        var base = 0
        for (var i = 0; i < p0.ops.length; ++i)
            if (p0.ops[i].after) base = Math.max(base, DL.docBytes(p0.ops[i].after))
        var edge = DL.LIMIT_BYTES - base
        verify(edge > 1000000)
        verify(RP.build(_input({ reason: "a".repeat(edge), supplier: null })).ok, "one character under the limit builds")
        compare(RP.build(_input({ reason: "a".repeat(edge + 1), supplier: null })).reason, "too-large")
    }

    function test_R7_multibyte_text_counts_in_bytes() {
        compare(RP.build(_input({ reason: "\u65e5".repeat(400000) })).reason, "too-large")
        verify(RP.build(_input({ reason: "z".repeat(400000) })).ok)
    }

    // ── reflect ───────────────────────────────────────────────────────────

    function test_F0_reflect_reads_a_good_answer() {
        var out = RP.reflect(_good())
        verify(out.ok)
        compare(out.productId, "p1")
        compare(out.stock, 15)
        compare(out.batchId, "BAT-2026-001")
        compare(out.supplierId, "SUP-001")
        compare(out.batch.batchId, "BAT-2026-001")
        compare(out.supplier.supplierId, "SUP-001")
        compare(out.purchase.txId, "tx-p-BAT-2026-001")
    }

    function test_F0b_reflect_known_and_no_supplier_have_a_null_supplier_doc() {
        var isSup = function(r) { return r.bind === "sup" || r.entity === "supplier" }
        var known = _good().filter(function(r) { return !isSup(r) })
        var out = RP.reflect(known)
        verify(out.ok, JSON.stringify(out))
        verify(out.supplier === null)
        compare(out.supplierId, "SUP-001", "the batch's own supplier id is used when nothing was minted")
        var none = _good().filter(function(r) { return !isSup(r) })
        none[1].after.supplierId = ""
        var out2 = RP.reflect(none)
        verify(out2.ok, JSON.stringify(out2))
        compare(out2.supplierId, "")
    }

    function _drop(list, pred) { return list.filter(function(r) { return !pred(r) }) }
    function _map(list, pred, mod) { return list.map(function(r) { return pred(r) ? mod(r) : r }) }
    function _after(extra) {
        return function(r) {
            var c = _copy(r)
            for (var k in extra) c.after[k] = extra[k]
            return c
        }
    }

    function test_F1_reflect_refuses_anything_that_is_not_exactly_one_restock_answer_data() {
        var g = _good()
        var isBatchMint = function(r) { return r.bind === "batch" }
        var isSupMint = function(r) { return r.bind === "sup" }
        var isDelta = function(r) { return r.kind === "delta" }
        var isBatchDoc = function(r) { return r.entity === "stock_batch" }
        var isSupDoc = function(r) { return r.entity === "supplier" }
        var isTx = function(r) { return r.entity === "transaction" }
        return [
            { tag: "not a list", detail: "not-a-list", results: null },
            { tag: "object", detail: "not-a-list", results: {} },
            { tag: "string", detail: "not-a-list", results: "x" },
            { tag: "empty", detail: "no-batch-mint", results: [] },
            { tag: "null entry", detail: "entry-0", results: [null].concat(g.slice(1)) },
            { tag: "unknown kind", detail: "kind-0", results: _map(g, isSupMint, function() { return { kind: "zap" } }) },
            { tag: "mint without id", detail: "mint-id", results: _map(g, isBatchMint, function(r) { var c = _copy(r); c.id = ""; return c }) },
            { tag: "supplier mint without id", detail: "mint-id", results: _map(g, isSupMint, function(r) { var c = _copy(r); c.id = ""; return c }) },
            { tag: "no batch mint", detail: "no-batch-mint", results: _drop(g, isBatchMint) },
            { tag: "no delta", detail: "shape", results: _drop(g, isDelta) },
            { tag: "two deltas", detail: "shape", results: g.concat([g[4]]) },
            { tag: "delta stock not a number", detail: "delta", results: _map(g, isDelta, function(r) { var c = _copy(r); c.after.stock = "15"; return c }) },
            { tag: "delta wrong entity", detail: "delta", results: _map(g, isDelta, function(r) { var c = _copy(r); c.entity = "order"; return c }) },
            { tag: "no batch doc", detail: "shape", results: _drop(g, isBatchDoc) },
            { tag: "batch id differs from mint", detail: "batch-doc", results: _map(g, isBatchDoc, _after({ batchId: "BAT-2026-099" })) },
            { tag: "batch of another product", detail: "batch-doc", results: _map(g, isBatchDoc, _after({ productId: "p2" })) },
            { tag: "no purchase", detail: "shape", results: _drop(g, isTx) },
            { tag: "purchase id differs", detail: "purchase-doc", results: _map(g, isTx, _after({ txId: "tx-p-other" })) },
            { tag: "supplier minted but no doc", detail: "supplier-doc", results: _drop(g, isSupDoc) },
            { tag: "supplier doc differs", detail: "supplier-doc", results: _map(g, isSupDoc, _after({ supplierId: "SUP-099" })) },
            { tag: "batch lacks minted supplier", detail: "supplier-doc", results: _map(g, isBatchDoc, _after({ supplierId: "SUP-099" })) },
            { tag: "supplier doc without a mint", detail: "supplier-without-mint", results: _drop(g, isSupMint) },
            { tag: "unknown mutation entity", detail: "mutation", results: _map(g, isSupDoc, function(r) { var c = _copy(r); c.entity = "order"; return c }) },
            { tag: "mutation without after", detail: "mutation", results: _map(g, isSupDoc, function(r) { var c = _copy(r); c.after = null; return c }) },
            { tag: "two purchases", detail: "shape", results: g.concat([g[5]]) },
            { tag: "two batches", detail: "shape", results: g.concat([g[3]]) },
            { tag: "two suppliers", detail: "supplier-doc", results: g.concat([g[2]]) }
        ]
    }

    function test_F1_reflect_refuses_anything_that_is_not_exactly_one_restock_answer(data) {
        var out = RP.reflect(_copy(data.results))
        compare(out.ok, false, JSON.stringify(out))
        compare(out.reason, "malformed-results")
        compare(out.detail, data.detail)
    }

    function test_F2_a_completion_answer_is_not_mistaken_for_a_restock() {
        var completion = [
            { entity: "stock_batch", entityId: "B1", kind: "delta", after: { qtyRemaining: 1 } },
            { entity: "inventory", entityId: "p1", kind: "delta", after: { stock: 4 } },
            { entity: "order", entityId: "o1", kind: "mutation", after: { orderId: "o1" } }
        ]
        compare(RP.reflect(completion).ok, false)
    }

    // ── monkey ────────────────────────────────────────────────────────────

    function test_M1_seeded_monkey_never_throws_and_every_result_is_ok_or_a_known_reason() {
        var rnd = _rng(20261101)
        var reasons = { "bad-key": 1, "bad-product": 1, "bad-quantity": 1, "bad-cost": 1, "bad-supplier": 1, "bad-time": 1, "reserved-text": 1, "too-large": 1 }
        var junk = [undefined, null, NaN, -1, 0, "", " ", "x", "{{sup}}", {}, [], 1e308, -0]
        var applied = 0, refused = 0
        for (var i = 0; i < 400; ++i) {
            var inp = _input({ key: OK.restockKey(OK.restockNonce(1700000000000 + i, rnd)) })
            var keys = ["productId", "qty", "unitCost", "supplier", "reason", "productName", "now", "date"]
            if (rnd() < 0.5) inp[keys[Math.floor(rnd() * keys.length)]] = junk[Math.floor(rnd() * junk.length)]
            var p = RP.build(inp)
            if (p.ok) {
                applied++
                verify(p.ops.length === 4 || p.ops.length === 6)
                verify(p.ops[p.at.delta].movements.length === 1)
            } else {
                refused++
                verify(reasons[p.reason] === 1, "reason " + p.reason)
            }
        }
        verify(applied > 100, "coverage floor: built " + applied)
        verify(refused > 15, "coverage floor: refused " + refused)
    }
}
