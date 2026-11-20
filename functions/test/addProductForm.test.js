"use strict";

// Atomic-ops AP3b: AddProductFlow.fromForm / moneyFromText / wholeFromText / priceSummary (design
// 2026-11-20-ap3b-add-product-dialog-design.md). The helper runs with its REAL text (testSupport/qmlHelpers.js); every accepted form is
// sent through the REAL planner and the REAL server code, so "the dialog lets through only what the planner and the server accept"
// (KNOWN-ISSUES 44) is proven, not assumed. tests/tst_AddProductForm.qml carries the unit cases for CI's qmltestrunner.
//
//   FM-1..2    the two parsers, table driven (happy, negative, edge, hostile)
//   FM-3..9    fromForm: the shape, each refusal, all errors at once, markup, tax, stock, limits, supplier, category
//   FM-10..11  priceSummary, and its parity with the price Save sends
//   FM-12..13  limits against the planner and the server; the maxima end to end
//   FM-14      MONKEY with an independent oracle that proves it reached every outcome
//   FM-15      source guards

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const OL = require("../lib/operationLogic");
const { strictDb } = require("./testSupport/strictDb");
const { load, plain, HELPER_DIR } = require("./testSupport/qmlHelpers");

const AF = load("AddProductFlow.js");
const AP = load("AddProductPlan.js");
const RF = load("RestockFlow.js");

const NOW = new Date("2026-06-15T12:00:00Z");
const KEY = "addProduct:1781000000000-abcdefabcdef";
const SUPPLIERS = [{ supplierId: "SUP-009", name: "Acme Farms" }];
const IDS = ["", "SUP-009"];

function form(over) {
    return Object.assign({
        name: "Tomato", sku: "TO-2026-001", size: "", description: "Red", category: "Veg", categoryIndex: 0, unit: "Kg",
        costText: "20", priceText: "30", markup: false, stockText: "5", minStockText: "2", taxable: false, taxPercentText: "0",
        pendingPartyText: "", newSupplierName: "", partyIndex: 0, supplierIds: IDS
    }, over || {});
}
const run = (over) => plain(AF.fromForm(form(over)));
const errorsOf = (over) => { const r = run(over); assert.equal(r.ok, false, JSON.stringify(over)); return r.errors; };

// The accepted args, through makeInput -> the real planner -> the real validator and apply.
async function serve(a) {
    const made = plain(AF.makeInput(Object.assign({ key: KEY, suppliers: SUPPLIERS, now: NOW }, a)));
    assert.equal(made.ok, true, "makeInput: " + JSON.stringify(made));
    const plan = plain(AP.build(made.input));
    assert.equal(plan.ok, true, "planner: " + JSON.stringify(plan));
    const v = OL.validateOperationRequest({ requestId: plan.key, opType: plan.opType, clientTimestamp: "CT", ops: plan.ops });
    assert.equal(v.ok, true, "validator: " + JSON.stringify(v));
    return OL.applyOperation(strictDb({}), { tenantId: "t1", actorUid: "u", actorRole: "owner", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: { __transform: "serverTimestamp" }, now: NOW });
}

// ---------------------------------------------------------------------------- FM-1, FM-2: parsers

test("FM-1 moneyFromText: plain non-negative decimals only", () => {
    const good = [["20", 20], ["0", 0], ["0.5", 0.5], [".5", 0.5], ["5.", 5], [" 12 ", 12], ["007", 7], ["1000000000", 1e9], ["0.10", 0.1]];
    for (const [t, n] of good) assert.equal(AF.moneyFromText(t), n, JSON.stringify(t));
    const bad = ["", " ", "abc", "12abc", "1,5", "1e3", "1E3", "-1", "-0", "+1", "0x10", "0b11", "Infinity", "NaN", "1 000", "1.2.3", ".",
        "1000000000.01", "9".repeat(400), "\u0661\u0662", "\u200b5", null, undefined, 12, {}, []];
    for (const t of bad) assert.ok(Number.isNaN(AF.moneyFromText(t)), "must refuse " + JSON.stringify(t));
});

