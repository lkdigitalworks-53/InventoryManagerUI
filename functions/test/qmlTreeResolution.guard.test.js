"use strict";

// Second guard of the "name not in scope" bug class (PR #188 sweep; the first is qmlHelperImports.guard.test.js).
//   SC-*    the scanners (synthetic sources)
//   TR-1    helper .js -> helper .js: every namespace used is `.import`ed
//   TR-2    qml -> qml: every type or singleton from another directory has its `import "<dir>"`
//   TR-3    every `pragma Singleton` file is registered in its directory's qmldir
// Same silent failure as the Restock Confirm bug: an unresolved name loads fine and throws at its first use.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { jsDotImports, unresolvedNamespaces, dirImports, missingDirImports } = require("./testSupport/qmlImportScan");

const QML = path.join(__dirname, "..", "..", "qml");
const norm = (p) => path.normalize(p);
const resolve = (own, rel) => norm(path.join(own, rel));

function walk(dir, ext, out) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p, ext, out); else if (e.name.endsWith(ext)) out.push(p);
    }
    return out;
}
const rel = (f) => path.relative(path.join(QML, ".."), f).split(path.sep).join("/");

// ---------------------------------------------------------------- the scanners

test("SC-1 jsDotImports reads .import lines of a helper file only", () => {
    const src = '.pragma library\n.import "OperationKeys.js" as Keys\nimport "x.js" as NotMe\n  .import "A.js" as A';
    assert.deepEqual(jsDotImports(src), [{ path: "OperationKeys.js", alias: "Keys" }, { path: "A.js", alias: "A" }]);
});

test("SC-2 unresolvedNamespaces: used and not declared is reported; alias, own var/function, JS global, comment, string are not", () => {
    const src = '.import "OperationKeys.js" as Keys\n// B.x() in prose\nvar s = "C.y"\nvar Own = {}\nfunction Fn() {}\n' +
        'function f() { return Keys.a() + Own.b + Fn.c + Math.max(1, 2) + JSON.stringify({}) + D.d() + Number.isNaN(1) }';
    assert.deepEqual(unresolvedNamespaces(src), ["D"]);
});

test("SC-3 unresolvedNamespaces: an import under a different alias does not clear the name that is used; lower-case and obj.Name are ignored", () => {
    assert.deepEqual(unresolvedNamespaces('.import "A.js" as X\nfunction f() { return Keys.a() + x.y + obj.Keys.z }'), ["Keys"]);
});

test("SC-4 dirImports resolves directory imports and skips .js imports", () => {
    const src = 'import QtQuick\nimport "../model"\nimport "../helper/X.js" as X\nimport "../components" as C';
    assert.deepEqual(dirImports(src, "qml/pages", resolve), [norm("qml/model"), norm("qml/components")]);
});

test("SC-5 missingDirImports: another directory's type without its import is reported", () => {
    const types = { InventoryStore: ["qml/model"], Local: ["qml/pages"] };
    assert.deepEqual(missingDirImports("Item { function f() { InventoryStore.restock() } }", "qml/pages", types, []).map((m) => m.type), ["InventoryStore"]);
    assert.deepEqual(missingDirImports("Item { Local { } }", "qml/pages", types, []), [], "same directory is implicit");
    assert.deepEqual(missingDirImports("Item { InventoryStore { } }", "qml/pages", types, ["qml/model"]), [], "imported");
});

test("SC-6 missingDirImports: a mention in a comment, a string or via another object is not a use", () => {
    const types = { InventoryStore: ["qml/model"] };
    const src = 'Item {\n // InventoryStore.x\n property string a: "InventoryStore.y"\n property var b: other.InventoryStore.z\n}';
    assert.deepEqual(missingDirImports(src, "qml/pages", types, []), []);
});

// ---------------------------------------------------------------- the real tree

const JS_FILES = walk(path.join(QML, "helper"), ".js", []);
const JS_NAMES = JS_FILES.map((f) => path.basename(f, ".js"));

test("TR-0 the scan sees the tree", () => {
    assert.ok(JS_NAMES.includes("RestockFlow") && JS_NAMES.includes("OperationKeys"));
    assert.ok(walk(QML, ".qml", []).length > 100);
});

test("TR-1 every namespace a helper .js uses is a JS global, its own, or `.import`ed", () => {
    const bad = [];
    for (const f of JS_FILES) {
        const miss = unresolvedNamespaces(fs.readFileSync(f, "utf8"));
        if (miss.length) bad.push(rel(f) + " uses " + miss.join(", ") + " without `.import \"<File>.js\" as <Name>`");
    }
    assert.deepEqual(bad, []);
});

test("TR-2 every QML file imports the directory of each type or singleton it uses from elsewhere", () => {
    const files = walk(QML, ".qml", []);
    const typeDirs = {};
    for (const f of files) (typeDirs[path.basename(f, ".qml")] = typeDirs[path.basename(f, ".qml")] || []).push(norm(path.dirname(f)));
    const bad = [];
    for (const f of files) {
        const own = norm(path.dirname(f));
        const src = fs.readFileSync(f, "utf8");
        const types = Object.assign({}, typeDirs);
        delete types[path.basename(f, ".qml")];
        for (const m of missingDirImports(src, own, types, dirImports(src, own, resolve)))
            bad.push(rel(f) + " uses " + m.type + " (defined in " + m.dirs.map((d) => path.relative(path.join(QML, ".."), d)).join(", ") + ") without importing its directory");
    }
    assert.deepEqual(bad, []);
});

test("TR-3 every `pragma Singleton` file is registered in its directory's qmldir", () => {
    const bad = [];
    for (const f of walk(QML, ".qml", [])) {
        if (!/^pragma Singleton\s*$/m.test(fs.readFileSync(f, "utf8"))) continue;
        const qd = path.join(path.dirname(f), "qmldir");
        const name = path.basename(f, ".qml");
        if (!fs.existsSync(qd) || !new RegExp("^singleton\\s+" + name + "\\s", "m").test(fs.readFileSync(qd, "utf8")))
            bad.push(rel(f) + " is a singleton but is not listed in its qmldir");
    }
    assert.deepEqual(bad, []);
});
