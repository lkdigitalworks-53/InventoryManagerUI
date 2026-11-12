"use strict";

// Guard for the "QML file uses a JS helper namespace it never imported" bug class.
// Found in PR #183's device test: RestockDialog's Confirm button did nothing, because the file called
// `RestockFlow.costFromText(...)` without `import "../helper/RestockFlow.js" as RestockFlow`. The handler threw
// ReferenceError before `busy = true`, so there was no toast, no spinner and no close.
//
//   SCAN-*  the scanner itself (synthetic sources), so the guard cannot silently stop guarding
//   TREE-*  the real tree: every .qml file under qml/, tests/ and test/
//   RD-*    the Restock dialog specifically (the file that shipped the bug)

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { stripNonCode, jsImports, missingImports } = require("./testSupport/qmlImportScan");

const ROOT = path.join(__dirname, "..", "..");

function walk(dir, ext, out) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        if (e.name === "node_modules" || e.name.startsWith(".")) continue;
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p, ext, out);
        else if (e.name.endsWith(ext)) out.push(p);
    }
    return out;
}

const JS_FILES = walk(path.join(ROOT, "qml"), ".js", []);
const JS_NAMES = JS_FILES.map((f) => path.basename(f, ".js"));
const QML_FILES = ["qml", "tests", "test"]
    .filter((d) => fs.existsSync(path.join(ROOT, d)))
    .flatMap((d) => walk(path.join(ROOT, d), ".qml", []));
const rel = (f) => path.relative(ROOT, f).split(path.sep).join("/");

// ---------------------------------------------------------------- the scanner

test("SCAN-1 a helper used without an import is reported", () => {
    const src = 'import "../helper"\nItem { function f() { return RestockFlow.costFromText("1") } }';
    assert.deepEqual(missingImports(src, ["RestockFlow", "OrderMath"]), ["RestockFlow"]);
});

test("SCAN-2 a directory import does not count: only the named .js import does", () => {
    const src = 'import "../helper"\nItem { property var x: OrderMath.allocate }';
    assert.deepEqual(missingImports(src, ["OrderMath"]), ["OrderMath"]);
});

test("SCAN-3 the right import clears it", () => {
    const src = 'import "../helper/RestockFlow.js" as RestockFlow\nItem { function f() { return RestockFlow.costFromText("1") } }';
    assert.deepEqual(missingImports(src, ["RestockFlow"]), []);
});

test("SCAN-4 an import under another alias does not clear the name that is used", () => {
    const src = 'import "../helper/RestockFlow.js" as RF\nItem { function f() { return RestockFlow.costFromText("1") } }';
    assert.deepEqual(missingImports(src, ["RestockFlow"]), ["RestockFlow"]);
});

test("SCAN-5 a mention in a line comment, a block comment or a string is not a use", () => {
    const src = [
        "Item {",
        "    // RestockFlow.costFromText is called by the plan",
        "    /* OrderMath.allocate(x) in a block",
        "       comment */",
        '    property string a: "see RestockFlow.costFromText"',
        "    property string b: 'OrderMath.allocate'",
        "    property string c: `${1} RestockFlow.x`",
        "}"
    ].join("\n");
    assert.deepEqual(missingImports(src, ["RestockFlow", "OrderMath"]), []);
});

test("SCAN-6 a quote inside a comment or a // inside a string does not hide a real use", () => {
    const src = [
        "Item {",
        "    // don't break the scan",
        '    property string u: "http://example.com"',
        "    function f() { return RestockFlow.costFromText(\"1\") }",
        "}"
    ].join("\n");
    assert.deepEqual(missingImports(src, ["RestockFlow"]), ["RestockFlow"]);
});

test("SCAN-7 a name reached through another object is not a bare use", () => {
    const src = "Item { property var x: other.RestockFlow.y; property var z: myRestockFlow.y; property var w: RestockFlowX.y }";
    assert.deepEqual(missingImports(src, ["RestockFlow"]), []);
});

test("SCAN-8 a bare name without a member access is not a use", () => {
    assert.deepEqual(missingImports("Item { property var x: RestockFlow }", ["RestockFlow"]), []);
});

test("SCAN-9 several missing names come back sorted, each once", () => {
    const src = "Item { function f() { return Zeta.a() + Alpha.b() + Alpha.c() } }";
    assert.deepEqual(missingImports(src, ["Zeta", "Alpha", "Beta"]), ["Alpha", "Zeta"]);
});

