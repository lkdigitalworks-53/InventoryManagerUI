"use strict";

// The QML twins of the picker helper tests (tests/tst_ProductSearch.qml, tst_ProductPickability.qml,
// tst_PickerDraft.qml) are DERIVED from the Node test files, so the two engines run the same case
// bodies and cannot drift. `derive` rebuilds a twin's text; pickerDormancy.test.js (PAIR-01) requires
// the committed twin to equal it. Regenerate after editing a Node test file:
//   node functions/test/testSupport/pickerTwin.js --write
//
// Rules the Node bodies follow so this works: assertions only through eq / ok / noThrow, data only
// through FX (tests/pickerFixtures.js), helpers only as function declarations inside the
// QML-PRELUDE block, and a title ending "(Node only)" is left out of the twin.

const fs = require("node:fs");
const path = require("node:path");

const TESTS = path.join(__dirname, "..", "..", "..", "tests");
const NODE = path.join(__dirname, "..");

const TWINS = [
    { node: "pickerSearch.test.js", qml: "tst_ProductSearch.qml", name: "ProductSearch", helper: "ProductSearch.js", alias: "PS" },
    { node: "pickerPickability.test.js", qml: "tst_ProductPickability.qml", name: "ProductPickability", helper: "ProductPickability.js", alias: "PK" },
    { node: "pickerDraft.test.js", qml: "tst_PickerDraft.qml", name: "PickerDraft", helper: "PickerDraft.js", alias: "PD" },
    { node: "pickerRowGeometry.test.js", qml: "tst_PickerRowGeometry.qml", name: "PickerRowGeometry", helper: "PickerRowGeometry.js", alias: "PG" },
    { node: "pickerSheetModel.test.js", qml: "tst_PickerSheetModel.qml", name: "PickerSheetModel", helper: "PickerSheetModel.js", alias: "PM" },
    { node: "newOrderPicker.test.js", qml: "tst_NewOrderPicker.qml", name: "NewOrderPicker", helper: "NewOrderPicker.js", alias: "NP" },
];

function slug(title) {
    return title.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").substring(0, 60);
}

function parseCases(src) {
    const cases = [];
    const re = /^test\("([A-Z]+-\d+[a-z]?) ([^"]*)", \(\) => \{\n([\s\S]*?)^\}\);$/gm;
    let m;
    while ((m = re.exec(src)) !== null) cases.push({ id: m[1], title: m[2], body: m[3] });
    return cases;
}

// A body copied into QML must not touch Node-only names; the QML engine would fail at run time, in CI only.
const NODE_ONLY = /\b(require|process|Buffer|assert|__dirname|__filename)\b|\bfs\.|\bpath\./;

function derive(spec) {
    const src = fs.readFileSync(path.join(NODE, spec.node), "utf8");
    const pre = /\/\/ QML-PRELUDE-BEGIN\n([\s\S]*?)\/\/ QML-PRELUDE-END/.exec(src);
    const indent = (text, n) => text.split("\n").map((l) => (l.length ? " ".repeat(n) + l : l)).join("\n");
    const out = [];
    out.push("import QtQuick");
    out.push("import QtTest");
    out.push('import "../qml/helper/' + spec.helper + '" as ' + spec.alias);
    out.push('import "pickerFixtures.js" as FX');
    out.push("");
    out.push("// DERIVED FILE, do not edit. Rebuilt from functions/test/" + spec.node + " by");
    out.push("// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);");
    out.push("// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.");
    out.push("// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.");
    out.push("// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md");
    out.push("TestCase {");
    out.push('    name: "' + spec.name + '"');
    out.push("");
    out.push("    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }");
    out.push("    function ok(cond, msg) { verify(cond, msg) }");
    out.push('    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }');
    if (pre) {
        if (NODE_ONLY.test(pre[1])) throw new Error(spec.node + ": QML-PRELUDE uses a Node-only name");
        out.push(""); out.push(indent(pre[1].replace(/\n+$/, ""), 4));
    }
    // A helper defined at the top of the Node file but outside the prelude does not exist in the QML twin: the twin
    // would load and then fail with a ReferenceError in CI only (it did, in the #187 review sweep). Refuse it here.
    const outside = src.replace(/\/\/ QML-PRELUDE-BEGIN\n[\s\S]*?\/\/ QML-PRELUDE-END/, "");
    const hidden = [];
    for (const m of outside.matchAll(/^(?:function (\w+)\(|const (\w+) =)/gm)) hidden.push(m[1] || m[2]);
    const known = new Set([spec.alias, "FX", "test"]);
    for (const c of parseCases(src)) {
        if (/\(Node only\)$/.test(c.title)) continue;
        for (const name of hidden)
            if (!known.has(name) && new RegExp("\\b" + name + "\\b").test(c.body))
                throw new Error(spec.node + " " + c.id + ": uses " + name + ", defined outside the QML-PRELUDE, so the QML twin cannot see it");
        if (NODE_ONLY.test(c.body)) throw new Error(spec.node + " " + c.id + ": body uses a Node-only name; end the title with (Node only) or rewrite it");
        out.push("");
        out.push("    function test_" + c.id.replace("-", "_") + "_" + slug(c.title) + "() {");
        out.push(indent(c.body.replace(/\n+$/, ""), 4));
        out.push("    }");
    }
    out.push("}");
    return out.join("\n") + "\n";
}

function qmlPath(spec) { return path.join(TESTS, spec.qml); }

if (require.main === module) {
    if (process.argv.includes("--write")) {
        for (const spec of TWINS) fs.writeFileSync(qmlPath(spec), derive(spec));
        console.log("wrote " + TWINS.length + " twins");
    }
}

module.exports = { TWINS, derive, parseCases, qmlPath };