test("FM-2 wholeFromText: whole numbers only, never cut (2.5 is refused, not 2)", () => {
    const good = [["5", 5], ["0", 0], ["007", 7], [" 5 ", 5], ["1000000", 1000000]];
    for (const [t, n] of good) assert.equal(AF.wholeFromText(t), n, JSON.stringify(t));
    const bad = ["", " ", "2.5", "5.", ".5", "-1", "+1", "1e3", "abc", "5 pcs", "1,000", "1000001", "9".repeat(400), "\u0665", null, undefined, 5];
    for (const t of bad) assert.ok(Number.isNaN(AF.wholeFromText(t)), "must refuse " + JSON.stringify(t));
});

// ---------------------------------------------------------------------------- FM-3: shape

test("FM-3 happy path: the exact arguments InventoryStore.addProduct takes, trimmed, cost = batch cost", () => {
    const r = run({ name: "  Tomato ", sku: " TO-1 ", size: " M ", description: " Red ", category: " Veg ", taxable: true, taxPercentText: "5", minStockText: "" });
    assert.deepEqual(r, { ok: true, args: {
        name: "Tomato", sku: "TO-1", category: "Veg", description: "Red", price: 20, unit: "Kg", stock: 5, minStock: 0, sellingPrice: 30,
        taxable: true, taxPercent: 5, party: "", unitCost: 20, size: "M" } });
    const none = run({ taxable: false, taxPercentText: "junk" });
    assert.equal(none.ok, true);
    assert.equal(none.args.taxPercent, 0, "a not-taxable product stores 0 whatever the tax field holds");
});

// ---------------------------------------------------------------------------- FM-4..: each refusal

test("FM-4 each field has its own refusal text (negative and hostile input)", () => {
    const table = [
        [{ name: "" }, "Enter a valid product name"], [{ name: "A" }, "Enter a valid product name"], [{ name: "   " }, "Enter a valid product name"],
        [{ name: undefined }, "Enter a valid product name"], [{ sku: "" }, "SKU required (tap Gen)"], [{ sku: "  " }, "SKU required (tap Gen)"],
        [{ categoryIndex: -1 }, "Select a category"], [{ categoryIndex: undefined }, "Select a category"], [{ categoryIndex: "0" }, "Select a category"],
        [{ costText: "" }, "Enter a valid cost"], [{ costText: "-5" }, "Enter a valid cost"], [{ costText: "12abc" }, "Enter a valid cost"],
        [{ costText: "1e3" }, "Enter a valid cost"], [{ costText: "1,5" }, "Enter a valid cost"], [{ costText: "2000000000" }, "Cost is too large. Use at most 1000000000"], [{ costText: "9".repeat(400) }, "Cost is too large. Use at most 1000000000"],
        [{ priceText: "" }, "Enter a valid price"], [{ priceText: "0" }, "Enter a valid price"], [{ priceText: "-1" }, "Enter a valid price"],
        [{ priceText: "x" }, "Enter a valid price"], [{ priceText: "2000000000" }, "Price is too large. Use at most 1000000000"], [{ priceText: "10" }, "Price < cost"],
        [{ stockText: "" }, "Enter the opening stock as a whole number (0 if none)"], [{ stockText: "2.5" }, "Enter the opening stock as a whole number (0 if none)"],
        [{ stockText: "-1" }, "Enter the opening stock as a whole number (0 if none)"], [{ stockText: "1000001" }, "Opening stock is too large. Use at most 1000000"], [{ stockText: "9".repeat(400) }, "Opening stock is too large. Use at most 1000000"],
        [{ minStockText: "abc" }, "Reorder level must be a whole number"], [{ minStockText: "-1" }, "Reorder level must be a whole number"],
        [{ minStockText: "1.5" }, "Reorder level must be a whole number"], [{ minStockText: "1000001" }, "Reorder level is too large. Use at most 1000000"],
        [{ taxable: true, taxPercentText: "" }, "Enter a valid tax % (0\u2013100)"], [{ taxable: true, taxPercentText: "100.01" }, "Enter a valid tax % (0\u2013100)"],
        [{ taxable: true, taxPercentText: "-1" }, "Enter a valid tax % (0\u2013100)"], [{ taxable: true, taxPercentText: "5%" }, "Enter a valid tax % (0\u2013100)"]
    ];
    for (const [over, text] of table) assert.deepEqual(errorsOf(over), [text], JSON.stringify(over));
});

