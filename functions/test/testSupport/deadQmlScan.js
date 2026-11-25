"use strict";
// Picker v2 S5f. Which QML files does nothing live use? A name counts only as a whole word in code (comments stripped, so a mention in a comment
// does not count) of a file that is itself live (see deadQmlFiles). A string like "Name.qml" counts as a use on purpose (a Loader
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

// -> sorted list of root-relative paths of .qml files that are NOT reachable. A file is a ROOT when the app's C++ / CMake text names it
// (Main.qml, and every type C++ creates). A file is LIVE when a root, or another live file, names it. Reachability, not a bare "has a
// user" count: a file whose only user is a dead file is dead too (StatusBadge was used only by the dead OrderRow), and so is a dead cycle
// (A names B, B names A, nothing else names either). Whole-word and string matches stay conservative: a clash keeps a file alive.
function deadQmlFiles(root) {
    const files = qmlFiles(path.join(root, "qml"));
    const text = new Map(files.map((f) => [f, stripComments(fs.readFileSync(f, "utf8"))]));
    const re = new Map(files.map((f) => [f, word(path.basename(f, ".qml"))]));
    const outside = outsideText(root);
    const live = new Set(files.filter((f) => re.get(f).test(outside)));
    const todo = [...live];
    while (todo.length) {
        const t = text.get(todo.pop());
        for (const f of files) if (!live.has(f) && re.get(f).test(t)) { live.add(f); todo.push(f); }
    }
    return files.filter((f) => !live.has(f)).map((f) => path.relative(root, f).split(path.sep).join("/")).sort();
}

module.exports = { deadQmlFiles };
