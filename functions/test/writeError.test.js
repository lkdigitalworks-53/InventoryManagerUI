"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { classifyWriteError, REJECTED, UNAVAILABLE, UNKNOWN } = require("../lib/writeError");

const TERMINAL_NUM = [3, 5, 6, 7, 9];
const TERMINAL_STR = ["invalid-argument", "not-found", "already-exists", "permission-denied", "failed-precondition"];
const TRANSIENT_NUM = [4, 8, 10, 13, 14];
const TRANSIENT_STR = ["deadline-exceeded", "resource-exhausted", "aborted", "internal", "unavailable"];

test("the three result strings are the wire contract the client reads", () => {
    assert.equal(REJECTED, "write-rejected");
    assert.equal(UNAVAILABLE, "write-unavailable");
    assert.equal(UNKNOWN, "write-failed");
});

test("every terminal gRPC code (numeric and string) -> write-rejected", () => {
    for (const code of [...TERMINAL_NUM, ...TERMINAL_STR])
        assert.equal(classifyWriteError({ code }), REJECTED, String(code));
});

test("every transient gRPC code (numeric and string) -> write-unavailable", () => {
    for (const code of [...TRANSIENT_NUM, ...TRANSIENT_STR])
        assert.equal(classifyWriteError({ code }), UNAVAILABLE, String(code));
});

test("unmapped gRPC codes (cancelled, unknown, out-of-range, data-loss, unauthenticated) -> write-failed", () => {
    for (const code of [0, 1, 2, 11, 12, 15, 16, 17, -1, "cancelled", "unknown", "out-of-range", "data-loss", "unauthenticated"])
        assert.equal(classifyWriteError({ code }), UNKNOWN, String(code));
});

test("a plain Error, or one with a non-Firestore code, -> write-failed", () => {
    assert.equal(classifyWriteError(new Error("boom")), UNKNOWN);
    assert.equal(classifyWriteError(Object.assign(new Error("x"), { code: "ECONNRESET" })), UNKNOWN);
});

test("null, undefined, primitives and code-less objects never throw -> write-failed", () => {
    for (const v of [null, undefined, 0, 7, "permission-denied", true, {}, [], { code: null }, { code: undefined }, { code: {} }])
        assert.equal(classifyWriteError(v), UNKNOWN, JSON.stringify(v));
});

test("a numeric code given as a string is NOT coerced (\"7\" is not 7)", () => {
    assert.equal(classifyWriteError({ code: "7" }), UNKNOWN);
});

test("terminal and transient sets are disjoint and every result is one of the three strings", () => {
    for (const t of [...TERMINAL_NUM, ...TERMINAL_STR])
        assert.ok(![...TRANSIENT_NUM, ...TRANSIENT_STR].includes(t), String(t));
    let seed = 42;
    const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
    const pool = [...TERMINAL_NUM, ...TERMINAL_STR, ...TRANSIENT_NUM, ...TRANSIENT_STR, 99, "x", null, undefined, NaN, {}];
    for (let i = 0; i < 500; i++) {
        const code = pool[Math.floor(rnd() * pool.length)];
        const out = classifyWriteError(rnd() < 0.1 ? code : { code });
        assert.ok([REJECTED, UNAVAILABLE, UNKNOWN].includes(out));
    }
});