test("FM-5 every problem at once, in field order; nothing is built", () => {
    const r = run({ name: "", sku: "", categoryIndex: -1, costText: "x", priceText: "y", stockText: "z", minStockText: "q", taxable: true, taxPercentText: "w",
        size: "s".repeat(41), pendingPartyText: "Acme" });
    assert.equal(r.ok, false);
    assert.equal(r.args, undefined);
    assert.deepEqual(r.errors, ["Enter a valid product name", "SKU required (tap Gen)", "Select a category", "Enter a valid cost", "Enter a valid price",
        "Enter the opening stock as a whole number (0 if none)", "Reorder level must be a whole number", "Enter a valid tax % (0\u2013100)",
        "Size is too long. Use at most 40 characters", "You typed a new supplier name. Tap Use to add it, or clear the field"]);
});

test("FM-6 markup mode: price = cost + markup %, to a whole rupee, same as the pill", () => {
    const m = (costText, priceText) => run({ markup: true, costText, priceText });
    assert.equal(m("20", "50").args.sellingPrice, 30);
    assert.equal(m("33", "10").args.sellingPrice, 36, "36.3 rounds to 36");
    assert.equal(m("33", "10").args.price, 33, "the product cost stays the cost");
    assert.equal(m("20", "0").args.sellingPrice, 20, "0% markup = cost, allowed");
    assert.deepEqual(plain(AF.fromForm(form({ markup: true, costText: "x", priceText: "50" }))).errors, ["Enter a valid cost", "Enter a valid price"]);
    assert.deepEqual(errorsOf({ markup: true, costText: "20", priceText: "-5" }), ["Enter a valid price"]);
    assert.equal(m("0.4", "0").args.sellingPrice, 0.4, "0% on a fractional cost is the cost itself, not a refusal (review sweep 1 of PR 207; it used to round to 0)");
    assert.deepEqual(errorsOf({ markup: true, costText: "1000000000", priceText: "100" }), ["Markup is too high. The selling price must be at most 1000000000"], "2e9 is over the limit, and the text says why");
    assert.deepEqual(errorsOf({ markup: true, costText: "0", priceText: "20" }), ["A markup needs a cost above 0"]);
});

test("FM-7 flat mode: price below cost is refused, equal is allowed", () => {
    assert.equal(run({ costText: "30", priceText: "30" }).ok, true);
    assert.deepEqual(errorsOf({ costText: "30", priceText: "29.99" }), ["Price < cost"]);
    assert.equal(run({ costText: "0", priceText: "0.01" }).ok, true, "a free-cost item with a price is fine");
});

test("FM-8 tax and stock edges", () => {
    assert.equal(run({ taxable: true, taxPercentText: "100" }).args.taxPercent, 100);
    assert.equal(run({ taxable: true, taxPercentText: "0" }).args.taxPercent, 0);
    assert.equal(run({ taxable: true, taxPercentText: "12.5" }).args.taxPercent, 12.5);
    assert.equal(run({ stockText: "0" }).args.stock, 0);
    assert.equal(run({ stockText: "1000000", costText: "1000000000", priceText: "1000000000" }).ok, true);
    assert.equal(run({ minStockText: "  " }).args.minStock, 0, "blank reorder level = 0");
    assert.equal(run({ minStockText: "0" }).args.minStock, 0);
    assert.equal(run({ minStockText: "1000000" }).args.minStock, 1000000);
});

