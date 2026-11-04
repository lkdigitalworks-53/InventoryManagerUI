"use strict";
// ProductSearch (qml/helper/ProductSearch.js). Cases SRCH-01..38, plan:
// docs/superpowers/plans/2026-11-03-product-picker-v2-s1-pure-helpers.md. The QML twin
// tests/tst_ProductSearch.qml is derived from these bodies (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const PS = load("ProductSearch.js");

// QML-PRELUDE-BEGIN
function prod(productId, name, sku, category) { return FX.P(productId, name, sku, category); }
function ids(list) { return FX.ids(list); }
// QML-PRELUDE-END

test("SRCH-01 empty query returns all in catalog order", () => {
    eq(ids(PS.filter(FX.CATALOG, "")), ["PRD-001", "PRD-002", "PRD-003"]);
});
test("SRCH-02 blank query is the same as empty", () => {
    eq(ids(PS.filter(FX.CATALOG, "   ")), ["PRD-001", "PRD-002", "PRD-003"]);
});
test("SRCH-03 null and undefined query are the same as empty", () => {
    eq(ids(PS.filter(FX.CATALOG, null)), ["PRD-001", "PRD-002", "PRD-003"]);
    eq(ids(PS.filter(FX.CATALOG, undefined)), ["PRD-001", "PRD-002", "PRD-003"]);
});
test("SRCH-04 case insensitive, equal scores fall back to name order", () => {
    eq(ids(PS.filter(FX.CATALOG, "TOMATO")), ["PRD-001", "PRD-002"]);
    eq(ids(PS.filter(FX.CATALOG, "tomato")), ["PRD-001", "PRD-002"]);
});
test("SRCH-05 finds by product id", () => {
    eq(ids(PS.filter(FX.CATALOG, "prd-003")), ["PRD-003"]);
});
test("SRCH-06 finds by sku", () => {
    eq(ids(PS.filter(FX.CATALOG, "mat-01")), ["PRD-003"]);
});
test("SRCH-07 finds by category", () => {
    eq(ids(PS.filter(FX.CATALOG, "tea")), ["PRD-003"]);
});
test("SRCH-08 every word must match, words may match different fields", () => {
    eq(ids(PS.filter(FX.CATALOG, "cherry veg")), ["PRD-001"]);
});
test("SRCH-09 a word that matches nothing gives nothing", () => {
    eq(ids(PS.filter(FX.CATALOG, "cherry banana")), []);
});
test("SRCH-10 exact id ranks above a name word match", () => {
    const list = [prod("A", "prd-1 special"), prod("prd-1", "Other")];
    eq(ids(PS.filter(list, "prd-1")), ["prd-1", "A"]);
});
test("SRCH-10b a name word ranks above a match buried in the id", () => {
    const list = [prod("1abc2", "Other"), prod("2", "abc thing")];
    eq(ids(PS.filter(list, "abc")), ["2", "1abc2"]);
});
test("SRCH-11 exact sku ranks above a sku prefix", () => {
    const list = [prod("X1", "n1", "abc"), prod("X2", "n2", "ab")];
    eq(ids(PS.filter(list, "ab")), ["X2", "X1"]);
});
test("SRCH-12 a name word prefix ranks above a substring", () => {
    const list = [prod("1", "Tomato"), prod("2", "Matcha")];
    eq(ids(PS.filter(list, "mat")), ["2", "1"]);
    const apart = [prod("1", "Amat"), prod("2", "Zeta Matcha")];
    eq(ids(PS.filter(apart, "mat")), ["2", "1"]);
    // name order would put "Amat" first, so only the word-start rank puts "Matcha" first
    eq(ids(PS.filter([prod("1", "Amat"), prod("2", "Matcha")], "mat")), ["2", "1"]);
});
test("SRCH-13 ties go by name, then catalog order", () => {
    const list = [prod("1", "b", undefined, "xcat"), prod("2", "a", undefined, "xcat"), prod("3", "a", undefined, "xcat")];
    eq(ids(PS.filter(list, "xcat")), ["2", "3", "1"]);
});
test("SRCH-14 regex characters are plain text", () => {
    const list = FX.CATALOG.concat([prod("RX", "a.b(c")]);
    noThrow(() => PS.filter(list, ".*"));
    noThrow(() => PS.filter(list, "("));
    noThrow(() => PS.filter(list, "["));
    noThrow(() => PS.filter(list, "\\"));
    eq(ids(PS.filter(list, ".*")), []);
    eq(ids(PS.filter(list, "(")), ["RX"]);
    eq(ids(PS.filter(list, "[")), []);
    eq(ids(PS.filter(list, "\\")), []);
});
test("SRCH-15 Devanagari prefix", () => {
    const list = [prod("D1", "टमाटर"), prod("D2", "Other")];
    eq(ids(PS.filter(list, "टमा")), ["D1"]);
});
test("SRCH-16 precomposed and decomposed accents find each other", () => {
    const pre = [prod("C1", "Café")];
    const dec = [prod("C2", "Café")];
    eq(ids(PS.filter(pre, "café")), ["C1"]);
    eq(ids(PS.filter(dec, "café")), ["C2"]);
});
test("SRCH-17 missing sku and category do not break matching", () => {
    const list = [{ productId: "A1", name: "Tomato" }, { productId: "A2", name: "Pear", category: null }];
    eq(ids(PS.filter(list, "tomato")), ["A1"]);
    eq(ids(PS.filter(list, "a2")), ["A2"]);
});
test("SRCH-18 only a non-empty string id makes a product (numeric, empty and null ids are junk)", () => {
    eq(ids(PS.filter([{ productId: 1001, name: "x" }], "100")), []);
    eq(ids(PS.filter([{ productId: "", name: "x" }], "")), []);
    eq(ids(PS.filter([{ productId: null, name: "x" }], "")), []);
    eq(ids(PS.filter([{ productId: "1001", name: "x" }], "100")), ["1001"]);
    eq(ids(PS.filter([{ productId: "0", name: "x" }], "")), ["0"]);
});
test("SRCH-19 junk entries are skipped, valid ones returned", () => {
    const list = [null, undefined, 5, "x", [], {}, prod("OK1", "Tomato")];
    eq(ids(PS.filter(list, "")), ["OK1"]);
    eq(ids(PS.filter(list, "tom")), ["OK1"]);
});
test("SRCH-20 category filter and its all-values", () => {
    eq(ids(PS.filter(FX.CATALOG, "", { category: "Tea" })), ["PRD-003"]);
    const all = ["PRD-001", "PRD-002", "PRD-003"];
    eq(ids(PS.filter(FX.CATALOG, "", { category: "All" })), all);
    eq(ids(PS.filter(FX.CATALOG, "", { category: "" })), all);
    eq(ids(PS.filter(FX.CATALOG, "", { category: "tea" })), ["PRD-003"]);
    eq(ids(PS.filter(FX.CATALOG, "", {})), all);
    eq(ids(PS.filter(FX.CATALOG, "", undefined)), all);
});
test("SRCH-21 query and category together", () => {
    eq(ids(PS.filter(FX.CATALOG, "tomato", { category: "Vegetables" })), ["PRD-001", "PRD-002"]);
    eq(ids(PS.filter(FX.CATALOG, "tomato", { category: "Tea" })), []);
});
test("SRCH-22 a very long query is cut to 200 characters and finishes fast", () => {
    const q = new Array(10001).join("a");
    const t0 = Date.now();
    eq(ids(PS.filter(FX.CATALOG, q)), []);
    ok(Date.now() - t0 < 500, "took too long");
    const longName = [prod("L1", q.substring(0, 200))];
    eq(ids(PS.filter(longName, q + "b")), ["L1"]);
    const a199 = new Array(200).join("a");
    eq(ids(PS.filter([prod("L2", a199 + "c")], a199 + "b")), []);
});
test("SRCH-23 a products argument that is not an array gives an empty list", () => {
    eq(PS.filter(null, "x"), []);
    eq(PS.filter({}, "x"), []);
    eq(PS.filter("abc", "x"), []);
    eq(PS.filter(undefined, "x"), []);
    eq(PS.filter("abc", ""), []);
    eq(PS.filter({ length: 1, 0: prod("A", "x") }, ""), []);
});
test("SRCH-24 input is never changed", () => {
    const list = FX.freeze([prod("A", "Tomato", "t1", "Veg"), prod("B", "Pear", "p1", "Fruit")]);
    noThrow(() => PS.filter(list, "to"));
    noThrow(() => PS.filter(list, "", { category: "Veg" }));
    eq(ids(list), ["A", "B"]);
});
test("SRCH-25 two products with the same name are both returned, in catalog order", () => {
    const list = [prod("1", "Tea"), prod("2", "Tea")];
    eq(ids(PS.filter(list, "tea")), ["1", "2"]);
});
test("SRCH-26 the same call twice gives the same answer", () => {
    eq(ids(PS.filter(FX.CATALOG, "to")), ids(PS.filter(FX.CATALOG, "to")));
});
test("SRCH-28 each score tier beats the next one, with names ordered against the rank", () => {
    eq(ids(PS.filter([prod("Q2", "aaa", "abx"), prod("ab", "zzz")], "ab")), ["ab", "Q2"]);
    eq(ids(PS.filter([prod("abx", "aaa"), prod("Q1", "zzz", "ab")], "ab")), ["Q1", "abx"]);
    eq(ids(PS.filter([prod("Q2", "aaa ab"), prod("Q1", "zzz", "abx")], "ab")), ["Q1", "Q2"]);
    eq(ids(PS.filter([prod("Q2", "aaa ab"), prod("abx", "zzz")], "ab")), ["abx", "Q2"]);
    eq(ids(PS.filter([prod("xabx", "aaa"), prod("Q2", "xaby"), prod("Q3", "bbb", "xaby")], "ab")), ["Q2", "xabx", "Q3"]);
});
test("SRCH-29 the scores of several words add up", () => {
    // P1: id exact (100) + sku middle (5) = 105. P2: id prefix (60) + sku prefix (60) = 120. P1 sorts first by name.
    const list = [prod("ab", "aaa", "xcd"), prod("abz", "zzz", "cdz")];
    eq(ids(PS.filter(list, "ab cd")), ["abz", "ab"]);
    // sum 110 (100 + 10) beats sum 65 (5 + 60) although the LAST word scores lower: not "last word wins"
    const rest = [prod("cdz", "aaa", "xabx"), prod("ab", "zzzxcdx")];
    eq(ids(PS.filter(rest, "ab cd")), ["ab", "cdz"]);
});
test("SRCH-30 any run of white space separates words", () => {
    eq(ids(PS.filter(FX.CATALOG, "cherry\ttomato")), ["PRD-001"]);
    eq(ids(PS.filter(FX.CATALOG, "cherry\n tomato")), ["PRD-001"]);
    eq(ids(PS.filter(FX.CATALOG, "  tomato  ")), ids(PS.filter(FX.CATALOG, "tomato")));
    eq(ids(PS.filter(FX.CATALOG, "\t")), ["PRD-001", "PRD-002", "PRD-003"]);
});
test("SRCH-31 an entry without a usable id is skipped whatever else it has", () => {
    eq(ids(PS.filter([{ productId: null, name: "x" }], "")), []);
    const fn = function() {};
    fn.productId = "F1";
    eq(ids(PS.filter([fn], "")), []);
});
test("SRCH-32 name and category must match exactly or by text, not by padding", () => {
    eq(ids(PS.filter(FX.CATALOG, "", { category: " Tea" })), []);
    eq(ids(PS.filter([{ productId: "N1", name: 123 }], "12")), ["N1"]);
    eq(ids(PS.filter([prod("W1", "   ")], "")), ["W1"]);
    eq(ids(PS.filter([prod("W1", "   ")], "x")), []);
});
test("SRCH-33 duplicate product ids are both returned", () => {
    eq(ids(PS.filter([prod("D", "Tea"), prod("D", "Tea")], "tea")), ["D", "D"]);
});
test("SRCH-34 accents match in both directions", () => {
    const pre = [prod("C1", "Café")];
    const dec = [prod("C2", "Café")];
    eq(ids(PS.filter(pre, "Café")), ["C1"]);
    eq(ids(PS.filter(dec, "Café")), ["C2"]);
    eq(ids(PS.filter(pre, "Café")), ["C1"]);
    eq(ids(PS.filter(dec, "Café")), ["C2"]);
});
test("SRCH-35 the category filter and the query both leave the order rule alone", () => {
    const list = [prod("1", "b", undefined, "Veg"), prod("2", "a", undefined, "Veg"), prod("3", "c", undefined, "Tea")];
    eq(ids(PS.filter(list, "", { category: "Veg" })), ["1", "2"]);
    eq(ids(PS.filter(list, "veg", {})), ["2", "1"]);
});
test("SRCH-36 tokenize drops empty words and cuts the query", () => {
    eq(PS.tokenize("  Red \t Tomato  "), ["red", "tomato"]);
    eq(PS.tokenize(""), []);
    eq(PS.tokenize(null), []);
    eq(PS.tokenize(new Array(10001).join("a")).length, 1);
    eq(PS.tokenize(new Array(10001).join("a"))[0].length, PS.MAX_QUERY);
});
test("SRCH-37 filter returns the very same product objects, not copies", () => {
    const list = [prod("S1", "Tea")];
    ok(PS.filter(list, "tea")[0] === list[0], "a copy was returned");
});
test("SRCH-38 a non-string category option is ignored", () => {
    eq(ids(PS.filter(FX.CATALOG, "", { category: 5 })), ["PRD-001", "PRD-002", "PRD-003"]);
    eq(ids(PS.filter(FX.CATALOG, "", { category: null })), ["PRD-001", "PRD-002", "PRD-003"]);
});
test("SRCH-27 seeded monkey, 400 rounds", () => {
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
});
