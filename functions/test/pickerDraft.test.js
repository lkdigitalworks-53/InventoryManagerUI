"use strict";
// PickerDraft (qml/helper/PickerDraft.js). Cases DRFT-01..42, plan:
// docs/superpowers/plans/2026-11-03-product-picker-v2-s1-pure-helpers.md. The QML twin
// tests/tst_PickerDraft.qml is derived from these bodies, except DRFT-26 which needs the file system
// (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const PD = load("PickerDraft.js");

test("DRFT-01 empty gives a new empty draft each time", () => {
    const a = PD.empty();
    const b = PD.empty();
    eq(a, {});
    ok(a !== b, "same object returned twice");
});
test("DRFT-02 parseQty accepts digits only", () => {
    eq(PD.parseQty("3"), { ok: true, qty: 3 });
    eq(PD.parseQty(" 12 "), { ok: true, qty: 12 });
    eq(PD.parseQty(7), { ok: true, qty: 7 });
    eq(PD.parseQty("0"), { ok: true, qty: 0 });
    eq(PD.parseQty("007"), { ok: true, qty: 7 });
});
test("DRFT-03 parseQty refuses everything else", () => {
    const bad = ["", "  ", "abc", "2.5", 2.5, "-1", -1, "+3", "1e3", NaN, Infinity, null, undefined, {}, []];
    for (let i = 0; i < bad.length; ++i) eq(PD.parseQty(bad[i]), { ok: false, qty: 0 });
});
test("DRFT-04 parseQty allows six digits at most", () => {
    eq(PD.parseQty("999999"), { ok: true, qty: 999999 });
    eq(PD.parseQty("1000000"), { ok: false, qty: 0 });
});
test("DRFT-05 setQty sets a quantity", () => {
    eq(PD.setQty({}, "A", "3", 10), { A: 3 });
});
test("DRFT-06 setQty clamps to the maximum", () => {
    eq(PD.setQty({}, "A", "50", 8), { A: 8 });
});
test("DRFT-07 setQty with 0 removes the product", () => {
    eq(PD.setQty({ A: 3 }, "A", "0", 10), {});
});
test("DRFT-08 setQty with junk text leaves the draft and returns a new object", () => {
    const d = { A: 3 };
    const junk = ["abc", "2.5", ""];
    for (let i = 0; i < junk.length; ++i) {
        const r = PD.setQty(d, "A", junk[i], 10);
        eq(r, { A: 3 });
        ok(r !== d, "returned the input object");
    }
});
test("DRFT-09 a missing or junk maximum removes the product", () => {
    eq(PD.setQty({ A: 3 }, "A", "2", 0), {});
    eq(PD.setQty({ A: 3 }, "A", "2", undefined), {});
    eq(PD.setQty({ A: 3 }, "A", "2", -4), {});
    eq(PD.setQty({ A: 3 }, "A", "2", NaN), {});
    eq(PD.setQty({}, "A", "2", 0), {});
});
test("DRFT-10 hostile ids leave the draft alone", () => {
    const ids = ["__proto__", "", 5, null, undefined];
    for (let i = 0; i < ids.length; ++i) {
        noThrow(() => PD.setQty({ A: 1 }, ids[i], "3", 10));
        eq(PD.setQty({ A: 1 }, ids[i], "3", 10), { A: 1 });
    }
    eq(({}).polluted, undefined);
    eq(Object.prototype.hasOwnProperty.call(Object.prototype, "3"), false);
});
test("DRFT-10b an own __proto__ key in a draft never reaches a result", () => {
    const d = JSON.parse('{"__proto__":{"polluted":1},"A":1}');
    const a = PD.setQty(d, "A", "2", 9);
    eq(a, { A: 2 });
    eq(a.polluted, undefined);
    eq(PD.step(d, "A", 1, 9).polluted, undefined);
    eq(PD.reconcile(d, () => 9).polluted, undefined);
    eq(PD.reconcile(d, () => 9), { A: 1 });
    eq(PD.totals(d, () => 2), { items: 1, lines: 1, amount: 2 });
    eq(PD.commitPlan(d, []), { adds: [{ productId: "A", qty: 1 }], bumps: [] });
});
test("DRFT-11 step up from nothing", () => {
    eq(PD.step({}, "A", 1, 5), { A: 1 });
});
test("DRFT-12 step down to zero removes the product", () => {
    eq(PD.step({ A: 1 }, "A", -1, 5), {});
});
test("DRFT-13 step up stops at the maximum", () => {
    eq(PD.step({ A: 5 }, "A", 1, 5), { A: 5 });
});
test("DRFT-14 step down below zero changes nothing", () => {
    eq(PD.step({}, "A", -1, 5), {});
    eq(PD.step({ B: 2 }, "A", -1, 5), { B: 2 });
});
test("DRFT-15 a junk step leaves the draft", () => {
    const bad = [NaN, 1.5, "1", Infinity, null];
    for (let i = 0; i < bad.length; ++i) eq(PD.step({ A: 2 }, "A", bad[i], 5), { A: 2 });
});
test("DRFT-16 no function changes its input", () => {
    const d = FX.freeze({ A: 2, B: 1 });
    const lines = FX.freeze([{ productId: "A", qty: 1 }]);
    noThrow(() => PD.setQty(d, "A", "4", 9));
    noThrow(() => PD.step(d, "B", 1, 9));
    noThrow(() => PD.totals(d, () => 1));
    noThrow(() => PD.commitPlan(d, lines));
    noThrow(() => PD.lineLimitReached(lines, d));
    noThrow(() => PD.reconcile(d, () => 1));
    eq(d, { A: 2, B: 1 });
});
test("DRFT-17 totals count items, lines and the amount", () => {
    const prices = { A: 10, B: 5 };
    eq(PD.totals({ A: 2, B: 3 }, (id) => prices[id]), { items: 5, lines: 2, amount: 35 });
});
test("DRFT-18 the amount is rounded to two decimals", () => {
    eq(PD.totals({ A: 1, B: 1 }, (id) => ({ A: 0.1, B: 0.2 })[id]).amount, 0.3);
    eq(PD.totals({ A: 3 }, () => 19.999).amount, 60);
});
test("DRFT-19 junk prices count as 0 and never break the counts", () => {
    const bad = [undefined, NaN, -5, "9"];
    for (let i = 0; i < bad.length; ++i) {
        const v = bad[i];
        eq(PD.totals({ A: 2 }, () => v), { items: 2, lines: 1, amount: 0 });
    }
    eq(PD.totals({ A: 2 }, undefined), { items: 2, lines: 1, amount: 0 });
    eq(PD.totals({ A: 0, B: "3", C: 2, D: 1.5 }, () => 1), { items: 2, lines: 1, amount: 2 });
    eq(PD.totals(null, () => 1), { items: 0, lines: 0, amount: 0 });
});
test("DRFT-20 commitPlan splits adds and bumps, sorted by id", () => {
    eq(PD.commitPlan({ B: 2, A: 1, C: 4 }, [{ productId: "B", qty: 9 }]),
       { adds: [{ productId: "A", qty: 1 }, { productId: "C", qty: 4 }], bumps: [{ productId: "B", qty: 2 }] });
});
test("DRFT-21 a corrupt draft entry never reaches the plan", () => {
    const plan = PD.commitPlan({ A: 0, B: -1, C: 2.5, D: "3", E: NaN, F: 2 }, []);
    eq(plan, { adds: [{ productId: "F", qty: 2 }], bumps: [] });
});
test("DRFT-22 empty and null inputs give an empty plan", () => {
    eq(PD.commitPlan({}, []), { adds: [], bumps: [] });
    eq(PD.commitPlan(null, []), { adds: [], bumps: [] });
    eq(PD.commitPlan({ A: 1 }, null), { adds: [{ productId: "A", qty: 1 }], bumps: [] });
});
test("DRFT-23 an existing line is found whatever its quantity field is called", () => {
    const shapes = [{ productId: "A", qty: 3 }, { productId: "A", quantity: 3 }, { productId: "A" }];
    for (let i = 0; i < shapes.length; ++i)
        eq(PD.commitPlan({ A: 1 }, [shapes[i]]), { adds: [], bumps: [{ productId: "A", qty: 1 }] });
});
test("DRFT-24 lineCountAfter counts distinct existing lines plus adds", () => {
    const lines = [{ productId: "A" }, { productId: "A" }, { productId: "B" }];
    eq(PD.lineCountAfter(lines, { adds: [{ productId: "C" }, { productId: "D" }] }), 4);
    eq(PD.lineCountAfter(lines, null), 2);
    eq(PD.lineCountAfter(lines, {}), 2);
    eq(PD.lineCountAfter(null, null), 0);
});
test("DRFT-25 the line limit counts new lines only", () => {
    const lines = [];
    for (let i = 0; i < PD.MAX_LINES - 1; ++i) lines.push({ productId: "L" + i });
    eq(PD.lineLimitReached(lines, {}), false);
    eq(PD.lineLimitReached(lines, { NEW: 1 }), true);
    eq(PD.lineLimitReached(lines, { L1: 4 }), false);
});
test("DRFT-26 MAX_LINES stays inside the server's operation cap (Node only)", () => {
    const root = path.join(__dirname, "..", "..");
    const plan = fs.readFileSync(path.join(root, "qml", "helper", "CompletionPlan.js"), "utf8");
    const server = fs.readFileSync(path.join(root, "functions", "lib", "operationLogic.js"), "utf8");
    const a = /var MAX_OPS = (\d+)/.exec(plan);
    const b = /const MAX_OPS = (\d+)/.exec(server);
    ok(a && b, "MAX_OPS not found in one of the two files");
    eq(Number(a[1]), Number(b[1]));
    ok(3 * PD.MAX_LINES + 1 <= Number(a[1]), "MAX_LINES too high for MAX_OPS");
});
test("DRFT-27 reconcile clamps to the current maximum", () => {
    eq(PD.reconcile({ A: 5, B: 2 }, (id) => ({ A: 3, B: 9 })[id]), { A: 3, B: 2 });
});
test("DRFT-28 reconcile removes what is no longer available, and fails closed", () => {
    eq(PD.reconcile({ A: 5, B: 2, C: 1 }, (id) => ({ A: 0, B: undefined })[id]), {});
    eq(PD.reconcile({ A: 5 }, undefined), {});
    eq(PD.reconcile({ A: 5 }, null), {});
    eq(PD.reconcile({ A: 0, B: "3", C: 2.5, D: 2 }, () => 9), { D: 2 });
});
test("DRFT-29 reconcile of a draft within limits returns an equal new object", () => {
    const d = { A: 1, B: 2 };
    const r = PD.reconcile(d, () => 9);
    eq(r, d);
    ok(r !== d, "returned the input object");
});
test("DRFT-30 seeded monkey, 400 rounds", () => {
    const rand = FX.rng(11);
    const texts = ["1", "5", "0", "abc", "2.5", "", "999999", "1000000", " 3 "];
    const pids = ["A", "B", "C", "__proto__", "", "D", "10", "9"];
    const pick = (list) => list[Math.floor(rand() * list.length)];
    let nonEmpty = 0;
    for (let round = 0; round < 400; ++round) {
        let d = PD.empty();
        const lines = rand() < 0.5 ? [{ productId: "B" }] : [];
        for (let i = 0; i < 20; ++i) {
            const r = rand();
            const maxQty = pick([0, 1, 4, 9, -1, undefined, 50]);
            if (r < 0.45) d = PD.setQty(d, pick(pids), pick(texts), maxQty);
            else if (r < 0.8) d = PD.step(d, pick(pids), pick([1, -1, 2, 1.5]), maxQty);
            else d = PD.reconcile(d, () => pick([0, 1, 3, 8]));
        }
        let sum = 0;
        for (const k in d) {
            ok(Number.isInteger(d[k]) && d[k] >= 1 && d[k] <= 999999, "bad quantity " + d[k]);
            sum += d[k];
        }
        const plan = PD.commitPlan(d, lines);
        if (sum > 0) nonEmpty++;
        const gate = PD.canCommit(lines, d);
        eq(gate.ok, sum > 0);
        eq(gate.reason, sum > 0 ? "" : "empty");
        let planSum = 0;
        const seen = {};
        const all = plan.adds.concat(plan.bumps);
        for (let i = 0; i < all.length; ++i) { planSum += all[i].qty; ok(!seen[all[i].productId], "id in both lists"); seen[all[i].productId] = true; }
        eq(planSum, sum);
        const sortedAdds = plan.adds.map((e) => e.productId).slice().sort();
        eq(plan.adds.map((e) => e.productId), sortedAdds);
        const sortedBumps = plan.bumps.map((e) => e.productId).slice().sort();
        eq(plan.bumps.map((e) => e.productId), sortedBumps);
    }
    ok(nonEmpty > 100, "the monkey rarely built a draft: " + nonEmpty);
});
test("DRFT-31 nothing changes an unfrozen input, and every success path returns a new object", () => {
    const d = { A: 2, B: 1 };
    const lines = [{ productId: "A", qty: 1 }];
    const results = [PD.setQty(d, "A", "4", 9), PD.step(d, "B", 1, 9), PD.reconcile(d, () => 1)];
    PD.totals(d, () => 1);
    PD.commitPlan(d, lines);
    PD.canCommit(lines, d);
    PD.lineLimitReached(lines, d);
    PD.lineCountAfter(lines, { adds: [] });
    eq(d, { A: 2, B: 1 });
    eq(lines, [{ productId: "A", qty: 1 }]);
    for (let i = 0; i < results.length; ++i) ok(results[i] !== d, "returned the input object");
    eq(results[0], { A: 4, B: 1 });
    eq(results[1], { A: 2, B: 2 });
    eq(results[2], { A: 1, B: 1 });
});
test("DRFT-32 MAX_LINES is 60 and the limit is exact at the edge", () => {
    eq(PD.MAX_LINES, 60);
    const l58 = [];
    for (let i = 0; i < 58; ++i) l58.push({ productId: "L" + i });
    eq(PD.lineLimitReached(l58, { NEW: 1 }), false);
    eq(PD.lineLimitReached(l58.concat([{ productId: "L58" }]), {}), false);
    eq(PD.lineLimitReached(l58.concat([{ productId: "L58" }]), { NEW: 1 }), true);
    eq(PD.lineLimitReached(l58.concat([{ productId: "L58" }, { productId: "L59" }]), {}), true);
});
test("DRFT-33 step ignores a corrupt stored value and starts from nothing", () => {
    eq(PD.step({ A: "3" }, "A", 1, 9), { A: 1 });
    eq(PD.step({ A: 2.5 }, "A", 1, 9), { A: 1 });
    eq(PD.step({ A: Infinity }, "A", 1, 9), { A: 1 });
    eq(PD.step({ A: -2 }, "A", 1, 9), { A: 1 });
    eq(PD.step({ A: 2 }, "A", "1", 9), { A: 2 });
    eq(PD.step({ A: 2 }, "A", 1, 9, 5), { A: 3 });
});
test("DRFT-34 the maximum is whole and finite, an infinite one is refused", () => {
    eq(PD.setQty({}, "A", "3", Infinity), {});
    eq(PD.setQty({}, "A", "9", 3.7), { A: 3 });
    eq(PD.step({}, "A", 1, Infinity), {});
    eq(PD.reconcile({ A: Infinity }, () => 9), {});
    eq(PD.reconcile({ A: 3 }, () => Infinity), {});
    eq(PD.reconcile({ A: 5 }, () => 3.9), { A: 3 });
});
test("DRFT-35 totals: price rules and the two-decimal amount", () => {
    eq(PD.totals({ A: 1 }, () => Infinity), { items: 1, lines: 1, amount: 0 });
    eq(PD.totals({ A: 1 }, () => 0), { items: 1, lines: 1, amount: 0 });
    eq(PD.totals({ A: 1 }, () => 0.15).amount, 0.15);
    eq(PD.totals({ A: 3 }, () => 0.335).amount, 1.01);
    const asked = [];
    PD.totals({ A: 1, B: 2 }, (id) => { asked.push(id); return 1; });
    eq(asked.sort(), ["A", "B"]);
});
test("DRFT-36 a throwing price counts as 0 and a throwing maximum drops only that product", () => {
    eq(PD.totals({ A: 2, B: 1 }, (id) => { if (id === "A") throw new Error("boom"); return 5; }), { items: 3, lines: 2, amount: 5 });
    eq(PD.reconcile({ A: 1, B: 2 }, (id) => { if (id === "A") throw new Error("boom"); return 9; }), { B: 2 });
});
test("DRFT-37 order lines: junk, null ids and look-alike ids", () => {
    eq(PD.commitPlan({ A: 1 }, [{ productId: null }]), { adds: [{ productId: "A", qty: 1 }], bumps: [] });
    eq(PD.commitPlan({ A: 1 }, [null, undefined, 5, "A", []]), { adds: [{ productId: "A", qty: 1 }], bumps: [] });
    eq(PD.commitPlan({ A: 1 }, { length: 1, 0: { productId: "A" } }), { adds: [{ productId: "A", qty: 1 }], bumps: [] });
    // a numeric id on the order matches the string id in the draft
    eq(PD.commitPlan({ "1": 2 }, [{ productId: 1 }]), { adds: [], bumps: [{ productId: "1", qty: 2 }] });
    // ids that are also Object.prototype names never collide
    eq(PD.commitPlan({ toString: 1 }, [{ productId: "toString" }]), { adds: [], bumps: [{ productId: "toString", qty: 1 }] });
    eq(PD.commitPlan({ A: 1 }, [{ productId: "hasOwnProperty" }]), { adds: [{ productId: "A", qty: 1 }], bumps: [] });
    eq(PD.commitPlan({ constructor: 1 }, []), { adds: [{ productId: "constructor", qty: 1 }], bumps: [] });
});
test("DRFT-38 integer-like ids sort as text, in every engine", () => {
    eq(PD.commitPlan({ "10": 1, "9": 1, "2": 1 }, []).adds.map((e) => e.productId), ["10", "2", "9"]);
    eq(PD.totals({ "10": 1, "9": 2, "2": 3 }, (id) => Number(id)), { items: 6, lines: 3, amount: 10 + 18 + 6 });
    eq(PD.setQty({ "10": 1 }, "9", "2", 5), { "10": 1, "9": 2 });
});
test("DRFT-39 legacy lines without a product id each count on their own", () => {
    eq(PD.lineCountAfter([{ productId: "" }, { productId: "" }, { productId: "A" }], null), 3);
    eq(PD.lineCountAfter([{ productId: null }, {}, { productId: "A" }], null), 3);
    eq(PD.lineCountAfter([null, undefined, 5, "x", []], null), 0);
    eq(PD.lineCountAfter([{ productId: "A" }, { productId: "A" }], { adds: [{ productId: "B" }] }), 2);
    const legacy = [];
    for (let i = 0; i < 59; ++i) legacy.push({ productId: "" });
    eq(PD.lineLimitReached(legacy, { NEW: 1 }), true);
    eq(PD.lineLimitReached(legacy, {}), false);
});
test("DRFT-40 canCommit: empty, within the limit, and over it", () => {
    eq(PD.canCommit([], {}), { ok: false, reason: "empty" });
    eq(PD.canCommit([], null), { ok: false, reason: "empty" });
    eq(PD.canCommit([], { A: 0, B: -1, C: "2" }), { ok: false, reason: "empty" });
    eq(PD.canCommit([], { A: 1 }), { ok: true, reason: "" });
    const l60 = [];
    for (let i = 0; i < 60; ++i) l60.push({ productId: "L" + i });
    eq(PD.canCommit(l60, { L3: 2 }), { ok: true, reason: "" });
    eq(PD.canCommit(l60, { NEW: 1 }), { ok: false, reason: "too-many-lines" });
    eq(PD.canCommit(l60.slice(0, 59), { NEW: 1 }), { ok: true, reason: "" });
    eq(PD.canCommit(l60.slice(0, 59), { NEW: 1, NEW2: 1 }), { ok: false, reason: "too-many-lines" });
    eq(PD.canCommit(l60.concat([{ productId: "" }]), { L3: 1 }), { ok: false, reason: "too-many-lines" });
});
test("DRFT-41 a stale draft over the cap is caught by canCommit, not by step or setQty", () => {
    let d = {};
    for (let i = 0; i < 64; ++i) d = PD.setQty(d, "N" + i, "1", 5);
    eq(Object.keys(d).length, 64);
    eq(PD.canCommit([], d), { ok: false, reason: "too-many-lines" });
});
test("DRFT-42 parseQty keeps its exact limits", () => {
    eq(PD.parseQty("000001"), { ok: true, qty: 1 });
    eq(PD.parseQty("0000001"), { ok: false, qty: 0 });
    eq(PD.parseQty("\t5\n"), { ok: true, qty: 5 });
    eq(PD.parseQty(1000000), { ok: false, qty: 0 });
    eq(PD.parseQty(999999), { ok: true, qty: 999999 });
});