test("FM-9 limits are on the TRIMMED text, at the edge, for every text field", () => {
    const L = (n) => "x".repeat(n);
    assert.equal(run({ name: L(100) }).ok, true);
    assert.deepEqual(errorsOf({ name: L(101) }), ["Product name is too long. Use at most 100 characters"]);
    assert.equal(run({ name: "  " + L(100) + "  " }).ok, true, "spaces around do not count");
    assert.equal(run({ sku: L(40) }).ok, true);
    assert.deepEqual(errorsOf({ sku: L(41) }), ["SKU is too long. Use at most 40 characters"]);
    assert.equal(run({ size: L(40) }).ok, true);
    assert.deepEqual(errorsOf({ size: L(41) }), ["Size is too long. Use at most 40 characters"]);
    assert.equal(run({ description: L(500) }).ok, true);
    assert.deepEqual(errorsOf({ description: L(501) }), ["Description is too long. Use at most 500 characters"]);
    assert.equal(run({ description: undefined, size: null, category: undefined }).ok, true, "optional text may be missing");
});

test("FM-10 supplier: a picked row, a typed new name (Use), nothing, an unused typed name, invisible text", () => {
    assert.equal(run().args.party, "");
    assert.equal(run({ partyIndex: 1 }).args.party, "SUP-009");
    assert.equal(run({ partyIndex: 99 }).args.party, "", "an index with no id behind it is no supplier");
    assert.deepEqual(run({ newSupplierName: "Acme" }).args.party, { newName: "Acme" });
    assert.deepEqual(run({ newSupplierName: "Acme", partyIndex: 1 }).args.party, { newName: "Acme" }, "a typed new name wins over the picker");
    assert.deepEqual(errorsOf({ pendingPartyText: "Acme" }), ["You typed a new supplier name. Tap Use to add it, or clear the field"]);
    assert.equal(run({ pendingPartyText: "\u200b \u200b" }).ok, true, "text nobody can see does not block the add");
    assert.equal(run({ pendingPartyText: "" }).ok, true);
});

test("FM-11 hostile whole form: junk, null, nothing never throws and is refused", () => {
    for (const f of [undefined, null, 5, "x", [], {}, { name: {} , sku: [] }]) {
        const r = plain(AF.fromForm(f));
        assert.equal(r.ok, false);
        assert.ok(Array.isArray(r.errors) && r.errors.length > 0 && r.errors.every((e) => typeof e === "string" && e.length > 0));
    }
});

// ---------------------------------------------------------------------------- priceSummary

test("FM-12 priceSummary: the pill uses the same parsing as Save, and its price is the price Save sends", () => {
    assert.equal(AF.priceSummary("20", "30", false), "Markup 50%   \u00b7   profit \u20b910.00");
    assert.equal(AF.priceSummary("20", "50", true), "Selling price \u20b930   \u00b7   profit \u20b910.00");
    assert.equal(AF.priceSummary("20", "10", false), "Markup -50%   \u00b7   profit \u20b9-10.00", "below cost is shown (Save refuses it)");
    for (const [c, v, markup, dash] of [["", "30", false, "Markup \u2014"], ["0", "30", false, "Markup \u2014"], ["20", "", true, "Selling price \u2014"],
        ["12abc", "30", false, "Markup \u2014"], ["20", "1e3", true, "Selling price \u2014"], ["x", "x", true, "Selling price \u2014"]])
        assert.equal(AF.priceSummary(c, v, markup), dash, JSON.stringify([c, v, markup]));
    for (const [c, m] of [["33", "10"], ["20", "50"], ["7.5", "12.5"], ["100", "0"]]) {
        const sp = run({ markup: true, costText: c, priceText: m }).args.sellingPrice;
        assert.equal(AF.priceSummary(c, m, true).split("\u20b9")[1].split(" ")[0], String(sp), "pill price = Save price for " + c + "/" + m);
    }
});

