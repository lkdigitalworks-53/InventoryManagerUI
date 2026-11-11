import QtQuick
import QtTest
import "../qml/helper/NewOrderPicker.js" as NP
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/newOrderPicker.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "NewOrderPicker"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    function prod(id, stock, over) {
        var p = { productId: id, name: "Name " + id, stock: stock, sellingPrice: 10, price: 4 };
        for (var k in (over || {})) p[k] = over[k];
        return p;
    }
    function line(id, qty, over) {
        var l = { name: "Name " + id, qty: qty, price: 10, productId: id, discountType: "flat", discountValue: 0 };
        for (var k in (over || {})) l[k] = over[k];
        return l;
    }
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
    // n products P0..P(n-1), each with stock 2 and two batches of 1: a line of 2 costs 2 batch changes + 1 stock + 1 sale.
    function world(n) {
        var products = [];
        var batchMap = {};
        for (var i = 0; i < n; ++i) {
            products.push(prod("P" + i, 2));
            batchMap["P" + i] = [{ batchId: "b" + i + "a", supplierId: "", qtyRemaining: 1, unitCost: 1 },
                                 { batchId: "b" + i + "b", supplierId: "", qtyRemaining: 1, unitCost: 1 }];
        }
        return { lookup: lk(products, batchMap), products: products, batchMap: batchMap };
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

    function test_NOP_01_cartqty_all_lines_of_the_product_string_id_matches_a_numeric() {
        const lines = [line("A", 2), line("B", 5), line("A", 3), line(7, 4), null, 5, "x", { productId: "A" }, { productId: "A", qty: NaN }, { productId: "", qty: 9 },
                       { productId: "A", qty: -4 }, { productId: "A", qty: 0 }];
        eq(NP.cartQty(lines, "A"), 5);
        eq(NP.cartQty(lines, "B"), 5);
        eq(NP.cartQty(lines, "7"), 4);
        eq(NP.cartQty(lines, 7), 4);
        eq(NP.cartQty(lines, "zz"), 0);
        for (const id of [undefined, null, "", NaN]) eq(NP.cartQty(lines, id), 0);
        for (const l of [undefined, null, 5, "x", {}, []]) eq(NP.cartQty(l, "A"), 0);
    }

    function test_NOP_02_availablefor_stock_minus_the_cart_whole_units_never_negative() {
        eq(NP.availableFor(prod("A", 10), [line("A", 3)]), 7);
        eq(NP.availableFor(prod("A", 10), []), 10);
        eq(NP.availableFor(prod("A", 3), [line("A", 5)]), 0);
        eq(NP.availableFor(prod("A", 3.9), []), 3);
        eq(NP.availableFor(prod("A", 10), [line("A", 2), line("A", 3)]), 5);
        eq(NP.availableFor(prod("A", 10), [line("B", 4)]), 10);
        eq(NP.availableFor(prod("A", 10), undefined), 10);
        eq(NP.availableFor(prod("A", 5), [line("A", -3)]), 5);
        for (const s of [0, -3, NaN, Infinity, "5", undefined, null, {}]) eq(NP.availableFor(prod("A", s), []), 0);
        for (const p of [undefined, null, 5, "x", {}, [], { productId: "", stock: 5 }, { stock: 5 }]) eq(NP.availableFor(p, []), 0);
    }

    function test_NOP_03_priceof_selling_price_first_the_legacy_price_when_there_is_n() {
        eq(NP.priceOf({ sellingPrice: 12.5, price: 4 }), 12.5);
        eq(NP.priceOf({ sellingPrice: 0, price: 4 }), 0);
        eq(NP.priceOf({ price: 4 }), 4);
        eq(NP.priceOf({ sellingPrice: undefined, price: 4 }), 4);
        eq(NP.priceOf({ sellingPrice: null, price: 4 }), 4);
        for (const bad of [-1, NaN, Infinity, "10", {}, [], true]) {
            eq(NP.priceOf({ sellingPrice: bad, price: 4 }), null);
            eq(NP.priceOf({ price: bad }), null);
        }
        eq(NP.priceOf({}), null);
        for (const p of [undefined, null, 5, "x"]) eq(NP.priceOf(p), null);
    }

    function test_NOP_04_applyplan_adds_a_new_line_product_name_selling_price_flat_di() {
        const lookup = lk([prod("A", 9), prod("B", 9, { sellingPrice: undefined, price: 6 })]);
        const r = NP.applyPlan([line("X", 1)], plan([e("A", 3), e("B", 2)]), lookup);
        eq(r.skipped, []);
        eq(r.lines, [line("X", 1),
                     { name: "Name A", qty: 3, price: 10, productId: "A", discountType: "flat", discountValue: 0 },
                     { name: "Name B", qty: 2, price: 6, productId: "B", discountType: "flat", discountValue: 0 }]);
    }

    function test_NOP_05_applyplan_bumps_an_existing_line_by_n_more_and_keeps_its_edi() {
        const lookup = lk([prod("A", 9)]);
        const edited = line("A", 2, { price: 7.5, discountType: "percent", discountValue: 10 });
        const r = NP.applyPlan([edited], plan([], [e("A", 3)]), lookup);
        eq(r.skipped, []);
        eq(r.lines, [line("A", 5, { price: 7.5, discountType: "percent", discountValue: 10 })]);
    }

    function test_NOP_06_applyplan_mixes_bumps_and_adds_bumps_change_their_lines_new_() {
        const lookup = lk([prod("A", 9), prod("B", 9), prod("C", 9), prod("D", 9)]);
        const r = NP.applyPlan([line("B", 1), line("A", 1)], plan([e("C", 1), e("D", 2)], [e("A", 2), e("B", 4)]), lookup);
        eq(r.skipped, []);
        eq(r.lines.map((l) => [l.productId, l.qty]), [["B", 5], ["A", 3], ["C", 1], ["D", 2]]);
    }

    function test_NOP_07_applyplan_clamps_to_what_is_left_now_and_says_so_asked_5_onl() {
        const lookup = lk([prod("A", 5)]);
        const r = NP.applyPlan([line("A", 2)], plan([], [e("A", 5)]), lookup);
        eq(r.lines, [line("A", 5)]);
        eq(r.skipped, [{ productId: "A", name: "Name A", reason: "reduced", added: 3, asked: 5 }]);
        const r2 = NP.applyPlan([], plan([e("A", 9)]), lookup);
        eq(r2.lines.map((l) => l.qty), [5]);
        eq(r2.skipped, [{ productId: "A", name: "Name A", reason: "reduced", added: 5, asked: 9 }]);
    }

    function test_NOP_08_applyplan_refuses_a_product_that_sold_out_since_the_last_tap() {
        const lookup = lk([prod("A", 0), prod("B", 2), prod("C", NaN)]);
        const r = NP.applyPlan([line("B", 2)], plan([e("A", 1), e("C", 1)], [e("B", 1)]), lookup);
        eq(r.lines, [line("B", 2)]);
        eq(r.skipped.map((s) => [s.productId, s.reason]), [["B", "out-of-stock"], ["A", "out-of-stock"], ["C", "out-of-stock"]]);
    }

    function test_NOP_09_applyplan_refuses_a_product_that_left_the_catalog_or_whose_l() {
        const lookup = lk([prod("A", 5)]);
        const r = NP.applyPlan([], plan([e("Z", 1), e("A", 1)]), lookup);
        eq(r.lines.map((l) => l.productId), ["A"]);
        eq(r.skipped, [{ productId: "Z", name: "Z", reason: "gone" }]);
        const boom = { productOf: function() { throw new Error("x"); }, batchesOf: function() { return []; } };
        eq(NP.applyPlan([line("Q", 1)], plan([e("A", 1)]), boom).skipped.map((s) => s.reason), ["gone"]);
        eq(NP.applyPlan([], plan([e("A", 1)]), { productOf: function() { return 7; } }).skipped.map((s) => s.reason), ["gone"]);
    }

    function test_NOP_10_applyplan_never_adds_a_new_line_without_a_valid_price_a_bump() {
        for (const bad of [undefined, null, -1, NaN, "5", {}]) {
            const lookup = lk([prod("A", 5, { sellingPrice: bad, price: bad })]);
            const r = NP.applyPlan([], plan([e("A", 1)]), lookup);
            eq(r.lines, []);
            eq(r.skipped, [{ productId: "A", name: "Name A", reason: "no-price" }]);
            const b = NP.applyPlan([line("A", 1, { price: 3 })], plan([], [e("A", 2)]), lookup);
            eq(b.lines, [line("A", 3, { price: 3 })]);
            eq(b.skipped, []);
        }
        eq(NP.applyPlan([], plan([e("A", 1)]), lk([prod("A", 5, { sellingPrice: 0 })])).lines.map((l) => l.price), [0]);
    }

    function test_NOP_11_applyplan_refuses_invalid_entries_without_throwing_bad_id_ba() {
        const lookup = lk([prod("A", 9)]);
        const junk = [e("A", 0), e("A", -1), e("A", 1.5), e("A", "3"), e("A", NaN), e("A", Infinity), e("A", undefined), e("", 2), e(5, 2),
                      { qty: 2 }, null, undefined, 7, "A", [], {}];
        for (const j of junk) {
            let r;
            noThrow(() => { r = NP.applyPlan([line("X", 1)], plan([j], [j]), lookup); });
            eq(r.lines, [line("X", 1)]);
            eq(r.skipped.length, 2);
            eq(r.skipped.every((s) => s.reason === "invalid"), true);
        }
    }

    function test_NOP_12_two_entries_for_one_product_share_the_stock_never_more_than_() {
        const lookup = lk([prod("A", 5)]);
        const r = NP.applyPlan([], plan([e("A", 3), e("A", 4)]), lookup);
        eq(r.lines.map((l) => [l.productId, l.qty]), [["A", 5]]);
        eq(r.skipped, [{ productId: "A", name: "Name A", reason: "reduced", added: 2, asked: 4 }]);
    }

    function test_NOP_13_a_plan_made_from_a_stale_order_still_makes_no_duplicate_line() {
        const lookup = lk([prod("A", 9), prod("B", 9)]);
        const r = NP.applyPlan([line("A", 2)], plan([e("A", 1)], [e("B", 4)]), lookup);
        eq(r.lines.map((l) => [l.productId, l.qty]), [["A", 3], ["B", 4]]);
        eq(r.skipped, []);
    }

    function test_NOP_14_applyplan_never_changes_its_input_and_the_output_lines_are_n() {
        const lookup = lk([prod("A", 9)]);
        const lines = FX.freeze([line("A", 2), line("B", 1)]);
        const p = FX.freeze(plan([e("C", 1)], [e("A", 1)]));
        const before = FX.canon([lines, p]);
        const r = NP.applyPlan(lines, p, lk([prod("A", 9), prod("C", 9)]));
        eq(FX.canon([lines, p]), before);
        r.lines[0].qty = 99;
        r.lines[1].name = "changed";
        eq(lines[0].qty, 2);
        eq(lines[1].name, "Name B");
        eq(NP.applyPlan(lines, plan(), lookup).lines, [line("A", 2), line("B", 1)]);
    }

    function test_NOP_15_a_numeric_product_id_on_a_cart_line_matches_the_string_id_of() {
        const lookup = lk([prod("7", 9)]);
        const r = NP.applyPlan([line(7, 2)], plan([e("7", 1)]), lookup);
        eq(r.lines.length, 1);
        eq(r.lines[0].qty, 3);
        eq(r.lines[0].productId, 7);
        eq(NP.availableFor(prod("7", 4), [line(7, 3)]), 1);
    }

    function test_NOP_16_junk_arguments_never_throw_and_change_nothing() {
        const bad = [undefined, null, 5, "x", {}, [], { adds: 5, bumps: "x" }];
        for (const p of bad) for (const l of bad) for (const lookup of [undefined, null, 5, {}, { productOf: 5 }, lk([prod("A", 5)])]) {
            let r;
            noThrow(() => { r = NP.applyPlan(l, p, lookup); });
            eq(Array.isArray(r.lines) && Array.isArray(r.skipped), true);
            noThrow(() => NP.opsCheck(l, p, lookup));
        }
        eq(NP.applyPlan(undefined, undefined, undefined), { lines: [], skipped: [] });
        eq(NP.applyPlan([line("A", 1), null, 3], plan(), lk([])).lines, [line("A", 1)]);
    }

    function test_NOP_17_skippednote_toast_sized_the_first_product_and_why_n_more_for() {
        eq(NP.skippedNote([]), "");
        eq(NP.skippedNote(undefined), "");
        eq(NP.skippedNote("x"), "");
        eq(NP.skippedNote([null, 5, "x"]), "");
        eq(NP.skippedNote([{ productId: "A", name: "Pen", reason: "out-of-stock" }]), "Pen: out of stock");
        eq(NP.skippedNote([{ productId: "A", name: "Pen", reason: "reduced", added: 3, asked: 5 }]), "Pen: only 3 of 5 added");
        eq(NP.skippedNote([{ productId: "A", name: "Pen", reason: "no-price" }]), "Pen: no price");
        eq(NP.skippedNote([{ productId: "A", name: "Cup", reason: "gone" }]), "Cup: no longer listed");
        eq(NP.skippedNote([{ productId: "C", name: "", reason: "invalid" }]), "C: not added");
        eq(NP.skippedNote([null, { productId: "A", name: "Pen", reason: "no-price" }, 5, { productId: "B", name: "Cup", reason: "gone" }, { productId: "C", name: "", reason: "invalid" }]),
           "Pen: no price (+2 more)");
        eq(NP.skippedNote([{ productId: "A", name: "Pen", reason: "mystery" }]), "Pen: not added");
        eq(NP.skippedNote([{}]), "A product: not added");
    }

    function test_NOP_18_opscheck_an_ordinary_order_fits() {
        const w = world(5);
        eq(NP.opsCheck([], plan(addRange(0, 5, 2)), w.lookup), { ok: true, text: "" });
        eq(NP.opsCheck(lineRange(0, 3, 2), plan(addRange(3, 5, 1)), w.lookup), { ok: true, text: "" });
        eq(NP.opsCheck([], plan(), w.lookup), { ok: true, text: "" });
    }

    function test_NOP_19_opscheck_boundary_49_lines_that_each_span_two_batches_cost_1() {
        const w = world(60);
        eq(NP.opsCheck([], plan(addRange(0, 49, 2)), w.lookup), { ok: true, text: "" });
        const r = NP.opsCheck([], plan(addRange(0, 50, 2)), w.lookup);
        eq(r.ok, false);
        ok(r.text.indexOf("too many items") >= 0 && r.text.indexOf("201 changes, limit 200") >= 0 && r.text.indexOf("50 lines") >= 0, r.text);
    }

    function test_NOP_20_opscheck_exactly_200_changes_still_fits_49_two_batch_lines_a() {
        const w = world(60);
        const single = lk(w.products, (function() { var m = {}; for (var k in w.batchMap) m[k] = w.batchMap[k]; m.P49 = [{ batchId: "one", supplierId: "", qtyRemaining: 5, unitCost: 1 }]; return m; })());
        eq(NP.opsCheck([], plan(addRange(0, 50, 2)), single), { ok: true, text: "" });
        eq(NP.opsCheck([], plan(addRange(0, 51, 2)), single).ok, false);
    }

    function test_NOP_21_opscheck_counts_the_lines_already_on_the_order_together_with() {
        const w = world(60);
        eq(NP.opsCheck(lineRange(0, 40, 2), plan(), w.lookup).ok, true);
        eq(NP.opsCheck(lineRange(0, 40, 2), plan(addRange(40, 50, 2)), w.lookup).ok, false);
        eq(NP.opsCheck(lineRange(0, 40, 2), plan(addRange(40, 49, 2)), w.lookup).ok, true);
        // a bump adds no line but can add a batch: 49 lines of 1 use one batch each (3 changes), bumping them to 2 uses two (4)
        eq(NP.opsCheck(lineRange(0, 49, 1), plan([], addRange(0, 49, 1)), w.lookup).ok, true);
        eq(NP.opsCheck(lineRange(0, 50, 1), plan([], addRange(0, 50, 1)), w.lookup).ok, false);
    }

    function test_NOP_22_opscheck_judges_the_size_only_a_stock_shortfall_and_a_vanish() {
        const w = world(3);
        // stock 2 but the cart already holds 9: completion's own checks refuse that, not the size check
        eq(NP.opsCheck([line("P0", 9)], plan(), w.lookup), { ok: true, text: "" });
        eq(NP.opsCheck([line("GONE", 3), line("P1", 1)], plan(addRange(2, 3, 1)), w.lookup), { ok: true, text: "" });
        // batches that cannot cover a line cost a repair batch, and that is counted (one more change per such line)
        const thin = lk([prod("A", 10)], { A: [{ batchId: "a1", supplierId: "", qtyRemaining: 1, unitCost: 1 }] });
        eq(NP.opsCheck([], plan([e("A", 4)]), thin), { ok: true, text: "" });
        // a shortfall on one line must not hide an order that is also too big (the planner would stop at the shortfall first)
        const big = world(60);
        eq(NP.opsCheck([line("P0", 9)], plan(addRange(1, 51, 2)), big.lookup).ok, false);
        eq(NP.opsCheck([line("P0", 9)], plan(addRange(1, 40, 2)), big.lookup).ok, true);
    }

    function test_NOP_23_opscheck_fails_closed_a_missing_lookup_a_missing_batch_reade() {
        const refused = { ok: false, text: "Could not check the size of this order. Try again" };
        const base = lk([prod("A", 5)]);
        eq(NP.opsCheck([], plan([e("A", 1)]), undefined), refused);
        eq(NP.opsCheck([], plan([e("A", 1)]), {}), refused);
        eq(NP.opsCheck([], plan([e("A", 1)]), { productOf: base.productOf }), refused);
        eq(NP.opsCheck([], plan([e("A", 1)]), { batchesOf: base.batchesOf }), refused);
        eq(NP.opsCheck([], plan([e("A", 1)]), { productOf: base.productOf, batchesOf: function() { throw new Error("x"); } }), refused);
        eq(NP.opsCheck([], plan([e("A", 1)]), { productOf: base.productOf, batchesOf: function() { return "junk"; } }), refused);
    }

    function test_NOP_24_seeded_monkey_300_rounds_the_order_never_exceeds_the_stock_n() {
        const rand = FX.rng(47);
        const pick = (list) => list[Math.floor(rand() * list.length)];
        const REASONS = ["invalid", "gone", "out-of-stock", "no-price", "reduced"];
        const seen = { added: 0, bumped: 0, reduced: 0, gone: 0, oos: 0, noprice: 0, invalid: 0, refusedSize: 0, big: 0, nearLimit: 0 };
        for (let round = 0; round < 300; ++round) {
            const products = [];
            for (let i = 0; i < 6; ++i)
                if (rand() < 0.85) products.push(prod("P" + i, pick([0, 1, 4, 9, -2, NaN, 3.7, "5", 20]), {
                    sellingPrice: pick([10, 0, 2.5, -1, NaN, undefined, "5"]), price: pick([4, undefined, -3]) }));
            const batchMap = {};
            for (let i = 0; i < 6; ++i) batchMap["P" + i] = pick([[], [{ batchId: "x" + i, supplierId: "", qtyRemaining: 3, unitCost: 1 }],
                                                                  [{ batchId: "y" + i, supplierId: "", qtyRemaining: 1, unitCost: 1 }, { batchId: "z" + i, supplierId: "", qtyRemaining: 1, unitCost: 1 }]]);
            // one round in ten is a big shop: 60 products with two batches each, so the size check has an exact answer
            const big = rand() < 0.1;
            const w = world(60);
            const lookup = big ? w.lookup : lk(products, batchMap);
            const lines = big ? lineRange(0, Math.floor(rand() * 31), 2) : [];
            if (!big) for (let i = 0; i < 6; ++i) if (rand() < 0.3) lines.push(line(pick(["P" + i, i]), pick([1, 2, 7])));
            const entry = () => ({ productId: pick(["P0", "P1", "P2", "P3", "P4", "P5", "P9", "", 5, null]), qty: pick([1, 2, 5, 9, 0, -1, 1.5, "3"]) });
            const adds = [], bumps = [];
            if (big) for (const x of addRange(30, 30 + Math.floor(rand() * 31), 2)) adds.push(x);
            else for (let i = 0; i < 5; ++i) { if (rand() < 0.5) adds.push(entry()); if (rand() < 0.4) bumps.push(entry()); }
            const p = plan(adds, bumps);
            const before = FX.canon([lines, p]);
            const r = NP.applyPlan(lines, p, lookup);
            eq(FX.canon([lines, p]), before);
            const ids = {};
            for (let i = 0; i < r.lines.length; ++i) {
                const l = r.lines[i];
                const key = String(l.productId);
                ok(!has(ids, key), "duplicate line " + key);
                ids[key] = true;
                ok(typeof l.qty === "number" && l.qty >= 1, "bad quantity");
                ok(typeof l.price === "number" && isFinite(l.price) && l.price >= 0, "bad price");
            }
            const totals = {};
            for (let i = 0; i < r.lines.length; ++i) totals[String(r.lines[i].productId)] = (totals[String(r.lines[i].productId)] || 0) + r.lines[i].qty;
            for (const key in totals) {
                const was = NP.cartQty(lines, key);
                const prodNow = (big ? w.products : products).filter((x) => x.productId === key)[0];
                const cap = prodNow ? Math.max(0, typeof prodNow.stock === "number" && isFinite(prodNow.stock) && prodNow.stock > 0 ? Math.floor(prodNow.stock) : 0) : 0;
                ok(totals[key] <= Math.max(was, cap), "above the stock: " + key + " " + totals[key] + " vs " + cap);
            }
            ok(r.lines.length >= lines.length, "a line was removed");
            for (let i = 0; i < r.skipped.length; ++i) {
                ok(REASONS.indexOf(r.skipped[i].reason) >= 0, "unknown reason");
                if (r.skipped[i].reason === "reduced") seen.reduced++;
                if (r.skipped[i].reason === "gone") seen.gone++;
                if (r.skipped[i].reason === "out-of-stock") seen.oos++;
                if (r.skipped[i].reason === "no-price") seen.noprice++;
                if (r.skipped[i].reason === "invalid") seen.invalid++;
            }
            eq(NP.skippedNote(r.skipped) === "", r.skipped.length === 0);
            if (r.lines.length > lines.length) seen.added++;
            if (r.lines.some((l, i) => i < lines.length && l.qty > lines[i].qty)) seen.bumped++;
            let check;
            noThrow(() => { check = NP.opsCheck(lines, p, lookup); });
            eq(typeof check.ok, "boolean");
            ok(check.ok || check.text.length > 0, "a refusal without words");
            if (!check.ok) seen.refusedSize++;
            // in a big shop every line costs exactly 4 changes (two batches, a stock change, a sale) plus 1 for the order
            if (big) { eq(check.ok, 4 * r.lines.length + 1 <= 200); seen.big++; if (check.ok && r.lines.length >= 45) seen.nearLimit++; }
        }
        ok(seen.added > 30 && seen.bumped > 5 && seen.reduced > 5 && seen.gone > 5 && seen.oos > 20 && seen.noprice > 5 && seen.invalid > 20
           && seen.big > 10 && seen.refusedSize > 3 && seen.nearLimit > 0,
           "the monkey never reached every outcome: " + FX.canon(seen));
    }

    function test_NOP_25_a_cart_line_with_a_negative_or_missing_quantity_frees_no_sto() {
        eq(NP.cartQty([line("A", -4), line("A", 2)], "A"), 2);
        const w = lk([prod("A", 5)]);
        // stock 5 and a stray -3 line: asking for 9 gives 5 (reduced), not 8
        const r = NP.applyPlan([line("A", -3)], plan([e("A", 9)]), w);
        eq(r.lines.length, 1);
        eq(r.lines[0].qty, 5);
        eq(r.skipped.length, 1);
        eq(r.skipped[0].reason, "reduced");
        // a line with no quantity counts as 0, so a bump of 2 gives 2
        const r2 = NP.applyPlan([line("A", undefined)], plan([], [e("A", 2)]), w);
        eq(r2.lines[0].qty, 2);
        eq(r2.skipped.length, 0);
        // a quantity that is a string counts as 0 as well
        const r3 = NP.applyPlan([line("A", "3")], plan([], [e("A", 2)]), w);
        eq(r3.lines[0].qty, 2);
    }

    function test_NOP_26_skippednote_cuts_a_long_name_to_12_characters_with_an_ellips() {
        const one = (name) => NP.skippedNote([{ productId: "A", name: name, reason: "gone" }]);
        eq(one("Twelve chars"), "Twelve chars: no longer listed");
        eq(one("Twelve chars!"), "Twelve char\u2026: no longer listed");
        eq(one("Extra Virgin Cold Pressed Olive Oil"), "Extra Virgi\u2026: no longer listed");
        eq(one("Pen         x"), "Pen\u2026: no longer listed");
        const apples = "\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E";
        eq(one(apples), "\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\u2026: no longer listed");
        eq(NP.skippedNote([{ productId: "prod-long-id-0001", name: "", reason: "gone" }]), "prod-long-i\u2026: no longer listed");
    }

    function test_NOP_27_monkey_any_mix_of_up_to_40_skipped_products_gives_a_note_of_() {
        const rand = FX.rng(91);
        const pick = (list) => list[Math.floor(rand() * list.length)];
        const names = ["", "Pen", "Extra Virgin Cold Pressed Olive Oil", "Basmati Rice 5kg family pack", "\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E\uD83C\uDF4E",
                       "Thirteen char", "Pen         x"];
        const reasons = ["invalid", "gone", "out-of-stock", "no-price", "reduced", "mystery"];
        for (let round = 0; round < 300; ++round) {
            const list = [];
            const n = 1 + Math.floor(rand() * 40);
            for (let i = 0; i < n; ++i)
                list.push({ productId: pick(["A", "B", "", "prod-long-id-0001"]), name: pick(names), reason: pick(reasons),
                            added: Math.floor(rand() * 1000), asked: Math.floor(rand() * 1000) });
            const note = NP.skippedNote(list);
            ok(note.length > 0 && note.length <= 48, "not toast-sized: " + note.length + " " + note);
            ok(!/[\uD800-\uDBFF]\u2026/.test(note), "an emoji was cut in half: " + note);
            eq(/ \(\+\d+ more\)$/.test(note), n > 1);
            if (n > 1) ok(note.indexOf("(+" + (n - 1) + " more)") > 0, "wrong count: " + note);
        }
    }
}
