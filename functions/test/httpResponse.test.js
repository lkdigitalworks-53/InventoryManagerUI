"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { send } = require("../lib/httpResponse");

// Minimal Express `res` stand-in. `send()` only touches set/status/json/
// headersSent, so a plain object with those members exercises the exact
// same code path as a real response — same pattern the QML tests use for
// mocking XMLHttpRequest.
function makeRes({ jsonThrows = false } = {}) {
    const res = {
        headersSent: false,
        headers: {},
        statusCode: null,
        jsonCalls: [],
        set(key, value) { this.headers[key] = value; return this; },
        status(code) { this.statusCode = code; return this; },
        json(body) {
            this.jsonCalls.push({ status: this.statusCode, body });
            if (jsonThrows && this.jsonCalls.length === 1) {
                // Simulate JSON.stringify throwing on the FIRST call only,
                // so a fallback second call (the 500) can still succeed —
                // mirrors res.json() calling JSON.stringify() internally.
                throw new TypeError("Converting circular structure to JSON");
            }
            this.headersSent = true;
            return this;
        },
    };
    return res;
}

// ── Happy path ────────────────────────────────────────────────────────────

test("send sets CORS headers and forwards status/body on the normal path", () => {
    const res = makeRes();
    send(res, 409, { ok: false, error: "conflict", conflict: true, current: { stock: 5 } });
    assert.equal(res.headers["Access-Control-Allow-Origin"], "*");
    assert.equal(res.headers["Access-Control-Allow-Methods"], "POST, OPTIONS");
    assert.equal(res.headers["Access-Control-Allow-Headers"], "Authorization, Content-Type");
    assert.equal(res.jsonCalls.length, 1);
    assert.equal(res.jsonCalls[0].status, 409);
    assert.deepEqual(res.jsonCalls[0].body, { ok: false, error: "conflict", conflict: true, current: { stock: 5 } });
});

// ── The new try/catch (E2E testing phase 2 followup, 13th round) ───────────
// This behavior shipped in PR #45 with no direct test — only reachable via
// a live HTTPS round trip before this file existed. Regression review found
// the gap; these tests close it.

test("send falls back to a logged 500 when the body can't be serialized", () => {
    const res = makeRes({ jsonThrows: true });
    const circular = {};
    circular.self = circular; // JSON.stringify throws on this
    assert.doesNotThrow(() => send(res, 200, circular));
    assert.equal(res.jsonCalls.length, 2);
    assert.equal(res.jsonCalls[0].status, 200); // the attempted (failing) call
    assert.equal(res.jsonCalls[1].status, 500); // the fallback
    assert.deepEqual(res.jsonCalls[1].body, { ok: false, error: "response-serialization-failed" });
});

test("send does not attempt the fallback write if headers were already sent", () => {
    // If a real Express response had already started streaming before the
    // .json() call failed, writing again would throw ERR_HTTP_HEADERS_SENT.
    // headersSent must gate the fallback, not just "did json() throw".
    const res = makeRes({ jsonThrows: true });
    res.headersSent = true; // simulate a response already in flight
    assert.doesNotThrow(() => send(res, 200, {}));
    assert.equal(res.jsonCalls.length, 1); // only the failing attempt — no fallback write
});

test("send always sets CORS headers even when the body fails to serialize", () => {
    const res = makeRes({ jsonThrows: true });
    const circular = {};
    circular.self = circular;
    send(res, 200, circular);
    assert.equal(res.headers["Access-Control-Allow-Origin"], "*");
});
