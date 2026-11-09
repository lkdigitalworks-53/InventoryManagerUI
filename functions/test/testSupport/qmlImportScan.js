"use strict";

// Static scan of one QML file for the "JS helper used without an import" bug class.
//
// Why it exists: qml/helper/qmldir lists only three singletons, so `import "../helper"` does NOT expose the
// helper .js files. A file must name each one: `import "../helper/RestockFlow.js" as RestockFlow`. When the
// line is missing, `RestockFlow.x()` is an unresolved name that throws ReferenceError at the first call. In a
// click handler that is a silent no-op (PR #183 review sweep, RestockDialog Confirm button). Nothing at load
// time reports it, and dialogs that import the Felgo chain cannot be loaded under qmltestrunner, so a Node
// text scan is the only check that sees every file.

// Replaces comments and string/template literals with spaces (newlines kept) so a helper name that only
// appears in prose or in a message text is not counted as a use. One alternation, scanned left to right,
// so a `//` inside a string and a quote inside a comment are both handled.
function stripNonCode(src) {
    return src.replace(
        /\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`/g,
        (m) => m.replace(/[^\n]/g, " "));
}

// `import "<path>.js" as <Alias>` lines, read from the RAW text (the path is a string literal).
// -> [{ path, alias }]
function jsImports(src) {
    const out = [];
    const re = /^[ \t]*import[ \t]+"([^"\n]+\.js)"[ \t]+as[ \t]+([A-Za-z_]\w*)/gm;
    let m;
    while ((m = re.exec(src)) !== null) out.push({ path: m[1], alias: m[2] });
    return out;
}

// Names (from `jsNames`, the basenames of the helper files) that the code uses as a namespace
// (`Name.member`) but that are not imported under that same alias. A name reached through another object
// (`obj.Name.x`) is not a bare use and is ignored.
// -> sorted array of names
function missingImports(src, jsNames) {
    const have = new Set(jsImports(src).map((i) => i.alias));
    const code = stripNonCode(src);
    const missing = [];
    for (const name of jsNames) {
        if (have.has(name)) continue;
        if (new RegExp("(?<![\\w.])" + name + "\\.(?=[A-Za-z_$])").test(code)) missing.push(name);
    }
    return missing.sort();
}

// Review (PR #188 sweep): the same bug class one layer down and sideways.
//   .js -> .js   a pragma-library helper reaches another helper only through `.import "X.js" as X`.
//   qml -> qml   a type or singleton from ANOTHER directory needs `import "<dir>"`; the same directory is implicit.

// `.import "<path>.js" as <Alias>` lines of a helper .js file. -> [{ path, alias }]
function jsDotImports(src) {
    const out = [];
    const re = /^[ \t]*\.import[ \t]+"([^"\n]+\.js)"[ \t]+as[ \t]+([A-Za-z_]\w*)/gm;
    let m;
    while ((m = re.exec(src)) !== null) out.push({ path: m[1], alias: m[2] });
    return out;
}

// Capitalised names a helper .js uses as a namespace (`Name.member`) that nothing in the file declares: not a JS
// global, not a `var`/`function` of the file, not an `.import ... as Name` alias. Looking at the alias, not at the
// file's basename, because helpers import under short aliases (`.import "OperationKeys.js" as Keys`).
// -> sorted array of names
const JS_GLOBALS = new Set(["Math", "JSON", "Object", "Number", "String", "Array", "Date", "Error", "TypeError", "RangeError",
    "RegExp", "Boolean", "Promise", "Symbol", "Map", "Set", "Intl", "Reflect", "Qt", "XMLHttpRequest", "Infinity", "NaN"]);
function unresolvedNamespaces(src) {
    const aliases = new Set(jsDotImports(src).map((i) => i.alias));
    const code = stripNonCode(src);
    const declared = new Set([...code.matchAll(/\b(?:var|let|const|function)\s+([A-Za-z_$][\w$]*)/g)].map((m) => m[1]));
    const used = new Set([...code.matchAll(/(?<![\w.$])([A-Z][A-Za-z0-9_]*)\.(?=[A-Za-z_$])/g)].map((m) => m[1]));
    return [...used].filter((n) => !JS_GLOBALS.has(n) && !aliases.has(n) && !declared.has(n)).sort();
}

// Directory imports (`import "../model"`, not .js) of a QML file, resolved to normalised paths relative to `ownDir`.
function dirImports(src, ownDir, resolve) {
    const out = [];
    const re = /^[ \t]*import[ \t]+"([^"\n]+)"[ \t]*(?:as[ \t]+\w+)?[ \t]*$/gm;
    let m;
    while ((m = re.exec(src)) !== null) if (!m[1].endsWith(".js")) out.push(resolve(ownDir, m[1]));
    return out;
}

// Type names used in `src` (as `Name {` or `Name.`) that are defined only in OTHER directories than `ownDir`
// and whose directory is not imported. `typeDirs` = { TypeName: [dir, ...] }. -> sorted [{ type, dirs }]
function missingDirImports(src, ownDir, typeDirs, imported) {
    const code = stripNonCode(src);
    const out = [];
    for (const name of Object.keys(typeDirs)) {
        const dirs = typeDirs[name];
        if (dirs.includes(ownDir)) continue;
        if (!new RegExp("(?<![\\w.])" + name + "\\s*[{.]").test(code)) continue;
        if (dirs.some((d) => imported.includes(d))) continue;
        out.push({ type: name, dirs });
    }
    return out.sort((a, b) => (a.type < b.type ? -1 : 1));
}

module.exports = { stripNonCode, jsImports, missingImports, jsDotImports, unresolvedNamespaces, dirImports, missingDirImports };
