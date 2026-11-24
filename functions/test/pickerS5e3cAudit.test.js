"use strict";
// Picker v2, slice S5e-3c: the font-scale and system-theme SOURCE audit. S5E3C-01..NN.
// Plan: docs/superpowers/plans/2026-11-24-product-picker-v2-s5e3c-font-and-theme-audit.md
// These READ the QML text (qmltestrunner cannot load Felgo pages). They pin WIRING and the audit ratchets, not what a phone paints: whether a typed
// letter is readable under the system dark theme, and which row clips at 2.0x font, are on-device checks (194 on).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { scanInstances, stripComments, qmlFiles } = require("./testSupport/qmlButtonScan");
const T = require("./testSupport/qmlThemeScaleScan");

const ROOT = path.join(__dirname, "..", "..");
const read = (r) => fs.readFileSync(path.join(ROOT, r), "utf8");
const ARC = ["components/ProductPickerSheet", "components/ProductPickerRow", "components/CartStepper", "components/ChipScroller",
    "components/SearchField", "components/BottomSheet", "components/ToastHost", "pages/NewOrderDialog", "pages/OrderDetailDialog"].map((a) => "qml/" + a + ".qml");
const TOK = T.colorTokens(read("qml/helper/Constants.qml"));
const fields = () => T.scanColors(ROOT, ["TextField", "TextArea"]);
const one = (file, id) => { const r = fields().filter((f) => f.file === file && f.id === id); assert.equal(r.length, 1, "expected one field " + id + " in " + file); return r[0]; };
// Dead = no other QML file names the type (StatusBadge is only used by the dead OrderRow, so it is dead too).
const users = (name) => qmlFiles(path.join(ROOT, "qml")).filter((f) => path.basename(f) !== name + ".qml" && new RegExp("\\b" + name + "\\b").test(fs.readFileSync(f, "utf8"))).map((f) => path.basename(f, ".qml"));

