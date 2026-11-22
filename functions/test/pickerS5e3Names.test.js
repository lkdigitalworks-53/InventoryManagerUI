"use strict";
// Picker v2, slice S5e-3a: the icon-only buttons speak, "Manage channels" and the four number fields are big enough. S5E3-01..24.
// Plan: docs/superpowers/plans/2026-11-22-product-picker-v2-s5e3a-unnamed-buttons-and-targets.md
// Like the S5e-1 wiring test these READ the QML text (qmltestrunner cannot load Felgo pages) and RUN the real name
// expressions in a sandbox, so a typo in a ternary fails here. They pin WIRING, not what Android does with it: whether
// TalkBack reads the names and whether a 48 dp field fits the row is the on-device plan (checks 162 to 175).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { stripComments, blankStrings, matchBrace, scanButtons, qmlFiles, scanTree } = require("./testSupport/qmlButtonScan");

const ROOT = path.join(__dirname, "..", "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const one = (src, f) => { const r = scanButtons(src).filter(f); assert.equal(r.length, 1, "expected exactly one match, got " + r.length); return r[0]; };

// ---- scanner (unit) ---------------------------------------------------------------------------------------------
test("S5E3-01 scanner: own name, own text, and what does NOT count (ToolTip.text, nested text, nested name, string content)", () => {
    const f = (s) => scanButtons(s)[0];
    assert.equal(f('QQC.AbstractButton { Accessible.name: qsTr("x") }').named, true);
    assert.equal(f('Button { text: "Today"; onClicked: go() }').ownText, true, "one-line block");
    assert.equal(f('Button { ToolTip.text: "a"; contentItem: Icon { name: "x" } }').ownText, false, "ToolTip.text is not a name (the S5e-1 scan missed two buttons on this)");
    assert.equal(f('AbstractButton { contentItem: Text { text: "Hi" } }').ownText, false, "nested text is not the button's text");
    assert.equal(f('AbstractButton { contentItem: Text { text: "Hi" } }').hasTextChild, true);
    assert.equal(f('AbstractButton { contentItem: Item { Accessible.name: "x" } }').named, false, "a name on a child is not the button's");
    assert.equal(f('AbstractButton { onClicked: log("text: x, Accessible.name: y, Text { z") }').named, false, "string content is not code");
    assert.equal(f('AbstractButton { onClicked: log("text: x") }').ownText, false);
    assert.equal(f('AbstractButton { onClicked: log("Text { z") }').hasTextChild, false);
});
test("S5E3-02 scanner: braces and slashes inside strings and comments never break the block", () => {
    const src = 'Item {\n  AbstractButton { // } a stray brace in a comment\n    /* { */ Accessible.name: "a}{b //c"\n    contentItem: Item { Icon { name: "x" } }\n  }\n}\n';
    const r = scanButtons(src);
    assert.equal(r.length, 1);
    assert.equal(r[0].named, true);
    assert.equal(r[0].hasTextChild, false);
    assert.equal(r[0].line, 2, "comments keep their newlines, so lines stay true");
});
test("S5E3-03 scanner: type boundaries, root flag, nested buttons, unbalanced input", () => {
    assert.equal(scanButtons("GhostButton { } PrimaryButton { } IconActionButton { } AuthPrimaryButton { }").length, 0, "a longer type name is not a raw button");
    assert.equal(scanButtons("QQC.Button { } ToolButton { } RoundButton { } AbstractButton { }").length, 4);
    const nested = scanButtons("AbstractButton {\n  contentItem: Item { Button { text: \"in\" } }\n}\n");
    assert.deepEqual(nested.map((b) => [b.type, b.root]), [["AbstractButton", true], ["Button", false]]);
    assert.throws(() => scanButtons("Item { AbstractButton { "), /unbalanced/);
    assert.deepEqual(scanButtons(""), []);
    assert.deepEqual(scanButtons("// only a comment { Button { }"), []);
});
test("S5E3-04 scanner helpers: stripComments keeps strings, blankStrings keeps length, matchBrace needs a balanced block", () => {
    assert.equal(stripComments('a "http://x" // c\nb'), 'a "http://x"     \nb');
    assert.equal(stripComments("a /* x\ny */ b").split("\n").length, 2);
    const t = blankStrings('f("a{b", \'c}d\')');
    assert.equal(t.length, 'f("a{b", \'c}d\')'.length);
    assert.equal(t.includes("{"), false);
    assert.equal(matchBrace("{ { } }", 0), 6);
    assert.equal(matchBrace("{ { }", 0), -1);
});

// ---- the ratchet ------------------------------------------------------------------------------------------------
test("S5E3-05 RATCHET: no icon-only raw button under qml/ lacks a spoken name (only the dead OrderRow helper is listed)", () => {
    const { iconOnly } = scanTree(ROOT);
    assert.deepEqual(iconOnly.map((b) => b.file), ["qml/helper/OrderRow.qml", "qml/helper/OrderRow.qml"],
        "a new unnamed icon button: give it Accessible.role and Accessible.name (S5e3a-D2). Found: " + JSON.stringify(iconOnly));
});
test("S5E3-06 the one allowed exception stays dead: nothing instantiates OrderRow (KNOWN-ISSUES 109)", () => {
    for (const f of qmlFiles(path.join(ROOT, "qml"))) {
        if (f.endsWith("OrderRow.qml")) continue;
        assert.equal(/\bOrderRow\s*\{/.test(stripComments(fs.readFileSync(f, "utf8"))), false,
            f + " now uses OrderRow: name its two icon buttons first and drop the exception in S5E3-05");
    }
});
test("S5E3-07 RATCHET (S5e-3b to-do): buttons whose label lives only in a child Text, pinned by file and count", () => {
    const { textChild } = scanTree(ROOT);
    const by = {};
    for (const b of textChild) by[b.file] = (by[b.file] || 0) + 1;
    assert.deepEqual(by, {
        "qml/components/FloatingTabbar.qml": 1, "qml/helper/SegmentedNav.qml": 1, "qml/pages/AddProductDialog.qml": 1,
        "qml/pages/DashboardPage.qml": 1, "qml/pages/InventoryPage.qml": 1, "qml/pages/ManageCategoriesDialog.qml": 2,
        "qml/pages/ManageOrderChannelsDialog.qml": 2, "qml/pages/NotificationsSheet.qml": 1, "qml/pages/ProfilePage.qml": 2,
        "qml/pages/SalesPage.qml": 1,
    }, "a new text-child button, or one fixed in S5e-3b: update this list on purpose (13 at S5e-3a)");
    assert.equal(textChild.length, 13);
});

// ---- the ten buttons --------------------------------------------------------------------------------------------
// [file, how to find the block, the name in each state (state objects feed the real expression), a snippet of the handler that must survive]
const dlgOpen = (v) => ({ dlg: { _addPartyOpen: v } });
const TEN = [
    ["qml/pages/ActivityPage.qml", (b) => /root\.backRequested\(\)/.test(b.body), [{}], ["Back"], "onClicked: root.backRequested()"],
    ["qml/pages/ProfilePage.qml", (b) => /root\.backRequested\(\)/.test(b.body), [{}], ["Back"], "onClicked: root.backRequested()"],
    ["qml/pages/StaffPage.qml", (b) => /root\.backRequested\(\)/.test(b.body), [{}], ["Back"], "onClicked: root.backRequested()"],
    ["qml/pages/AddProductDialog.qml", (b) => /id: addPartyToggle/.test(b.body), [dlgOpen(false), dlgOpen(true)], ["Add new supplier", "Close new supplier"], "dlg._addPartyOpen = !dlg._addPartyOpen"],
    ["qml/pages/RestockDialog.qml", (b) => /id: addPartyToggle/.test(b.body), [dlgOpen(false), dlgOpen(true)], ["Add new supplier", "Close new supplier"], "dlg._addPartyOpen = !dlg._addPartyOpen"],
    ["qml/pages/EditProductDialog.qml", (b) => /id: renamePartyToggle/.test(b.body), [{ root: { _renaming: false } }, { root: { _renaming: true } }], ["Rename supplier", "Cancel renaming supplier"], "root._renaming = !root._renaming"],
    ["qml/pages/ProfileSettingsDialog.qml", (b) => /id: editButton/.test(b.body), [{ root: { workspaceEditMode: false } }, { root: { workspaceEditMode: true } }], ["Rename workspace", "Cancel renaming workspace"], "root.workspaceEditMode = true"],
    ["qml/pages/MemberManagementDialog.qml", (b) => /\"pause-status\"/.test(b.body), [{ modelData: { status: "active" } }, { modelData: { status: "suspended" } }], ["Suspend member", "Activate member"], "root._openConfirm(\"status\""],
    ["qml/pages/MemberManagementDialog.qml", (b) => /\"Remove member\"/.test(b.body) && /Constants\.danger/.test(b.body), [{}], ["Remove member"], "root._openConfirm(\"remove\""],
];
const nameOf = (b) => { const m = /(?:^|[\s;{])Accessible\.name\s*:\s*([^\n]+)/.exec(b.ownSrc); assert.ok(m, "no own Accessible.name"); return m[1].trim(); };
const run = (expr, ctx) => vm.runInNewContext("(" + expr + ")", Object.assign({ qsTr: (s) => s }, JSON.parse(JSON.stringify(ctx))));

TEN.forEach(([file, find, states, expected, handler], i) => {
    test("S5E3-" + String(8 + i).padStart(2, "0") + " " + file.split("/").pop() + ": button #" + (i + 1) + " is a Button with the name " + JSON.stringify(expected) + " and keeps its handler", () => {
        const b = one(read(file), (x) => !x.root && find(x));
        assert.match(b.ownSrc, /Accessible\.role: Accessible\.Button/);
        const expr = nameOf(b);
        const names = states.map((s) => run(expr, s));
        assert.deepEqual(names, expected);
        if (names.length > 1) assert.notEqual(names[0], names[1], "both states speak the same: the toggle would not say what it does now");
        assert.ok(b.body.includes(handler), "the handler changed: " + handler);
    });
});

// ---- the FAB ----------------------------------------------------------------------------------------------------
test("S5E3-17 FloatingActionButton speaks its `label` (default empty) as a Button", () => {
    const src = stripComments(read("qml/components/FloatingActionButton.qml"));
    const b = one(src, (x) => x.root);
    assert.equal(b.named, true);
    assert.match(b.ownSrc, /Accessible\.role: Accessible\.Button/);
    assert.match(b.ownSrc, /Accessible\.name: root\.label/);
    assert.match(b.ownSrc, /property string label: ""/);
    assert.match(b.ownSrc, /property string iconName: "add"/, "the icon property stays");
});
test("S5E3-18 RATCHET: the FAB has exactly three users and every one passes a qsTr label", () => {
    const users = [];
    for (const f of qmlFiles(path.join(ROOT, "qml"))) {
        if (f.endsWith("FloatingActionButton.qml")) continue;
        const src = stripComments(fs.readFileSync(f, "utf8")), t = blankStrings(src);
        const re = /\bFloatingActionButton\s*\{/g;
        let m;
        while ((m = re.exec(t))) {
            const open = m.index + m[0].length - 1, close = matchBrace(t, open);
            users.push({ file: path.relative(ROOT, f).split(path.sep).join("/"), body: src.slice(open + 1, close) });
        }
    }
    assert.deepEqual(users.map((u) => u.file).sort(), ["qml/pages/InventoryPage.qml", "qml/pages/OrdersPage.qml", "qml/pages/StaffPage.qml"],
        "a new FloatingActionButton user: give it a label (S5e3a-D4)");
    for (const u of users) assert.match(u.body, /(^|\s)label:\s*(root\.\w+ \? )?qsTr\("[^"]+"\)/, u.file + " has no qsTr label");
    const staff = users.find((u) => u.file.endsWith("StaffPage.qml")).body;
    const expr = /label:\s*([^\n]+)/.exec(staff)[1];
    assert.equal(run(expr, { root: { canInviteMembers: true } }), "Add staff or invite member");
    assert.equal(run(expr, { root: { canInviteMembers: false } }), "Add staff");
    assert.match(users.find((u) => u.file.endsWith("InventoryPage.qml")).body, /label: qsTr\("Add product"\)/);
    assert.match(users.find((u) => u.file.endsWith("OrdersPage.qml")).body, /label: qsTr\("New order"\)/);
});

// ---- the link and the four fields ------------------------------------------------------------------------------
test("S5E3-19 'Manage channels': 48 dp, its own text is the spoken name (no chevron), the chevron is only drawn, the handler stays (KI 70 a)", () => {
    const b = one(read("qml/pages/NewOrderDialog.qml"), (x) => /id: manageChannelsLink/.test(x.body));
    assert.match(b.ownSrc, /text: qsTr\("Manage channels"\)/);
    assert.equal(b.ownSrc.includes("›"), false, "the chevron is in the spoken name");
    assert.match(b.ownSrc, /implicitHeight: dp\(48\)/);
    assert.equal(/dp\(28\)/.test(b.body), false, "28 dp is back");
    assert.match(b.body, /text: manageChannelsLink\.text \+ "  ›"/);
    assert.match(b.body, /onClicked: dlg\.manageChannelsRequested\(\)/);
    assert.match(b.body, /Layout\.alignment: Qt\.AlignRight/);
});
test("S5E3-20 the four number fields: Layout.minimumHeight 48 (grows with the font), centred text, padding and font untouched (KI 70 b)", () => {
    const want = { "qml/pages/NewOrderDialog.qml": ["linePriceField", "lineDiscField"], "qml/pages/OrderDetailDialog.qml": ["priceField", "lineDiscountField"] };
    for (const [file, ids] of Object.entries(want)) {
        const src = stripComments(read(file)), t = blankStrings(src);
        const re = /\bQQC\.TextField\s*\{/g;
        const fields = [];
        let m;
        while ((m = re.exec(t))) { const o = m.index + m[0].length - 1; fields.push(src.slice(o + 1, matchBrace(t, o))); }
        assert.equal(fields.length, 2, file + " has " + fields.length + " QQC.TextField blocks: a new one needs a 48 dp minimum too");
        assert.deepEqual(fields.map((f) => /id: (\w+)/.exec(f)[1]), ids);
        for (const f of fields) {
            assert.match(f, /Layout\.minimumHeight: dp\(48\)/, file);
            assert.match(f, /verticalAlignment: TextInput\.AlignVCenter/);
            assert.equal(/Layout\.preferredHeight/.test(f), false, "a fixed preferred height clips the text at a big font");
            assert.match(f, /topPadding: dp\(6\)/);
            assert.match(f, /bottomPadding: dp\(6\)/);
            assert.match(f, /font\.pixelSize: sp\(Constants\.fsBody\)/);
            assert.match(f, /selectByMouse: true/);
        }
    }
});
test("S5E3-21 the four fields keep their commit wiring (focus out, accept) and the price field still swaps plain and formatted text", () => {
    const nd = stripComments(read("qml/pages/NewOrderDialog.qml"));
    assert.match(nd, /onEditingFinished: _commitPrice\(\)/);
    assert.match(nd, /onAccepted: _commitPrice\(\)/);
    assert.match(nd, /onEditingFinished: _commitDiscount\(\)/);
    assert.match(nd, /if \(activeFocus\) \{ text = String\(modelData\.price\); selectAll\(\) \}/);
    const od = stripComments(read("qml/pages/OrderDetailDialog.qml"));
    assert.match(od, /onEditingFinished: _commitDiscount\(\)/);
    assert.match(od, /products\.setProperty\(row\.rowIdx, "price", v\)/);
});

// ---- rules for the words ---------------------------------------------------------------------------------------
test("S5E3-22 every added name is qsTr with literals only, plain ASCII, short, not an icon id, and not the same word for two different jobs", () => {
    const all = [];
    for (const [file, find] of TEN.map((r) => [r[0], r[1]])) all.push(nameOf(one(read(file), (x) => !x.root && find(x))));
    for (const expr of all) {
        const calls = expr.match(/qsTr\([^)]*\)/g) || [];
        assert.ok(calls.length >= 1, expr + " is not translatable");
        for (const c of calls) assert.match(c, /^qsTr\("[A-Za-z][A-Za-z ]{2,38}"\)$/, c + " is not a plain short literal");
        assert.equal(/\+/.test(blankStrings(expr)), false, expr + " builds the name by concatenation (translators cannot reorder it)");
    }
    const spoken = ["Add new supplier", "Close new supplier", "Rename supplier", "Cancel renaming supplier", "Rename workspace",
        "Cancel renaming workspace", "Suspend member", "Activate member", "Remove member", "Back"];
    assert.equal(new Set(spoken).size, spoken.length);
    for (const w of spoken) assert.equal(["add", "close", "edit", "check", "pause-status"].includes(w.toLowerCase()), false, w + " is an icon id (Back is a real word and the icon is named back: allowed)");
});

// ---- monkey, regression -----------------------------------------------------------------------------------------
test("S5E3-23 MONKEY: 400 seeded random buttons (decoys in strings, comments, nesting): the scanner agrees with the generator every time", () => {
    let seed = 20261122;
    const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    for (let n = 0; n < 400; n++) {
        const named = rnd() < 0.4, ownText = rnd() < 0.3, textChild = rnd() < 0.4, nestedName = rnd() < 0.3, tip = rnd() < 0.4;
        const strDecoy = rnd() < 0.4, comDecoy = rnd() < 0.4, oneLine = rnd() < 0.3, rootLevel = rnd() < 0.3;
        const sep = oneLine ? "; " : "\n    ";
        const parts = [];
        if (named) parts.push('Accessible.name: qsTr("n' + n + '")');
        if (ownText) parts.push('text: "t' + n + '"');
        if (tip) parts.push('ToolTip.text: "tip"');
        if (strDecoy) parts.push('onClicked: log("text: } { Accessible.name: x Text { ")');
        if (comDecoy && !oneLine) parts.push('// text: x } Accessible.name: y');
        if (nestedName) parts.push("contentItem: Item { Accessible.name: \"deep\"; Icon { name: \"x\" } }");
        else if (textChild) parts.push('contentItem: Text { text: "child" }');
        else parts.push("contentItem: Icon { name: \"x\" }");
        const head = pick(["AbstractButton", "QQC.AbstractButton", "Button", "QQC.Button", "ToolButton", "RoundButton"]);
        const block = head + " {" + (oneLine ? " " : "\n    ") + parts.join(sep) + (oneLine ? " }" : "\n}");
        const src = rootLevel ? block + "\n" : "Item {\n  Row {\n" + block + "\n  }\n}\n";
        const r = scanButtons(src).filter((b) => b.type === head.replace("QQC.", ""));
        assert.equal(r.length, 1, "seed step " + n + " found " + r.length + ": " + src);
        assert.equal(r[0].named, named, "named, step " + n + ": " + src);
        assert.equal(r[0].ownText, ownText, "ownText, step " + n + ": " + src);
        assert.equal(r[0].hasTextChild, !nestedName && textChild, "hasTextChild, step " + n + ": " + src);
        assert.equal(r[0].root, rootLevel);
    }
});
test("S5E3-24 REGRESSION: the files S5e-1 pinned still hold (sheet surface has zero unnamed buttons) and no qml file lost its balance", () => {
    for (const rel of ["qml/components/ProductPickerRow.qml", "qml/components/SearchField.qml", "qml/components/BottomSheet.qml", "qml/components/CartStepper.qml", "qml/components/ProductPickerSheet.qml"]) {
        for (const b of scanButtons(read(rel))) assert.equal(b.named || b.ownText, true, rel + " line " + b.line + " is unnamed");
    }
    for (const f of qmlFiles(path.join(ROOT, "qml"))) scanButtons(fs.readFileSync(f, "utf8")); // throws on unbalanced braces
});
