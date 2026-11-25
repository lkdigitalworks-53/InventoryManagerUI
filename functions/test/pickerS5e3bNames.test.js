"use strict";
// Picker v2, slice S5e-3b: the buttons that draw their label in a child Text speak, the four price/discount fields speak, and the three
// member buttons say which member. S5E3B-01..NN. Plan: docs/superpowers/plans/2026-11-23-product-picker-v2-s5e3b-names-for-text-buttons-and-fields.md
// Like S5e-3a these READ the QML text (qmltestrunner cannot load Felgo pages) and RUN the real name expressions in a sandbox. They pin WIRING,
// not what Android does with it: whether TalkBack reads each name once is the on-device plan (checks 180 on).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { stripComments, blankStrings, scanButtons, scanInstances, scanFields, qmlFiles } = require("./testSupport/qmlButtonScan");

const ROOT = path.join(__dirname, "..", "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const rel = (f) => path.relative(ROOT, f).split(path.sep).join("/");
const one = (src, f) => { const r = scanButtons(src).filter(f); assert.equal(r.length, 1, "expected exactly one match, got " + r.length); return r[0]; };
const nameOf = (b) => { const m = /(?:^|[\s;{])Accessible\.name\s*:\s*([^\n]+)/.exec(b.ownSrc); assert.ok(m, "no own Accessible.name"); return m[1].trim(); };
// qsTr returns a String with the real `.arg(...)` (a replacer function: "$&" in an item name must stay literal), so expressions run as written.
const run = (expr, ctx) => String(vm.runInNewContext("(" + expr + ")", Object.assign({
    qsTr: (s) => Object.assign(new String(s), { arg: (v) => s.replace("%1", () => String(v)) }),
}, JSON.parse(JSON.stringify(ctx)))));
const texts = (b) => scanInstances(b.body, "Text");
const textWithId = (b, id) => {
    const r = texts(b).filter((t) => new RegExp("(^|[\\s;{])id:\\s*" + id + "\\b").test(t.ownSrc));
    assert.equal(r.length, 1, "expected one Text with id " + id + ", got " + r.length);
    return r[0];
};
const textExpr = (t) => { const m = /(?:^|[\s;{])text\s*:\s*([^\n]+)/.exec(t.ownSrc); assert.ok(m, "the drawn Text has no text"); return m[1].trim(); };

// ---- the eleven buttons -----------------------------------------------------------------------------------------
// kind "ref": Accessible.name is `<id>.text` of the drawn Text (that Text is Accessible.ignored, so it is not read twice)
// kind "own": the button's own `text` is the words, Accessible.name: text, and the picture adds a chevron that is never spoken
// kind "expr": the name is its own expression (it says WHICH row, or carries a value), the drawn words are ignored
// [file, find, kind, drawn expr (ref) | null, states, expected, handler, ignoredTexts, word the name must contain, keep]
const ROWS = [
    ["qml/components/FloatingTabbar.qml", (b) => /\bid: tab\b/.test(b.body), "ref", "modelData.label", [{ modelData: { label: "Home" } }], ["Home"], "root.tabChanged(index)", 1, "", "Layout.fillHeight: true"],
    ["qml/pages/AddProductDialog.qml", (b) => /id: advToggle/.test(b.body), "ref", 'qsTr("Advanced")', [{}], ["Advanced"], "onClicked: open = !open", 1, "", "Layout.preferredHeight: dp(32)"],
    ["qml/pages/DashboardPage.qml", (b) => /id: seeAllActivityBtn/.test(b.body), "own", null, [{}], ["See all"], "onClicked: root.seeAllActivityRequested()", 1, "", "implicitHeight: dp(28)"],
    ["qml/pages/NotificationsSheet.qml", (b) => /ActivityLog\.dismissAll\(\)/.test(b.body), "ref", 'qsTr("Clear all")', [{}], ["Clear all"], "onClicked: ActivityLog.dismissAll()", 1, "", "implicitHeight: dp(28)"],
    ["qml/pages/SalesPage.qml", (b) => /root\._showAllActivities = !root\._showAllActivities/.test(b.body), "ref", 'root._showAllActivities ? qsTr("Show less") : qsTr("See all")',
        [{ root: { _showAllActivities: false } }, { root: { _showAllActivities: true } }], ["See all", "Show less"], "root._showAllActivities = !root._showAllActivities", 1, "", "implicitHeight: dp(28)"],
    ["qml/pages/ManageCategoriesDialog.qml", (b) => /CategoryStore\.setDefault\(modelData\)/.test(b.body), "expr", null, [{ modelData: "Tea" }], ["Set Tea as default"], "CategoryStore.setDefault(modelData)", 1, "default", "implicitHeight: dp(28)"],
    ["qml/pages/ManageCategoriesDialog.qml", (b) => /root\._confirmRemove\(modelData\)/.test(b.body), "expr", null, [{ modelData: "Tea" }], ["Remove Tea"], "root._confirmRemove(modelData)", 1, "remove", "implicitHeight: dp(28)"],
    ["qml/pages/ManageOrderChannelsDialog.qml", (b) => /OrderChannelStore\.setDefault\(modelData\)/.test(b.body), "expr", null, [{ modelData: "Walk-in" }], ["Set Walk-in as default"], "OrderChannelStore.setDefault(modelData)", 1, "default", "implicitHeight: dp(28)"],
    ["qml/pages/ManageOrderChannelsDialog.qml", (b) => /id: removeBtn/.test(b.body), "expr", null, [{ modelData: "Walk-in" }], ["Remove Walk-in"], "root._confirmRemove(modelData)", 1, "remove", "implicitHeight: dp(28)"],
    // the "ID: abcdef...wxyz" Text stays readable on purpose: it carries the value, the name only says what a tap does
    ["qml/pages/ProfilePage.qml", (b) => /id: uidBtn/.test(b.body), "expr", null, [{}], ["Copy user ID"], "Clipboard.copy(AuthStore.uid)", 0, "id", "padding: dp(6)"],
    ["qml/pages/ProfilePage.qml", (b) => /id: settingsRowRoot/.test(b.body), "expr", null,
        [{ label: "Language", trailingText: "English" }, { label: "Edit profile", trailingText: "" }], ["Language, English", "Edit profile"], "implicitHeight: dp(52)", 2, "", "Layout.fillWidth: true"],
];

ROWS.forEach(([file, find, kind, drawn, states, expected, handler, ignoredTexts, word, keep], i) => {
    test("S5E3B-" + String(i + 1).padStart(2, "0") + " " + file.split("/").pop() + ": " + JSON.stringify(expected) + " (" + kind + "), drawn text ignored x" + ignoredTexts + ", handler and size kept", () => {
        const b = one(read(file), (x) => !x.root && find(x));
        assert.equal(b.named, true, "the scanner does not see an own Accessible.name");
        assert.equal(b.ownText && kind !== "own", false, "an own `text` on a button that is not the 'own' kind: pick one recipe");
        const expr = nameOf(b);
        let names;
        if (kind === "ref") {
            const m = /^(\w+)\.text$/.exec(expr);
            assert.ok(m, "a 'ref' name must be `<id>.text`, got " + expr);
            const t = textWithId(b, m[1]);
            assert.equal(t.ignored, true, "the drawn Text is read as a second stop (set Accessible.ignored: true)");
            assert.equal(textExpr(t), drawn, "the drawn words changed: update the table on purpose");
            names = states.map((s) => run(drawn, s));
        } else if (kind === "own") {
            assert.equal(expr, "text", "an 'own' name is the button's own text");
            assert.match(b.ownSrc, /(^|[\s;{])text: qsTr\("See all"\)/);
            assert.equal(b.ownSrc.includes("›"), false, "the chevron would be spoken");
            const t = texts(b);
            assert.equal(t.length, 1);
            assert.equal(t[0].ignored, true);
            assert.equal(textExpr(t[0]), 'seeAllActivityBtn.text + "  ›"', "the picture is the name plus the chevron");
            names = states.map(() => run('qsTr("See all")', {}));
        } else {
            names = states.map((s) => run(expr, s));
            assert.equal(texts(b).filter((t) => t.ignored).length, ignoredTexts, "ignored Text count");
        }
        assert.deepEqual(names, expected);
        if (names.length > 1) assert.notEqual(names[0], names[1], "both states speak the same: a toggle that does not say what it does now");
        if (word) for (const n of names) assert.ok(n.toLowerCase().includes(word), "label in name: the picture says '" + word + "', the name '" + n + "' does not");
        assert.ok(b.body.includes(handler) || b.ownSrc.includes(handler), "the handler or size changed: " + handler);
        assert.ok(b.ownSrc.includes(keep), "a layout property changed: " + keep);
        assert.equal(b.body.includes("Accessible.role"), false, "AbstractButton is a Button already; the role line is not needed (Skill 187 rule 3)");
    });
});

test("S5E3B-12 the ROWS table covers exactly the eleven buttons S5e-3a left unnamed (13 minus the two it pins)", () => {
    assert.equal(ROWS.length, 11);
    assert.equal(new Set(ROWS.map((r) => r[0] + "|" + r[2] + "|" + r[5].join())).size, 11, "two rows describe the same button");
});

// ---- who the member buttons speak for ---------------------------------------------------------------------------
test("S5E3B-13 MemberManagementDialog: card.memberLabel is the display name, else the email, else the word 'member'; all three buttons use it", () => {
    const src = stripComments(read("qml/pages/MemberManagementDialog.qml"));
    const m = /readonly property string memberLabel:\s*([^\n]+)/.exec(src);
    assert.ok(m, "memberLabel is gone");
    assert.equal(run(m[1], { modelData: { displayName: "Asha", email: "a@x.in" } }), "Asha");
    assert.equal(run(m[1], { modelData: { displayName: "", email: "a@x.in" } }), "a@x.in");
    assert.equal(run(m[1], { modelData: { email: "" } }), "member");
    assert.equal(run(m[1], { modelData: {} }), "member");
    assert.equal((src.match(/card\.memberLabel/g) || []).length, 3, "Suspend/Activate use it twice, Remove once");
    assert.equal(/qsTr\("(Suspend|Activate|Remove) member"\)/.test(src), false, "the old name that is the same on every card is back");
});

// ---- the four number fields -------------------------------------------------------------------------------------
const FIELDS = [
    ["qml/pages/NewOrderDialog.qml", "linePriceField", [{ modelData: { name: "Soap" } }], ["Price of Soap"]],
    ["qml/pages/NewOrderDialog.qml", "lineDiscField", [{ modelData: { name: "Soap", discountType: "percent" } }, { modelData: { name: "Soap", discountType: "flat" } }],
        ["Discount of Soap, percent", "Discount of Soap, flat amount"]],
    ["qml/pages/OrderDetailDialog.qml", "priceField", [{ model: { name: "Soap" } }], ["Price of Soap"]],
    ["qml/pages/OrderDetailDialog.qml", "lineDiscountField", [{ model: { name: "Soap" }, row: { lineDiscType: "percent" } }, { model: { name: "Soap" }, row: { lineDiscType: "flat" } }],
        ["Discount of Soap, percent", "Discount of Soap, flat amount"]],
];
FIELDS.forEach(([file, id, states, expected], i) => {
    test("S5E3B-" + String(14 + i) + " " + file.split("/").pop() + " " + id + ": speaks " + JSON.stringify(expected) + " (KNOWN-ISSUES 120)", () => {
        const f = scanInstances(read(file), "TextField").filter((x) => new RegExp("id: " + id + "\\b").test(x.ownSrc));
        assert.equal(f.length, 1);
        assert.equal(f[0].named, true);
        const names = states.map((s) => run(/Accessible\.name:\s*([^\n]+)/.exec(f[0].ownSrc)[1], s));
        assert.deepEqual(names, expected);
        if (names.length > 1) assert.notEqual(names[0], names[1], "percent and flat speak the same: the user cannot tell which unit the number is in");
        assert.match(f[0].ownSrc, /Layout\.minimumHeight: dp\(48\)/, "S5e-3a size kept");
        assert.match(f[0].ownSrc, /selectByMouse: true/);
    });
});

test("S5E3B-18 RATCHET: text fields under qml/ with no Accessible.name, pinned (the 4 order fields are fixed; 3 left, KNOWN-ISSUES 120)", () => {
    const left = scanFields(ROOT).map((f) => f.file + "|" + f.type + "|" + (f.placeholder ? "placeholder" : "no placeholder"));
    assert.deepEqual(left, [
        "qml/components/AuthPasswordField.qml|TextField|no placeholder",
        "qml/components/AuthTextField.qml|TextField|no placeholder",
        "qml/pages/ProfileSettingsDialog.qml|TextField|placeholder",
    ], "a new unnamed text field, or one of these fixed: update this list on purpose");
});

// ---- the tab bar ------------------------------------------------------------------------------------------------
test("S5E3B-19 Main.qml: all four tabs carry a non-empty qsTr label (the tab speaks its label)", () => {
    const src = stripComments(read("qml/Main.qml"));
    const tabs = src.match(/\{ iconName: "[a-z]+", label: qsTr\("[A-Za-z ]+"\) \}/g) || [];
    assert.equal(tabs.length, 4, "a tab label lost its qsTr, or a tab was added: " + tabs.join(" "));
    assert.deepEqual(tabs.map((t) => /qsTr\("([^"]+)"\)/.exec(t)[1]), ["Home", "Orders", "Stock", "Analysis"]);
});

// ---- ratchets ---------------------------------------------------------------------------------------------------
test("S5E3B-20 RATCHET: every named button that draws a child Text either ignores that Text or is on the short list of reasons", () => {
    const ign = {}, keep = {};
    for (const f of qmlFiles(path.join(ROOT, "qml"))) {
        for (const b of scanButtons(fs.readFileSync(f, "utf8"))) {
            if (b.root || !b.named || !b.hasTextChild) continue;
            const t = texts(b).some((x) => x.ignored), bucket = t ? ign : keep;
            bucket[rel(f)] = (bucket[rel(f)] || 0) + 1;
        }
    }
    assert.deepEqual(ign, {
        "qml/components/FloatingTabbar.qml": 1, "qml/pages/AddProductDialog.qml": 1, "qml/pages/DashboardPage.qml": 1, "qml/pages/ManageCategoriesDialog.qml": 2,
        "qml/pages/ManageOrderChannelsDialog.qml": 2, "qml/pages/NotificationsSheet.qml": 1, "qml/pages/ProfilePage.qml": 1, "qml/pages/SalesPage.qml": 1,
    });
    // OrdersPage approve button: its Text is the progress ("3 / 10"), worth hearing; ProfilePage uidBtn: the Text is the ID value
    assert.deepEqual(keep, { "qml/pages/OrdersPage.qml": 1, "qml/pages/ProfilePage.qml": 1 }, "a named button now reads its Text twice, or one of these two changed");
});
test("S5E3B-21 RATCHET: the one text-child button left unnamed keeps its reason (KNOWN-ISSUES 123); the dead SegmentedNav is deleted (KNOWN-ISSUES 128, S5f)", () => {
    const inv = one(read("qml/pages/InventoryPage.qml"), (b) => !b.root && /id: card\b/.test(b.body));
    assert.equal(inv.named || inv.ownText, false, "ProductCard got a name: the device checks 176 to 179 decided it? update KNOWN-ISSUES 123 and S5E3-07");
    assert.match(inv.body, /signal restockClicked\(\)/, "ProductCard holds other buttons (the reason it is left)");
    assert.equal(fs.existsSync(path.join(ROOT, "qml", "helper", "SegmentedNav.qml")), false, "SegmentedNav came back: name its buttons first");
    for (const f of qmlFiles(path.join(ROOT, "qml"))) {
        assert.equal(/\bSegmentedNav\b/.test(stripComments(fs.readFileSync(f, "utf8"))), false, rel(f) + " names SegmentedNav");
    }
});
test("S5E3B-22 every added name: qsTr literals only (letters, spaces, %1, commas), short, no concatenation (the data label of SettingsRow excepted), no role line", () => {
    const exprs = [];
    for (const r of ROWS) {
        if (r[2] !== "expr") continue;
        exprs.push([r[0], nameOf(one(read(r[0]), (x) => !x.root && r[1](x))), r[0].endsWith("ProfilePage.qml") && /settingsRowRoot/.test(r[1].toString())]);
    }
    for (const f of FIELDS) exprs.push([f[0], /Accessible\.name:\s*([^\n]+)/.exec(scanInstances(read(f[0]), "TextField").find((x) => new RegExp("id: " + f[1] + "\\b").test(x.ownSrc)).ownSrc)[1].trim(), false]);
    assert.equal(exprs.length, 6 + 4);
    for (const [file, expr, isData] of exprs) {
        const calls = expr.match(/qsTr\([^)]*\)/g) || [];
        if (!isData) assert.ok(calls.length >= 1, file + ": " + expr + " is not translatable");
        for (const c of calls) assert.match(c, /^qsTr\("[A-Za-z][A-Za-z ,%1]{2,38}"\)$/, c + " is not a plain short literal");
        if (!isData) assert.equal(/\+/.test(blankStrings(expr)), false, expr + " builds the name by concatenation (translators cannot reorder it)");
    }
});
test("S5E3B-23 categories: the visible 'Remove' is translatable now (it was a bare string)", () => {
    const src = stripComments(read("qml/pages/ManageCategoriesDialog.qml"));
    assert.equal(/text:\s*"Remove"/.test(src), false);
    assert.match(src, /text: qsTr\("Remove"\)/);
});

// ---- monkey -----------------------------------------------------------------------------------------------------
const HOSTILE = ["", " ", "%1", "%2 %1", "$&", "$1", "'", "\"", "\\", "100% cotton", "A/B", "Ünïcödé", "कारोबार", "😀 deal", "x".repeat(300), "a\nb", "{ }", "text: x", "Accessible.name: y"];
test("S5E3B-24 MONKEY: every per-row name, run against 19 hostile item names plus 300 seeded random ones, keeps the item name verbatim and never throws", () => {
    const rowExprs = ROWS.filter((r) => r[9] === "implicitHeight: dp(28)" && r[2] === "expr").map((r) => nameOf(one(read(r[0]), (x) => !x.root && r[1](x))));
    assert.equal(rowExprs.length, 4);
    const fieldExprs = FIELDS.map((f) => [f, /Accessible\.name:\s*([^\n]+)/.exec(scanInstances(read(f[0]), "TextField").find((x) => new RegExp("id: " + f[1] + "\\b").test(x.ownSrc)).ownSrc)[1].trim()]);
    const lbl = /readonly property string memberLabel:\s*([^\n]+)/.exec(stripComments(read("qml/pages/MemberManagementDialog.qml")))[1];
    let seed = 20261123;
    const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
    const alphabet = "abcXYZ 019%$&'\"{}\\/ñé字";
    const names = HOSTILE.slice();
    for (let n = 0; n < 300; n++) { let s = ""; for (let k = Math.floor(rnd() * 24); k > 0; k--) s += alphabet[Math.floor(rnd() * alphabet.length)]; names.push(s); }
    for (const item of names) {
        for (const e of rowExprs) { const out = run(e, { modelData: item }); assert.ok(out.includes(item), JSON.stringify(item) + " lost in " + out); assert.ok(/^(Set|Remove) /.test(out)); }
        for (const [f, e] of fieldExprs) {
            const withName = JSON.parse(JSON.stringify(f[2][0]));
            (withName.modelData || withName.model).name = item;
            const out = run(e, withName);
            // an empty name speaks the word "item" (PR #216 sweep F-1); every other name is kept verbatim
            assert.ok(out.includes(item === "" ? "item" : item), JSON.stringify(item) + " lost in " + out);
            assert.equal(/ of $/.test(out) || /undefined|null/.test(out), false, "a name with nothing after 'of': " + out);
        }
        // the member label falls back to the word "member" only when both display name and email are empty
        assert.equal(run(lbl, { modelData: { displayName: item, email: "" } }), item === "" ? "member" : item);
    }
});
test("S5E3B-25 MONKEY: scanFields/scanInstances `named` and `placeholder` against a generator (300 seeded blocks; decoys in strings, comments, nested blocks, look-alike types)", () => {
    let seed = 20261124;
    const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
    for (let n = 0; n < 300; n++) {
        const named = rnd() < 0.5, ph = rnd() < 0.4, nested = rnd() < 0.3, strDecoy = rnd() < 0.4, comDecoy = rnd() < 0.4, oneLine = rnd() < 0.3;
        const parts = [];
        if (named) parts.push('Accessible.name: qsTr("n' + n + '")');
        if (ph) parts.push('placeholderText: "p' + n + '"');
        if (strDecoy) parts.push('onTextChanged: log("Accessible.name: } { placeholderText: x TextField { ")');
        if (comDecoy && !oneLine) parts.push("// Accessible.name: x } placeholderText: y");
        if (nested) parts.push('background: Rectangle { Accessible.name: "deep"; placeholderText: "deep" }');
        const head = ["TextField", "QQC.TextField", "TextArea"][Math.floor(rnd() * 3)];
        const block = head + " {" + (oneLine ? " " : "\n    ") + parts.join(oneLine ? "; " : "\n    ") + (oneLine ? " }" : "\n}");
        const decoys = '// TextField { Accessible.name: "c" }\nAuthTextField { }\nMyTextField { }\nText { text: "TextField { }" }\n';
        const type = head.endsWith("TextArea") ? "TextArea" : "TextField";
        const r = scanInstances("Item {\n" + decoys + block + "\n}\n", type);
        assert.equal(r.length, 1, "step " + n + " found " + r.length + ": " + block);
        assert.equal(r[0].named, named, "named, step " + n + ": " + block);
        assert.equal(r[0].placeholder, ph, "placeholder, step " + n + ": " + block);
    }
});

// ---- regression -------------------------------------------------------------------------------------------------
test("S5E3B-26 REGRESSION: S5e-3a names and S5e-1 sheet surface still hold; no qml file lost its balance", () => {
    for (const f of ["qml/pages/ActivityPage.qml", "qml/pages/ProfilePage.qml", "qml/pages/StaffPage.qml", "qml/pages/AddProductDialog.qml", "qml/pages/RestockDialog.qml",
        "qml/pages/EditProductDialog.qml", "qml/pages/ProfileSettingsDialog.qml", "qml/pages/MemberManagementDialog.qml"]) {
        assert.ok(/Accessible\.role: Accessible\.Button/.test(read(f)), f + " lost an S5e-3a icon-button name");
    }
    for (const f of qmlFiles(path.join(ROOT, "qml"))) scanButtons(fs.readFileSync(f, "utf8")); // throws on unbalanced braces
    scanFields(ROOT);
    assert.match(read("qml/pages/NewOrderDialog.qml"), /text: manageChannelsLink\.text \+ "  ›"/, "the S5e-3a link recipe is untouched");
});

test("S5E3B-27 scanFields on a hand-made tree: TextField and TextArea, prefixed or not, named or not, look-alike types and comments are not fields", () => {
    const os = require("node:os");
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "s5e3b-"));
    try {
        fs.mkdirSync(path.join(dir, "qml", "sub"), { recursive: true });
        fs.writeFileSync(path.join(dir, "qml", "A.qml"), 'Item {\n  QQC.TextField { placeholderText: "p" }\n  TextField { Accessible.name: "ok" }\n  AuthTextField { }\n  // TextArea { }\n}\n');
        fs.writeFileSync(path.join(dir, "qml", "sub", "B.qml"), 'Item {\n  TextArea { }\n  QQC.TextArea { Accessible.name: "ok"; placeholderText: "x" }\n}\n');
        assert.deepEqual(scanFields(dir), [
            { file: "qml/A.qml", line: 2, type: "TextField", placeholder: true },
            { file: "qml/sub/B.qml", line: 2, type: "TextArea", placeholder: false },
        ]);
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

// ---- PR #216 sweep: an order line with no name --------------------------------------------------------------------
test("S5E3B-28 SWEEP F-1: a line with an empty, missing or null name speaks 'item', never 'Price of ' or 'Price of undefined' (imported or legacy lines)", () => {
    for (const [file, id, states] of FIELDS) {
        const expr = /Accessible\.name:\s*([^\n]+)/.exec(scanInstances(read(file), "TextField").find((x) => new RegExp("id: " + id + "\\b").test(x.ownSrc)).ownSrc)[1].trim();
        assert.match(expr, /\|\| qsTr\("item"\)/, file + " " + id + ": the fallback is gone");
        for (const st of states) {
            const key = st.modelData ? "modelData" : "model";
            for (const bad of [{ name: "" }, {}, { name: null }]) {
                const ctx = JSON.parse(JSON.stringify(st));
                ctx[key] = Object.assign({}, ctx[key]); delete ctx[key].name; Object.assign(ctx[key], bad);
                const out = run(expr, ctx);
                assert.match(out, /^(Price|Discount) of item(, percent|, flat amount)?$/, file + " " + id + ": " + JSON.stringify(bad) + " -> " + out);
            }
        }
    }
});
test("S5E3B-29 SWEEP F-1: the fallback word is a plain qsTr literal, one per field expression use (translators get one 'item')", () => {
    // only on `Accessible.name:` lines: OrderDetailDialog already uses the same fallback in its activity text (three more uses)
    const n = (f) => stripComments(read(f)).split("\n").filter((l) => /Accessible\.name:/.test(l)).join("\n").match(/\|\| qsTr\("item"\)/g).length;
    assert.equal(n("qml/pages/NewOrderDialog.qml"), 3, "NewOrderDialog: price once, discount twice (percent and flat)");
    assert.equal(n("qml/pages/OrderDetailDialog.qml"), 3, "OrderDetailDialog: price once, discount twice (percent and flat)");
});
