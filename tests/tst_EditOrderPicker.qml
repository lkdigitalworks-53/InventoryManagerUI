import QtQuick
import QtTest
import "../qml/helper/EditOrderPicker.js" as EP
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/editOrderPicker.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "EditOrderPicker"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    function prod(id, stock, over) {
        var p = { productId: id, name: "Name " + id, stock: stock, sellingPrice: 10, price: 4, taxable: false, taxPercent: 0 };
        for (var k in (over || {})) p[k] = over[k];
        return p;
    }
    // A dialog row as _lineItemArray() hands it over (quantity, not qty).
    function row(id, quantity, over) {
        var r = { productId: id, name: "Name " + id, price: 10, quantity: quantity, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 };
        for (var k in (over || {})) r[k] = over[k];
        return r;
    }
    // A picker line as linesOf makes it.
    function line(id, qty, over) {
        var l = { productId: id, name: "Name " + id, qty: qty, price: 10, discountType: "flat", discountValue: 0 };
        for (var k in (over || {})) l[k] = over[k];
        return l;
    }
    function orig(id, quantity, taxable, taxPercent) { return { productId: id, quantity: quantity, taxable: taxable, taxPercent: taxPercent }; }
    function ctx(status, original) { return { status: status, original: original || [] }; }
    function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
    function lk(products, batchMap) {
        var byId = {};
        for (var i = 0; i < products.length; ++i) byId[products[i].productId] = products[i];
        return {
            productOf: function(id) { return has(byId, id) ? byId[id] : null; },
            batchesOf: function(id) { return (batchMap && has(batchMap, id)) ? batchMap[id] : []; }
        };
    }
    function plan(adds, bumps) { return { adds: adds || [], bumps: bumps || [] }; }
    function e(id, qty) { return { productId: id, qty: qty }; }
    // n products P0..P(n-1), each stock 2 with two batches of 1: a line of 2 costs 2 batch changes + 1 stock + 1 sale.
    function world(n) {
        var products = [];
        var batchMap = {};
        for (var i = 0; i < n; ++i) {
            products.push(prod("P" + i, 2));
            batchMap["P" + i] = [{ batchId: "b" + i + "a", supplierId: "", qtyRemaining: 1, unitCost: 1 },
                                 { batchId: "b" + i + "b", supplierId: "", qtyRemaining: 1, unitCost: 1 }];
        }
        return { lookup: lk(products, batchMap), products: products };
    }
    function lineRange(from, to, qty) {
        var out = [];
        for (var i = from; i < to; ++i) out.push(line("P" + i, qty));
        return out;
    }
    function addRange(from, to, qty) {
        var out = [];
        for (var i = from; i < to; ++i) out.push(e("P" + i, qty));
        return out;
    }
    // A small deterministic generator, so a failing monkey run can be replayed from its seed.
    function rng(seed) {
        var s = seed % 2147483647;
        if (s <= 0) s += 2147483646;
        return function() { s = (s * 16807) % 2147483647; return (s - 1) / 2147483646; };
    }

    function test_EOP_01_linesof_one_picker_line_per_row_in_the_same_order_quantity_r() {
        const rows = [row("A", 2, { discountType: "percent", discountValue: 12 }), null, row("B", 5, { discountType: "weird", discountValue: undefined }), 7];
        const out = EP.linesOf(rows);
        eq(out.length, 4);
        eq(out[0], line("A", 2, { discountType: "percent", discountValue: 12 }));
        eq(out[1], { productId: "", name: "", qty: 0, price: 0, discountType: "flat", discountValue: 0 });
        eq(out[2], line("B", 5));
        eq(out[3].productId, "");
        for (const bad of [undefined, null, 5, "x", {}]) eq(EP.linesOf(bad), []);
    }

    function test_EOP_02_availablefor_pending_and_processing_on_hand_minus_what_the_o() {
        for (const st of ["pending", "processing"]) {
            eq(EP.availableFor(prod("A", 10), [line("A", 3)], ctx(st)), 7);
            eq(EP.availableFor(prod("A", 10), [], ctx(st)), 10);
            eq(EP.availableFor(prod("A", 3), [line("A", 5)], ctx(st)), 0);
            eq(EP.availableFor(prod("A", 10), [line("A", 2), line("A", 3)], ctx(st)), 5);
            eq(EP.availableFor(prod("A", 3.9), [], ctx(st)), 3);
            // the original lines are ignored: this order has not taken its units out of stock yet
            eq(EP.availableFor(prod("A", 10), [line("A", 3)], ctx(st, [orig("A", 3, false, 0)])), 7);
        }
    }

    function test_EOP_03_availablefor_completed_on_hand_plus_the_units_the_order_held() {
        const c = ctx("completed", [orig("A", 3, false, 0)]);
        eq(EP.availableFor(prod("A", 4), [line("A", 3)], c), 4);      // unchanged line: available is the true on-hand
        eq(EP.availableFor(prod("A", 4), [line("A", 1)], c), 6);      // returned two: they are back on the shelf
        eq(EP.availableFor(prod("A", 4), [line("A", 5)], c), 2);      // two more taken
        eq(EP.availableFor(prod("A", 4), [], c), 7);                  // line removed: all three free for a re-add
        eq(EP.availableFor(prod("A", 0), [line("A", 3)], c), 0);
        eq(EP.availableFor(prod("A", 0), [line("A", 9)], c), 0);      // never negative
        eq(EP.availableFor(prod("A", 4.9), [line("A", 3)], c), 4);    // whole units
        eq(EP.availableFor(prod("A", 4), [line("A", 2), line("A", 1)], c), 4);   // all lines of the product count
        eq(EP.availableFor(prod("A", 5), [line("A", 1.5)], c), 6);    // 5 + 3 - 1.5 = 6.5, whole units
    }

    function test_EOP_04_availablefor_completed_a_product_that_was_not_on_the_order_a() {
        const c = ctx("completed", [orig("B", 5, false, 0)]);
        eq(EP.availableFor(prod("A", 4), [line("A", 1)], c), 3);
        eq(EP.availableFor(prod("A", 4), [], c), 4);
        eq(EP.availableFor(prod("A", 4), [], ctx("completed")), 4);
        eq(EP.availableFor(prod("A", 4), [], ctx("completed", undefined)), 4);
    }

    function test_EOP_05_availablefor_any_status_that_is_not_exactly_completed_uses_t() {
        const original = [orig("A", 3, false, 0)];
        for (const st of ["", "Completed", "complete", "done", undefined, null, 5, {}])
            eq(EP.availableFor(prod("A", 4), [line("A", 3)], { status: st, original: original }), 1);
        for (const c of [undefined, null, 5, "completed", []]) eq(EP.availableFor(prod("A", 4), [line("A", 3)], c), 1);
    }

    function test_EOP_06_availablefor_ids_match_as_strings_junk_original_quantities_c() {
        const c = ctx("completed", [orig(7, 3, false, 0), orig("J", "3", false, 0), orig("K", -2, false, 0), orig("L", NaN, false, 0), null, 5, { quantity: 4 }]);
        eq(EP.availableFor(prod("7", 4), [line(7, 3)], c), 4);
        eq(EP.availableFor(prod(7, 4), [line("7", 3)], c), 4);
        for (const id of ["J", "K", "L"]) eq(EP.availableFor(prod(id, 4), [], c), 4);
        for (const p of [undefined, null, 5, "x", {}, [], { productId: "", stock: 5 }, { stock: 5 }]) eq(EP.availableFor(p, [], c), 0);
        for (const s of [0, -3, NaN, Infinity, "5", undefined, null]) eq(EP.availableFor(prod("A", s), [], ctx("completed", [orig("A", 2, false, 0)])), 2);
    }

    function test_EOP_07_seedof_a_completed_order_s_product_keeps_its_booked_tax_ever() {
        const p = prod("A", 9, { taxable: true, taxPercent: 18 });
        eq(EP.seedOf(p, ctx("completed", [orig("A", 2, true, 5)])), { taxable: true, taxPercent: 5 });
        eq(EP.seedOf(p, ctx("completed", [orig("A", 2, false, 0)])), { taxable: false, taxPercent: 0 });   // booked as not taxable stays so
        eq(EP.seedOf(p, ctx("completed", [orig("B", 2, true, 5)])), { taxable: true, taxPercent: 18 });
        eq(EP.seedOf(p, ctx("completed")), { taxable: true, taxPercent: 18 });
        eq(EP.seedOf(p, ctx("pending", [orig("A", 2, true, 5)])), { taxable: true, taxPercent: 18 });
        eq(EP.seedOf(p, ctx("processing", [orig("A", 2, true, 5)])), { taxable: true, taxPercent: 18 });
        eq(EP.seedOf(prod("A", 9), ctx("pending")), { taxable: false, taxPercent: 0 });
    }

    function test_EOP_08_seedof_a_rate_that_is_not_a_finite_number_0_is_0_a_missing_p() {
        for (const bad of [-1, NaN, Infinity, "18", undefined, null, {}]) {
            eq(EP.seedOf(prod("A", 9, { taxable: true, taxPercent: bad }), ctx("pending")), { taxable: true, taxPercent: 0 });
            eq(EP.seedOf(prod("A", 9), ctx("completed", [orig("A", 1, true, bad)])), { taxable: true, taxPercent: 0 });
        }
        for (const p of [undefined, null, 5, "x"]) eq(EP.seedOf(p, ctx("pending")), { taxable: false, taxPercent: 0 });
        noThrow(() => EP.seedOf(prod("A", 1), undefined));
    }

    function test_EOP_09_applyplan_pending_a_new_product_is_appended_with_name_sellin() {
        const lookup = lk([prod("A", 9, { taxable: true, taxPercent: 12 }), prod("B", 9, { sellingPrice: undefined, price: 6 })]);
        const r = EP.applyPlan([line("X", 1)], plan([e("A", 3), e("B", 2)]), ctx("pending"), lookup);
        eq(r.skipped, []);
        eq(r.sets, []);
        eq(r.appends, [
            { productId: "A", name: "Name A", price: 10, quantity: 3, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 12 },
            { productId: "B", name: "Name B", price: 6, quantity: 2, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }]);
    }

    function test_EOP_10_applyplan_a_bump_sets_the_line_s_new_total_by_its_row_index_() {
        const lookup = lk([prod("A", 9), prod("B", 9)]);
        const lines = [line("X", 1), line("A", 2, { price: 7.5, discountType: "percent", discountValue: 10 })];
        const r = EP.applyPlan(lines, plan([], [e("A", 3)]), ctx("pending"), lookup);
        eq(r.skipped, []);
        eq(r.appends, []);
        eq(r.sets, [{ index: 1, productId: "A", quantity: 5 }]);
        eq(lines[1].price, 7.5);
    }

    function test_EOP_11_applyplan_completed_a_bump_is_capped_by_on_hand_plus_the_ori() {
        const c = ctx("completed", [orig("A", 3, true, 5)]);
        const lookup = lk([prod("A", 2)]);
        const r = EP.applyPlan([line("A", 3)], plan([], [e("A", 9)]), c, lookup);
        eq(r.sets, [{ index: 0, productId: "A", quantity: 5 }]);
        eq(r.skipped, [{ productId: "A", name: "Name A", reason: "reduced", added: 2, asked: 9 }]);
    }

    function test_EOP_12_applyplan_completed_a_line_removed_in_this_edit_and_picked_a() {
        const c = ctx("completed", [orig("A", 3, true, 5)]);
        const lookup = lk([prod("A", 1, { taxable: true, taxPercent: 18 })]);
        const r = EP.applyPlan([], plan([e("A", 4)]), c, lookup);
        eq(r.sets, []);
        eq(r.appends, [{ productId: "A", name: "Name A", price: 10, quantity: 4, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 5 }]);
        eq(r.skipped, []);
        const over = EP.applyPlan([], plan([e("A", 9)]), c, lookup);
        eq(over.appends[0].quantity, 4);
        eq(over.skipped, [{ productId: "A", name: "Name A", reason: "reduced", added: 4, asked: 9 }]);
    }

    function test_EOP_13_applyplan_completed_a_product_that_was_never_on_the_order_is() {
        const c = ctx("completed", [orig("B", 3, true, 5)]);
        const lookup = lk([prod("A", 2, { taxable: true, taxPercent: 18 })]);
        const r = EP.applyPlan([line("B", 3)], plan([e("A", 5)]), c, lookup);
        eq(r.appends, [{ productId: "A", name: "Name A", price: 10, quantity: 2, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 18 }]);
        eq(r.skipped, [{ productId: "A", name: "Name A", reason: "reduced", added: 2, asked: 5 }]);
    }

    function test_EOP_14_applyplan_a_stale_plan_never_makes_a_duplicate_line_an_add_f() {
        const lookup = lk([prod("A", 9), prod("B", 9)]);
        const r = EP.applyPlan([line("A", 2)], plan([e("A", 1)], [e("B", 2)]), ctx("pending"), lookup);
        eq(r.sets, [{ index: 0, productId: "A", quantity: 3 }]);
        eq(r.appends.length, 1);
        eq(r.appends[0].productId, "B");
        eq(r.appends[0].quantity, 2);
    }

    function test_EOP_15_applyplan_two_entries_for_one_product_together_never_exceed_() {
        const lookup = lk([prod("A", 5)]);
        const p = plan([e("A", 4)], [e("A", 4)]);
        const pending = EP.applyPlan([line("A", 1)], p, ctx("pending"), lookup);
        eq(pending.sets, [{ index: 0, productId: "A", quantity: 5 }]);
        const done = EP.applyPlan([line("A", 1)], p, ctx("completed", [orig("A", 1, false, 0)]), lookup);
        eq(done.sets, [{ index: 0, productId: "A", quantity: 6 }]);
    }

    function test_EOP_16_applyplan_sold_out_no_price_new_line_only_gone_and_throwing_() {
        const lookup = lk([prod("S", 0), prod("N", 9, { sellingPrice: undefined, price: undefined }), prod("A", 9, { sellingPrice: undefined, price: undefined })]);
        const r = EP.applyPlan([line("A", 2)], plan([e("S", 1), e("N", 1), e("Z", 1)], [e("A", 1)]), ctx("pending"), lookup);
        eq(r.appends, []);
        eq(r.sets, [{ index: 0, productId: "A", quantity: 3 }]);
        eq(r.skipped.map(function(s) { return s.productId + ":" + s.reason; }), ["S:out-of-stock", "N:no-price", "Z:gone"]);
        const boom = { productOf: function() { throw new Error("x"); }, batchesOf: function() { return []; } };
        const g = EP.applyPlan([], plan([e("A", 1)]), ctx("pending"), boom);
        eq(g.appends, []);
        eq(g.skipped.map(function(s) { return s.reason; }), ["gone"]);
        // a catalog that answers once and then loses the product (it left between the stock read and the tax read): refused, never added untaxed
        let calls = 0;
        const flaky = { productOf: function(id) { calls++; return calls <= 1 ? prod("A", 9, { taxable: true, taxPercent: 18 }) : null; }, batchesOf: function() { return []; } };
        const f = EP.applyPlan([], plan([e("A", 1)]), ctx("pending"), flaky);
        eq(f.appends, []);
        eq(f.skipped.map(function(s) { return s.reason; }), ["gone"]);
    }

    function test_EOP_17_applyplan_invalid_entries_blank_id_fractional_zero_negative_() {
        const lookup = lk([prod("A", 9)]);
        const bad = [e("", 1), e("A", 1.5), e("A", 0), e("A", -2), e("A", "3"), e("A", NaN), { productId: 5, qty: 1 }, null, 7, undefined];
        const r = EP.applyPlan([], plan(bad), ctx("pending"), lookup);
        eq(r.appends, []);
        eq(r.sets, []);
        eq(r.skipped.length, bad.length);
        for (const s of r.skipped) eq(s.reason, "invalid");
    }

    function test_EOP_18_applyplan_the_lines_it_was_given_are_never_changed() {
        const lookup = lk([prod("A", 9), prod("B", 9)]);
        const lines = [line("A", 2, { price: 3 })];
        const before = JSON.stringify(lines);
        EP.applyPlan(lines, plan([e("B", 2)], [e("A", 1)]), ctx("pending"), lookup);
        eq(JSON.stringify(lines), before);
    }

    function test_EOP_19_applyplan_a_row_index_is_the_index_of_its_row_even_next_to_a() {
        const rows = [row("X", 1), null, row(7, 2)];
        const lines = EP.linesOf(rows);
        const lookup = lk([prod("7", 9)]);
        const r = EP.applyPlan(lines, plan([], [e("7", 3)]), ctx("pending"), lookup);
        eq(r.sets, [{ index: 2, productId: 7, quantity: 5 }]);
    }

    function test_EOP_20_applyplan_nothing_it_is_given_can_make_it_throw_it_answers_e() {
        noThrow(() => {
            for (const lines of [undefined, null, 5, "x", {}]) for (const pl of [undefined, null, 5, {}, { adds: 5, bumps: "x" }]) for (const c of [undefined, null, 5, {}])
                for (const lookup of [undefined, null, 5, {}, { productOf: 5 }]) {
                    const r = EP.applyPlan(lines, pl, c, lookup);
                    if (r.sets.length !== 0 || r.appends.length !== 0) throw new Error("added something from junk");
                }
        });
    }

    function test_EOP_21_commitcheck_a_completed_order_is_always_ok_its_edit_has_no_o() {
        const w = world(60);
        const big = addRange(0, 60, 2);
        eq(EP.commitCheck([], plan(big), ctx("completed"), w.lookup), { ok: true, text: "" });
        eq(EP.commitCheck([], plan(big), ctx("pending"), w.lookup).ok, false);
        eq(EP.commitCheck([], plan(big), ctx("processing"), w.lookup).ok, false);
    }

    function test_EOP_22_commitcheck_pending_and_processing_the_dry_run_judges_the_si() {
        const w = world(60);
        for (const st of ["pending", "processing"]) {
            eq(EP.commitCheck(lineRange(0, 48, 2), plan(addRange(48, 49, 2)), ctx(st), w.lookup), { ok: true, text: "" });
            const r = EP.commitCheck(lineRange(0, 49, 2), plan(addRange(49, 50, 2)), ctx(st), w.lookup);
            eq(r.ok, false);
            ok(r.text.length > 0);
        }
    }

    function test_EOP_23_commitcheck_fails_closed_for_a_pending_order_when_it_cannot_() {
        const w = world(3);
        const noBatches = { productOf: w.lookup.productOf };
        eq(EP.commitCheck([], plan([e("P0", 1)]), ctx("pending"), noBatches).ok, false);
        eq(EP.commitCheck([], plan([e("P0", 1)]), ctx("pending"), undefined).ok, false);
        eq(EP.commitCheck([], plan([e("P0", 1)]), ctx("pending"), { productOf: function() { throw new Error("x"); }, batchesOf: function() { return []; } }).ok, true);
        eq(EP.commitCheck(undefined, plan([e("P0", 1)]), ctx("pending"), w.lookup).ok, true);
        eq(EP.commitCheck([], plan(addRange(0, 3, 1)), undefined, w.lookup).ok, true);
        eq(EP.commitCheck([], plan(addRange(0, 60, 2)), { status: "weird" }, world(60).lookup).ok, false);
    }

    function test_EOP_25_monkey_seeded_over_random_orders_and_plans_no_product_ever_e() {
        for (let seed = 1; seed <= 150; ++seed) {
            const rand = rng(seed);
            const n = 1 + Math.floor(rand() * 6);
            const products = [];
            for (let i = 0; i < n; ++i) products.push(prod("P" + i, Math.floor(rand() * 9), { taxable: rand() < 0.5, taxPercent: Math.floor(rand() * 28) }));
            const completed = rand() < 0.5;
            const original = [];
            const rows = [];
            for (let i = 0; i < n; ++i) {
                if (rand() < 0.5) { const q = 1 + Math.floor(rand() * 4); original.push(orig("P" + i, q, rand() < 0.5, Math.floor(rand() * 28))); if (rand() < 0.7) rows.push(row("P" + i, Math.max(1, q + Math.floor(rand() * 3) - 1), { price: 3 + i })); }
                else if (!completed && rand() < 0.4) rows.push(row("P" + i, 1 + Math.floor(rand() * 3), { price: 3 + i }));
            }
            const c = ctx(completed ? "completed" : "pending", original);
            const lines = EP.linesOf(rows);
            const adds = [], bumps = [];
            const m = Math.floor(rand() * 6);
            for (let k = 0; k < m; ++k) (rand() < 0.5 ? adds : bumps).push(e("P" + Math.floor(rand() * (n + 1)), Math.floor(rand() * 7) - 1 + (rand() < 0.1 ? 0.5 : 0)));
            const r = EP.applyPlan(lines, plan(adds, bumps), c, lk(products));
            const total = {};
            const next = lines.map(function(l) { return { productId: l.productId, qty: l.qty }; });
            for (const s of r.sets) { ok(s.index >= 0 && s.index < lines.length, "set index in range, seed " + seed); next[s.index].qty = s.quantity; ok(s.quantity > lines[s.index].qty, "a set only adds, seed " + seed); }
            for (const a of r.appends) next.push({ productId: a.productId, qty: a.quantity });
            const seen = {};
            for (const l of next) { total[l.productId] = (total[l.productId] || 0) + l.qty; }
            for (const a of r.appends) { ok(!seen[a.productId], "a product is appended once, seed " + seed); seen[a.productId] = true; ok(lines.every(function(l) { return String(l.productId) !== a.productId; }), "no duplicate of an existing line, seed " + seed); ok(a.quantity > 0 && a.discountValue === 0 && a.discountType === "flat", "shape, seed " + seed); }
            for (const p of products) {
                const o = completed ? original.filter(function(x) { return x.productId === p.productId; })[0] : null;
                const heldBefore = lines.reduce(function(s2, l) { return l.productId === p.productId ? s2 + l.qty : s2; }, 0);
                const limit = Math.max(heldBefore, p.stock + (o ? o.quantity : 0));
                ok((total[p.productId] || 0) <= limit, "limit of " + p.productId + ", seed " + seed + ": " + (total[p.productId] || 0) + " > " + limit);
            }
            eq(next.length >= lines.length, true);
        }
    }

    function test_EOP_27_originalof_ids_match_as_strings_in_both_directions_the_first() {
        const list = [null, 5, orig("", 9, true, 5), orig(7, 2, true, 18), orig("A", 3, false, 0), orig("A", 8, true, 5)];
        eq(EP.originalOf(list, "7").quantity, 2);    // numeric id on the order, string id asked
        eq(EP.originalOf(list, 7).quantity, 2);
        eq(EP.originalOf([orig("7", 4, false, 0)], 7).quantity, 4);    // string id on the order, numeric id asked
        eq(EP.originalOf(list, "A").quantity, 3);    // first match
        for (const blank of ["", undefined, null, "Z"]) eq(EP.originalOf(list, blank), null);
        for (const bad of [undefined, null, 5, "x", {}]) eq(EP.originalOf(bad, "A"), null);
        // the helper's own readers use it: a numeric id on the order is booked tax and units for a string id
        const c = ctx("completed", [orig(7, 2, true, 18)]);
        eq(EP.seedOf(prod("7", 5, { taxable: false, taxPercent: 0 }), c), { taxable: true, taxPercent: 18 });
        eq(EP.availableFor(prod("7", 1), [], c), 3);
    }

    function test_EOP_28_applyplan_a_bump_keeps_a_fractional_quantity_the_line_alread() {
        const lookup = lk([prod("A", 10)]);
        for (const status of ["pending", "completed"]) {
            const c = ctx(status, status === "completed" ? [orig("A", 2.5, false, 0)] : []);
            const r = EP.applyPlan([line("A", 2.5)], plan([], [e("A", 1)]), c, lookup);
            eq(r.sets, [{ index: 0, productId: "A", quantity: 3.5 }]);
            eq(r.skipped, []);
        }
        for (const bad of [0, -3, NaN, undefined, "2"]) {
            const r = EP.applyPlan([line("A", bad)], plan([], [e("A", 2)]), ctx("pending"), lookup);
            eq(r.sets, [{ index: 0, productId: "A", quantity: 2 }]);
        }
        const r2 = EP.applyPlan([line("A", 2.5)], plan([], [e("A", 5)]), ctx("pending"), lk([prod("A", 5)]));
        eq(r2.sets, [{ index: 0, productId: "A", quantity: 4.5 }]);
        eq(r2.skipped.map(function(s) { return s.reason; }), ["reduced"]);
    }

    function test_EOP_29_applyplan_a_junk_row_inside_the_lines_keeps_its_index_and_ne() {
        const lines = [null, line("A", 1), 7, "x", line("B", 2)];
        let r = null;
        noThrow(() => { r = EP.applyPlan(lines, plan([e("C", 1)], [e("B", 1), e("A", 2)]), ctx("pending"), lk([prod("A", 9), prod("B", 9)])); });
        eq(r.sets, [{ index: 1, productId: "A", quantity: 3 }, { index: 4, productId: "B", quantity: 3 }]);
        eq(r.appends.length, 0);
        eq(r.skipped.map(function(s) { return s.reason; }), ["gone"]);
        const r2 = EP.applyPlan(lines, plan([e("N", 2)], []), ctx("pending"), lk([prod("A", 9), prod("B", 9), prod("N", 9)]));
        eq(r2.sets, []);
        eq(r2.appends.map(function(a) { return [a.productId, a.quantity]; }), [["N", 2]]);
        eq(lines.length, 5);
        eq(lines[0], null);
    }

    function test_EOP_30_monkey_seeded_fractional_quantities_and_junk_rows_a_set_only() {
        for (let seed = 1; seed <= 150; ++seed) {
            const rand = rng(seed + 1000);
            const n = 1 + Math.floor(rand() * 5);
            const products = [];
            for (let i = 0; i < n; ++i) products.push(prod("P" + i, Math.floor(rand() * 9)));
            const completed = rand() < 0.5;
            const original = [];
            const lines = [];
            for (let i = 0; i < n; ++i) {
                if (rand() < 0.3) lines.push(rand() < 0.5 ? null : 7);
                if (rand() < 0.7) {
                    const q = 0.5 * (1 + Math.floor(rand() * 8));
                    lines.push(line("P" + i, q));
                    if (completed && rand() < 0.7) original.push(orig("P" + i, q, false, 0));
                }
            }
            const adds = [], bumps = [];
            for (let k = 0; k < Math.floor(rand() * 6); ++k) (rand() < 0.5 ? adds : bumps).push(e("P" + Math.floor(rand() * (n + 1)), 1 + Math.floor(rand() * 4)));
            const r = EP.applyPlan(lines, plan(adds, bumps), ctx(completed ? "completed" : "pending", original), lk(products));
            const next = lines.map(function(l) { return (l && typeof l === "object") ? { productId: l.productId, qty: l.qty } : null; });
            for (const s of r.sets) {
                ok(s.index >= 0 && s.index < next.length && next[s.index] !== null && next[s.index].productId === s.productId, "a set points at its own row, seed " + seed);
                ok(s.quantity > next[s.index].qty, "a set only adds, seed " + seed);
                next[s.index].qty = s.quantity;
            }
            for (const a of r.appends) next.push({ productId: a.productId, qty: a.quantity });
            for (const p of products) {
                let held = 0, after = 0;
                for (let i = 0; i < lines.length; ++i) if (lines[i] && lines[i].productId === p.productId && lines[i].qty > 0) held += lines[i].qty;
                for (const l of next) if (l && l.productId === p.productId && l.qty > 0) after += l.qty;
                const o = completed ? original.filter(function(x) { return x.productId === p.productId; })[0] : null;
                const limit = Math.max(held, p.stock + (o ? Math.floor(o.quantity) : 0));
                ok(after <= limit, "limit of " + p.productId + ", seed " + seed + ": " + after + " > " + limit);
            }
        }
    }

    function test_EOP_31_applyplan_a_row_whose_quantity_is_nan_or_not_a_number_is_nev() {
        const lines = [line("A", NaN), line("B", 2), line("C", undefined), line("D", "2"), line("E", -1), line("F", Infinity)];
        const prods = [prod("A", 9), prod("B", 9), prod("C", 9), prod("D", 9), prod("E", 9), prod("F", 9)];
        const before = JSON.stringify(lines);
        const r = EP.applyPlan(lines, plan([], [e("B", 1)]), ctx("pending"), lk(prods));
        eq(r.sets, [{ index: 1, productId: "B", quantity: 3 }]);
        eq(r.appends.length, 0);
        eq(JSON.stringify(lines), before);
        // a bump ON the NaN row counts the row as holding 0: it gets a real, finite quantity
        const r2 = EP.applyPlan(lines, plan([], [e("A", 2)]), ctx("pending"), lk(prods));
        eq(r2.sets, [{ index: 0, productId: "A", quantity: 2 }]);
        // an untouched plan changes nothing at all, however bad the rows are
        eq(EP.applyPlan(lines, plan([], []), ctx("completed", [orig("A", 1, false, 0)]), lk(prods)).sets, []);
    }
}