test("FM-12b sweep 1 of PR 207: the pill and Save read the cost and price fields the same way (grid of nasty input)", () => {
    const costs = ["", "x", "0", "0.4", "10.40", "20", "33", "999999999", "1000000000", "2000000000", "9".repeat(400)];
    const prices = ["", "x", "-1", "0", "0.2", "10", "30", "100", "100000000", "1000000000", "2000000000", "9".repeat(400)];
    const priceBad = (e) => e === "Enter a valid price" || e.startsWith("Price is too large") || e.startsWith("Markup is too high") || e.startsWith("A markup needs");
    const costBad = (e) => e === "Enter a valid cost" || e.startsWith("Cost is too large");
    let shown = 0, dashed = 0;
    for (const markup of [false, true]) for (const c of costs) for (const v of prices) {
        const tag = JSON.stringify([c.slice(0, 12), v.slice(0, 12), markup]);
        const dash = markup ? "Selling price \u2014" : "Markup \u2014";
        const pill = AF.priceSummary(c, v, markup);
        const r = run({ markup, costText: c, priceText: v });
        const errs = r.ok ? [] : r.errors;
        const accepted = !errs.some(costBad) && !errs.some(priceBad);
        if (pill !== dash) { shown++; assert.ok(accepted, "the pill shows a price Save refuses: " + tag + " " + pill + " " + JSON.stringify(errs)); }
        else dashed++;
        if (accepted && Number(c) > 0) assert.notEqual(pill, dash, "Save accepts it but the pill is blank: " + tag);
        if (r.ok && r.args.price > 0) assert.ok(pill.includes("profit \u20b9" + (r.args.sellingPrice - r.args.price).toFixed(2)), "pill profit = Save profit: " + tag);
    }
    assert.ok(shown > 10 && dashed > 10, "the grid covers both outcomes");
    assert.equal(AF.priceSummary("1000", "100000000", true), "Selling price \u2014", "a markup whose price is over the limit shows no price");
    assert.equal(AF.priceSummary("10", "0", false), "Markup \u2014", "a price of 0 is refused by Save, so the pill shows no markup");
});

test("FM-12c sweep 1 of PR 207: a markup price is never below the cost; it is the old whole rupee whenever that was not below the cost", () => {
    const costs = ["0.01", "0.4", "0.5", "1", "7.5", "10.40", "33", "99.99", "100.4", "1234.56"];
    const marks = ["0", "0.1", "0.2", "1", "5", "12.5", "50", "100", "300"];
    for (const c of costs) for (const m of marks) {
        const r = run({ markup: true, costText: c, priceText: m });
        assert.equal(r.ok, true, c + "/" + m + " " + JSON.stringify(r));
        const cost = Number(c), old = Math.round((Number(m) * cost) / 100 + cost);
        assert.ok(r.args.sellingPrice >= cost, "never below cost: " + c + "/" + m);
        assert.equal(r.args.sellingPrice, old >= cost ? old : cost, "only a below-cost result changes: " + c + "/" + m);
    }
    assert.equal(run({ markup: true, costText: "10.40", priceText: "0" }).args.sellingPrice, 10.4);
    assert.equal(run({ markup: true, costText: "100.4", priceText: "0.05" }).args.sellingPrice, 100.4, "100.4 + 0.05% = 100.45 rounds to 100, below the cost");
    assert.equal(AF.priceSummary("10.40", "0", true), "Selling price \u20b910.4   \u00b7   profit \u20b90.00");
});

test("FM-12d sweep 1 of PR 207: too large and not valid are different messages, for every amount field", () => {
    const pairs = [["costText", "Enter a valid cost", "Cost is too large. Use at most 1000000000"],
        ["priceText", "Enter a valid price", "Price is too large. Use at most 1000000000"],
        ["stockText", "Enter the opening stock as a whole number (0 if none)", "Opening stock is too large. Use at most 1000000"],
        ["minStockText", "Reorder level must be a whole number", "Reorder level is too large. Use at most 1000000"]];
    for (const [field, invalid, large] of pairs) {
        const big = field === "stockText" || field === "minStockText" ? "1000001" : "1000000001";
        const e1 = errorsOf({ [field]: "12abc" }), e2 = errorsOf({ [field]: big });
        assert.ok(e1.includes(invalid), field + " junk: " + JSON.stringify(e1));
        assert.ok(e2.includes(large), field + " too large: " + JSON.stringify(e2));
        assert.ok(!e2.includes(invalid), field + " too large must not also say invalid");
    }
    assert.equal(run({ costText: "1000000000", priceText: "1000000000" }).ok, true, "the limit itself is allowed");
    assert.equal(run({ stockText: "1000000", minStockText: "1000000" }).ok, true);
});

