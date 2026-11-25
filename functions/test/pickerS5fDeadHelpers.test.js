"use strict";
// Picker v2, slice S5f: five dead helpers deleted (KNOWN-ISSUES 121, 128, 143). S5F-01..NN.
// Plan: docs/superpowers/plans/2026-11-24-product-picker-v2-s5f-dead-helper-cleanup.md
// Source reads only (qmltestrunner cannot load Felgo pages). They pin that the files stay deleted and that no NEW dead QML file appears
// (dead = not reachable from a file the app's C++ / CMake names: a chain or a cycle of dead files is dead).
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

test("S5F-03 RATCHET: the only QML files nothing live uses are the two Auth buttons (dead, KNOWN-ISSUES 146) and AnalysisService (dormant on purpose, README: not yet wired into SalesPage)", () => {
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
        { "main.cpp": "x B Host", "CMakeLists.txt": "set(f C)", "src/3rdparty/lib.cpp": "D", "src/real.cpp": "// none" });
    assert.deepEqual(deadQmlFiles(r), ["qml/D.qml"]);
});

test("S5F-07 scanner: empty tree, one file, nested dirs, a file used only from a deeper directory", () => {
    assert.deepEqual(deadQmlFiles(tree({})), []);
    assert.deepEqual(deadQmlFiles(tree({ "Solo.qml": "Item { }" })), ["qml/Solo.qml"]);
    const nested = { "a/b/Deep.qml": "Item { }", "c/User.qml": "Deep { }" };
    assert.deepEqual(deadQmlFiles(tree(nested, { "main.cpp": "User" })), []);
    assert.deepEqual(deadQmlFiles(tree(nested)), ["qml/a/b/Deep.qml", "qml/c/User.qml"], "no root: the user is dead, so what only it uses is dead too");
});

test("S5F-13 scanner: a file used only by a dead file is dead (chain), a dead cycle is dead, a live second user rescues, a comment is no user", () => {
    const files = {
        "Main.qml": "App { A { } /* Hidden { } */ }", "A.qml": "B { Shared { } }", "B.qml": "Item { }",    // live chain
        "X.qml": "Y { }", "Y.qml": "Z { }", "Z.qml": "Item { }",                                      // dead chain: nothing names X
        "P.qml": "Q { }", "Q.qml": "P { }",                                                            // dead cycle
        "Shared.qml": "Item { }", "Dead.qml": "Shared { }", "Hidden.qml": "Item { }",                  // Shared: named by dead Dead AND live A
    };
    assert.deepEqual(deadQmlFiles(tree(files, { "main.cpp": "Main" })), ["qml/Dead.qml", "qml/Hidden.qml", "qml/P.qml", "qml/Q.qml", "qml/X.qml", "qml/Y.qml", "qml/Z.qml"]);
});

// ---- monkey: 300 seeded random trees (chains, cycles, decoys); the expected dead set comes from a plain graph walk over the edges the generator drew
test("S5F-08 monkey: 300 seeded random trees with decoys agree with a graph walk from the entry file", () => {
    let seed = 20261124;
    const rnd = (n) => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed % n; };
    for (let round = 0; round < 300; round++) {
        const n = 2 + rnd(8), names = Array.from({ length: n }, (_, i) => "Comp" + String.fromCharCode(65 + i) + (rnd(2) ? "X" : ""));
        const edges = names.map(() => []), body = names.map(() => "Item { ");
        names.forEach((name, i) => {
            const count = 1 + rnd(4);
            for (let k = 0; k < count; k++) {
                const j = rnd(n), other = names[j], kind = rnd(5);
                if (kind === 0 && j !== i) { body[i] += other + " { } "; edges[i].push(j); }
                else if (kind === 1 && j !== i) { body[i] += "Loader { source: \"" + other + ".qml\" } "; edges[i].push(j); }
                else if (kind === 2) body[i] += "// " + other + " { }\n";                    // comment decoy
                else if (kind === 3) body[i] += "My" + other + " { } ";                      // longer-name decoy (no word boundary before the name)
                else body[i] += name + " { } ";                                              // self decoy
            }
        });
        const entry = rnd(n), seen = new Set([entry]), walk = [entry];
        while (walk.length) for (const j of edges[walk.pop()]) if (!seen.has(j)) { seen.add(j); walk.push(j); }
        const files = { "Main.qml": "App { " + names[entry] + " { } }" };
        names.forEach((name, i) => { files[name + ".qml"] = body[i] + "}"; });
        const expected = names.filter((_, i) => !seen.has(i)).map((x) => "qml/" + x + ".qml").sort();
        assert.deepEqual(deadQmlFiles(tree(files, { "main.cpp": "load(\"qml/Main.qml\")" })), expected, "round " + round + ": " + JSON.stringify(files));
    }
});

