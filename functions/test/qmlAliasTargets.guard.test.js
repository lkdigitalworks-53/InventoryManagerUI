"use strict";

// Guard for the "QML name that does not exist, fatal at load" bug class (PR #191 review pass 4, Android launch crash).
// AuthTextField.qml had `property alias maxLength: input.maxLength`. `input` is a QQC.TextField, whose property is
// `maximumLength` (`maxLength` is QLineEdit). An alias to a missing property is a COMPILE error: AuthTextField.qml did not
// load, so neither did LoginPage or Main.qml, and the app exited at launch on a device. No test saw it: Felgo components
// cannot be loaded under qmltestrunner, and the old G-5 test pinned the wrong name.
//
//   AS-*  the alias scanner (synthetic sources)
//   AL-*  the real tree: every `property alias` points at a (type, property) pair checked against the Qt docs
//   IM-*  every `import "<path>"` / `.import "<path>"` resolves with EXACT letter case (Android is case-sensitive; the
//         Windows and macOS dev machines are not, so a wrong-case path runs there and fails only on the phone)

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { stripNonCode } = require("./testSupport/qmlImportScan");

const QML = path.join(__dirname, "..", "..", "qml");
const rel = (f) => path.relative(path.join(QML, ".."), f).split(path.sep).join("/");

function walk(dir, ext, out) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p, ext, out); else if (e.name.endsWith(ext)) out.push(p);
    }
    return out;
}

// (type -> properties) an alias may target. Each pair was checked against the Qt docs. A NEW alias to a pair that is not
// here fails AL-1: look the property up in the docs for that type first, then add it. `data` is the default property of
// Item and of the layouts.
const ALIAS_OK = {
    "QQC.TextField": ["text", "placeholderText", "echoMode", "inputMethodHints", "readOnly", "maximumLength", "acceptableInput"],
    "Image": ["source", "status"],
    "Text": ["text"],
    "Item": ["data"],
    "ColumnLayout": ["data"],
    "RowLayout": ["data"],
    "Connections": ["target"],
    "Repeater": ["model"]
};

// -> [{ name, target, id, prop, type }] for each `property alias name: id.prop` (or `: id`, then prop is "").
// `type` is the type of the object that declares `id:` in the same file, or "" if none is found.
function aliases(src) {
    const code = stripNonCode(src);
    const out = [];
    const re = /property\s+alias\s+(\w+)\s*:\s*([\w.]+)/g;
    let m;
    while ((m = re.exec(code)) !== null) {
        const [id, ...rest] = m[2].split(".");
        const decl = new RegExp("([A-Z][\\w.]*)\\s*\\{[^{}]*?\\bid:\\s*" + id + "\\b").exec(code);
        out.push({ name: m[1], target: m[2], id, prop: rest.join("."), type: decl ? decl[1] : "" });
    }
    return out;
}

// An alias of one id to another object (no property) is always fine; an alias to `id.prop` needs the pair in ALIAS_OK.
function badAliases(src) {
    return aliases(src).filter((a) => a.prop !== "" && !(ALIAS_OK[a.type] || []).includes(a.prop));
}

// Resolves `rel` against `fromDir` and returns the real path only when EVERY segment has the exact case on disk, else null.
function resolveExact(fromDir, relPath) {
    let cur = path.resolve(fromDir);
    for (const seg of relPath.split("/")) {
        if (seg === "" || seg === ".") continue;
        if (seg === "..") { cur = path.dirname(cur); continue; }
        let names;
        try { names = fs.readdirSync(cur); } catch (e) { return null; }
        if (!names.includes(seg)) return null;
        cur = path.join(cur, seg);
    }
    return cur;
}

// ---------------------------------------------------------------- the scanner

test("AS-1 an alias of an id's property is read with the type that declares the id", () => {
    const src = "Item {\n QQC.TextField {\n  id: input\n }\n property alias maxLength: input.maxLength\n}";
    assert.deepEqual(aliases(src).map((a) => [a.name, a.id, a.prop, a.type]), [["maxLength", "input", "maxLength", "QQC.TextField"]]);
});