// ---------------------------------------------------------------------------- planner and server

test("FM-13 the constants and the extremes: the largest accepted form is accepted by the planner and the real server", async () => {
    assert.equal(AF.MAX_MONEY, RF.MAX_UNIT_COST, "one source of truth for the biggest price");
    assert.ok(Number.isFinite(AF.MAX_STOCK * AF.MAX_MONEY), "stock * cost cannot overflow");
    const max = run({ name: "n".repeat(100), sku: "s".repeat(40), size: "z".repeat(40), description: "d".repeat(500), stockText: "1000000", minStockText: "1000000",
        costText: "1000000000", priceText: "1000000000", taxable: true, taxPercentText: "100", newSupplierName: "S".repeat(100) });
    assert.equal(max.ok, true);
    const out = await serve(max.args);
    assert.equal(out.ok, true, JSON.stringify(out));
    const small = run({ stockText: "0", costText: "0", priceText: "0.01", minStockText: "" });
    assert.equal((await serve(small.args)).ok, true, "no stock = no batch, still a valid add");
    const frac = run({ costText: "0.005", priceText: "0.01" });
    assert.equal((await serve(frac.args)).ok, true);
});

// ---------------------------------------------------------------------------- monkey

function rng(seed) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }

test("FM-14 MONKEY: 4000 random forms. An independent oracle agrees on accept or refuse; every accepted form is accepted by the planner and the server; every error kind is reached", async () => {
    const R = rng(20261120);
    const pick = (a) => a[Math.floor(R() * a.length)];
    const nums = ["0", "1", "5", "20", "30", "99.5", "100", "100.5", "1000000", "1000001", "1000000000", "1000000001", "", " ", "-1", "abc", "1e3", "1,5", "2.5", "007", ".5", "5.", "0x1f", "12abc"];
    const texts = ["", " ", "A", "Ab", "Tomato", "x".repeat(40), "x".repeat(41), "x".repeat(100), "x".repeat(101), "x".repeat(500), "x".repeat(501), "\u200b", "{{prd}}", "a{{b"];
    const parties = ["", "Acme", " ", "\u200b", "Zed"];
    const seen = new Set();
    let accepted = 0, refused = 0;
    const nan = (t) => Number.isNaN(AF.moneyFromText(t));
    // The oracle: written from the design table, not from the helper's code.
    const oracleOk = (f) => {
        const t = (v) => (typeof v === "string" ? v.trim() : "");
        const money = (v) => { const s = t(v); return /^(\d+\.?\d*|\.\d+)$/.test(s) && Number(s) <= 1e9 ? Number(s) : null; };
        const whole = (v) => { const s = t(v); return /^\d+$/.test(s) && Number(s) <= 1e6 ? Number(s) : null; };
        const cost = money(f.costText), typed = money(f.priceText);
        let price = null;
        if (typed !== null) price = f.markup ? (cost === null ? null : Math.round((typed * cost) / 100 + cost)) : typed;
        if (t(f.name).length < 2 || t(f.name).length > 100) return false;
        if (t(f.sku).length < 1 || t(f.sku).length > 40) return false;
        if (!(f.categoryIndex >= 0) || cost === null || price === null || price <= 0 || price > 1e9 || price < cost) return false;
        if (whole(f.stockText) === null) return false;
        if (t(f.minStockText) !== "" && whole(f.minStockText) === null) return false;
        if (f.taxable) { const tp = money(f.taxPercentText); if (tp === null || tp > 100) return false; }
        if (t(f.size).length > 40 || t(f.description).length > 500) return false;
        if (t(f.pendingPartyText).replace(/[\u200b\u2060\ufeff\u200c\u200d]/g, "").length > 0) return false;
        return true;
    };
    for (let i = 0; i < 4000; i++) {
        // Mostly valid, then 0 to 2 fields corrupted from the junk pools: both outcomes are common and every field is hit alone.
        const good = ["1", "5", "20", "30", "99.5", "100"];
        const f = form({ name: pick(["Tomato", "Ab", "Basmati Rice 5kg"]), sku: pick(["TO-1", "x".repeat(40)]), categoryIndex: 0, costText: pick(["1", "5", "20"]),
            priceText: pick(["30", "99.5", "100"]), markup: false, stockText: pick(good), minStockText: pick(["", "0", "2"]), taxable: R() < 0.5,
            taxPercentText: pick(["0", "5", "18", "100"]), partyIndex: pick([0, 1]), newSupplierName: R() < 0.3 ? pick(["Acme", "Zed"]) : "" });
        if (R() < 0.25) { f.markup = true; f.priceText = pick(["0", "10", "50", "100"]); }
        const fields = ["name", "sku", "size", "description", "categoryIndex", "costText", "priceText", "stockText", "minStockText", "taxPercentText", "pendingPartyText"];
        for (let k = Math.floor(R() * 3); k > 0; k--) {
            const fld = pick(fields);
            f[fld] = fld === "categoryIndex" ? pick([-1, 1]) : (/Text$/.test(fld) && fld !== "pendingPartyText") ? pick(nums) : fld === "pendingPartyText" ? pick(parties) : pick(texts);
        }
        const r = plain(AF.fromForm(f));
        assert.equal(r.ok, oracleOk(f), "oracle disagrees for " + JSON.stringify(f));
        if (r.ok) {
            accepted++;
            await serve(r.args);
        } else {
            refused++;
            for (const e of r.errors) seen.add(e.replace(/\d+/g, "N"));
            assert.ok(r.errors.length > 0);
        }
    }
    assert.ok(accepted > 400 && refused > 400, "reached both outcomes: " + accepted + "/" + refused);
    for (const must of ["Enter a valid product name", "SKU required (tap Gen)", "Select a category", "Enter a valid cost", "Enter a valid price", "Price < cost",
        "Enter the opening stock as a whole number (N if none)", "Reorder level must be a whole number", "Enter a valid tax % (N\u2013N)",
        "Product name is too long. Use at most N characters", "SKU is too long. Use at most N characters", "Size is too long. Use at most N characters",
        "Description is too long. Use at most N characters", "You typed a new supplier name. Tap Use to add it, or clear the field"])
        assert.ok(seen.has(must), "the monkey never reached: " + must);
    assert.ok(nan("x"));
});

// ---------------------------------------------------------------------------- source guards

test("FM-15 the helper reads no control, store, clock or random source, and never uses the lenient parsers", () => {
    const src = fs.readFileSync(path.join(HELPER_DIR, "AddProductFlow.js"), "utf8");
    const at = src.indexOf("AP3b (design");
    assert.ok(at > 0);
    const part = src.substring(at).replace(/\/\/[^\n]*/g, "");
    for (const bad of ["parseFloat", "parseInt", "Date", "Math.random", "Store.", "AuthStore", "console."])
        assert.equal(part.includes(bad), false, "AP3b helper must not use " + bad);
    assert.equal(/\bparseFloat\(|\bparseInt\(/.test(src.replace(/\/\/[^\n]*/g, "")), false, "no lenient parser anywhere in the file");
});

test("FM-13b sweep 1 of PR 207: the floor price (cost 10.40 at 0% markup) goes through the real planner and server", async () => {
    const r = run({ markup: true, costText: "10.40", priceText: "0" });
    assert.equal(r.ok, true);
    assert.equal(r.args.sellingPrice, 10.4);
    const out = await serve(r.args);
    assert.equal(out.ok, true, JSON.stringify(out));
});
