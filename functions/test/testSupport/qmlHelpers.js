"use strict";

// Loads a QML `.pragma library` helper (qml/helper/*.js) into Node so its REAL text runs, including
// its `.import "X.js" as Alias` lines (resolved to the other helpers' own contexts). Top-level
// functions and vars of the file become properties of the returned object. Values come from another
// realm: use `plain()` before a strict deepEqual.

const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const HELPER_DIR = path.join(__dirname, "..", "..", "..", "qml", "helper");
const cache = {};

function load(file) {
    if (cache[file]) return cache[file];
    let src = fs.readFileSync(path.join(HELPER_DIR, file), "utf8");
    if (!/^\.pragma library\s*$/m.test(src)) throw new Error(file + " is not a pragma library file");
    const ctx = {};
    src = src.replace(/^\.pragma library\s*$/m, "")
             .replace(/^\.import "([^"]+)" as (\w+)\s*$/gm, (m, f, alias) => { ctx[alias] = load(f); return ""; });
    vm.runInNewContext(src, ctx);
    cache[file] = ctx;
    return ctx;
}

const plain = (v) => JSON.parse(JSON.stringify(v));

// Source text of `function <name>(...) { ... }` from a QML file under qml/, by brace matching from the
// first "{" after the signature (fine for bodies with no brace inside a string or comment; the caller
// asserts what it needs from the result). Lets a test run the REAL body of a QML function in a sandbox.
function extractFunction(relPath, name) {
    const src = fs.readFileSync(path.join(HELPER_DIR, "..", relPath), "utf8");
    const at = src.indexOf("function " + name + "(");
    if (at < 0) throw new Error("function " + name + " not found in " + relPath);
    const open = src.indexOf("{", src.indexOf(")", at));
    let depth = 0, i = open;
    for (; i < src.length; i++) { if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) break; }
    return src.substring(at, i + 1);
}

module.exports = { load, plain, extractFunction, HELPER_DIR };