// ---- commit B: PhotoSourceSheet font sizes through sp(), rows grow with their text ------------------------------------------------
const { scanPixelSizes } = require("./testSupport/qmlThemeScaleScan");
const SHEET = "qml/components/PhotoSourceSheet.qml";
const sheet = () => fs.readFileSync(path.join(ROOT, SHEET), "utf8");
const TOKENS = (() => { const o = {}; for (const m of fs.readFileSync(path.join(ROOT, "qml/helper/Constants.qml"), "utf8").matchAll(/readonly property int (fs\w+):\s*(\d+)/g)) o[m[1]] = +m[2]; return o; })();

test("S5F-09 PhotoSourceSheet: no bare pixel size; its 7 sizes are sp() of a font token, and each token still equals the old number (same look at scale 1.0)", () => {
    const sizes = scanPixelSizes(ROOT).filter((p) => p.file === SHEET);
    assert.equal(sizes.length, 7);
    assert.deepEqual(sizes.filter((p) => p.raw || !p.scaled), []);
    const lines = sheet().split("\n").filter((l) => /font\.pixelSize/.test(l));
    assert.equal(lines.length, 7);
    const want = [["fsTitle", 16], ["fsBodyLg", 14], ["fsCaption", 11], ["fsBodyLg", 14], ["fsCaption", 11], ["fsBodyLg", 14], ["fsCaption", 11]];
    lines.forEach((l, i) => {
        const m = /font\.pixelSize:\s*sp\(Constants\.(fs\w+)\)/.exec(l);
        assert.ok(m, "line " + i + " is not sp(Constants.fs*): " + l.trim());
        assert.equal(m[1], want[i][0]);
        assert.equal(TOKENS[m[1]], want[i][1], m[1] + " no longer equals the old pixel size " + want[i][1] + ": the look changed");
    });
});

test("S5F-10 PhotoSourceSheet: the three rows grow with their label column and never go below 56 (the old fixed height)", () => {
    const src = sheet();
    assert.equal(/implicitHeight:\s*56\b/.test(src), false, "a fixed 56 row would clip big text again");
    const rows = [...src.matchAll(/implicitHeight:\s*(Math\.max\(56,\s*(\w+)\.implicitHeight\s*\+\s*20\))/g)];
    assert.deepEqual(rows.map((r) => r[2]), ["camLabels", "galLabels", "remLabels"]);
    for (const r of rows) assert.equal(new RegExp("id:\\s*" + r[2] + "\\b").test(src), true, r[2] + " has no Column with that id");
    assert.equal((src.match(/Column \{\s*\n\s*id: (camLabels|galLabels|remLabels)/g) || []).length, 3, "each id sits on the label Column");
});

test("S5F-11 monkey: the row formula on 500 seeded text heights is never below 56, always holds the text plus 20, and is 56 for any text up to 36", () => {
    const expr = /implicitHeight:\s*(Math\.max\(56,\s*camLabels\.implicitHeight\s*\+\s*20\))/.exec(sheet())[1];
    const f = new Function("camLabels", "Math", "return " + expr + ";");
    let seed = 1124;
    const rnd = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; };
    let prev = -1;
    for (const h of [0, 1, 32.2, 36, 36.01, 100, 1e6]) { const v = f({ implicitHeight: h }, Math); assert.ok(v >= 56 && v >= h + 20 && v >= prev); prev = v; }
    for (let i = 0; i < 500; i++) {
        const h = rnd() * 200, v = f({ implicitHeight: h }, Math);
        assert.ok(v >= 56 && v >= h + 20, "h=" + h);
        if (h <= 36) assert.equal(v, 56, "h=" + h);
        else assert.equal(v, h + 20);
    }
    assert.equal(f({ implicitHeight: 32.2 }, Math), 56, "two lines at 14 and 11 px (about 32) keep the old 56 row");
});

