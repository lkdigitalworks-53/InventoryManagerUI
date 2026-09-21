import QtQuick
import QtTest
import "../qml/helper/CompletionPlan.js" as CP

// Headless tests for the pure planner behind the atomic order-completion
// operation. Pure JS, no singletons: nothing here can be polluted by another test.
// Design: docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
TestCase {
    name: "CompletionPlan"

    // Small deterministic PRNG (LCG) so a failing monkey run reproduces from its seed.
    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    function _batch(id, remaining, cost, supplier) {
        return { batchId: id, supplierId: supplier || "", qtyRemaining: remaining, unitCost: cost || 0 }
    }

    // Records what the planner asked the hooks for, so tests can assert on it.
    function _hooks(calls) {
        return {
            orderUpdate: function(lines) {
                calls.orderUpdate.push(lines)
                return { before: { status: "pending" }, after: { status: "completed", products: lines } }
            },
            saleDocs: function(after) {
                calls.saleDocs.push(after)
                var out = []
                for (var i = 0; i < after.products.length; ++i)
                    out.push({ txId: "tx-s-o1-1-" + i, productId: after.products[i].productId })
                return out
            }
        }
    }

    function _calls() { return { orderUpdate: [], saleDocs: [] } }

    function _input(over) {
        var base = {
            orderId: "o1", epoch: 1, now: "2026-09-20T10:00:00.000Z", clampStock: false,
            lines: [{ line: { productId: "p1", name: "Widget", quantity: 3 }, productId: "p1", name: "Widget", qty: 3 }],
            stockByProduct: { p1: 10 },
            batchesByProduct: { p1: [_batch("b1", 10, 5, "s1")] }
        }
        for (var k in over) base[k] = over[k]
        return base
    }

    function _ops(plan, entity, kind) {
        var out = []
        for (var i = 0; i < plan.ops.length; ++i)
            if (plan.ops[i].entity === entity && (!kind || plan.ops[i].kind === kind)) out.push(plan.ops[i])
        return out
    }

    // -- happy path -------------------------------------------------------------

    function test_single_line_single_batch_builds_the_full_operation() {
        var c = _calls()
        var p = CP.build(_input(), _hooks(c))
        compare(p.ok, true)
        compare(p.key, "completeOrder:o1:1")
        compare(p.opType, "completeOrder")
        // batch delta, stock delta, order update, one sale doc
        compare(p.ops.length, 4)
        compare(JSON.stringify(p.ops[0]), JSON.stringify({ kind: "delta", entity: "stock_batch", entityId: "b1",
            deltas: { qtyRemaining: -3 }, floors: { qtyRemaining: 0 }, clamps: {} }))
        compare(JSON.stringify(p.ops[1]), JSON.stringify({ kind: "delta", entity: "inventory", entityId: "p1",
            deltas: { stock: -3 }, floors: { stock: 0 }, clamps: {} }))
        compare(p.ops[2].entity, "order")
        compare(p.ops[2].action, "update")
        compare(p.ops[3].entity, "transaction")
        compare(p.ops[3].action, "create")
        compare(p.ops[3].before, null)
        compare(p.ops[3].entityId, "tx-s-o1-1-0")
    }

    function test_consumption_lineage_is_stamped_on_the_returned_lines() {
        var p = CP.build(_input(), _hooks(_calls()))
        compare(JSON.stringify(p.lines[0].consumption),
                JSON.stringify([{ batchId: "b1", supplierId: "s1", qtyConsumed: 3, unitCost: 5 }]))
        compare(p.lines[0].name, "Widget", "the original line fields survive")
    }

    function test_the_input_line_object_is_never_mutated() {
        var input = _input()
        CP.build(input, _hooks(_calls()))
        compare(input.lines[0].line.consumption, undefined)
    }

    function test_predicted_state_matches_the_plan() {
        var p = CP.build(_input(), _hooks(_calls()))
        compare(p.predicted.batches.b1, 7)
        compare(p.predicted.stock.p1, 7)
        compare(p.predicted.created.length, 0)
    }

    function test_operation_order_is_batches_then_stock_then_order_then_sales() {
        var p = CP.build(_input(), _hooks(_calls()))
        var seq = []
        for (var i = 0; i < p.ops.length; ++i) seq.push(p.ops[i].entity)
        compare(seq.join(","), "stock_batch,inventory,order,transaction")
    }

    function test_orderAfter_is_returned_and_hooks_run_exactly_once_each() {
        var c = _calls()
        var p = CP.build(_input(), _hooks(c))
        compare(c.orderUpdate.length, 1)
        compare(c.saleDocs.length, 1)
        compare(p.orderAfter.status, "completed")
        compare(c.saleDocs[0], p.orderAfter, "sale docs are built from the order AFTER completion")
    }

    // -- FIFO -------------------------------------------------------------------

    function test_a_line_spanning_two_batches_consumes_oldest_first() {
        var p = CP.build(_input({
            lines: [{ line: { productId: "p1" }, productId: "p1", name: "Widget", qty: 8 }],
            batchesByProduct: { p1: [_batch("b1", 5, 2, "s1"), _batch("b2", 10, 3, "s2")] }
        }), _hooks(_calls()))
        var d = _ops(p, "stock_batch", "delta")
        compare(d.length, 2)
        compare(d[0].entityId, "b1"); compare(d[0].deltas.qtyRemaining, -5)
        compare(d[1].entityId, "b2"); compare(d[1].deltas.qtyRemaining, -3)
        compare(p.lines[0].consumption.length, 2)
        compare(p.lines[0].consumption[1].unitCost, 3)
    }

    function test_empty_and_zero_quantity_batches_are_skipped() {
        var p = CP.build(_input({
            batchesByProduct: { p1: [_batch("b0", 0, 1), _batch("bn", undefined, 1), _batch("b1", 10, 5)] }
        }), _hooks(_calls()))
        var d = _ops(p, "stock_batch", "delta")
        compare(d.length, 1)
        compare(d[0].entityId, "b1")
    }

    function test_a_batch_missing_cost_and_supplier_defaults_to_zero_and_empty() {
        var p = CP.build(_input({ batchesByProduct: { p1: [{ batchId: "b1", qtyRemaining: 10 }] } }), _hooks(_calls()))
        compare(JSON.stringify(p.lines[0].consumption[0]),
                JSON.stringify({ batchId: "b1", supplierId: "", qtyConsumed: 3, unitCost: 0 }))
    }

    function test_two_lines_of_the_same_product_share_batch_availability() {
        var p = CP.build(_input({
            lines: [
                { line: { productId: "p1" }, productId: "p1", name: "Widget", qty: 6 },
                { line: { productId: "p1" }, productId: "p1", name: "Widget", qty: 3 }
            ],
            batchesByProduct: { p1: [_batch("b1", 7, 1), _batch("b2", 10, 1)] }
        }), _hooks(_calls()))
        var d = _ops(p, "stock_batch", "delta")
        // line 1: 6 from b1. line 2: 1 left in b1, then 2 from b2.
        compare(d.length, 3)
        compare(d[1].entityId, "b1"); compare(d[1].deltas.qtyRemaining, -1)
        compare(d[2].entityId, "b2"); compare(d[2].deltas.qtyRemaining, -2)
        compare(p.predicted.batches.b1, 0)
        compare(p.predicted.batches.b2, 8)
        compare(p.predicted.stock.p1, 1)
    }

    // -- drift repair -----------------------------------------------------------

    function test_a_shortfall_is_booked_as_a_fully_consumed_repair_batch() {
        var p = CP.build(_input({
            lines: [{ line: { productId: "p1" }, productId: "p1", name: "Widget", qty: 8 }],
            batchesByProduct: { p1: [_batch("b1", 5, 2, "s1")] }
        }), _hooks(_calls()))
        compare(p.ok, true)
        var creates = _ops(p, "stock_batch", "mutation")
        compare(creates.length, 1)
        compare(creates[0].entityId, "BAT-RPR-o1-1-0")
        compare(creates[0].action, "create")
        compare(creates[0].before, null)
        compare(creates[0].after.qtyReceived, 3)
        compare(creates[0].after.qtyRemaining, 0)
        compare(creates[0].after.unitCost, 0)
        compare(creates[0].after.note, CP.REPAIR_NOTE)
        compare(creates[0].after.receivedDate, "2026-09-20T10:00:00.000Z")
        var last = p.lines[0].consumption[p.lines[0].consumption.length - 1]
        compare(JSON.stringify(last), JSON.stringify({ batchId: "BAT-RPR-o1-1-0", supplierId: "", qtyConsumed: 3, unitCost: 0 }))
        compare(p.predicted.created.length, 1)
    }

    function test_a_product_with_no_batches_at_all_is_repaired_in_full() {
        var p = CP.build(_input({ batchesByProduct: {} }), _hooks(_calls()))
        compare(p.ok, true)
        compare(_ops(p, "stock_batch", "delta").length, 0)
        compare(_ops(p, "stock_batch", "mutation")[0].after.qtyReceived, 3)
    }

    function test_repair_batch_ids_are_unique_per_line() {
        var p = CP.build(_input({
            lines: [
                { line: { productId: "p1" }, productId: "p1", name: "A", qty: 1 },
                { line: { productId: "p2" }, productId: "p2", name: "B", qty: 1 }
            ],
            stockByProduct: { p1: 5, p2: 5 }, batchesByProduct: {}
        }), _hooks(_calls()))
        var creates = _ops(p, "stock_batch", "mutation")
        compare(creates[0].entityId, "BAT-RPR-o1-1-0")
        compare(creates[1].entityId, "BAT-RPR-o1-1-1")
    }

    // -- stock validation and clamping (D3) -------------------------------------

    function test_insufficient_stock_is_rejected_before_any_hook_runs() {
        var c = _calls()
        var p = CP.build(_input({ stockByProduct: { p1: 2 } }), _hooks(c))
        compare(p.ok, false)
        compare(p.reason, "out-of-stock")
        compare(p.errors[0], "Widget: need 3, only 2 in stock")
        compare(c.orderUpdate.length, 0)
        compare(c.saleDocs.length, 0)
    }

    function test_demand_is_summed_across_lines_of_the_same_product() {
        var p = CP.build(_input({
            lines: [
                { line: {}, productId: "p1", name: "Widget", qty: 6 },
                { line: {}, productId: "p1", name: "Widget", qty: 6 }
            ],
            stockByProduct: { p1: 10 }
        }), _hooks(_calls()))
        compare(p.ok, false)
        compare(p.errors.length, 1, "the second line is what tips it over")
        compare(p.errors[0], "Widget: need 12, only 10 in stock")
    }

    function test_an_unknown_product_is_not_found_in_inventory() {
        var p = CP.build(_input({
            lines: [
                { line: {}, productId: "ghost", name: "Ghost", qty: 1 },
                { line: {}, productId: "", name: "Blank", qty: 1 }
            ]
        }), _hooks(_calls()))
        compare(p.ok, false)
        compare(p.errors.length, 2)
        compare(p.errors[0], "Ghost: not found in inventory")
        compare(p.errors[1], "Blank: not found in inventory")
    }

    function test_clampStock_accepts_the_sale_and_clamps_the_stock_delta() {
        var p = CP.build(_input({ clampStock: true, stockByProduct: { p1: 2 } }), _hooks(_calls()))
        compare(p.ok, true)
        var s = _ops(p, "inventory")[0]
        compare(JSON.stringify(s.floors), "{}")
        compare(JSON.stringify(s.clamps), JSON.stringify({ stock: 0 }))
        compare(p.predicted.stock.p1, 0, "predicted stock never goes below zero when clamping")
        // 2 in stock but 3 sold and only 10 in b1: batch covers it, no repair needed
        compare(_ops(p, "stock_batch", "mutation").length, 0)
    }

    function test_clampStock_still_reports_unknown_products() {
        var p = CP.build(_input({ clampStock: true, lines: [{ line: {}, productId: "ghost", name: "Ghost", qty: 1 }] }), _hooks(_calls()))
        compare(p.ok, false)
        compare(p.errors[0], "Ghost: not found in inventory")
    }

    function test_a_negative_quantity_line_does_not_free_up_stock_for_another_line() {
        var p = CP.build(_input({
            lines: [
                { line: {}, productId: "p1", name: "Widget", qty: -5 },
                { line: {}, productId: "p1", name: "Widget", qty: 12 }
            ],
            stockByProduct: { p1: 10 }
        }), _hooks(_calls()))
        compare(p.ok, false)
        compare(p.errors[0], "Widget: need 12, only 10 in stock")
    }

    // Product and batch ids are data. One that happens to name an Object.prototype
    // member must behave like any other id, not like a member that "exists".
    function test_an_id_that_names_an_object_prototype_member_is_still_just_an_id() {
        var unknown = CP.build(_input({
            lines: [{ line: {}, productId: "constructor", name: "Odd", qty: 1 }]
        }), _hooks(_calls()))
        compare(unknown.ok, false)
        compare(unknown.errors[0], "Odd: not found in inventory")

        var p = CP.build(_input({
            lines: [{ line: {}, productId: "toString", name: "Odd", qty: 2 }],
            stockByProduct: { toString: 5 },
            batchesByProduct: { toString: [_batch("valueOf", 5, 1)] }
        }), _hooks(_calls()))
        compare(p.ok, true)
        compare(p.predicted.batches.valueOf, 3)
        compare(p.predicted.stock.toString, 3)
    }

    // -- edge cases -------------------------------------------------------------

    function test_a_zero_quantity_line_passes_through_with_empty_consumption_and_no_ops() {
        var p = CP.build(_input({
            lines: [
                { line: { productId: "p1", name: "Widget" }, productId: "p1", name: "Widget", qty: 0 },
                { line: { productId: "p1", name: "Widget" }, productId: "p1", name: "Widget", qty: 2 }
            ]
        }), _hooks(_calls()))
        compare(p.ok, true)
        compare(p.lines.length, 2, "no hole where the zero line was")
        compare(JSON.stringify(p.lines[0].consumption), "[]")
        compare(_ops(p, "inventory").length, 1)
    }

    function test_an_order_with_no_lines_still_produces_the_order_update() {
        var p = CP.build(_input({ lines: [] }), _hooks(_calls()))
        compare(p.ok, true)
        compare(p.ops.length, 1)
        compare(p.ops[0].entity, "order")
    }

    function test_the_operation_cap_is_enforced_at_200() {
        compare(CP.MAX_OPS, 200)
        var lines = [], stock = {}, batches = {}
        // 100 lines x (1 batch delta + 1 stock delta) = 200 ops, + order + 100 sales = 301
        for (var i = 0; i < 100; ++i) {
            lines.push({ line: {}, productId: "p" + i, name: "P" + i, qty: 1 })
            stock["p" + i] = 5
            batches["p" + i] = [_batch("b" + i, 5, 1)]
        }
        var p = CP.build(_input({ lines: lines, stockByProduct: stock, batchesByProduct: batches }), _hooks(_calls()))
        compare(p.ok, false)
        compare(p.reason, "too-many-ops")
        verify(p.errors[0].indexOf("limit 200") >= 0)
    }

    function test_exactly_200_ops_is_allowed() {
        // 66 lines x 3 ops (batch, stock, sale) = 198, + order = 199, + 1 more line's stock-less
        // zero-qty line adds a sale doc only = 200.
        var lines = [], stock = {}, batches = {}
        for (var i = 0; i < 66; ++i) {
            lines.push({ line: {}, productId: "p" + i, name: "P" + i, qty: 1 })
            stock["p" + i] = 5
            batches["p" + i] = [_batch("b" + i, 5, 1)]
        }
        lines.push({ line: {}, productId: "p0", name: "P0", qty: 0 })
        var p = CP.build(_input({ lines: lines, stockByProduct: stock, batchesByProduct: batches }), _hooks(_calls()))
        compare(p.ok, true)
        compare(p.ops.length, 200)
    }

    function test_201_ops_is_rejected() {
        var lines = [], stock = {}, batches = {}
        for (var i = 0; i < 66; ++i) {
            lines.push({ line: {}, productId: "p" + i, name: "P" + i, qty: 1 })
            stock["p" + i] = 5
            batches["p" + i] = [_batch("b" + i, 5, 1)]
        }
        // two zero-quantity lines add a sale doc each: 198 + order + 2 = 201
        lines.push({ line: {}, productId: "p0", name: "P0", qty: 0 })
        lines.push({ line: {}, productId: "p0", name: "P0", qty: 0 })
        var p = CP.build(_input({ lines: lines, stockByProduct: stock, batchesByProduct: batches }), _hooks(_calls()))
        compare(p.ok, false)
        compare(p.reason, "too-many-ops")
    }

    // A reopened order's lines still carry the consumption booked by its earlier
    // completion; re-completing must replace it, not append to it.
    function test_stale_consumption_on_an_input_line_is_replaced_not_appended() {
        var stale = [{ batchId: "old", supplierId: "s0", qtyConsumed: 99, unitCost: 9 }]
        var p = CP.build(_input({
            lines: [{ line: { productId: "p1", consumption: stale }, productId: "p1", name: "Widget", qty: 3 }]
        }), _hooks(_calls()))
        compare(p.lines[0].consumption.length, 1)
        compare(p.lines[0].consumption[0].batchId, "b1")
        compare(stale.length, 1, "and the caller's own array is untouched")
    }

    // -- determinism (the whole point) ------------------------------------------

    function test_the_same_input_always_yields_the_same_plan_and_key() {
        var a = CP.build(_input(), _hooks(_calls()))
        var b = CP.build(_input(), _hooks(_calls()))
        compare(JSON.stringify(a), JSON.stringify(b))
        compare(a.key, b.key)
    }

    function test_a_different_epoch_yields_a_different_key_and_different_repair_ids() {
        var a = CP.build(_input({ epoch: 1, batchesByProduct: {} }), _hooks(_calls()))
        var b = CP.build(_input({ epoch: 2, batchesByProduct: {} }), _hooks(_calls()))
        verify(a.key !== b.key)
        verify(_ops(a, "stock_batch", "mutation")[0].entityId !== _ops(b, "stock_batch", "mutation")[0].entityId)
    }

    // -- monkey -----------------------------------------------------------------

    // Random orders against random batches: whatever the shape, the plan must
    // consume exactly what was sold, never touch a batch beyond what it holds, and
    // never plan more than the cap.
    function test_monkey_random_orders_consume_exactly_what_was_sold() {
        var rand = _rng(20260920)
        for (var run = 0; run < 300; ++run) {
            var nProducts = 1 + Math.floor(rand() * 4)
            var stock = {}, batches = {}, lines = [], sold = {}
            for (var p = 0; p < nProducts; ++p) {
                var pid = "p" + p
                var nb = Math.floor(rand() * 4)
                var bl = [], total = 0
                for (var b = 0; b < nb; ++b) {
                    var q = Math.floor(rand() * 6)
                    bl.push(_batch(pid + "b" + b, q, 1 + b))
                    total += q
                }
                batches[pid] = bl
                stock[pid] = 20
            }
            var nLines = 1 + Math.floor(rand() * 5)
            for (var l = 0; l < nLines; ++l) {
                var lpid = "p" + Math.floor(rand() * nProducts)
                var qty = Math.floor(rand() * 5)
                lines.push({ line: {}, productId: lpid, name: lpid, qty: qty })
                sold[lpid] = (sold[lpid] || 0) + qty
            }
            var plan = CP.build(_input({ lines: lines, stockByProduct: stock, batchesByProduct: batches }), _hooks(_calls()))
            if (!plan.ok) { compare(plan.reason === "out-of-stock" || plan.reason === "too-many-ops", true); continue }

            var consumed = {}
            for (var i = 0; i < plan.lines.length; ++i)
                for (var c = 0; c < plan.lines[i].consumption.length; ++c) {
                    var e = plan.lines[i].consumption[c]
                    consumed[lines[i].productId] = (consumed[lines[i].productId] || 0) + e.qtyConsumed
                }
            for (var sp in sold) compare(consumed[sp] || 0, sold[sp], "run " + run + " product " + sp)

            var taken = {}
            var d = _ops(plan, "stock_batch", "delta")
            for (var j = 0; j < d.length; ++j) taken[d[j].entityId] = (taken[d[j].entityId] || 0) - d[j].deltas.qtyRemaining
            for (var pid2 in batches)
                for (var bb = 0; bb < batches[pid2].length; ++bb) {
                    var bid = batches[pid2][bb].batchId
                    verify((taken[bid] || 0) <= batches[pid2][bb].qtyRemaining, "run " + run + " overdrew " + bid)
                }
            verify(plan.ops.length <= CP.MAX_OPS)
        }
    }
}