// ---- A. the five typed-text fields of the picker arc ---------------------------------------------------------------------
test("S5E3C-01 SearchField: typed text and hint colours are pinned, readable on the pill's own fill", () => {
    const src = read("qml/components/SearchField.qml"), f = one("qml/components/SearchField.qml", "input");
    assert.match(f.own, /(^|[\s;{])color\s*:\s*Constants\.textPrimary\s*$/m);
    assert.match(f.own, /(^|[\s;{])placeholderTextColor\s*:\s*Constants\.textSecondary\s*$/m);
    const fill = /^\s*color\s*:\s*Constants\.(\w+)\s*$/m.exec(src.split("QQC.TextField")[0].split("Rectangle {")[1]);
    assert.ok(fill, "the pill fill is no longer a Constants token: re-read this slice");
    assert.ok(T.contrast(TOK.textPrimary, TOK[fill[1]]) >= 4.5);
    assert.ok(T.contrast(TOK.textSecondary, TOK[fill[1]]) >= 4.5);
});

const ORDER_FIELDS = [
    ["qml/pages/NewOrderDialog.qml", "linePriceField"], ["qml/pages/NewOrderDialog.qml", "lineDiscField"],
    ["qml/pages/OrderDetailDialog.qml", "priceField"], ["qml/pages/OrderDetailDialog.qml", "lineDiscountField"],
];
ORDER_FIELDS.forEach(([file, id], n) => {
    test("S5E3C-0" + (2 + n) + " " + id + " (" + path.basename(file) + "): typed text is pinned, enabled and disabled, readable on the fill", () => {
        const f = one(file, id), m = /(^|[\s;{])color\s*:\s*(\w+)\.enabled\s*\?\s*Constants\.textPrimary\s*:\s*Constants\.textMuted\s*$/m.exec(f.own);
        assert.ok(m, id + ": no enabled-aware pinned colour");
        assert.equal(m[2], id, "the ternary must read THIS field's enabled");
        // The fill is the field's own background Rectangle: cardBg while enabled, subtleBg while disabled.
        const bg = new RegExp("id:\\s*" + id + "\\b[\\s\\S]*?background:\\s*Rectangle\\s*\\{[\\s\\S]*?color:\\s*" + id + "\\.enabled\\s*\\?\\s*Constants\\.(\\w+)\\s*:\\s*Constants\\.(\\w+)").exec(read(file));
        assert.deepEqual([bg[1], bg[2]], ["cardBg", "subtleBg"]);
        assert.ok(T.contrast(TOK.textPrimary, TOK.cardBg) >= 4.5);
    });
});

test("S5E3C-06 no typed-text control of the picker arc leaves its colour to the system palette", () => {
    const bad = fields().filter((f) => ARC.includes(f.file) && !f.colored);
    assert.deepEqual(bad.map((f) => f.file + ":" + f.line), []);
    const inArc = fields().filter((f) => ARC.includes(f.file));
    assert.equal(inArc.length, 6, "the arc holds exactly 6 typed-text fields (the sheet's quantity box, which already set its colour, + 1 search + 4 order); a new one needs a pin");
    assert.match(inArc.find((f) => f.id === "qtyField").own, /(^|[\s;{])color\s*:\s*Constants\./m, "the quantity box colour is a Constants token");
});

test("S5E3C-07 ratchet: no TextField or TextArea in the app leaves its typed-text colour to the system palette (login fields pinned in the PR review)", () => {
    const left = fields().filter((f) => !f.colored).map((f) => f.file + ":" + f.line);
    assert.deepEqual(left, [], "a new typed-text control needs a pinned `color` (KI 142)");
    for (const file of ["qml/components/AuthPasswordField.qml", "qml/components/AuthTextField.qml"]) {
        const f = one(file, "input");
        assert.match(f.own, /(^|[\s;{])color\s*:\s*input\.enabled\s*\?\s*Constants\.textPrimary\s*:\s*Constants\.textMuted\s*$/m, file + ": typed text");
        assert.match(f.own, /(^|[\s;{])placeholderTextColor\s*:\s*Constants\.textSecondary\s*$/m, file + ": hint");
        assert.match(read(file), /color:\s*input\.enabled\s*\?\s*"#ffffff"\s*:\s*"#f9fafb"/, file + ": the fill is a fixed white / near-white, which is why the text is pinned");
    }
    // The pins are readable on the two fills the login boxes paint (enabled "#ffffff", disabled "#f9fafb"); the disabled text is muted by design.
    for (const fill of ["#ffffff", "#f9fafb"]) assert.ok(T.contrast(TOK.textPrimary, fill) >= 4.5 && T.contrast(TOK.textSecondary, fill) >= 4.5, fill);
});

test("S5E3C-23 the Restock SpinBox pins its typed text through palette.text (a SpinBox has no `color`), and no SpinBox in the app sets `color`", () => {
    const boxes = T.scanColors(ROOT, ["SpinBox"]);
    assert.deepEqual(boxes.map((b) => b.file + ":" + b.id), ["qml/pages/RestockDialog.qml:qtyField"], "a new SpinBox needs the same pin (KI 142)");
    assert.equal(boxes[0].colored, false, "`color:` on a SpinBox is a non-existent property (QML error): use palette.text");
    assert.match(boxes[0].own, /(^|[\s;{])palette\.text\s*:\s*qtyField\.enabled\s*\?\s*Constants\.textPrimary\s*:\s*Constants\.textMuted\s*$/m);
    assert.match(read("qml/pages/RestockDialog.qml"), /id:\s*qtyField\b[\s\S]*?background:\s*Rectangle\s*\{[\s\S]*?color:\s*Constants\.cardBg/, "the fill is the Constants.cardBg token, readable under textPrimary");
    assert.ok(T.contrast(TOK.textPrimary, TOK.cardBg) >= 4.5);
});

test("S5E3C-08 ratchet: the 3 Text/Label blocks with no colour are invisible or dead (nothing a user reads)", () => {
    const bare = T.scanColors(ROOT, ["Text", "Label"]).filter((t) => !t.colored);
    assert.deepEqual(bare.map((t) => t.file), ["qml/components/ToastHost.qml", "qml/helper/CardKPI.qml", "qml/pages/LoginPage.qml"]);
    assert.ok(bare[0].hidden && bare[2].hidden, "ToastHost measure and the Login wordmark mask are `visible: false`");
    assert.deepEqual(users("CardKPI"), [], "CardKPI has a user now: its bare Text is real");
});

// ---- B. font scale -----------------------------------------------------------------------------------------------------------
test("S5E3C-09 the picker arc has no bare pixel size and no colour literal (all through sp() and Constants)", () => {
    assert.deepEqual(T.scanPixelSizes(ROOT).filter((p) => ARC.includes(p.file) && p.raw), []);
    const hex = T.scanHex(ROOT);
    assert.deepEqual(ARC.filter((f) => hex[f]), []);
    assert.ok(T.scanPixelSizes(ROOT).filter((p) => ARC.includes(p.file)).length >= 60, "the arc's own sizes were all read");
});

test("S5E3C-10 ratchet: 25 bare pixel sizes, 7 on a live photo sheet and 18 in dead helpers (KI 143)", () => {
    const by = {};
    T.scanPixelSizes(ROOT).filter((p) => p.raw).forEach((p) => { by[p.file] = (by[p.file] || 0) + 1; });
    assert.deepEqual(by, {
        "qml/components/PhotoSourceSheet.qml": 7, "qml/helper/CardKPI.qml": 4, "qml/helper/OrderRow.qml": 10,
        "qml/helper/PlaceholderPage.qml": 1, "qml/helper/SegmentedNav.qml": 2, "qml/helper/StatusBadge.qml": 1,
    });
    assert.deepEqual(users("PhotoSourceSheet").sort(), ["EditProductDialog", "Main"]);
    for (const dead of ["CardKPI", "OrderRow", "PlaceholderPage", "SegmentedNav"]) assert.deepEqual(users(dead), [], dead + " has a user now");
    assert.deepEqual(users("StatusBadge"), ["OrderRow"], "StatusBadge is only kept alive by the dead OrderRow");
});

test("S5E3C-11 every pixel size that is neither bare nor sp()/dp() is AvatarBadge's _font, and that is sp() on every branch", () => {
    const odd = T.scanPixelSizes(ROOT).filter((p) => !p.raw && !p.scaled);
    assert.deepEqual(odd.map((p) => p.file + " " + p.expr), ["qml/components/AvatarBadge.qml root._font"]);
    const line = /readonly property int _font:([^\n]+)/.exec(read("qml/components/AvatarBadge.qml"))[1];
    assert.equal((line.match(/\bsp\(\d+\)/g) || []).length, 4);
    assert.equal((line.match(/\d+/g) || []).length, 4, "no number outside sp()");
});

test("S5E3C-12 ratchet: colour literals by file (Constants.qml is where they belong; the rest are KI 143)", () => {
    assert.deepEqual(T.scanHex(ROOT), {
        "qml/components/AlertDialog.qml": 2, "qml/components/AuthPasswordField.qml": 16, "qml/components/AuthPrimaryButton.qml": 1,
        "qml/components/AuthSecondaryButton.qml": 6, "qml/components/AuthTextField.qml": 8, "qml/components/PhotoSourceSheet.qml": 15,
        "qml/components/ProductPhotoGallery.qml": 4, "qml/components/StockProgressBar.qml": 2, "qml/helper/CardKPI.qml": 7,
        "qml/helper/Constants.qml": 44, "qml/helper/OrderRow.qml": 18, "qml/helper/PlaceholderPage.qml": 3,
        "qml/helper/SegmentedNav.qml": 8, "qml/helper/StatusBadge.qml": 8, "qml/model/StaffStore.qml": 2,
    });
    assert.equal(qmlFiles(path.join(ROOT, "qml")).length - Object.keys(T.scanHex(ROOT)).length >= 70, true, "most of the tree has none");
});

// ---- C. contrast of the text tokens ---------------------------------------------------------------------------------------
test("S5E3C-13 text tokens on the four light surfaces: primary and secondary pass 4.5, muted does not (KI 144)", () => {
    const bg = ["cardBg", "screenBg", "appBg", "subtleBg"].map((n) => TOK[n]);
    assert.deepEqual(["cardBg", "screenBg", "appBg", "subtleBg"].filter((n) => !TOK[n]), [], "a surface token is no longer a plain hex");
    for (const b of bg) {
        assert.ok(T.contrast(TOK.textPrimary, b) >= 4.5);
        assert.ok(T.contrast(TOK.textSecondary, b) >= 4.5);
        assert.ok(T.contrast(TOK.textMuted, b) < 4.5);
    }
    assert.deepEqual([TOK.textPrimary, TOK.textSecondary, TOK.textMuted].map((t) => +T.contrast(t, TOK.cardBg).toFixed(2)), [17.85, 7.58, 2.56]);
});

test("S5E3C-14 ratchet: Text coloured `textMuted` in the picker arc (the 2.56:1 token) stays at 2", () => {
    const n = Object.fromEntries(ARC.map((f) => [f, (stripComments(read(f)).match(/color\s*:\s*Constants\.textMuted/g) || []).length]).filter(([, c]) => c));
    assert.deepEqual(n, { "qml/components/ProductPickerSheet.qml": 1, "qml/pages/OrderDetailDialog.qml": 1 });
});

// ---- D. fixed-height rows -------------------------------------------------------------------------------------------------------
test("S5E3C-15 ratchet: two fixed 48 dp rows hold unwrapped text in the arc, one line each (not a defect, a device look, KI 145)", () => {
    const r = T.scanFixedHeightText(ROOT, ARC);
    assert.deepEqual(r.map((x) => x.file + ":" + x.prop + "=" + x.expr + " texts=" + x.texts), [
        "qml/components/ProductPickerSheet.qml:Layout.preferredHeight=dp(48) texts=1",
        "qml/pages/NewOrderDialog.qml:implicitHeight=dp(48) texts=1",
    ]);
    assert.match(read("qml/components/ProductPickerSheet.qml"), /Layout\.fillWidth: true\s+text: qsTr\("In stock only"\)/);
    assert.match(read("qml/pages/NewOrderDialog.qml"), /text: manageChannelsLink\.text \+ "  ›"/);
});

// ---- E. regression: the pins changed nothing else ---------------------------------------------------------------------------
test("S5E3C-16 the four order fields keep their name, 48 dp minimum, sp() font and inputs (S5e-3a/3b pins survive)", () => {
    for (const [file, id] of ORDER_FIELDS) {
        const own = one(file, id).own;
        assert.match(own, /Accessible\.name\s*:/, id);
        assert.match(own, /Layout\.minimumHeight\s*:\s*dp\(48\)/, id);
        assert.match(own, /font\.pixelSize\s*:\s*sp\(Constants\.fsBody\)/, id);
        assert.match(own, /inputMethodHints\s*:\s*Qt\.ImhFormattedNumbersOnly/, id);
        assert.match(own, /horizontalAlignment\s*:\s*Text\.AlignRight/, id);
    }
    const s = one("qml/components/SearchField.qml", "input").own;
    assert.match(s, /Accessible\.name\s*:\s*input\.placeholderText/);
    assert.match(s, /background\s*:\s*Item\s*\{\}/);
});

// ---- F. the scanners themselves ---------------------------------------------------------------------------------------------
const tmpRoot = (files) => { const d = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "s5e3c-")); fs.mkdirSync(path.join(d, "qml")); for (const [n, s] of Object.entries(files)) fs.writeFileSync(path.join(d, "qml", n), s); return d; };

test("S5E3C-17 scanColors: own depth-1 colour only; comments, strings, nested children and look-alike types do not count", () => {
    const d = tmpRoot({ "A.qml": [
        "Item {",
        "  QQC.TextField { id: a; color: x }",                                  // coloured
        "  TextField { id: b; background: Rectangle { color: \"red\" } }",       // child colour only
        "  TextField { id: c\n // color: x\n }",                                 // comment only
        "  TextField { id: d; placeholderText: \"color: x\" }",                  // string only
        "  AuthTextField { id: e }",                                             // other type
        "  TextField { id: h; border.color: \"red\"; selectionColor: \"x\" }",       // look-alike property names
        "  Label { id: f; visible: false }",                                     // hidden, bare
        "  Text { id: g; text: \"}\"; color: y }",                               // brace in a string
        "}"].join("\n") });
    const r = T.scanColors(d, ["TextField", "Label", "Text"]);
    assert.deepEqual(r.map((x) => x.id + ":" + x.colored + ":" + x.hidden), ["a:true:false", "b:false:false", "c:false:false", "d:false:false", "h:false:false", "f:false:true", "g:true:false"]);
});

test("S5E3C-18 scanPixelSizes: bare, sp, dp, reference, trailing comment, string and comment look-alikes", () => {
    const d = tmpRoot({ "B.qml": ["Text { font.pixelSize: sp(13) }", "Text { font.pixelSize: 14 }", "Text { font.pixelSize: dp(5) }", "Text { font.pixelSize: root._font }", "Text { font.pixelSize: 13 + extra }",
        "Text { font.pixelSize: 12   // note", "}", "Text { text: \"pixelSize: 9\" }", "// font.pixelSize: 8", "Icon { size: 20 }"].join("\n") });
    assert.deepEqual(T.scanPixelSizes(d).map((p) => p.expr + ":" + (p.raw ? "raw" : p.scaled ? "scaled" : "ref")),
        ["sp(13):scaled", "14:raw", "dp(5):scaled", "root._font:ref", "13 + extra:ref", "12:raw"]);
});

test("S5E3C-19 contrast: black on white is 21, a colour on itself 1, symmetric, and the token reader skips aliases and rgba", () => {
    assert.equal(+T.contrast("#000000", "#ffffff").toFixed(2), 21);
    assert.equal(T.contrast("#336699", "#336699"), 1);
    assert.equal(T.contrast("#0f172a", "#f9fafb"), T.contrast("#f9fafb", "#0f172a"));
    const t = T.colorTokens('readonly property color a: "#112233"\nreadonly property color b: a\nreadonly property color c: Qt.rgba(1, 1, 1, 0.5)\n// readonly property color d: "#445566"\nreadonly property color e: "#abc"');
    assert.deepEqual(t, { a: "#112233" });
});

// Seeded generator (mulberry32): each block has a known truth; the scanner must agree on 300 hostile ones.
function rng(seed) { return () => { seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }

test("S5E3C-20 monkey: 300 seeded Text/TextField blocks with decoys, the scanner agrees with the generator", () => {
    const r = rng(20261124), pick = (a) => a[Math.floor(r() * a.length)];
    const lines = [], truth = [];
    for (let i = 0; i < 300; i++) {
        const type = pick(["Text", "Label", "TextField", "QQC.TextField", "TextArea"]), own = r() < 0.5, hide = r() < 0.3;
        const body = [
            "id: n" + i,
            own ? "color: Constants.textPrimary" : pick(["", "// color: red", "text: \"color: red }\"", "background: Rectangle { color: \"white\" }", "Rectangle { color: \"x\" }"]),
            hide ? "visible: false" : pick(["", "text: \"{\"", "// visible: false"]),
        ].filter(Boolean);
        lines.push(type + " {\n  " + body.join("\n  ") + "\n}");
        truth.push([type.replace("QQC.", ""), "n" + i, own, hide]);
    }
    const d = tmpRoot({ "M.qml": "Item {\n" + lines.join("\n") + "\n}" });
    const got = T.scanColors(d, ["Text", "Label", "TextField", "TextArea"]).map((x) => [x.type, x.id, x.colored, x.hidden]);
    const key = (a) => a.join("|");
    assert.deepEqual(got.map(key).sort(), truth.map(key).sort());
});

test("S5E3C-21 monkey: 300 seeded pixelSize lines, the scanner agrees on raw / scaled / reference", () => {
    const r = rng(7), pick = (a) => a[Math.floor(r() * a.length)];
    const rows = [], truth = [];
    for (let i = 0; i < 300; i++) {
        const n = 1 + Math.floor(r() * 40), kind = pick(["raw", "sp", "dp", "ref", "rawc"]);
        const expr = { raw: String(n), rawc: n + "  // c", sp: "sp(" + n + ")", dp: "dp(" + n + ")", ref: "root._f" + i }[kind];
        rows.push("Text { font.pixelSize: " + expr + " }");
        truth.push(kind === "raw" || kind === "rawc" ? "raw" : kind === "ref" ? "ref" : "scaled");
    }
    const d = tmpRoot({ "P.qml": rows.join("\n") });
    assert.deepEqual(T.scanPixelSizes(d).map((p) => (p.raw ? "raw" : p.scaled ? "scaled" : "ref")), truth);
});

test("S5E3C-22 scanFixedHeightText: fixed height with text is listed; minimumHeight, no text, elide and look-alikes are not", () => {
    const d = tmpRoot({ "F.qml": [
        "Item {",
        "  Rectangle { id: a; height: dp(40); Text { text: \"x\" } }",                      // listed
        "  Rectangle { id: b; Layout.minimumHeight: dp(48); Text { text: \"x\" } }",         // grows
        "  Rectangle { id: c; height: dp(40) }",                                             // no text
        "  Rectangle { id: d; implicitHeight: dp(40); Text { elide: Text.ElideRight } }",    // listed, allElide
        "  Rectangle { id: e; height: parent.height; Text { text: \"x\" } }",                // not a literal
        "}"].join("\n") });
    const r = T.scanFixedHeightText(d, ["qml/F.qml"]);
    assert.deepEqual(r.map((x) => x.prop + ":" + x.allElide), ["height:false", "implicitHeight:true"]);
});