test("SCAN-10 jsImports reads path and alias, ignores non-js imports and indented lines are accepted", () => {
    const src = 'import QtQuick\nimport "../helper"\n  import "../helper/StaffScope.js" as StaffScope\nimport "../helper/FailureCause.js" as FC';
    assert.deepEqual(jsImports(src), [
        { path: "../helper/StaffScope.js", alias: "StaffScope" },
        { path: "../helper/FailureCause.js", alias: "FC" }
    ]);
});

test("SCAN-11 stripNonCode keeps line count and length", () => {
    const src = 'a // x\n"b"\n/* c\nd */ e';
    const out = stripNonCode(src);
    assert.equal(out.length, src.length);
    assert.equal(out.split("\n").length, src.split("\n").length);
    assert.equal(out.trim().endsWith("e"), true);
});

test("SCAN-12 empty source and empty name list are safe", () => {
    assert.deepEqual(missingImports("", ["RestockFlow"]), []);
    assert.deepEqual(missingImports("Item { x: RestockFlow.y }", []), []);
});

// ---------------------------------------------------------------- the real tree

test("TREE-0 the scan sees the tree it is meant to guard", () => {
    assert.ok(JS_NAMES.includes("RestockFlow"), "RestockFlow.js not found under qml/");
    assert.ok(QML_FILES.some((f) => rel(f) === "qml/pages/RestockDialog.qml"), "RestockDialog.qml not scanned");
    assert.ok(QML_FILES.length > 100, "suspiciously few QML files: " + QML_FILES.length);
});

test("TREE-1 helper file names are unique, so a namespace means one file", () => {
    assert.equal(new Set(JS_NAMES).size, JS_NAMES.length, "duplicate helper basename: " + JS_NAMES.join(","));
});

test("TREE-2 no QML file uses a JS helper namespace it did not import", () => {
    const bad = [];
    for (const f of QML_FILES) {
        const miss = missingImports(fs.readFileSync(f, "utf8"), JS_NAMES);
        if (miss.length) bad.push(rel(f) + " uses " + miss.join(", ") + " without `import \"<path>/<Name>.js\" as <Name>`");
    }
    assert.deepEqual(bad, []);
});

test("TREE-3 every .js import in a QML file points at a file that exists", () => {
    const bad = [];
    for (const f of QML_FILES) {
        for (const i of jsImports(fs.readFileSync(f, "utf8"))) {
            if (!fs.existsSync(path.resolve(path.dirname(f), i.path))) bad.push(rel(f) + " imports missing " + i.path);
        }
    }
    assert.deepEqual(bad, []);
});

// ---------------------------------------------------------------- the Restock dialog

const DIALOG = fs.readFileSync(path.join(ROOT, "qml", "pages", "RestockDialog.qml"), "utf8");

test("RD-1 RestockDialog imports RestockFlow.js under the name it uses", () => {
    assert.ok(jsImports(DIALOG).some((i) => i.alias === "RestockFlow" && i.path === "../helper/RestockFlow.js"));
});

test("RD-2 RestockDialog uses RestockFlow only for functions and vars RestockFlow.js defines", () => {
    const code = stripNonCode(DIALOG);
    const used = [...code.matchAll(/(?<![\w.])RestockFlow\.([A-Za-z_$]\w*)/g)].map((m) => m[1]);
    assert.ok(used.length > 0, "dialog no longer uses RestockFlow: update this guard");
    const defined = new Set([...fs.readFileSync(path.join(ROOT, "qml", "helper", "RestockFlow.js"), "utf8")
        .matchAll(/^(?:function|var) ([A-Za-z_$]\w*)\b/gm)].map((m) => m[1]));   // R5a: the dialog also reads RestockFlow.MAX_* limits
    for (const fn of used) assert.ok(defined.has(fn), "RestockFlow." + fn + " is not defined in RestockFlow.js");
});

test("RD-3 the Confirm handler sets busy only after every name it needs is resolvable", () => {
    // A throw before `busy = true` is the silent failure; a throw after it would leave the sheet stuck busy.
    // The handler must not reference any other helper namespace that is missing an import.
    const at = DIALOG.indexOf("onPrimaryClicked:");
    assert.ok(at > 0, "onPrimaryClicked not found");
    const handler = DIALOG.slice(at);
    assert.deepEqual(missingImports(DIALOG, JS_NAMES), []);
    assert.ok(handler.indexOf("RestockFlow.costFromText") < handler.indexOf("busy = true"), "costFromText must run before busy = true so a bad cost cannot leave the sheet busy");
});
