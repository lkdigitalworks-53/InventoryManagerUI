import QtQuick
import QtTest
import "../qml/helper/PickerSheetModel.js" as PM
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/pickerSheetModel.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "PickerSheetModel"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    function rowKeys() {
        return ["productId", "name", "sku", "category", "unit", "photoId", "price", "available", "maxQty", "inOrder", "qty",
                "canAdd", "reason", "reasonText", "pillStatus", "pillLabel", "inOrderLabel", "atMax"];
    }
    function strKeys() { return ["productId", "name", "sku", "category", "unit", "photoId", "reason", "reasonText", "pillStatus", "pillLabel", "inOrderLabel"]; }
    function numKeys() { return ["price", "available", "maxQty", "inOrder", "qty"]; }
    function boolKeys() { return ["canAdd", "atMax"]; }
    function prod(id, stock, over) {
        var p = { productId: id, name: "Name " + id, sku: "SKU-" + id, category: "Cat", stock: stock, sellingPrice: 10, minStock: 1 };
        for (var k in (over || {})) p[k] = over[k];
        return p;
    }
    function hooks(over) {
        var h = {
            hasPendingMint: function() { return false; },
            unsyncedState: function() { return ""; },
            availableFor: function(p) { return typeof p.stock === "number" ? p.stock : 0; }
        };
        for (var k in (over || {})) h[k] = over[k];
        return h;
    }
    function mk(products, over) {
        var inp = { products: products, hooks: hooks(), orderLines: [], draft: {}, query: "", category: "All", inStockOnly: false };
        for (var k in (over || {})) inp[k] = over[k];
        return PM.build(inp);
    }
    function ids(v) { var out = []; for (var i = 0; i < v.rows.length; ++i) out.push(v.rows[i].productId); return out; }
    function lines(n) { var out = []; for (var i = 0; i < n; ++i) out.push({ productId: "L" + i, qty: 1 }); return out; }

    function test_SHEET_01_junk_input_never_throws_and_gives_an_empty_uncommittable_vie() {
        const junk = [undefined, null, {}, 5, "x", [], { products: 5, hooks: 5, orderLines: "x", draft: 7 }];
        for (let i = 0; i < junk.length; ++i) {
            noThrow(() => PM.build(junk[i]));
            const v = PM.build(junk[i]);
            eq(v.rows, []);
            eq(v.draft, {});
            eq(v.canCommit, { ok: false, reason: "empty" });
            eq(v.empty.kind, "no-products");
            eq(v.hiddenCount, 0);
        }
    }

    function test_SHEET_02_an_empty_query_lists_the_catalog_in_catalog_order_every_row_() {
        const v = mk([prod("B", 5), prod("A", 5), prod("C", 5)]);
        eq(ids(v), ["B", "A", "C"]);
        for (let i = 0; i < v.rows.length; ++i) {
            const r = v.rows[i];
            eq(Object.keys(r).sort(), rowKeys().slice().sort());
            for (let k = 0; k < strKeys().length; ++k) eq(typeof r[strKeys()[k]], "string");
            for (let k = 0; k < numKeys().length; ++k) ok(typeof r[numKeys()[k]] === "number" && isFinite(r[numKeys()[k]]), numKeys()[k] + " is not a finite number");
            for (let k = 0; k < boolKeys().length; ++k) eq(typeof r[boolKeys()[k]], "boolean");
        }
    }

    function test_SHEET_02b_a_plain_row_holds_exactly_these_values_no_reason_text_no_on_() {
        const v = mk([prod("A", 5, { unit: "kg", photoIds: ["p1"] })]);
        eq(v.rows[0], { productId: "A", name: "Name A", sku: "SKU-A", category: "Cat", unit: "kg", photoId: "p1", price: 10,
                        available: 5, maxQty: 5, inOrder: 0, qty: 0, canAdd: true, reason: "", reasonText: "",
                        pillStatus: "active", pillLabel: "5 left", inOrderLabel: "", atMax: false });
    }

    function test_SHEET_03_row_text_name_falls_back_to_the_id_price_prefers_sellingpric() {
        const v = mk([
            prod("A", 5, { name: "", sellingPrice: undefined, price: 7, photoIds: ["p1", "p2"], unit: "kg" }),
            prod("B", 5, { name: undefined, sku: undefined, category: undefined, sellingPrice: "x", price: "y", photoIds: [5] }),
            prod("C", 5, { sellingPrice: 12.5, price: 99, photoIds: [] })
        ]);
        eq([v.rows[0].name, v.rows[0].price, v.rows[0].photoId, v.rows[0].unit], ["A", 7, "p1", "kg"]);
        eq([v.rows[1].name, v.rows[1].sku, v.rows[1].category, v.rows[1].price, v.rows[1].photoId], ["B", "", "", 0, ""]);
        eq([v.rows[2].price, v.rows[2].photoId], [12.5, ""]);
    }

    function test_SHEET_04_availability_pill_n_left_low_at_or_under_the_minimum_never_c() {
        const v = mk([prod("A", 5, { minStock: 2 }), prod("B", 2, { minStock: 2 }), prod("C", 4, { minStock: undefined })]);
        eq([v.rows[0].pillStatus, v.rows[0].pillLabel], ["active", "5 left"]);
        eq([v.rows[1].pillStatus, v.rows[1].pillLabel], ["low", "2 left"]);
        eq([v.rows[2].pillStatus, v.rows[2].pillLabel], ["active", "4 left"]);
        // a minimum that is not a number never makes a product look low: "9" would coerce to 9 in a bare comparison
        eq(mk([prod("A", 5, { minStock: "9" }), prod("B", 5, { minStock: NaN }), prod("C", 5, { minStock: null })]).rows.map((r) => r.pillStatus), ["active", "active", "active"]);
    }

    function test_SHEET_05_a_pending_mint_a_queued_restock_an_unsynced_edit_and_a_delet() {
        const v = mk([prod("A", 5), prod("B", 5), prod("C", 5), prod("D", 5), prod("E", 5)], {
            hooks: hooks({
                hasPendingMint: (id) => id === "A",
                hasQueuedRestock: (id) => id === "B",
                unsyncedState: (id) => (id === "C" ? "parked" : ""),
                isDeleting: (id) => id === "D"
            })
        });
        eq(ids(v), ["E"]);
        eq(v.hiddenCount, 4);
        eq(v.hiddenNote, "4 products hidden while they sync");
    }

    function test_SHEET_05b_a_disabled_row_always_has_words_even_for_a_reason_code_this_() {
        eq(PM.reasonTextFor("out-of-stock"), "Out of stock");
        eq(PM.reasonTextFor("order-full"), "Order is full");
        eq(PM.reasonTextFor("unavailable"), "Not available right now");
        eq(PM.reasonTextFor("something-new"), "Not available right now");
        eq(PM.reasonTextFor(undefined), "Not available right now");
        eq(PM.reasonTextFor("__proto__"), "Not available right now");
    }

    function test_SHEET_06_hiddennote_words_none_one_many_junk() {
        eq(PM.hiddenNote(0), "");
        eq(PM.hiddenNote(1), "1 product hidden while it syncs");
        eq(PM.hiddenNote(2), "2 products hidden while they sync");
        eq(PM.hiddenNote(undefined), "");
        eq(PM.hiddenNote(-3), "");
        eq(PM.hiddenNote("2"), "");
    }

    function test_SHEET_07_the_hidden_count_only_covers_products_that_match_the_search_() {
        const products = [prod("A", 5, { name: "Apple", category: "Fruit" }), prod("B", 5, { name: "Banana", category: "Fruit" }),
                          prod("C", 5, { name: "Cab", category: "Veg" })];
        const h = hooks({ hasPendingMint: (id) => id === "B" || id === "C" });
        eq(mk(products, { hooks: h }).hiddenCount, 2);
        eq(mk(products, { hooks: h, query: "ban" }).hiddenCount, 1);
        eq(mk(products, { hooks: h, category: "Veg" }).hiddenCount, 1);
        eq(mk(products, { hooks: h, query: "zzz" }).hiddenCount, 0);
    }

    function test_SHEET_08_an_out_of_stock_product_is_shown_disabled_with_the_words_and() {
        const products = [prod("A", 5), prod("B", 0)];
        const v = mk(products);
        eq([v.rows[1].canAdd, v.rows[1].reason, v.rows[1].reasonText, v.rows[1].pillStatus, v.rows[1].pillLabel, v.rows[1].maxQty],
           [false, "out-of-stock", "Out of stock", "out of stock", "Out of stock", 0]);
        eq(v.rows[1].atMax, false);
        eq(ids(mk(products, { inStockOnly: true })), ["A"]);
        eq(mk(products, { inStockOnly: true }).hiddenCount, 0);
        eq(mk(products, { inStockOnly: true, query: "zzz" }).empty.kind, "no-match");
    }

    function test_SHEET_09_at_the_line_limit_a_new_product_is_disabled_as_order_full_a_() {
        const base = lines(59);
        const v = mk([prod("N1", 5), prod("N2", 5), prod("L3", 5)], {
            orderLines: base.concat([{ productId: "N2", qty: 2 }]),
            hooks: hooks({ inOrderQty: (id) => (id === "N2" ? 2 : (id === "L3" ? 1 : 0)) })
        });
        eq([v.rows[0].canAdd, v.rows[0].reason, v.rows[0].reasonText, v.rows[0].pillLabel], [false, "order-full", "Order is full", "Order full"]);
        eq([v.rows[1].canAdd, v.rows[1].inOrderLabel], [true, "In this order: 2"]);
        eq([v.rows[2].canAdd, v.rows[2].inOrderLabel], [true, "In this order: 1"]);
    }

    function test_SHEET_10_a_draft_survives_a_search_that_hides_its_row_and_the_row_com() {
        const products = [prod("A", 5, { name: "Apple" }), prod("B", 5, { name: "Banana" })];
        const hidden = mk(products, { draft: { A: 2 }, query: "banana" });
        eq(ids(hidden), ["B"]);
        eq(hidden.draft, { A: 2 });
        eq(hidden.totals.items, 2);
        eq(hidden.draftChanged, false);
        const back = mk(products, { draft: hidden.draft, query: "" });
        eq([back.rows[0].productId, back.rows[0].qty], ["A", 2]);
    }

    function test_SHEET_11_reconcile_clamps_a_quantity_above_the_stock_and_flags_the_ch() {
        const v = mk([prod("A", 5)], { draft: { A: 9 } });
        eq(v.draft, { A: 5 });
        eq(v.draftChanged, true);
        eq([v.rows[0].qty, v.rows[0].atMax], [5, true]);
    }

    function test_SHEET_12_reconcile_drops_a_product_that_left_the_catalog_went_out_of_() {
        const products = [prod("A", 5), prod("B", 0), prod("C", 5)];
        const v = mk(products, { draft: { A: 1, B: 2, C: 3, Z: 4 }, hooks: hooks({ hasPendingMint: (id) => id === "C" }) });
        eq(v.draft, { A: 1 });
        eq(v.draftChanged, true);
    }

    function test_SHEET_13_an_unchanged_draft_is_not_flagged() {
        const v = mk([prod("A", 5), prod("B", 5)], { draft: { A: 2, B: 5 } });
        eq(v.draftChanged, false);
        eq(v.draft, { A: 2, B: 5 });
    }

    function test_SHEET_14_the_draft_is_capped_by_the_stock_that_remains_never_by_what_() {
        const v = mk([prod("A", 5)], { draft: { A: 5 }, orderLines: [{ productId: "A", qty: 3 }], hooks: hooks({ inOrderQty: () => 3 }) });
        eq([v.rows[0].qty, v.rows[0].maxQty, v.rows[0].inOrder, v.rows[0].atMax], [5, 5, 3, true]);
    }

    function test_SHEET_15_totals_items_lines_and_the_amount_at_the_selling_price_a_mis() {
        const products = [prod("A", 9, { sellingPrice: 2.5 }), prod("B", 9, { sellingPrice: undefined, price: 4 }), prod("C", 9, { sellingPrice: undefined, price: undefined })];
        const v = mk(products, { draft: { A: 2, B: 1, C: 3 } });
        eq(v.totals, { items: 6, lines: 3, amount: 9 });
    }

    function test_SHEET_16_commit_gate_empty_ok_and_more_than_60_lines() {
        const products = [prod("A", 5)];
        eq(mk(products).canCommit, { ok: false, reason: "empty" });
        eq(mk(products, { draft: { A: 1 } }).canCommit, { ok: true, reason: "" });
        eq(mk(products, { draft: { A: 1 } }).commitNote, "");
        const over = mk(products, { draft: { A: 1 }, orderLines: lines(60) });
        eq(over.canCommit, { ok: false, reason: "too-many-lines" });
        eq(over.commitNote, "An order holds at most 60 lines.");
    }

    function test_SHEET_17_the_empty_states_each_with_its_own_words() {
        eq(mk([]).empty, { kind: "no-products", text: "There are no products to add yet." });
        const syncing = mk([prod("A", 5)], { hooks: hooks({ hasPendingMint: () => true }) });
        eq(syncing.empty, { kind: "all-hidden", text: "Everything that matches is still syncing." });
        eq(mk([prod("A", 0)], { inStockOnly: true }).empty, { kind: "none-in-stock", text: "No in-stock product matches." });
        eq(mk([prod("A", 5)], { query: "zzz" }).empty, { kind: "no-match", text: "No products match \"zzz\"." });
        eq(mk([prod("A", 5, { category: "Veg" })], { category: "Tea" }).empty, { kind: "no-match", text: "No products in this category." });
        eq(mk([prod("A", 5)]).empty, { kind: "", text: "" });
    }

    function test_SHEET_18_a_long_query_is_cut_to_40_characters_in_the_empty_text() {
        const q = "q".repeat(60);
        eq(mk([prod("A", 5)], { query: q }).empty.text, "No products match \"" + "q".repeat(40) + "...\".");
    }

    function test_SHEET_19_categories_all_first_no_blanks_or_junk_case_insensitive_firs() {
        const list = [prod("A", 1, { category: "veg" }), prod("B", 1, { category: "Fruit" }), prod("C", 1, { category: "Veg" }),
                      prod("D", 1, { category: "  " }), prod("E", 1, { category: undefined }), prod("F", 1, { category: " tea " }),
                      { productId: 7, category: "Junk" }, null, 5, "x"];
        eq(PM.categories(list), ["All", "Fruit", "tea", "veg"]);
        eq(PM.categories(undefined), ["All"]);
        eq(PM.categories([]), ["All"]);
    }

    function test_SHEET_20_the_chip_filters_by_category_regardless_of_case_and_search_r() {
        const tea = mk(FX.CATALOG.map((p) => ({ productId: p.productId, name: p.name, sku: p.sku, category: p.category, stock: 3, sellingPrice: 1 })), { category: "tea" });
        eq(ids(tea), ["PRD-003"]);
        const tomato = mk(FX.CATALOG.map((p) => ({ productId: p.productId, name: p.name, sku: p.sku, category: p.category, stock: 3, sellingPrice: 1 })), { query: "tomato" });
        eq(ids(tomato), ["PRD-001", "PRD-002"]);
    }

    function test_SHEET_21_sameorder_the_same_ids_in_the_same_order_only() {
        const v = mk([prod("A", 5), prod("B", 5)]);
        eq(PM.sameOrder(["A", "B"], v.rows), true);
        eq(PM.sameOrder(["B", "A"], v.rows), false);
        eq(PM.sameOrder(["A"], v.rows), false);
        eq(PM.sameOrder(["A", "B", "C"], v.rows), false);
        eq(PM.sameOrder([], []), true);
        eq(PM.sameOrder(undefined, v.rows), false);
        eq(PM.sameOrder(["A", "B"], undefined), false);
        eq(PM.sameOrder(["A", "B"], [null, null]), false);
    }

    function test_SHEET_22_a_missing_or_partial_hooks_object_fails_closed_every_row_dis() {
        const products = [prod("A", 5), prod("B", 5)];
        const bad = [undefined, null, {}, 5, { availableFor: () => 5 }, { hasPendingMint: () => false, unsyncedState: () => "" }];
        for (let i = 0; i < bad.length; ++i) {
            const v = mk(products, { hooks: bad[i], draft: { A: 1 } });
            eq(ids(v), ["A", "B"]);
            for (let k = 0; k < v.rows.length; ++k) {
                eq([v.rows[k].canAdd, v.rows[k].maxQty], [false, 0]);
                // A missing availableFor reads as no stock (S1 behaviour: disabled, "Out of stock"); every other gap is "unavailable".
                ok(v.rows[k].reason === "unavailable" || (i === 5 && v.rows[k].reason === "out-of-stock"), "reason " + v.rows[k].reason + " for hooks case " + i);
                ok(v.rows[k].reasonText.length > 0 && v.rows[k].pillLabel.length > 0, "a disabled row without words");
            }
            eq(v.draft, {});
        }
    }

    function test_SHEET_23_a_hook_that_throws_disables_that_row_and_nothing_else() {
        const products = [prod("A", 5), prod("B", 5)];
        const v = mk(products, { hooks: hooks({ availableFor: (p) => { if (p.productId === "A") throw new Error("boom"); return 5; } }) });
        eq([v.rows[0].canAdd, v.rows[0].reason], [false, "unavailable"]);
        eq([v.rows[1].canAdd, v.rows[1].maxQty], [true, 5]);
    }

    function test_SHEET_24_the_hooks_are_asked_by_product_id_and_availablefor_gets_the_() {
        const seen = { mint: [], avail: [] };
        mk([prod("A", 5)], { hooks: hooks({ hasPendingMint: (id) => { seen.mint.push(id); return false; }, availableFor: (p) => { seen.avail.push(p.productId); return 5; } }) });
        ok(seen.mint.indexOf("A") >= 0, "hasPendingMint was not asked with the id");
        ok(seen.avail.indexOf("A") >= 0, "availableFor did not get the product");
    }

    function test_SHEET_25_frozen_inputs_are_never_changed_and_the_result_holds_new_obj() {
        const products = FX.freeze([prod("A", 5), prod("B", 0)]);
        const draft = FX.freeze({ A: 9 });
        const orderLines = FX.freeze([{ productId: "L", qty: 1 }]);
        const h = FX.freeze(hooks());
        const v = PM.build({ products: products, hooks: h, orderLines: orderLines, draft: draft, query: "", category: "All", inStockOnly: false });
        eq(v.draft, { A: 5 });
        ok(v.draft !== draft, "returned the input draft");
        ok(v.rows[0] !== products[0], "a row is the product object itself");
        eq(draft, { A: 9 });
    }

    function test_SHEET_26_seeded_monkey_300_rounds_every_row_addable_or_explained_the_() {
        const rand = FX.rng(23);
        const pick = (list) => list[Math.floor(rand() * list.length)];
        const seen = { rows: 0, disabled: 0, hidden: 0, empty: 0, committable: 0, drafted: 0 };
        for (let round = 0; round < 300; ++round) {
            const products = [];
            const n = Math.floor(rand() * 8);
            for (let i = 0; i < n; ++i)
                products.push(prod("P" + i, pick([0, 1, 4, 9, -2, NaN, 3.7]), { category: pick(["A", "a", "B", "", undefined]), name: pick(["Red", "Blue", "", "Réd"]) }));
            const hiddenIds = {};
            for (let i = 0; i < n; ++i) if (rand() < 0.25) hiddenIds["P" + i] = true;
            const draft = {};
            for (let i = 0; i < 10; ++i) if (rand() < 0.5) draft[pick(["P0", "P1", "P2", "P3", "P9", "__proto__", ""])] = pick([1, 2, 5, 50, 0, -1]);
            const v = mk(products, {
                draft: draft, query: pick(["", "red", "p1", "zzz", "  ", "r"]), category: pick(["All", "A", "B", "zz"]), inStockOnly: rand() < 0.3,
                orderLines: rand() < 0.1 ? lines(60) : [], hooks: hooks({ hasPendingMint: (id) => !!hiddenIds[id] })
            });
            let items = 0;
            for (const k in v.draft) {
                ok(Number.isInteger(v.draft[k]) && v.draft[k] >= 1, "bad draft quantity");
                items += v.draft[k];
                ok(!hiddenIds[k], "a hidden product stayed in the draft");
            }
            eq(v.totals.items, items);
            eq(v.canCommit.ok, items > 0 && v.canCommit.reason === "");
            for (let r = 0; r < v.rows.length; ++r) {
                const row = v.rows[r];
                ok(!hiddenIds[row.productId], "a hidden product is listed");
                ok(row.qty <= row.maxQty || (!row.canAdd && row.qty === 0), "quantity above the maximum");
                if (row.canAdd) ok(row.maxQty >= 1, "an addable row with no stock");
                else ok(row.reasonText.length > 0 && row.maxQty === 0, "a disabled row without words");
                eq(Object.keys(row).sort(), rowKeys().slice().sort());
                seen.rows++;
                if (!row.canAdd) seen.disabled++;
            }
            if (v.hiddenCount > 0) seen.hidden++;
            if (v.rows.length === 0) seen.empty++;
            if (v.canCommit.ok) seen.committable++;
            if (items > 0) seen.drafted++;
        }
        ok(seen.rows > 100 && seen.disabled > 20 && seen.hidden > 20 && seen.empty > 10 && seen.committable > 10 && seen.drafted > 10,
           "the monkey never reached every outcome: " + FX.canon(seen));
    }
}
