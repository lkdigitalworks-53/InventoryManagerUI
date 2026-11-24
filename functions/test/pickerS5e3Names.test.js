"use strict";
// Picker v2, slice S5e-3a: the icon-only buttons speak, "Manage channels" and the four number fields are big enough. S5E3-01..30 (25..30 are the review sweep of PR #215: wrapper components).
// Plan: docs/superpowers/plans/2026-11-22-product-picker-v2-s5e3a-unnamed-buttons-and-targets.md
// Like the S5e-1 wiring test these READ the QML text (qmltestrunner cannot load Felgo pages) and RUN the real name
// expressions in a sandbox, so a typo in a ternary fails here. They pin WIRING, not what Android does with it: whether
// TalkBack reads the names and whether a 48 dp field fits the row is the on-device plan (checks 162 to 175).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { stripComments, blankStrings, matchBrace, scanButtons, scanInstances, qmlFiles, scanTree } = require("./testSupport/qmlButtonScan");

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
test("S5E3-05 RATCHET: no icon-only raw button under qml/ lacks a spoken name (no exception left: the dead OrderRow helper was deleted in S5f)", () => {
    const { iconOnly } = scanTree(ROOT);
    assert.deepEqual(iconOnly.map((b) => b.file), [],
        "a new unnamed icon button: give it Accessible.role and Accessible.name (S5e3a-D2). Found: " + JSON.stringify(iconOnly));
});
test("S5E3-06 the old exception is gone for good: OrderRow.qml is deleted and no QML file names it (KNOWN-ISSUES 121, closed in S5f)", () => {
    assert.equal(fs.existsSync(path.join(ROOT, "qml", "helper", "OrderRow.qml")), false, "OrderRow came back: its two icon buttons need a spoken name first");
    for (const f of qmlFiles(path.join(ROOT, "qml"))) {
        assert.equal(/\bOrderRow\b/.test(stripComments(fs.readFileSync(f, "utf8"))), false, f + " names OrderRow");
    }
});
test("S5E3-07 RATCHET: buttons whose label lives only in a child Text and that have no name, pinned by file (13 at S5e-3a, 2 after S5e-3b, 1 after S5f)", () => {
    const { textChild } = scanTree(ROOT);
    const by = {};
    for (const b of textChild) by[b.file] = (by[b.file] || 0) + 1;
    // S5e-3b named 11 (pickerS5e3bNames.test.js); S5f deleted the dead SegmentedNav (KNOWN-ISSUES 128). Left on purpose: InventoryPage's ProductCard
    // is a card that holds other buttons (KNOWN-ISSUES 123 class: decide on a device, checks 176 to 179).
    assert.deepEqual(by, { "qml/pages/InventoryPage.qml": 1 },
        "a new text-child button, or the ProductCard one fixed: update this list on purpose");
    assert.equal(textChild.length, 1);
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
    // S5e-3b (KNOWN-ISSUES 124): the three member buttons say WHICH member ("Suspend Asha"); S5e-3a spoke "Suspend member" for every card.
    ["qml/pages/MemberManagementDialog.qml", (b) => /\"pause-status\"/.test(b.body), [{ modelData: { status: "active" }, card: { memberLabel: "Asha" } }, { modelData: { status: "suspended" }, card: { memberLabel: "Asha" } }], ["Suspend Asha", "Activate Asha"], "root._openConfirm(\"status\""],
    ["qml/pages/MemberManagementDialog.qml", (b) => /\"Remove member\"/.test(b.body) && /Constants\.danger/.test(b.body), [{ card: { memberLabel: "Asha" } }], ["Remove Asha"], "root._openConfirm(\"remove\""],
];
const nameOf = (b) => { const m = /(?:^|[\s;{])Accessible\.name\s*:\s*([^\n]+)/.exec(b.ownSrc); assert.ok(m, "no own Accessible.name"); return m[1].trim(); };
// qsTr returns a String with the real `.arg(...)`, so expressions run as written (S5e-3b: names with %1).
const run = (expr, ctx) => String(vm.runInNewContext("(" + expr + ")", Object.assign({
    qsTr: (s) => Object.assign(new String(s), { arg: (v) => s.replace("%1", () => String(v)) }),
}, JSON.parse(JSON.stringify(ctx)))));

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
        for (const c of calls) assert.match(c, /^qsTr\("[A-Za-z][A-Za-z %1]{2,38}"\)$/, c + " is not a plain short literal");
        assert.equal(/\+/.test(blankStrings(expr)), false, expr + " builds the name by concatenation (translators cannot reorder it)");
    }
    const spoken = ["Add new supplier", "Close new supplier", "Rename supplier", "Cancel renaming supplier", "Rename workspace",
        "Cancel renaming workspace", "Suspend %1", "Activate %1", "Remove %1", "Back"];
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

// ---- review sweep of PR #215: wrapper components ----------------------------------------------------------------
// The raw-button scan skips a component whose ROOT is the button (FloatingActionButton, IconActionButton, ...), so the icon-only
// buttons made from such a wrapper were never counted: 11 header and form buttons had no spoken name (KNOWN-ISSUES 97).
const rel = (f) => path.relative(ROOT, f).split(path.sep).join("/");
const instancesOf = (type) => {
    const out = [];
    for (const f of qmlFiles(path.join(ROOT, "qml"))) {
        if (f.endsWith("/" + type + ".qml")) continue;
        for (const i of scanInstances(fs.readFileSync(f, "utf8"), type)) out.push(Object.assign({ file: rel(f) }, i));
    }
    return out;
};
// qsTr returns a String that has the real `.arg(...)`, so the label expressions run as written.
const runLabel = (expr, ctx) => String(vm.runInNewContext("(" + expr + ")", Object.assign({
    qsTr: (x) => Object.assign(new String(x), { arg: (v) => x.replace("%1", v) }),
}, JSON.parse(JSON.stringify(ctx)))));
const labelOf = (i) => { const m = /(?:^|[\s;{])label\s*:\s*([^\n]+)/.exec(i.ownSrc); assert.ok(m, "no own label"); return m[1].trim(); };

test("S5E3-25 IconActionButton speaks its `label`, else its `text`, as a Button (the default stays empty)", () => {
    const b = one(stripComments(read("qml/components/IconActionButton.qml")), (x) => x.root);
    assert.match(b.ownSrc, /property string label: ""/);
    assert.match(b.ownSrc, /property string iconName: ""/, "the icon property stays");
    assert.match(b.ownSrc, /Accessible\.role: Accessible\.Button/);
    const expr = nameOf(b);
    assert.equal(run(expr, { root: { label: "Export", text: "J" } }), "Export", "a label wins over the text");
    assert.equal(run(expr, { root: { label: "", text: "J" } }), "J", "no label: the text, as before");
    assert.equal(run(expr, { root: { label: "", text: "" } }), "", "neither: silent (the ratchet below stops that)");
});

// [file, a regex that finds the instance, the badge states that feed the label, the words spoken in each, a handler that must survive]
const IAB = [
    ["qml/pages/AddStaffDialog.qml", /iconName: "calendar"/, [{}], ["Pick join date"], "onClicked: joinPicker.open()"],
    ["qml/pages/DashboardPage.qml", /iconName: "bell"/, [{ badgeText: "" }, { badgeText: "5" }], ["Notifications", "Notifications, 5 waiting"], "onClicked: root.showNotificationsRequested()"],
    ["qml/pages/DashboardPage.qml", /text: root\._initial\(\)/, [{}], ["Profile"], "onClicked: root.navigateToProfile()"],
    ["qml/pages/InventoryPage.qml", /iconName: "import"/, [{}], ["Import products"], "onClicked: root.importRequested()"],
    ["qml/pages/InventoryPage.qml", /iconName: "export"/, [{}], ["Export products"], "onClicked: root.exportRequested()"],
    ["qml/pages/OrdersPage.qml", /iconName: "import"/, [{}], ["Import orders"], "onClicked: root.importRequested()"],
    ["qml/pages/OrdersPage.qml", /iconName: "export"/, [{}], ["Export orders"], "onClicked: root.exportRequested()"],
    ["qml/pages/OrdersPage.qml", /iconName: "settings"/, [{ badgeText: "" }, { badgeText: "\u2022" }], ["Filters", "Filters, active"], "onClicked: root.filtersRequested()"],
    ["qml/pages/SalesPage.qml", /iconName: "settings"/, [{ badgeText: "" }, { badgeText: "\u2022" }], ["Filters", "Filters, active"], "analysisFilterSheet.open()"],
    ["qml/pages/SalesPage.qml", /iconName: "export"/, [{}], ["Export analysis"], "root.exportRequested(root.buildAnalysisWorkbook())"],
    ["qml/pages/StaffPage.qml", /iconName: "staff"/, [{}], ["Manage members"], "onClicked: root.manageMembersClicked()"],
    ["qml/pages/StaffPage.qml", /iconName: "export"/, [{}], ["Export staff"], "onClicked: root.exportRequested()"],
];
IAB.forEach(([file, find, states, expected, handler], i) => {
    test("S5E3-26." + String(i + 1).padStart(2, "0") + " " + file.split("/").pop() + ": IconActionButton " + JSON.stringify(expected) + " speaks, differs per state, keeps its handler", () => {
        const hits = scanInstances(read(file), "IconActionButton").filter((x) => find.test(x.body));
        assert.equal(hits.length, 1, "expected exactly one instance, got " + hits.length);
        const names = states.map((st) => runLabel(labelOf(hits[0]), st));
        assert.deepEqual(names, expected);
        if (names.length > 1) assert.notEqual(names[0], names[1], "both states speak the same: a screen reader user cannot tell a badge is up");
        assert.ok(hits[0].body.includes(handler), "the handler changed: " + handler);
    });
});
test("S5E3-27 RATCHET: every IconActionButton instance has a label (or a speaking wrapper above it); the list of instances is pinned", () => {
    const all = instancesOf("IconActionButton"), by = {};
    for (const i of all) by[i.file] = (by[i.file] || 0) + 1;
    assert.deepEqual(by, {
        "qml/components/RefreshAction.qml": 1, "qml/pages/AddStaffDialog.qml": 1, "qml/pages/DashboardPage.qml": 2, "qml/pages/InventoryPage.qml": 2,
        "qml/pages/OrdersPage.qml": 3, "qml/pages/SalesPage.qml": 2, "qml/pages/StaffPage.qml": 2,
    }, "a new IconActionButton: give it `label: qsTr(...)` and add it to the IAB table");
    const bare = all.filter((i) => !i.labelled && !i.ignored);
    assert.deepEqual(bare.map((i) => i.file + ":" + i.line), [], "unnamed IconActionButton: pass label: qsTr(...) (S5e3a-D4 recipe)");
    const ignored = all.filter((i) => i.ignored);
    assert.deepEqual(ignored.map((i) => i.file), ["qml/components/RefreshAction.qml"], "the only instance that may stay silent is the one under RefreshAction's own named wrapper");
    assert.match(read("qml/components/RefreshAction.qml"), /Accessible\.name: RefreshCaption\.accessibleName\(root\._view\)/, "RefreshAction no longer speaks for its button");
    assert.equal(all.filter((i) => i.labelled).length, IAB.length, "the IAB table and the labelled instances disagree");
});
test("S5E3-28 words of the wrapper labels: qsTr literals only, plain, short, no concatenation, distinct per file, not an icon id", () => {
    const seen = {};
    for (const i of instancesOf("IconActionButton").filter((x) => x.labelled)) {
        const expr = labelOf(i), calls = expr.match(/qsTr\("[^"]*"\)/g) || [];
        assert.ok(calls.length >= 1, expr + " is not translatable");
        for (const c of calls) assert.match(c, /^qsTr\("[A-Za-z][A-Za-z ,%1]{2,38}"\)$/, c + " is not a plain short literal");
        assert.equal(/\+/.test(blankStrings(expr)), false, expr + " builds the label by concatenation");
        for (const c of calls) {
            const w = /"([^"]*)"/.exec(c)[1];
            assert.equal(["import", "export", "settings", "staff", "calendar", "bell"].includes(w.toLowerCase()), false, w + " is an icon id");
            (seen[i.file] = seen[i.file] || []).push(w);
        }
    }
    for (const [f, words] of Object.entries(seen)) assert.equal(new Set(words).size, words.length, f + " speaks one word for two jobs: " + words);
});
test("S5E3-29 RATCHET: the components whose ROOT is a raw button are pinned with what speaks for them (KNOWN-ISSUES 123 for the two unverified)", () => {
    const roots = qmlFiles(path.join(ROOT, "qml")).filter((f) => scanButtons(fs.readFileSync(f, "utf8")).some((b) => b.root)).map(rel);
    assert.deepEqual(roots, [
        "qml/components/ActionTile.qml", "qml/components/AuthPrimaryButton.qml", "qml/components/AuthSecondaryButton.qml", "qml/components/DangerButton.qml",
        "qml/components/FloatingActionButton.qml", "qml/components/GhostButton.qml", "qml/components/IconActionButton.qml", "qml/components/ListCard.qml",
        "qml/components/PrimaryButton.qml",
    ], "a new component whose root is a button: decide what speaks for it (label, text, or a name at each use) and add it here");
    for (const f of ["AuthPrimaryButton", "AuthSecondaryButton", "DangerButton", "GhostButton", "PrimaryButton"])
        assert.match(stripComments(read("qml/components/" + f + ".qml")), /text: root\.text/, f + " no longer draws its own `text`, which is what Qt speaks");
    for (const f of ["FloatingActionButton", "IconActionButton"]) assert.match(read("qml/components/" + f + ".qml"), /Accessible\.name: /, f + " lost its spoken name");
    // ActionTile (caption) and ListCard (title, subtitle) draw their words only in a child Text and set no name: UNVERIFIED on a device, KI 123.
    for (const f of ["ActionTile", "ListCard"]) assert.equal(/Accessible\.name/.test(read("qml/components/" + f + ".qml")), false, f + " now has a name: update KNOWN-ISSUES 123 and this pin");
});
test("S5E3-30 MONKEY: scanInstances against a generator (300 seeded blocks, decoys in strings, comments, nested blocks; look-alike type names are not instances)", () => {
    let seed = 20261123;
    const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
    for (let n = 0; n < 300; n++) {
        const labelled = rnd() < 0.5, ignored = rnd() < 0.3, nestedLabel = rnd() < 0.3, strDecoy = rnd() < 0.4, comDecoy = rnd() < 0.4, oneLine = rnd() < 0.3;
        const parts = [];
        if (labelled) parts.push('label: qsTr("n' + n + '")');
        if (ignored) parts.push("Accessible.ignored: true");
        if (strDecoy) parts.push('onClicked: log("label: } { Accessible.ignored: true IconActionButton { ")');
        if (comDecoy && !oneLine) parts.push("// label: x } Accessible.ignored: true");
        if (nestedLabel) parts.push('contentItem: Item { label: "deep"; Accessible.ignored: true }');
        const block = "IconActionButton {" + (oneLine ? " " : "\n    ") + parts.join(oneLine ? "; " : "\n    ") + (oneLine ? " }" : "\n}");
        const decoys = '// IconActionButton { label: "c" }\nMyIconActionButton { }\nIconActionButtonX { }\nText { text: "IconActionButton { }" }\n';
        const r = scanInstances("Item {\n" + decoys + block + "\n}\n", "IconActionButton");
        assert.equal(r.length, 1, "step " + n + " found " + r.length + ": " + block);
        assert.equal(r[0].labelled, labelled, "labelled, step " + n + ": " + block);
        assert.equal(r[0].ignored, ignored, "ignored, step " + n + ": " + block);
        assert.equal(r[0].line, 6, "line, step " + n);
    }
    assert.throws(() => scanInstances("Item { IconActionButton { ", "IconActionButton"), /unbalanced/);
    assert.deepEqual(scanInstances("", "IconActionButton"), []);
});
