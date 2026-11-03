"use strict";
// Product picker v2, slice S1: the three helpers are dormant (nothing calls them yet), have the shape
// a `.pragma library` file needs (Skill 83), and the QML twins are exactly what the Node tests derive.
// DORM-01..03 and PAIR-01..02. S3 changes DORM-01 on purpose, in the same PR that wires a dialog.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { TWINS, derive, qmlPath } = require("./testSupport/pickerTwin");

const ROOT = path.join(__dirname, "..", "..");
const HELPERS = ["ProductSearch", "ProductPickability", "PickerDraft"];
const NAMES = /ProductSearch|ProductPickability|PickerDraft/;

function walk(dir, out) {
    if (!fs.existsSync(dir)) return out;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        if (e.name === "node_modules" || e.name === "coverage" || e.name === ".git") continue;
        const full = path.join(dir, e.name);
        if (e.isDirectory()) walk(full, out);
        else if (/\.(qml|js|cpp|h|json|txt|cmake|pro|pri|qrc)$/.test(e.name)) out.push(full);
    }
    return out;
}

const ALLOWED = new Set([
    "qml/helper/ProductSearch.js", "qml/helper/ProductPickability.js", "qml/helper/PickerDraft.js",
    "tests/tst_ProductSearch.qml", "tests/tst_ProductPickability.qml", "tests/tst_PickerDraft.qml",
    "functions/test/pickerSearch.test.js", "functions/test/pickerPickability.test.js", "functions/test/pickerDraft.test.js",
    "tests/pickerFixtures.js", "functions/test/pickerFlow.test.js", "functions/test/pickerDormancy.test.js", "functions/test/testSupport/pickerTwin.js",
]);

test("DORM-01 nothing outside the helpers and their tests mentions them", () => {
    const files = [].concat(walk(path.join(ROOT, "qml"), []), walk(path.join(ROOT, "src"), []),
                            walk(path.join(ROOT, "tests"), []), walk(path.join(ROOT, "functions"), []));
    const main = path.join(ROOT, "main.cpp");
    if (fs.existsSync(main)) files.push(main);
    assert.ok(files.length > 100, "walk found too few files: " + files.length);
    const offenders = files.map((f) => path.relative(ROOT, f).split(path.sep).join("/"))
        .filter((rel) => !ALLOWED.has(rel))
        .filter((rel) => NAMES.test(fs.readFileSync(path.join(ROOT, rel), "utf8")));
    assert.deepEqual(offenders, []);
});

test("DORM-02 each helper is a plain pragma library with no Felgo or singleton dependency", () => {
    for (const h of HELPERS) {
        const src = fs.readFileSync(path.join(ROOT, "qml", "helper", h + ".js"), "utf8");
        assert.ok(/^\.pragma library\s*$/m.test(src.split("\n").slice(0, 1).join("\n")), h + " must start with .pragma library");
        assert.ok(!/^\s*\.import\b/m.test(src), h + " has an .import line");
        assert.ok(!/\b(Constants|InventoryStore|StockBatchStore|OutboxStore|DataModel|Felgo)\b|\bdp\(|\bsp\(/.test(src), h + " names a singleton or a Felgo unit");
    }
    const fx = fs.readFileSync(path.join(ROOT, "tests", "pickerFixtures.js"), "utf8");
    assert.ok(/^\.pragma library\s*$/m.test(fx.split("\n")[0]));
});

test("DORM-03 the helpers are not in qml/helper/qmldir yet", () => {
    const qmldir = path.join(ROOT, "qml", "helper", "qmldir");
    if (!fs.existsSync(qmldir)) return;
    const src = fs.readFileSync(qmldir, "utf8");
    for (const h of HELPERS) assert.ok(!src.includes(h), h + " is in qmldir: S2 adds it deliberately, with this test");
});

test("PAIR-01 every QML twin is exactly what the Node test derives", () => {
    for (const spec of TWINS) {
        const have = fs.readFileSync(qmlPath(spec), "utf8");
        assert.equal(have, derive(spec), spec.qml + " is stale: run node functions/test/testSupport/pickerTwin.js --write");
    }
});

test("PAIR-02 each twin has one function per Node case, and the Node-only case is the only gap", () => {
    for (const spec of TWINS) {
        const node = fs.readFileSync(path.join(__dirname, spec.node), "utf8");
        const nodeIds = [...node.matchAll(/^test\("([A-Z]+-\d+) /gm)].map((m) => m[1]);
        const nodeOnly = [...node.matchAll(/^test\("([A-Z]+-\d+) [^"]*\(Node only\)"/gm)].map((m) => m[1]);
        const qml = fs.readFileSync(qmlPath(spec), "utf8");
        const qmlIds = [...qml.matchAll(/function test_([A-Z]+_\d+)_/g)].map((m) => m[1].replace("_", "-"));
        assert.deepEqual(qmlIds, nodeIds.filter((id) => !nodeOnly.includes(id)));
        assert.equal(new Set(nodeIds).size, nodeIds.length, "duplicate case id in " + spec.node);
    }
});

test("PAIR-03 no QML twin method starts with an upper-case letter (the QML engine refuses it at compile time)", () => {
    for (const spec of TWINS) {
        const qml = fs.readFileSync(qmlPath(spec), "utf8");
        const bad = [...qml.matchAll(/^\s*function ([A-Z]\w*)\(/gm)].map((m) => m[1]);
        assert.deepEqual(bad, [], spec.qml);
    }
});
