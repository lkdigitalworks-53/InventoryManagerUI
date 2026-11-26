"use strict";
// Picker v2, slice S5g: the two dead Auth buttons are deleted (KNOWN-ISSUES 146, 143). S5G-01..09 (07..09 added in the PR 221 review sweep).
// Plan: docs/superpowers/plans/2026-11-25-product-picker-v2-s5g-auth-buttons-and-final-pass.md
// Source reads only (qmltestrunner cannot load Felgo pages). They pin that the files stay deleted, that nothing names them
// (in code, qmldir, QML tests, C++ or CMake) and that the login screen still has the buttons it really uses.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { stripComments, qmlFiles } = require("./testSupport/qmlButtonScan");

const ROOT = path.join(__dirname, "..", "..");
const GONE = ["AuthPrimaryButton", "AuthSecondaryButton"];
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");

// Every file under a directory, recursive, sorted.
function walk(dir) {
    const out = [];
    if (!fs.existsSync(dir)) return out;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) out.push(...walk(p)); else out.push(p);
    }
    return out.sort();
}
// Every file of the app that could name a type: QML and JS under qml/ (comments stripped; a JS helper can `Qt.createComponent` by
// string), every qmldir anywhere under qml/, QML and JS tests (recursive), C++ and CMake. Whole-word match.
function mentions(root, names) {
    const hay = [];
    for (const f of walk(path.join(root, "qml"))) {
        const b = path.basename(f);
        if (/\.(qml|js|mjs)$/.test(b)) hay.push([path.relative(root, f), stripComments(fs.readFileSync(f, "utf8"))]);
        else if (b === "qmldir") hay.push([path.relative(root, f), fs.readFileSync(f, "utf8")]);
    }
    for (const f of walk(path.join(root, "tests"))) if (/\.(qml|js|mjs)$/.test(f)) hay.push([path.relative(root, f), stripComments(fs.readFileSync(f, "utf8"))]);
    for (const f of ["main.cpp", "CMakeLists.txt"]) if (fs.existsSync(path.join(root, f))) hay.push([f, fs.readFileSync(path.join(root, f), "utf8")]);
    const out = [];
    for (const [f, t] of hay) for (const n of names) if (new RegExp("\\b" + n + "\\b").test(t)) out.push(f + " names " + n);
    return out.sort();
}
// Where a QML file of that name lives, anywhere under qml/ (any folder, the qml/ root included).
function filesNamed(root, names) {
    return walk(path.join(root, "qml")).filter((f) => names.some((n) => path.basename(f) === n + ".qml")).map((f) => path.relative(root, f)).sort();
}
// Temp trees are removed after the run: S5G-03 and S5G-06 build about 300 of them.
const made = [];
function cleanup() { while (made.length) fs.rmSync(made.pop(), { recursive: true, force: true }); }
test.after(cleanup);
function tree(files, extra) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "s5g-"));
    made.push(root);
    fs.mkdirSync(path.join(root, "qml"), { recursive: true });
    for (const [n, body] of Object.entries(files)) { fs.mkdirSync(path.dirname(path.join(root, "qml", n)), { recursive: true }); fs.writeFileSync(path.join(root, "qml", n), body); }
    for (const [n, body] of Object.entries(extra || {})) { fs.mkdirSync(path.dirname(path.join(root, n)), { recursive: true }); fs.writeFileSync(path.join(root, n), body); }
    return root;
}

test("S5G-01 the two dead Auth buttons are deleted, from every folder under qml/ (components, helper, model, pages, logic, the root)", () => {
    assert.deepEqual(filesNamed(ROOT, GONE), [], "a deleted button came back");
});

test("S5G-02 nothing names a deleted button: no QML file (comments aside), no qmldir, no QML test, no C++ or CMake", () => {
    assert.deepEqual(mentions(ROOT, GONE), []);
});

test("S5G-03 the matcher itself: it finds a real use in each kind of file, and ignores a comment and look-alike names", () => {
    const bad = tree({ "Page.qml": "Item { AuthPrimaryButton { } }", "components/qmldir": "AuthSecondaryButton 1.0 AuthSecondaryButton.qml" },
        { "main.cpp": "// none", "CMakeLists.txt": "set(x AuthPrimaryButton)", "tests/tst_X.qml": "Item { AuthSecondaryButton { } }" });
    assert.deepEqual(mentions(bad, GONE), ["CMakeLists.txt names AuthPrimaryButton", "qml/Page.qml names AuthPrimaryButton",
        "qml/components/qmldir names AuthSecondaryButton", "tests/tst_X.qml names AuthSecondaryButton"]);
    const ok = tree({ "Page.qml": "Item { // AuthPrimaryButton { }\n /* AuthSecondaryButton */ PrimaryButton { } MyAuthPrimaryButton { } AuthPrimaryButtonX { } AuthSecondary { } }" }, { "main.cpp": "x" });
    assert.deepEqual(mentions(ok, GONE), [], "a comment, a longer name, a shorter name and a prefixed name are not uses");
    assert.deepEqual(mentions(tree({}), GONE), [], "empty tree");
});

