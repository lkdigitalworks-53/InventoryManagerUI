"use strict";
// Picker v2, slice S5f: five dead helpers deleted (KNOWN-ISSUES 121, 128, 143). S5F-01..NN.
// Plan: docs/superpowers/plans/2026-11-24-product-picker-v2-s5f-dead-helper-cleanup.md
// Source reads only (qmltestrunner cannot load Felgo pages). They pin that the files stay deleted and that no NEW dead QML file appears.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { deadQmlFiles } = require("./testSupport/deadQmlScan");
const { stripComments, qmlFiles } = require("./testSupport/qmlButtonScan");

const ROOT = path.join(__dirname, "..", "..");
const GONE = ["CardKPI", "OrderRow", "PlaceholderPage", "SegmentedNav", "StatusBadge"];

test("S5F-01 the five dead helpers are deleted", () => {
    for (const n of GONE) assert.equal(fs.existsSync(path.join(ROOT, "qml", "helper", n + ".qml")), false, n + ".qml came back");
});

test("S5F-02 nothing names a deleted helper: no QML file (comments aside), no qmldir, no QML test, no C++ or CMake", () => {
    const hay = [];
    for (const f of qmlFiles(path.join(ROOT, "qml"))) hay.push([f, stripComments(fs.readFileSync(f, "utf8"))]);
    for (const f of fs.readdirSync(path.join(ROOT, "tests"))) if (/\.(qml|js)$/.test(f)) hay.push([f, stripComments(fs.readFileSync(path.join(ROOT, "tests", f), "utf8"))]);
    for (const d of ["helper", "components", "model"]) hay.push([d + "/qmldir", fs.readFileSync(path.join(ROOT, "qml", d, "qmldir"), "utf8")]);
    for (const f of ["main.cpp", "CMakeLists.txt"]) hay.push([f, fs.readFileSync(path.join(ROOT, f), "utf8")]);
    for (const [f, t] of hay) for (const n of GONE) assert.equal(new RegExp("\\b" + n + "\\b").test(t), false, path.basename(f) + " names " + n);
});

test("S5F-03 RATCHET: the only QML files nothing uses are the two Auth buttons (dead, KNOWN-ISSUES 146) and AnalysisService (dormant on purpose, README: not yet wired into SalesPage)", () => {
    assert.deepEqual(deadQmlFiles(ROOT), ["qml/components/AuthPrimaryButton.qml", "qml/components/AuthSecondaryButton.qml", "qml/model/AnalysisService.qml"],
        "a NEW unused QML file (delete it, or use it), or one of these three deleted/used: update this list on purpose");
});

test("S5F-04 the live helpers the dead ones were next to are still there (Constants, FormValidator, SafeArea, InlineDatePicker)", () => {
    for (const n of ["Constants", "FormValidator", "SafeArea", "InlineDatePicker"]) assert.equal(fs.existsSync(path.join(ROOT, "qml", "helper", n + ".qml")), true, n);
    assert.match(fs.readFileSync(path.join(ROOT, "qml", "helper", "qmldir"), "utf8"), /singleton Constants 1\.0 Constants\.qml/);
});

// ---- the scanner, on hand-built trees ---------------------------------------------------------------------------------------
function tree(files, extra) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "deadqml-"));
    fs.mkdirSync(path.join(root, "qml"), { recursive: true });
    for (const [n, body] of Object.entries(files)) { fs.mkdirSync(path.dirname(path.join(root, "qml", n)), { recursive: true }); fs.writeFileSync(path.join(root, "qml", n), body); }
    for (const [n, body] of Object.entries(extra || {})) { fs.mkdirSync(path.dirname(path.join(root, n)), { recursive: true }); fs.writeFileSync(path.join(root, n), body); }
    return root;
}

test("S5F-05 scanner: a real user keeps a file alive; a self-mention, a comment, a longer name and a shorter name do not", () => {
    const r = tree({
        "Main.qml": "App { Used { } }",
        "Used.qml": "Item { property int Used: 1 }",                    // self-mention does not count
        "Commented.qml": "Item { }",
        "Long.qml": "Item { }",
        "Short.qml": "Item { }",
        "Other.qml": "Item { // Commented { }\n /* Commented { } */ LongName { } MyShort { } }",
    }, { "main.cpp": "load(\"qml/Main.qml\")" });
    assert.deepEqual(deadQmlFiles(r), ["qml/Commented.qml", "qml/Long.qml", "qml/Other.qml", "qml/Short.qml"]);
});

test("S5F-06 scanner: a string source, a C++ mention and a CMake mention count as users; the 3rdparty C++ tree does not", () => {
    const r = tree({ "A.qml": "Item { }", "B.qml": "Item { }", "C.qml": "Item { }", "D.qml": "Item { }", "Host.qml": "Loader { source: \"A.qml\" }" },
        { "main.cpp": "x B", "CMakeLists.txt": "set(f C)", "src/3rdparty/lib.cpp": "D", "src/real.cpp": "// none" });
    assert.deepEqual(deadQmlFiles(r), ["qml/D.qml", "qml/Host.qml"]);
});

test("S5F-07 scanner: empty tree, one file, nested dirs, a file used only from a deeper directory", () => {
    assert.deepEqual(deadQmlFiles(tree({})), []);
    assert.deepEqual(deadQmlFiles(tree({ "Solo.qml": "Item { }" })), ["qml/Solo.qml"]);
    assert.deepEqual(deadQmlFiles(tree({ "a/b/Deep.qml": "Item { }", "c/User.qml": "Deep { }" })), ["qml/c/User.qml"]);
});

// ---- monkey: 300 seeded random trees, expected dead set known by construction --------------------------------------------------
test("S5F-08 monkey: 300 seeded random trees with decoys agree with the set known by construction", () => {
    let seed = 20261124;
    const rnd = (n) => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed % n; };
    for (let round = 0; round < 300; round++) {
        const n = 2 + rnd(8), names = Array.from({ length: n }, (_, i) => "Comp" + String.fromCharCode(65 + i) + (rnd(2) ? "X" : ""));
        const used = new Set(), files = {};
        names.forEach((name, i) => {
            let body = "Item { ";
            for (let k = 0; k < 1 + rnd(4); k++) {
                const j = rnd(n), other = names[j], kind = rnd(5);
                if (kind === 0 && j !== i) { body += other + " { } "; used.add(j); }
                else if (kind === 1 && j !== i) { body += "Loader { source: \"" + other + ".qml\" } "; used.add(j); }
                else if (kind === 2) body += "// " + other + " { }\n";                  // comment decoy
                else if (kind === 3) body += "My" + other + " { } ";                    // longer-name decoy (only a decoy when `other` is not itself a prefix match; names are unique so it never is)
                else body += name + " { } ";                                            // self decoy
            }
            files[name + ".qml"] = body + "}";
        });
        const expected = names.filter((_, i) => !used.has(i)).map((x) => "qml/" + x + ".qml").sort();
        assert.deepEqual(deadQmlFiles(tree(files)), expected, "round " + round + ": " + JSON.stringify(files));
    }
});
