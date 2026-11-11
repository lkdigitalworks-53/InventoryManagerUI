"use strict";

// QML's JavaScript engine refuses some words as names that Node accepts. `var long = ...` in tests/tst_RestockFlow.qml
// made the WHOLE file fail to compile ("Expected token `identifier'", PR #191): none of its tests ran and the QML job went
// red. Node cannot see that, so this reads every QML and helper file and fails on a declaration that uses such a word.
//
// The list is the ECMAScript keywords plus the ES3 "future reserved words" (long, int, float, ...) and the strict-mode ones
// (let, static, ...). Today the tree has no use of any of them, so the guard cannot cry wolf; if a word on the list is ever
// proven fine in QML, delete it from the list with the proof in the commit message.
//
//   Q-1  the scanner finds a variable, a function name, a parameter and a QML property named like a reserved word
//   Q-2  the scanner ignores comments and strings
//   Q-3  no file under qml/ or tests/ declares such a name

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..", "..");

const RESERVED = new Set([
    // ECMAScript keywords
    "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export",
    "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null", "return", "super",
    "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with",
    // ES3 future reserved words (QML's engine refuses `long`; the rest of that family is kept for the same reason)
    "abstract", "boolean", "byte", "char", "double", "final", "float", "goto", "int", "long", "native", "short",
    "synchronized", "throws", "transient", "volatile",
    // strict-mode reserved words
    "implements", "interface", "let", "package", "private", "protected", "public", "static", "yield",
]);

// Comments and string literals out (same length is not needed: only the declarations matter). A regex literal that holds a
// quote is rare in this tree; if one ever confuses the scan the failure shows the word and file, never a silent pass.
function stripNonCode(src) {
    return src
        .replace(/\/\*[\s\S]*?\*\//g, " ")
        .replace(/"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'/g, '""')
        .replace(/\/\/[^\n]*/g, " ");
}

// -> [{ word, kind }] for every declared name that is a reserved word.
function reservedDeclarations(src) {
    const code = stripNonCode(src);
    const hits = [];
    const add = (name, kind) => { if (name && RESERVED.has(name)) hits.push({ word: name, kind }); };
    for (const m of code.matchAll(/\b(?:var|let|const)\s+([A-Za-z_$][\w$]*)/g)) add(m[1], "variable");
    for (const m of code.matchAll(/\bfunction\s*([A-Za-z_$][\w$]*)?\s*\(([^)]*)\)/g)) {
        add(m[1], "function name");
        for (const p of m[2].split(",")) add(p.trim().split(/[\s=]/)[0], "parameter");
    }
    for (const m of code.matchAll(/\bproperty\s+(?:alias\s+|var\s+)?(?:[\w.<>]+\s+)?([A-Za-z_$][\w$]*)\s*[:\n]/g)) add(m[1], "QML property");
    return hits;
}

function qmlAndJsFiles(dir) {
    const out = [];
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, e.name);
        if (e.isDirectory()) out.push(...qmlAndJsFiles(full));
        else if (/\.(qml|js)$/.test(e.name)) out.push(full);
    }
    return out;
}

test("Q-1 the scanner finds a variable, a function name, a parameter and a QML property that is a reserved word", () => {
    assert.deepEqual(reservedDeclarations('var long = "L".repeat(150)'), [{ word: "long", kind: "variable" }]);
    assert.deepEqual(reservedDeclarations("let int = 1; const float = 2"), [{ word: "int", kind: "variable" }, { word: "float", kind: "variable" }]);
    assert.deepEqual(reservedDeclarations("function short(a) { return a }"), [{ word: "short", kind: "function name" }]);
    assert.deepEqual(reservedDeclarations("function f(a, final, b = 2) {}"), [{ word: "final", kind: "parameter" }]);
    assert.deepEqual(reservedDeclarations("var f = function(volatile) {}"), [{ word: "volatile", kind: "parameter" }]);
    assert.deepEqual(reservedDeclarations("property int long: 5"), [{ word: "long", kind: "QML property" }]);
});

test("Q-2 the scanner ignores comments and strings, and normal names", () => {
    assert.deepEqual(reservedDeclarations("// var long = 1\n/* var int = 2 */\nvar s = \"var float = 3\"\nvar longName = 1, interval = 2"), []);
    assert.deepEqual(reservedDeclarations("function longer(shorty, integer) {}\nproperty int interval: 1"), []);
});

test("Q-3 no QML or helper file declares a name that QML's JavaScript engine refuses", () => {
    const files = [...qmlAndJsFiles(path.join(ROOT, "qml")), ...qmlAndJsFiles(path.join(ROOT, "tests"))];
    assert.ok(files.length > 100, "found only " + files.length + " files: the scan root is wrong");
    const bad = [];
    for (const f of files)
        for (const h of reservedDeclarations(fs.readFileSync(f, "utf8"))) bad.push(path.relative(ROOT, f) + ": " + h.kind + " `" + h.word + "`");
    assert.deepEqual(bad, [], "reserved word used as a name (the file will not compile in QML):\n" + bad.join("\n"));
});