test("S5G-04 regression: the login screen keeps the buttons it really uses (PrimaryButton, GhostButton) and its two live Auth fields", () => {
    const login = stripComments(read("qml/pages/LoginPage.qml"));
    for (const n of ["PrimaryButton", "GhostButton", "AuthTextField", "AuthPasswordField"]) assert.match(login, new RegExp("\\b" + n + " \\{"), "LoginPage no longer uses " + n);
    for (const n of ["PrimaryButton", "GhostButton", "AuthTextField", "AuthPasswordField"]) assert.equal(fs.existsSync(path.join(ROOT, "qml", "components", n + ".qml")), true, n);
});

test("S5G-05 the colour literals outside Constants.qml dropped by exactly the seven the two buttons held (56 to 49, KNOWN-ISSUES 143)", () => {
    const T = require("./testSupport/qmlThemeScaleScan");
    const hex = T.scanHex(ROOT);
    const outside = Object.entries(hex).filter(([f]) => f !== "qml/helper/Constants.qml").reduce((a, [, n]) => a + n, 0);
    assert.equal(outside, 49);
});

test("S5G-06 MONKEY: 300 seeded trees, a name placed in a random kind of file or in a random decoy; the matcher finds exactly the real ones", () => {
    let seed = 20261125;
    const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
    const kinds = [["Page.qml", "Item { NAME { } }", true], ["Page.qml", "Item { // NAME { }\n }", false], ["Page.qml", "Item { /* NAME */ }", false],
        ["Page.qml", "Item { MyNAME { } }", false], ["Page.qml", "Item { NAMEX { } }", false], ["x/Deep.qml", "Item { property var t: NAME }", true]];
    for (let i = 0; i < 300; ++i) {
        const name = GONE[Math.floor(rnd() * GONE.length)];
        const [file, body, real] = kinds[Math.floor(rnd() * kinds.length)];
        const extra = rnd() < 0.3 ? { "CMakeLists.txt": "set(f NAME)".replace("NAME", name) } : {};
        const r = tree({ [file]: body.replace(/NAME/g, name) }, extra);
        const expectCount = (real ? 1 : 0) + (extra["CMakeLists.txt"] ? 1 : 0);
        assert.equal(mentions(r, GONE).length, expectCount, "round " + i + " " + file + " " + body);
    }
});

test("S5G-07 review sweep: the matcher also reads a JS helper (Qt.createComponent by string) and a qmldir in any folder, and a test in a sub-folder", () => {
    const r = tree({ "helper/Make.js": 'function f() { return Qt.createComponent("../components/AuthPrimaryButton.qml"); }', "logic/qmldir": "AuthSecondaryButton 1.0 AuthSecondaryButton.qml" },
        { "tests/sub/tst_Deep.js": "var x = AuthPrimaryButton;" });
    assert.deepEqual(mentions(r, GONE), ["qml/helper/Make.js names AuthPrimaryButton", "qml/logic/qmldir names AuthSecondaryButton", "tests/sub/tst_Deep.js names AuthPrimaryButton"]);
    const ok = tree({ "helper/Make.js": "// AuthPrimaryButton\n/* AuthSecondaryButton */ var a = MyAuthPrimaryButton;" });
    assert.deepEqual(mentions(ok, GONE), [], "a JS comment and a look-alike name are not uses");
});

test("S5G-08 review sweep: the file-name check finds a deleted name in ANY folder under qml/ (logic, the root, a new folder), and nothing for look-alike file names", () => {
    const r = tree({ "logic/AuthPrimaryButton.qml": "Item { }", "AuthSecondaryButton.qml": "Item { }", "new/dir/AuthPrimaryButton.qml": "Item { }" });
    assert.deepEqual(filesNamed(r, GONE), ["qml/AuthSecondaryButton.qml", "qml/logic/AuthPrimaryButton.qml", "qml/new/dir/AuthPrimaryButton.qml"]);
    const ok = tree({ "components/PrimaryButton.qml": "Item { }", "components/MyAuthPrimaryButton.qml": "Item { }", "components/AuthPrimaryButton.txt": "x" });
    assert.deepEqual(filesNamed(ok, GONE), []);
    assert.deepEqual(filesNamed(tree({}), GONE), [], "empty tree");
    assert.deepEqual(filesNamed(path.join(os.tmpdir(), "s5g-does-not-exist"), GONE), [], "no qml folder at all");
});

test("S5G-09 review sweep: the temp trees the tests build are removed (no leak of s5g-* folders)", () => {
    const r = tree({ "Page.qml": "Item { }" });
    assert.equal(fs.existsSync(r), true);
    cleanup();
    assert.equal(fs.existsSync(r), false, "cleanup left the tree behind");
    assert.equal(made.length, 0);
});
