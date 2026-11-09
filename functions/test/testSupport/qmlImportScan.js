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

module.exports = { stripNonCode, jsImports, missingImports };
