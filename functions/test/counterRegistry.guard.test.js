"use strict";

// Drift guard (Skill 138 pattern: a guard only guards if the guard itself is mutation-tested).
// The server mints ids with lib/counterRegistry.js; the client still mints the same counters from
// QML (FirebaseService.mintCounterValue) until their consumers migrate (design 7b). Both write the
// SAME counter doc, so the id format, the counter name and the doc-id rule must agree byte for byte.
// The QML stores are not importable from Node, so this reads their source.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const R = require("../lib/counterRegistry");

const MODEL = path.join(__dirname, "..", "..", "qml", "model");
const read = (f) => fs.readFileSync(path.join(MODEL, f), "utf8");

// True when the source has at least one `Gateway.recordMutation("<entity>", <id>, "create"` and EVERY
// one of them uses `idExpr` as the doc id (one stray caller with another id would fork the id space).
function everyCreateUses(src, entity, idExpr) {
    const re = new RegExp('Gateway\\.recordMutation\\("' + entity + '", ([^,]+), "create"', "g");
    const ids = [];
    let m;
    while ((m = re.exec(src)) !== null) ids.push(m[1].trim());
    return ids.length > 0 && ids.every((x) => x === idExpr);
}

// Each row: what the QML source must still contain for one registry entry.
function expectations(year) {
    const sup = R.describe("supplier", year);
    const bat = R.describe("stock_batch", year);
    return [
        { file: "SupplierStore.qml", label: "supplier counter name", re: new RegExp('mintCounterValue\\("counters/' + sup.counterName + '"') },
        { file: "SupplierStore.qml", label: "supplier id format", re: new RegExp("callback\\(ok \\? \\('" + sup.prefix + "' \\+ String\\(value\\)\\.padStart\\(3, '0'\\)\\)") },
        { file: "SupplierStore.qml", label: "supplier doc id = supplierId", test: (src) => everyCreateUses(src, "supplier", "doc.supplierId") },
        { file: "StockBatchStore.qml", label: "batch counter name per year", re: /mintCounterValue\("counters\/stockBatches-" \+ year,/ },
        { file: "StockBatchStore.qml", label: "batch id prefix per year", re: /return "BAT-" \+ year \+ "-"/ },
        { file: "StockBatchStore.qml", label: "batch id padding", re: /callback\(ok \? \(prefix \+ String\(value\)\.padStart\(3, '0'\)\) : ""\)/ },
        { file: "StockBatchStore.qml", label: "batch doc id = batchId", test: (src) => everyCreateUses(src, "stock_batch", "doc.batchId") }
    ];
}
function failures(sources, year) {
    return expectations(year).filter((e) => !(e.test ? e.test(sources[e.file]) : e.re.test(sources[e.file]))).map((e) => e.file + ": " + e.label);
}
const sources = () => ({ "SupplierStore.qml": read("SupplierStore.qml"), "StockBatchStore.qml": read("StockBatchStore.qml") });

test("guard: the QML stores still mint supplier and batch ids exactly as the server registry does", () => {
    assert.deepEqual(failures(sources(), "2026"), []);
});

test("guard: a changed counter name, prefix, padding or doc id in QML is caught (the guard itself is mutation-tested)", () => {
    const base = sources();
    const mutants = [
        ["SupplierStore.qml", "counters/suppliers", "counters/supplier"],
        ["SupplierStore.qml", "'SUP-' + String(value).padStart(3, '0')", "'SUP-' + String(value).padStart(4, '0')"],
        ["SupplierStore.qml", "Gateway.recordMutation(\"supplier\", doc.supplierId, \"create\"", "Gateway.recordMutation(\"supplier\", doc.name, \"create\""],
        ["StockBatchStore.qml", "\"counters/stockBatches-\" + year", "\"counters/batches-\" + year"],
        ["StockBatchStore.qml", "return \"BAT-\" + year + \"-\"", "return \"BATCH-\" + year + \"-\""],
        ["StockBatchStore.qml", "prefix + String(value).padStart(3, '0')", "prefix + String(value)"],
        ["StockBatchStore.qml", "Gateway.recordMutation(\"stock_batch\", doc.batchId, \"create\"", "Gateway.recordMutation(\"stock_batch\", doc.id, \"create\""]
    ];
    for (const [file, from, to] of mutants) {
        assert.ok(base[file].indexOf(from) >= 0, "mutant target not found: " + from);
        // replace() hits the FIRST occurrence only: for the doc-id rows that is "one stray caller among the others"
        const mutated = Object.assign({}, base, { [file]: base[file].replace(from, to) });
        assert.ok(failures(mutated, "2026").length >= 1, "not caught: " + from + " -> " + to);
    }
});

test("guard: registry facts the client relies on", () => {
    assert.equal(R.describe("supplier", "2026").collection, "suppliers");
    assert.equal(R.describe("stock_batch", "2026").collection, "stock_batches");
    // gatewayLogic's entity map is where the client's Gateway.recordMutation("supplier"/"stock_batch") lands
    const { ENTITY_COLLECTIONS } = require("../lib/gatewayLogic");
    assert.equal(ENTITY_COLLECTIONS.supplier, R.describe("supplier", "2026").collection);
    assert.equal(ENTITY_COLLECTIONS.stock_batch, R.describe("stock_batch", "2026").collection);
});
