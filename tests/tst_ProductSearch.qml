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

    function prod(productId, name, sku, category) { return FX.P(productId, name, sku, category); }
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
        const list = [prod("A", "prd-1 special"), prod("prd-1", "Other")];
        eq(ids(PS.filter(list, "prd-1")), ["prd-1", "A"]);
    }

    function test_SRCH_10b_a_name_word_ranks_above_a_match_buried_in_the_id() {
        const list = [prod("1abc2", "Other"), prod("2", "abc thing")];
        eq(ids(PS.filter(list, "abc")), ["2", "1abc2"]);
    }

    function test_SRCH_11_exact_sku_ranks_above_a_sku_prefix() {
        const list = [prod("X1", "n1", "abc"), prod("X2", "n2", "ab")];
        eq(ids(PS.filter(list, "ab")), ["X2", "X1"]);
    }

    function test_SRCH_12_a_name_word_prefix_ranks_above_a_substring() {
        const list = [prod("1", "Tomato"), prod("2", "Matcha")];
        eq(ids(PS.filter(list, "mat")), ["2", "1"]);
        const apart = [prod("1", "Amat"), prod("2", "Zeta Matcha")];
        eq(ids(PS.filter(apart, "mat")), ["2", "1"]);
        // name order would put "Amat" first, so only the word-start rank puts "Matcha" first
        eq(ids(PS.filter([prod("1", "Amat"), prod("2", "Matcha")], "mat")), ["2", "1"]);
    }

    function test_SRCH_13_ties_go_by_name_then_catalog_order() {
        const list = [prod("1", "b", undefined, "xcat"), prod("2", "a", undefined, "xcat"), prod("3", "a", undefined, "xcat")];
        eq(ids(PS.filter(list, "xcat")), ["2", "3", "1"]);
    }

    function test_SRCH_14_regex_characters_are_plain_text() {
        const list = FX.CATALOG.concat([prod("RX", "a.b(c")]);
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
        const list = [prod("D1", "टमाटर"), prod("D2", "Other")];
        eq(ids(PS.filter(list, "टमा")), ["D1"]);
    }

    function test_SRCH_16_precomposed_and_decomposed_accents_find_each_other() {
        const pre = [prod("C1", "Café")];
        const dec = [prod("C2", "Café")];
        eq(ids(PS.filter(pre, "café")), ["C1"]);
        eq(ids(PS.filter(dec, "café")), ["C2"]);
    }

    function test_SRCH_17_missing_sku_and_category_do_not_break_matching() {
        const list = [{ productId: "A1", name: "Tomato" }, { productId: "A2", name: "Pear", category: null }];
        eq(ids(PS.filter(list, "tomato")), ["A1"]);
        eq(ids(PS.filter(list, "a2")), ["A2"]);
    }

    function test_SRCH_18_only_a_non_empty_string_id_makes_a_product_numeric_empty_and() {
        eq(ids(PS.filter([{ productId: 1001, name: "x" }], "100")), []);
        eq(ids(PS.filter([{ productId: "", name: "x" }], "")), []);
        eq(ids(PS.filter([{ productId: null, name: "x" }], "")), []);
        eq(ids(PS.filter([{ productId: "1001", name: "x" }], "100")), ["1001"]);
        eq(ids(PS.filter([{ productId: "0", name: "x" }], "")), ["0"]);
    }

    function test_SRCH_19_junk_entries_are_skipped_valid_ones_returned() {
        const list = [null, undefined, 5, "x", [], {}, prod("OK1", "Tomato")];
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
        ok(Date.now() - t0 < 500, "took too long");
        const longName = [prod("L1", q.substring(0, 200))];
        eq(ids(PS.filter(longName, q + "b")), ["L1"]);
        const a199 = new Array(200).join("a");
        eq(ids(PS.filter([prod("L2", a199 + "c")], a199 + "b")), []);
    }

    function test_SRCH_23_a_products_argument_that_is_not_an_array_gives_an_empty_list() {
        eq(PS.filter(null, "x"), []);
        eq(PS.filter({}, "x"), []);
        eq(PS.filter("abc", "x"), []);
        eq(PS.filter(undefined, "x"), []);
        eq(PS.filter("abc", ""), []);
        eq(PS.filter({ length: 1, 0: prod("A", "x") }, ""), []);
    }

    function test_SRCH_24_input_is_never_changed() {
        const list = FX.freeze([prod("A", "Tomato", "t1", "Veg"), prod("B", "Pear", "p1", "Fruit")]);
        noThrow(() => PS.filter(list, "to"));
        noThrow(() => PS.filter(list, "", { category: "Veg" }));
        eq(ids(list), ["A", "B"]);
    }

    function test_SRCH_25_two_products_with_the_same_name_are_both_returned_in_catalog() {
        const list = [prod("1", "Tea"), prod("2", "Tea")];
        eq(ids(PS.filter(list, "tea")), ["1", "2"]);
    }

    function test_SRCH_26_the_same_call_twice_gives_the_same_answer() {
        eq(ids(PS.filter(FX.CATALOG, "to")), ids(PS.filter(FX.CATALOG, "to")));
    }

    function test_SRCH_28_each_score_tier_beats_the_next_one_with_names_ordered_agains() {
        eq(ids(PS.filter([prod("Q2", "aaa", "abx"), prod("ab", "zzz")], "ab")), ["ab", "Q2"]);
        eq(ids(PS.filter([prod("abx", "aaa"), prod("Q1", "zzz", "ab")], "ab")), ["Q1", "abx"]);
        eq(ids(PS.filter([prod("Q2", "aaa ab"), prod("Q1", "zzz", "abx")], "ab")), ["Q1", "Q2"]);
        eq(ids(PS.filter([prod("Q2", "aaa ab"), prod("abx", "zzz")], "ab")), ["abx", "Q2"]);
        eq(ids(PS.filter([prod("xabx", "aaa"), prod("Q2", "xaby"), prod("Q3", "bbb", "xaby")], "ab")), ["Q2", "xabx", "Q3"]);
    }

    function test_SRCH_29_the_scores_of_several_words_add_up() {
        // P1: id exact (100) + sku middle (5) = 105. P2: id prefix (60) + sku prefix (60) = 120. P1 sorts first by name.
        const list = [prod("ab", "aaa", "xcd"), prod("abz", "zzz", "cdz")];
        eq(ids(PS.filter(list, "ab cd")), ["abz", "ab"]);
        // sum 110 (100 + 10) beats sum 65 (5 + 60) although the LAST word scores lower: not "last word wins"
        const rest = [prod("cdz", "aaa", "xabx"), prod("ab", "zzzxcdx")];
        eq(ids(PS.filter(rest, "ab cd")), ["ab", "cdz"]);
    }

    function test_SRCH_30_any_run_of_white_space_separates_words() {
        eq(ids(PS.filter(FX.CATALOG, "cherry\ttomato")), ["PRD-001"]);
        eq(ids(PS.filter(FX.CATALOG, "cherry\n tomato")), ["PRD-001"]);
        eq(ids(PS.filter(FX.CATALOG, "  tomato  ")), ids(PS.filter(FX.CATALOG, "tomato")));
        eq(ids(PS.filter(FX.CATALOG, "\t")), ["PRD-001", "PRD-002", "PRD-003"]);
    }

    function test_SRCH_31_an_entry_without_a_usable_id_is_skipped_whatever_else_it_has() {
        eq(ids(PS.filter([{ productId: null, name: "x" }], "")), []);
        const fn = function() {};
        fn.productId = "F1";
        eq(ids(PS.filter([fn], "")), []);
    }

    function test_SRCH_32_name_and_category_must_match_exactly_or_by_text_not_by_paddi() {
        eq(ids(PS.filter(FX.CATALOG, "", { category: " Tea" })), []);
        eq(ids(PS.filter([{ productId: "N1", name: 123 }], "12")), ["N1"]);
        eq(ids(PS.filter([prod("W1", "   ")], "")), ["W1"]);
        eq(ids(PS.filter([prod("W1", "   ")], "x")), []);
    }

    function test_SRCH_33_duplicate_product_ids_are_both_returned() {
        eq(ids(PS.filter([prod("D", "Tea"), prod("D", "Tea")], "tea")), ["D", "D"]);
    }

    function test_SRCH_34_accents_match_in_both_directions() {
        const pre = [prod("C1", "Café")];
        const dec = [prod("C2", "Café")];
        eq(ids(PS.filter(pre, "Café")), ["C1"]);
        eq(ids(PS.filter(dec, "Café")), ["C2"]);
        eq(ids(PS.filter(pre, "Café")), ["C1"]);
        eq(ids(PS.filter(dec, "Café")), ["C2"]);
    }

    function test_SRCH_35_the_category_filter_and_the_query_both_leave_the_order_rule_() {
        const list = [prod("1", "b", undefined, "Veg"), prod("2", "a", undefined, "Veg"), prod("3", "c", undefined, "Tea")];
        eq(ids(PS.filter(list, "", { category: "Veg" })), ["1", "2"]);
        eq(ids(PS.filter(list, "veg", {})), ["2", "1"]);
    }

    function test_SRCH_36_tokenize_drops_empty_words_and_cuts_the_query() {
        eq(PS.tokenize("  Red \t Tomato  "), ["red", "tomato"]);
        eq(PS.tokenize(""), []);
        eq(PS.tokenize(null), []);
        eq(PS.tokenize(new Array(10001).join("a")).length, 1);
        eq(PS.tokenize(new Array(10001).join("a"))[0].length, PS.MAX_QUERY);
    }

    function test_SRCH_37_filter_returns_the_very_same_product_objects_not_copies() {
        const list = [prod("S1", "Tea")];
        ok(PS.filter(list, "tea")[0] === list[0], "a copy was returned");
    }

    function test_SRCH_38_a_non_string_category_option_is_ignored() {
        eq(ids(PS.filter(FX.CATALOG, "", { category: 5 })), ["PRD-001", "PRD-002", "PRD-003"]);
        eq(ids(PS.filter(FX.CATALOG, "", { category: null })), ["PRD-001", "PRD-002", "PRD-003"]);
    }

    function test_SRCH_27_seeded_monkey_400_rounds() {
        const rand = FX.rng(7);
        const words = ["tom", "TOM", "Café", "टम", "a.b", "(", "x", "  ", "veg", "tea", "1", "prd"];
        const pick = (list) => list[Math.floor(rand() * list.length)];
        let nonEmpty = 0;
        for (let round = 0; round < 400; ++round) {
            const list = [];
            const n = Math.floor(rand() * 8);
            for (let i = 0; i < n; ++i) {
                const p = { productId: pick(["P1", "P2", "7", "tom-" + i]) };
                if (rand() < 0.8) p.name = pick(words) + " " + pick(words);
                if (rand() < 0.5) p.sku = pick(words);
                if (rand() < 0.5) p.category = pick([null, "Veg", "Tea", "veg"]);
                list.push(p);
            }
            const q = pick(words) + (rand() < 0.5 ? " " + pick(words) : "");
            let out = [];
            noThrow(() => { out = PS.filter(list, q); });
            ok(out.length <= list.length, "more results than products");
            const tokens = PS.tokenize(q);
            let want = 0;
            for (let k = 0; k < list.length; ++k) {
                const h = [list[k].productId, list[k].name, list[k].sku, list[k].category].join(" ").normalize("NFC").toLowerCase();
                let all = true;
                for (let t = 0; t < tokens.length; ++t) if (h.indexOf(tokens[t]) < 0) all = false;
                if (all) { want++; ok(out.indexOf(list[k]) >= 0, "a matching product is missing from the result"); }
            }
            eq(out.length, want);
            if (out.length > 0) nonEmpty++;
            for (let k = 0; k < out.length; ++k) {
                ok(list.indexOf(out[k]) >= 0, "result is not one of the products");
                ok(out.indexOf(out[k]) === k, "duplicate result");
            }
        }
        ok(nonEmpty > 20, "the monkey never found anything: " + nonEmpty);
    }
}
