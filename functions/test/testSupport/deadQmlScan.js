"use strict";
// Picker v2 S5f. Which QML files does nothing use? A file is used when ANOTHER file under qml/ (comments stripped, so a mention in a comment
// does not count), or the app's C++ / CMake text, names its type as a whole word. A string like "Name.qml" counts as a use on purpose (a Loader
// source is a real user). Whole-word match: `AuthPrimaryButton` is not a use of `PrimaryButton`.
const fs = require("node:fs");
const path = require("node:path");
const { stripComments, qmlFiles } = require("./qmlButtonScan");

const word = (n) => new RegExp("\\b" + n.replace(/[^\w]/g, "") + "\\b");

function outsideText(root) {
    let s = "";
    for (const f of ["main.cpp", "CMakeLists.txt"]) if (fs.existsSync(path.join(root, f))) s += fs.readFileSync(path.join(root, f), "utf8") + "\n";
    const src = path.join(root, "src");
    const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        if (e.name === "3rdparty") continue;
        const p = path.join(d, e.name);
        if (e.isDirectory()) walk(p); else if (/\.(cpp|h|hpp|qrc)$/.test(e.name)) s += fs.readFileSync(p, "utf8") + "\n";
    } };
    if (fs.existsSync(src)) walk(src);
    return s;
}

// -> sorted list of root-relative paths of .qml files that no other file names.
function deadQmlFiles(root) {
    const files = qmlFiles(path.join(root, "qml"));
    const text = new Map(files.map((f) => [f, stripComments(fs.readFileSync(f, "utf8"))]));
    const outside = outsideText(root);
    const dead = [];
    for (const f of files) {
        const re = word(path.basename(f, ".qml"));
        const used = re.test(outside) || files.some((g) => g !== f && re.test(text.get(g)));
        if (!used) dead.push(path.relative(root, f).split(path.sep).join("/"));
    }
    return dead.sort();
}

module.exports = { deadQmlFiles, outsideText };
