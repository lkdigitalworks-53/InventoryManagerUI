"use strict";
// Picker v2, slice S5g: the two dead Auth buttons are deleted (KNOWN-ISSUES 146, 143). S5G-01..NN.
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

// Every file of the app that could name a type: QML (comments stripped), QML tests, qmldir files, C++, CMake. Whole-word match.
function mentions(root, names) {
    const hay = [];
    for (const f of qmlFiles(path.join(root, "qml"))) hay.push([path.relative(root, f), stripComments(fs.readFileSync(f, "utf8"))]);
    const tdir = path.join(root, "tests");
    if (fs.existsSync(tdir)) for (const f of fs.readdirSync(tdir)) if (/\.(qml|js)$/.test(f)) hay.push(["tests/" + f, stripComments(fs.readFileSync(path.join(tdir, f), "utf8"))]);
    for (const d of ["helper", "components", "model"]) {
        const q = path.join(root, "qml", d, "qmldir");
        if (fs.existsSync(q)) hay.push([path.relative(root, q), fs.readFileSync(q, "utf8")]);
    }
    for (const f of ["main.cpp", "CMakeLists.txt"]) if (fs.existsSync(path.join(root, f))) hay.push([f, fs.readFileSync(path.join(root, f), "utf8")]);
    const out = [];
    for (const [f, t] of hay) for (const n of names) if (new RegExp("\\b" + n + "\\b").test(t)) out.push(f + " names " + n);
    return out.sort();
}
function tree(files, extra) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "s5g-"));
    fs.mkdirSync(path.join(root, "qml"), { recursive: true });
    for (const [n, body] of Object.entries(files)) { fs.mkdirSync(path.dirname(path.join(root, "qml", n)), { recursive: true }); fs.writeFileSync(path.join(root, "qml", n), body); }
    for (const [n, body] of Object.entries(extra || {})) { fs.mkdirSync(path.dirname(path.join(root, n)), { recursive: true }); fs.writeFileSync(path.join(root, n), body); }
    return root;
}

test("S5G-01 the two dead Auth buttons are deleted, from every place a QML file can live", () => {
    for (const n of GONE) for (const d of ["components", "helper", "model", "pages"]) assert.equal(fs.existsSync(path.join(ROOT, "qml", d, n + ".qml")), false, d + "/" + n + ".qml came back");
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