test("S5F-12 regression: the sheet's six labels, its three signals and its 15 colour literals are unchanged", () => {
    const src = sheet();
    for (const s of ["Set product photo", "Take photo", "Use the camera", "Choose from gallery", "Pick an existing image", "Remove photo", "Clear the existing image"]) assert.ok(src.includes('"' + s + '"'), s);
    assert.match(src, /root\.removeRequested\(\)/);
    assert.match(src, /NativeUtils\.displayCameraPicker\(\)/);
    assert.equal((src.match(/#[0-9a-fA-F]{6}\b/g) || []).length, 15, "colour literals stay KI 143's, not touched here");
});

// ---- PR #220 review, commit C: the sheet scrolls when taller than its cap; labels wrap instead of running out of the row -----------
const codeOf = () => stripComments(sheet());

test("S5F-14 PhotoSourceSheet: contentItem is a vertical Flickable around contentCol; Popup height still reads contentCol and is capped at 80%", () => {
    const src = codeOf();
    assert.match(src, /contentItem:\s*Flickable\s*\{[^]*?clip:\s*true[^]*?flickableDirection:\s*Flickable\.VerticalFlick[^]*?boundsBehavior:\s*Flickable\.StopAtBounds[^]*?contentWidth:\s*width[^]*?contentHeight:\s*contentCol\.implicitHeight/);
    assert.match(src, /ColumnLayout\s*\{\s*\n\s*id:\s*contentCol\s*\n\s*width:\s*root\.availableWidth/);
    assert.match(src, /height:\s*Math\.min\(contentCol\.implicitHeight \+ dp\(24\),\s*\n?\s*parent \? parent\.height \* 0\.8 : 480\)/);
    assert.equal(/contentItem:\s*ColumnLayout/.test(src), false, "the old non-scrolling contentItem came back");
    assert.equal(/\bScrollView\s*\{/.test(src), false, "BottomSheet.qml says why a sheet must not size from a ScrollView");
    assert.equal(/ScrollView inside handles overflow/.test(sheet()), false, "the stale comment about a ScrollView that never existed came back");
});

test("S5F-15 PhotoSourceSheet: each label Column is as wide as its row minus its Icon, all six texts wrap at that width, the handle uses Layout sizes", () => {
    const src = codeOf();
    for (const [icon, col] of [["camIcon", "camLabels"], ["galIcon", "galLabels"], ["remIcon", "remLabels"]]) {
        assert.equal(new RegExp("Icon \\{ id: " + icon + ";").test(src), true, icon);
        assert.equal(new RegExp("id: " + col + "\\s*\\n\\s*width: Math\\.max\\(0, parent\\.width - " + icon + "\\.width - parent\\.spacing\\)").test(src), true, col);
    }
    const texts = src.match(/Text \{[^\n]*\}/g) || [];
    assert.equal(texts.length, 6);
    for (const l of texts) assert.match(l, /Text \{ width: parent\.width; wrapMode: Text\.WordWrap; text: /);
    assert.match(src, /Layout\.preferredWidth: 40; Layout\.preferredHeight: 4; radius: 2/);
    assert.equal(/\bwidth: 40; height: 4/.test(src), false, "a bare width/height on a Layout child came back");
});

test("S5F-16 monkey: the label width formula on 500 seeded row widths is never negative and is the row minus icon minus spacing when that fits", () => {
    const expr = /width: (Math\.max\(0, parent\.width - camIcon\.width - parent\.spacing\))/.exec(codeOf())[1];
    const f = new Function("parent", "camIcon", "Math", "return " + expr + ";");
    let seed = 220;
    const rnd = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; };
    const icon = { width: 20 };
    for (const w of [-50, -1, 0, 1, 31.9, 32, 32.1, 308, 1e6]) { const v = f({ width: w, spacing: 12 }, icon, Math); assert.ok(v >= 0, "w=" + w); assert.equal(v, Math.max(0, w - 32)); }
    for (let i = 0; i < 500; i++) {
        const w = rnd() * 800 - 100, sp = Math.floor(rnd() * 24), iw = Math.floor(rnd() * 40), v = f({ width: w, spacing: sp }, { width: iw }, Math);
        assert.ok(v >= 0, "w=" + w);
        if (w - iw - sp >= 0) assert.equal(v, w - iw - sp); else assert.equal(v, 0);
    }
});
