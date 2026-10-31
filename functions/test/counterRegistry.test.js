"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const R = require("../lib/counterRegistry");

test("isKnownCounter: only registry keys, never inherited object names", () => {
    assert.equal(R.isKnownCounter("supplier"), true);
    assert.equal(R.isKnownCounter("stock_batch"), true);
    for (const bad of ["product", "order", "staff", "", "toString", "constructor", "__proto__", "hasOwnProperty", null, undefined, 5, {}])
        assert.equal(R.isKnownCounter(bad), false, String(bad));
});

test("yearFor: calendar year in Asia/Kolkata, boundaries on both sides of Jan 1 IST", () => {
    assert.equal(R.COUNTER_TIME_ZONE, "Asia/Kolkata");
    assert.equal(R.yearFor(new Date("2026-12-31T18:29:59Z")), "2026");   // 23:59:59 IST Dec 31
    assert.equal(R.yearFor(new Date("2026-12-31T18:30:00Z")), "2027");   // 00:00:00 IST Jan 1
    assert.equal(R.yearFor(new Date("2027-01-01T00:00:00Z")), "2027");
    assert.equal(R.yearFor(new Date("2026-06-15T12:00:00Z")), "2026");
});

test("describe: names, collections and prefixes per registry key and year", () => {
    assert.deepEqual(R.describe("supplier", "2026"),
        { key: "supplier", entity: "supplier", collection: "suppliers", counterName: "suppliers", prefix: "SUP-" });
    assert.deepEqual(R.describe("stock_batch", "2027"),
        { key: "stock_batch", entity: "stock_batch", collection: "stock_batches", counterName: "stockBatches-2027", prefix: "BAT-2027-" });
    assert.equal(R.describe("nope", "2026"), null);
    assert.equal(R.describe("constructor", "2026"), null);
});

test("formatId: 3-digit left pad, never truncates (same as String(n).padStart(3,'0') in QML)", () => {
    assert.equal(R.formatId("SUP-", 1), "SUP-001");
    assert.equal(R.formatId("SUP-", 12), "SUP-012");
    assert.equal(R.formatId("SUP-", 999), "SUP-999");
    assert.equal(R.formatId("SUP-", 1000), "SUP-1000");
    assert.equal(R.formatId("BAT-2026-", 7), "BAT-2026-007");
});

test("numberOf: exactly prefix + digits, numeric value, else null", () => {
    assert.equal(R.numberOf("SUP-", "SUP-007"), 7);
    assert.equal(R.numberOf("SUP-", "SUP-1000"), 1000);
    assert.equal(R.numberOf("BAT-2026-", "BAT-2026-012"), 12);
    for (const bad of ["SUP-", "SUP-12a", "SUP-1.5", "SUP--3", "SUP- 3", "sup-3", "PRD-003", "BAT-2025-003", "SUP-99999999999999999999", "", null, undefined, 3])
        assert.equal(R.numberOf("SUP-", bad), null, String(bad));
    assert.equal(R.numberOf("BAT-2026-", "BAT-2025-003"), null);   // other year is not this counter
});

test("maxNumber: numeric max over ids, 0 when none match", () => {
    assert.equal(R.maxNumber("SUP-", []), 0);
    assert.equal(R.maxNumber("SUP-", ["SUP-003", "SUP-010", "SUP-9"]), 10);
    assert.equal(R.maxNumber("SUP-", ["SUP-999", "SUP-1000"]), 1000);          // lexical order would say 999
    assert.equal(R.maxNumber("SUP-", ["junk", "SUP-x", "PRD-050"]), 0);
    assert.equal(R.maxNumber("BAT-2026-", ["BAT-2025-099", "BAT-2026-004"]), 4);
});

test("usableCount: whole numbers from 0 to MAX_COUNTER only", () => {
    for (const ok of [0, 1, 6, 1000, R.MAX_COUNTER]) assert.equal(R.usableCount(ok), true, String(ok));
    for (const bad of [-1, 3.5, NaN, Infinity, "5", "abc", null, undefined, {}, [], true, R.MAX_COUNTER + 1, 1e15, Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER + 1])
        assert.equal(R.usableCount(bad), false, String(bad));
});

test("MAX_COUNTER (M16): the ceiling is nine digits, a number above it is not a counter id, and the edge is exact", () => {
    assert.equal(R.MAX_COUNTER, 999999999);
    assert.equal(R.numberOf("SUP-", "SUP-999999999"), 999999999);          // the last id the server will use
    assert.equal(R.numberOf("SUP-", "SUP-1000000000"), null);              // one above
    assert.equal(R.numberOf("SUP-", "SUP-9007199254740991"), null);        // 2^53 - 1: used to parse, then n + 1 === n + 2 trouble
    assert.equal(R.numberOf("SUP-", "SUP-9007199254740993"), null);        // not even representable
    assert.equal(R.numberOf("SUP-", "SUP-" + "9".repeat(400)), null);      // parseInt gives Infinity, never a number
    assert.equal(R.maxNumber("SUP-", ["SUP-005", "SUP-9007199254740991", "SUP-1000000000"]), 5);   // junk above the ceiling cannot drag the seed up
});

test("round trip: formatId then numberOf gives the number back (monkey over 0..5000 and odd widths)", () => {
    for (let n = 0; n <= 5000; n += 7) assert.equal(R.numberOf("SUP-", R.formatId("SUP-", n)), n);
    for (const n of [99999, 123456789, R.MAX_COUNTER])
        assert.equal(R.numberOf("BAT-2026-", R.formatId("BAT-2026-", n)), n);
});

test("yearFor: refuses a formatter result that is not 4 digits instead of minting a wrong prefix", () => {
    const real = Intl.DateTimeFormat;
    Intl.DateTimeFormat = function () { return { format: () => "٢٠٢٦" }; };
    try { assert.throws(() => R.yearFor(new Date()), /unexpected year/); }
    finally { Intl.DateTimeFormat = real; }
    assert.equal(R.yearFor(new Date("2026-06-15T12:00:00Z")), "2026");
});
