import QtQuick
import QtTest
import "../qml/helper/ProductSearch.js" as PS
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/pickerSearch.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "ProductSearch"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    function P(productId, name, sku, category) { return FX.P(productId, name, sku, category); }
    function ids(list) { return FX.ids(list); }

    function test_SRCH_01_empty_query_returns_all_in_catalog_order() {
        eq(ids(PS.filter(FX.CATALOG, "")), ["PRD-001", "PRD-002", "PRD-003"]);
    }

    function test_SRCH_02_blank_query_is_the_same_as_empty() {
        eq(ids(PS.filter(FX.CATALOG, "   ")), ["PRD-001", "PRD-002", "PRD-003"]);
    }

    function test_SRCH_03_null_and_undefined_query_are_the_same_as_empty() {
        eq(ids(PS.filter(FX.CATALOG, null)), ["PRD-001", "PRD-002", "PRD-003"]);
        eq(ids(PS.filter(FX.CATALOG, undefined)), ["PRD-001", "PRD-002", "PRD-003"]);
    }

    function test_SRCH_04_case_insensitive_equal_scores_fall_back_to_name_order() {
        eq(ids(PS.filter(FX.CATALOG, "TOMATO")), ["PRD-001", "PRD-002"]);
        eq(ids(PS.filter(FX.CATALOG, "tomato")), ["PRD-001", "PRD-002"]);
    }

    function test_SRCH_05_finds_by_product_id() {
        eq(ids(PS.filter(FX.CATALOG, "prd-003")), ["PRD-003"]);
    }

    function test_SRCH_06_finds_by_sku() {
        eq(ids(PS.filter(FX.CATALOG, "mat-01")), ["PRD-003"]);
    }

    function test_SRCH_07_finds_by_category() {
        eq(ids(PS.filter(FX.CATALOG, "tea")), ["PRD-003"]);
    }

    function test_SRCH_08_every_word_must_match_words_may_match_different_fields() {
        eq(ids(PS.filter(FX.CATALOG, "cherry veg")), ["PRD-001"]);
    }

    function test_SRCH_09_a_word_that_matches_nothing_gives_nothing() {
        eq(ids(PS.filter(FX.CATALOG, "cherry banana")), []);
    }

    function test_SRCH_10_exact_id_ranks_above_a_name_word_match() {
        const list = [P("A", "prd-1 special"), P("prd-1", "Other")];
        eq(ids(PS.filter(list, "prd-1")), ["prd-1", "A"]);
    }

    function test_SRCH_11_exact_sku_ranks_above_a_sku_prefix() {
        const list = [P("X1", "n1", "abc"), P("X2", "n2", "ab")];
        eq(ids(PS.filter(list, "ab")), ["X2", "X1"]);
    }

    function test_SRCH_12_a_name_word_prefix_ranks_above_a_substring() {
        const list = [P("1", "Tomato"), P("2", "Matcha")];
        eq(ids(PS.filter(list, "mat")), ["2", "1"]);
        const apart = [P("1", "Amat"), P("2", "Zeta Matcha")];
        eq(ids(PS.filter(apart, "mat")), ["2", "1"]);
    }

    function test_SRCH_13_ties_go_by_name_then_catalog_order() {
        const list = [P("1", "b", undefined, "xcat"), P("2", "a", undefined, "xcat"), P("3", "a", undefined, "xcat")];
        eq(ids(PS.filter(list, "xcat")), ["2", "3", "1"]);
    }

    function test_SRCH_14_regex_characters_are_plain_text() {
        const list = FX.CATALOG.concat([P("RX", "a.b(c")]);
        noThrow(() => PS.filter(list, ".*"));
        noThrow(() => PS.filter(list, "("));
        noThrow(() => PS.filter(list, "["));
        noThrow(() => PS.filter(list, "\\"));
        eq(ids(PS.filter(list, ".*")), []);
        eq(ids(PS.filter(list, "(")), ["RX"]);
        eq(ids(PS.filter(list, "[")), []);
        eq(ids(PS.filter(list, "\\")), []);
    }

    function test_SRCH_15_devanagari_prefix() {
        const list = [P("D1", "टमाटर"), P("D2", "Other")];
        eq(ids(PS.filter(list, "टमा")), ["D1"]);
    }

    function test_SRCH_16_precomposed_and_decomposed_accents_find_each_other() {
        const pre = [P("C1", "Café")];
        const dec = [P("C2", "Café")];
        eq(ids(PS.filter(pre, "café")), ["C1"]);
        eq(ids(PS.filter(dec, "café")), ["C2"]);
    }

    function test_SRCH_17_missing_sku_and_category_do_not_break_matching() {
        const list = [{ productId: "A1", name: "Tomato" }, { productId: "A2", name: "Pear", category: null }];
        eq(ids(PS.filter(list, "tomato")), ["A1"]);
        eq(ids(PS.filter(list, "a2")), ["A2"]);
    }

    function test_SRCH_18_numeric_product_id() {
        eq(ids(PS.filter([{ productId: 1001, name: "x" }], "100")), [1001]);
    }

    function test_SRCH_19_junk_entries_are_skipped_valid_ones_returned() {
        const list = [null, undefined, 5, "x", [], {}, P("OK1", "Tomato")];
        eq(ids(PS.filter(list, "")), ["OK1"]);
        eq(ids(PS.filter(list, "tom")), ["OK1"]);
    }

    function test_SRCH_20_category_filter_and_its_all_values() {
        eq(ids(PS.filter(FX.CATALOG, "", { category: "Tea" })), ["PRD-003"]);
        const all = ["PRD-001", "PRD-002", "PRD-003"];
        eq(ids(PS.filter(FX.CATALOG, "", { category: "All" })), all);
        eq(ids(PS.filter(FX.CATALOG, "", { category: "" })), all);
        eq(ids(PS.filter(FX.CATALOG, "", { category: "tea" })), ["PRD-003"]);
        eq(ids(PS.filter(FX.CATALOG, "", {})), all);
        eq(ids(PS.filter(FX.CATALOG, "", undefined)), all);
    }

    function test_SRCH_21_query_and_category_together() {
        eq(ids(PS.filter(FX.CATALOG, "tomato", { category: "Vegetables" })), ["PRD-001", "PRD-002"]);
        eq(ids(PS.filter(FX.CATALOG, "tomato", { category: "Tea" })), []);
    }

    function test_SRCH_22_a_very_long_query_is_cut_to_200_characters_and_finishes_fast() {
        const q = new Array(10001).join("a");
        const t0 = Date.now();
        eq(ids(PS.filter(FX.CATALOG, q)), []);
        ok(Date.now() - t0 < 50, "took too long");
        const longName = [P("L1", q.substring(0, 200))];
        eq(ids(PS.filter(longName, q + "b")), ["L1"]);
    }

    function test_SRCH_23_a_products_argument_that_is_not_an_array_gives_an_empty_list() {
        eq(PS.filter(null, "x"), []);
        eq(PS.filter({}, "x"), []);
        eq(PS.filter("abc", "x"), []);
        eq(PS.filter(undefined, "x"), []);
    }

    function test_SRCH_24_input_is_never_changed() {
        const list = FX.freeze([P("A", "Tomato", "t1", "Veg"), P("B", "Pear", "p1", "Fruit")]);
        noThrow(() => PS.filter(list, "to"));
        noThrow(() => PS.filter(list, "", { category: "Veg" }));
        eq(ids(list), ["A", "B"]);
    }

    function test_SRCH_25_two_products_with_the_same_name_are_both_returned_in_catalog() {
        const list = [P("1", "Tea"), P("2", "Tea")];
        eq(ids(PS.filter(list, "tea")), ["1", "2"]);
    }

    function test_SRCH_26_the_same_call_twice_gives_the_same_answer() {
        eq(ids(PS.filter(FX.CATALOG, "to")), ids(PS.filter(FX.CATALOG, "to")));
    }

    function test_SRCH_27_seeded_monkey_400_rounds() {
        const rand = FX.rng(7);
        const words = ["tom", "TOM", "Café", "टम", "a.b", "(", "x", "  ", "veg", "tea", "1", "prd"];
        const pick = (list) => list[Math.floor(rand() * list.length)];
        for (let round = 0; round < 400; ++round) {
            const list = [];
            const n = Math.floor(rand() * 8);
            for (let i = 0; i < n; ++i) {
                const p = { productId: pick(["P1", "P2", 7, "tom-" + i]) };
                if (rand() < 0.8) p.name = pick(words) + " " + pick(words);
                if (rand() < 0.5) p.sku = pick(words);
                if (rand() < 0.5) p.category = pick([null, "Veg", "Tea", "veg"]);
                list.push(p);
            }
            const q = pick(words) + (rand() < 0.5 ? " " + pick(words) : "");
            let out = [];
            noThrow(() => { out = PS.filter(list, q); });
            ok(out.length <= list.length, "more results than products");
            for (let k = 0; k < out.length; ++k) {
                ok(list.indexOf(out[k]) >= 0, "result is not one of the products");
                ok(out.indexOf(out[k]) === k, "duplicate result");
                const hay = [out[k].productId, out[k].name, out[k].sku, out[k].category].join(" ").normalize("NFC").toLowerCase();
                const tokens = PS.tokenize(q);
                for (let t = 0; t < tokens.length; ++t) ok(hay.indexOf(tokens[t]) >= 0, "a token does not match");
            }
        }
    }
}
