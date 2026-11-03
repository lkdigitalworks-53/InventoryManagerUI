"use strict";

// Loads tests/pickerFixtures.js (shared with the QML twins) into Node, and gives the three assertion
// helpers the picker test bodies use. Bodies use ONLY eq, ok, noThrow and FX so that
// the QML twins can be derived from them mechanically (see pickerDormancy.test.js, PAIR-01).

const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const assert = require("node:assert/strict");

const FIXTURES = path.join(__dirname, "..", "..", "..", "tests", "pickerFixtures.js");

function loadFixtures() {
    const src = fs.readFileSync(FIXTURES, "utf8").replace(/^\.pragma library\s*$/m, "");
    const ctx = {};
    vm.runInNewContext(src, ctx);
    return ctx;
}

const FX = loadFixtures();
const eq = (actual, expected) => assert.equal(FX.canon(actual), FX.canon(expected));
const ok = (cond, msg) => assert.ok(cond, msg);
const noThrow = (fn) => assert.doesNotThrow(fn);

module.exports = { FX, eq, ok, noThrow };
