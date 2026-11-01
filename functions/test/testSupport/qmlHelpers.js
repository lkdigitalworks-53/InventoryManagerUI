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

module.exports = { load, plain, HELPER_DIR };
