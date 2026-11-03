"use strict";
// ProductSearch (qml/helper/ProductSearch.js). Cases SRCH-01..27, plan:
// docs/superpowers/plans/2026-11-03-product-picker-v2-s1-pure-helpers.md. The QML twin
// tests/tst_ProductSearch.qml is derived from these bodies (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const PS = load("ProductSearch.js");

// QML-PRELUDE-BEGIN
function P(productId, name, sku, category) { return FX.P(productId, name, sku, category); }
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
    const list = [P("A", "prd-1 special"), P("prd-1", "Other")];
    eq(ids(PS.filter(list, "prd-1")), ["prd-1", "A"]);
});
test("SRCH-10b a name word ranks above a match buried in the id", () => {
    const list = [P("1abc2", "Other"), P("2", "abc thing")];
    eq(ids(PS.filter(list, "abc")), ["2", "1abc2"]);
});
test("SRCH-11 exact sku ranks above a sku prefix", () => {
    const list = [P("X1", "n1", "abc"), P("X2", "n2", "ab")];
    eq(ids(PS.filter(list, "ab")), ["X2", "X1"]);
});
test("SRCH-12 a name word prefix ranks above a substring", () => {
    const list = [P("1", "Tomato"), P("2", "Matcha")];
    eq(ids(PS.filter(list, "mat")), ["2", "1"]);
    const apart = [P("1", "Amat"), P("2", "Zeta Matcha")];
    eq(ids(PS.filter(apart, "mat")), ["2", "1"]);
});
test("SRCH-13 ties go by name, then catalog order", () => {
    const list = [P("1", "b", undefined, "xcat"), P("2", "a", undefined, "xcat"), P("3", "a", undefined, "xcat")];
    eq(ids(PS.filter(list, "xcat")), ["2", "3", "1"]);
});
test("SRCH-14 regex characters are plain text", () => {
    const list = FX.CATALOG.concat([P("RX", "a.b(c")]);
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
    const list = [P("D1", "टमाटर"), P("D2", "Other")];
    eq(ids(PS.filter(list, "टमा")), ["D1"]);
});
test("SRCH-16 precomposed and decomposed accents find each other", () => {
    const pre = [P("C1", "Café")];
    const dec = [P("C2", "Café")];
    eq(ids(PS.filter(pre, "café")), ["C1"]);
    eq(ids(PS.filter(dec, "café")), ["C2"]);
});
test("SRCH-17 missing sku and category do not break matching", () => {
    const list = [{ productId: "A1", name: "Tomato" }, { productId: "A2", name: "Pear", category: null }];
    eq(ids(PS.filter(list, "tomato")), ["A1"]);
    eq(ids(PS.filter(list, "a2")), ["A2"]);
});
test("SRCH-18 numeric product id", () => {
    eq(ids(PS.filter([{ productId: 1001, name: "x" }], "100")), [1001]);
});
test("SRCH-19 junk entries are skipped, valid ones returned", () => {
    const list = [null, undefined, 5, "x", [], {}, P("OK1", "Tomato")];
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
    ok(Date.now() - t0 < 50, "took too long");
    const longName = [P("L1", q.substring(0, 200))];
    eq(ids(PS.filter(longName, q + "b")), ["L1"]);
});
test("SRCH-23 a products argument that is not an array gives an empty list", () => {
    eq(PS.filter(null, "x"), []);
    eq(PS.filter({}, "x"), []);
    eq(PS.filter("abc", "x"), []);
    eq(PS.filter(undefined, "x"), []);
});
test("SRCH-24 input is never changed", () => {
    const list = FX.freeze([P("A", "Tomato", "t1", "Veg"), P("B", "Pear", "p1", "Fruit")]);
    noThrow(() => PS.filter(list, "to"));
    noThrow(() => PS.filter(list, "", { category: "Veg" }));
    eq(ids(list), ["A", "B"]);
});
test("SRCH-25 two products with the same name are both returned, in catalog order", () => {
    const list = [P("1", "Tea"), P("2", "Tea")];
    eq(ids(PS.filter(list, "tea")), ["1", "2"]);
});
test("SRCH-26 the same call twice gives the same answer", () => {
    eq(ids(PS.filter(FX.CATALOG, "to")), ids(PS.filter(FX.CATALOG, "to")));
});
test("SRCH-27 seeded monkey, 400 rounds", () => {
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
});