test("AS-2 the bug of this guard: QQC.TextField has no maxLength, it has maximumLength", () => {
    const wrong = "Item {\n QQC.TextField { id: input }\n property alias maxLength: input.maxLength\n}";
    const right = "Item {\n QQC.TextField { id: input }\n property alias maximumLength: input.maximumLength\n}";
    assert.equal(badAliases(wrong).length, 1);
    assert.equal(badAliases(right).length, 0);
});

test("AS-3 an alias of a whole object has no property to check", () => {
    const src = "Item {\n QQC.TextField { id: input }\n property alias inputItem: input\n}";
    assert.equal(badAliases(src).length, 0);
});

test("AS-4 an id that is declared nowhere, or a type not in the table, is reported", () => {
    assert.equal(badAliases("Item { property alias a: ghost.text }").length, 1);
    assert.equal(badAliases("Item {\n Rectangle { id: r }\n property alias c: r.color\n}").length, 1);
});

test("AS-5 an alias in a comment or a string is not an alias", () => {
    const src = 'Item {\n // property alias a: ghost.text\n property string s: "property alias b: ghost.text"\n}';
    assert.deepEqual(aliases(src), []);
});

test("AS-6 resolveExact: the right case resolves, a wrong case in any segment does not, a missing file does not", () => {
    const pages = path.join(QML, "pages");
    assert.ok(resolveExact(pages, "../helper/RestockFlow.js"));
    assert.ok(resolveExact(pages, "../components"));
    assert.equal(resolveExact(pages, "../helper/restockflow.js"), null);
    assert.equal(resolveExact(pages, "../Helper/RestockFlow.js"), null);
    assert.equal(resolveExact(pages, "../helper/NoSuchFile.js"), null);
});

// ---------------------------------------------------------------- the real tree

const QML_FILES = walk(QML, ".qml", []);
const JS_FILES = walk(QML, ".js", []);

test("AL-0 the scan sees the tree and finds the aliases", () => {
    assert.ok(QML_FILES.length > 100);
    const n = QML_FILES.reduce((s, f) => s + aliases(fs.readFileSync(f, "utf8")).length, 0);
    assert.ok(n >= 20, "found only " + n + " aliases");
});

test("AL-1 every `property alias x: id.prop` targets a (type, property) pair that is checked against the Qt docs", () => {
    const bad = [];
    for (const f of QML_FILES) {
        for (const a of badAliases(fs.readFileSync(f, "utf8"))) {
            bad.push(rel(f) + ": alias " + a.name + " -> " + a.target + " (type " + (a.type || "not found") + ")");
        }
    }
    assert.deepEqual(bad, [], "an alias to a property the type does not have fails the file at load. Check the Qt docs, then add the pair to ALIAS_OK");
});

test("AL-2 no QML file declares or sets `maxLength` (QLineEdit's name): QML spells it maximumLength", () => {
    const bad = QML_FILES.filter((f) => /\bmaxLength\b/.test(stripNonCode(fs.readFileSync(f, "utf8")))).map(rel);
    assert.deepEqual(bad, []);
});

test("AL-3 AuthTextField (used by LoginPage and the restock dialog) forwards maximumLength to its TextField", () => {
    const src = fs.readFileSync(path.join(QML, "components", "AuthTextField.qml"), "utf8");
    assert.match(src, /property alias maximumLength:\s*input\.maximumLength/);
});

test("IM-1 every import path in qml/ resolves with exact letter case", () => {
    const bad = [];
    for (const f of [...QML_FILES, ...JS_FILES]) {
        const lines = fs.readFileSync(f, "utf8").split("\n");
        lines.forEach((l, i) => {
            const m = /^\s*\.?import\s+"([^"]+)"/.exec(l);
            if (m && resolveExact(path.dirname(f), m[1]) === null) bad.push(rel(f) + ":" + (i + 1) + " " + m[1]);
        });
    }
    assert.deepEqual(bad, []);
});
