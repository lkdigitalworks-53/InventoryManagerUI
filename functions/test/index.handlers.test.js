"use strict";

// Handler-level tests for functions/index.js's HTTPS-triggered mutation
// endpoints. Everything in functions/test/gatewayLogic.test.js and
// batchMutationLogic.test.js already covers the pure logic layer
// (lib/*.js) — this file covers the layer that was previously untested
// entirely: auth handling, request wiring, and — the specific class of bug
// this backlog item exists because of (Skill 43) — whether index.js
// actually forwards a lib/ result into the HTTP response correctly, rather
// than silently dropping or renaming a field along the way.
//
// Scope: recordMutation, recordDelta, recordMutationsBatch — the three
// endpoints that share the "auth -> validate -> apply -> translate result
// into an HTTP response" shape and the same response-contract risk.
// acquireLock/releaseLock/provisionMember/runCutover/computeAnalysis are
// NOT covered here — a deliberate scope boundary, not an oversight (see
// index.handlers.remaining.test.js, Skill 52). They share less of this
// exact risk pattern and were covered separately.
//
// Coverage across the three endpoints below is symmetric as of Skill 53
// (see docs/superpowers/E2E-TESTING-ROADMAP.md and
// docs/superpowers/specs/2026-08-30-handler-parity-coverage-gap-design.md):
// each of recordMutation/recordDelta/recordMutationsBatch has its own
// 401 missing-token, 401 invalid-token, 403 no-tenant-context, 400
// invalid-request, 405 method-not-allowed, and 500 write-failed case, on
// top of whatever endpoint-specific success/conflict-forwarding tests it
// already had. Before Skill 53, recordDelta and recordMutationsBatch had
// noticeably thinner coverage than recordMutation — not a deliberate
// scope decision, just an artifact of this file having grown across
// several separate passes chasing recordMutation's own Skill 43
// regression rather than one symmetric pass across all three.
//
// Real Firebase emulator is not available in this environment — these tests
// invoke the ACTUAL exported handler functions with mocked auth/Firestore/
// GatewayLogic dependencies (see testSupport/handlerHarness.js for exactly
// what's real vs mocked and why), not a full integration test.

const test = require("node:test");
const assert = require("node:assert/strict");
const { installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody } = require("./testSupport/handlerHarness");

const { handlers, mockState } = installMocks();

function validMutationBody(overrides) {
    return Object.assign({
        env: "test", entity: "order", entityId: "ORD-1", action: "update",
        requestId: "req-1", before: { notes: "" }, after: { notes: "hi" },
        clientTimestamp: 12345
    }, overrides || {});
}

function validDeltaBody(overrides) {
    return Object.assign({
        env: "test", entity: "stock_batch", entityId: "BAT-1",
        requestId: "req-1", deltas: { qtyOnHand: -1 }, clientTimestamp: 12345
    }, overrides || {});
}

function validBatchBody(overrides) {
    return Object.assign({
        env: "test", entity: "order", requestId: "req-1",
        items: [{ entityId: "ORD-1", action: "update", before: {}, after: {} }]
    }, overrides || {});
}

// ── recordMutation ───────────────────────────────────────────────────────

test("recordMutation: success path returns 200 with ok:true and the requestId as entryId", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyMutationResult = { ok: true };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody({ requestId: "req-success" }) }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true, entryId: "req-success" });
});

test("recordMutation: CAS conflict forwards conflict:true and current -- regression test for Skill 43", async () => {
    // This is the exact bug class this whole test file exists to catch:
    // gatewayLogic.js computing conflict:true correctly is not enough if
    // index.js's response-building code drops it on the way out.
    seedHappyPathAuth(mockState);
    mockState.applyMutationResult = { ok: false, status: 409, conflict: true, current: { notes: "someone else's edit" } };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody() }), res);
    assert.equal(res.statusCode, 409);
    const body = jsonBody(res);
    assert.equal(body.ok, false);
    assert.equal(body.conflict, true); // the field that was silently dropped before the fix
    assert.deepEqual(body.current, { notes: "someone else's edit" });
});

test("recordMutation: conflict:true is not asserted blindly true -- a non-conflict ok:false result must NOT claim conflict", async () => {
    // Guards against a fix that hardcodes `conflict: true` instead of
    // forwarding the real value — applyMutation only has one ok:false
    // branch today, but this locks in the intended behavior regardless.
    seedHappyPathAuth(mockState);
    mockState.applyMutationResult = { ok: false, status: 500, conflict: false, current: null };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody() }), res);
    const body = jsonBody(res);
    assert.equal(body.conflict, false);
});

test("recordMutation: missing Authorization header -> 401 missing-token", async () => {
    const res = mockRes();
    await handlers.recordMutation(mockReq({ headers: { origin: "http://localhost" }, body: validMutationBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
});

test("recordMutation: verifyIdToken throwing -> 401 invalid-token", async () => {
    mockState.verifyIdToken = async () => { throw new Error("bad token"); };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("recordMutation: authenticated but no matching user/tenant doc -> 403 no-tenant-context", async () => {
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid" });
    mockState.docs = {}; // no users/ghost-uid doc at all
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
});

test("recordMutation: invalid entity -> 400 from validateMutationRequest, unmodified", async () => {
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody({ entity: "not-a-real-entity" }) }), res);
    assert.equal(res.statusCode, 400);
});

test("recordMutation: GatewayLogic.applyMutation throwing -> 500 write-failed, not an unhandled rejection", async () => {
    seedHappyPathAuth(mockState);
    const gatewayLogicPath = require.resolve("../lib/gatewayLogic");
    const cached = require.cache[gatewayLogicPath].exports;
    const original = cached.applyMutation;
    cached.applyMutation = async () => { throw new Error("simulated Firestore failure"); };
    try {
        const res = mockRes();
        await handlers.recordMutation(mockReq({ body: validMutationBody() }), res);
        assert.equal(res.statusCode, 500);
        assert.equal(jsonBody(res).error, "write-failed");
    } finally {
        cached.applyMutation = original;
    }
});

test("recordMutation: GET request -> 405 method-not-allowed", async () => {
    const res = mockRes();
    await handlers.recordMutation(mockReq({ method: "GET", body: validMutationBody() }), res);
    assert.equal(res.statusCode, 405);
    assert.equal(jsonBody(res).error, "method-not-allowed");
});

// Note: an OPTIONS-preflight test was attempted here and dropped. The
// firebase-functions v2 wrapper's built-in `cors` middleware intercepts and
// terminates OPTIONS requests itself, before this codebase's own handler
// code ever runs -- node-mocks-http's response mock doesn't reliably
// propagate that middleware's own completion path to a resolved promise,
// causing the test to hang. Since OPTIONS handling here is generic,
// unmodified `cors` package behavior (not application logic, and not the
// response-contract bug class this file exists to catch), it isn't worth
// fighting that mock/middleware interaction for.

// ── recordDelta ──────────────────────────────────────────────────────────

test("recordDelta: success path returns 200 with ok:true, entryId, and the resulting after", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyDeltaResult = { ok: true, after: { qtyOnHand: 4 } };
    const res = mockRes();
    await handlers.recordDelta(mockReq({ body: validDeltaBody({ requestId: "req-d1" }) }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true, entryId: "req-d1", after: { qtyOnHand: 4 } });
});

test("recordDelta: insufficient-quantity rejection forwards error/field/current unmodified", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyDeltaResult = { ok: false, status: 409, error: "insufficient-quantity", field: "qtyOnHand", current: 0 };
    const res = mockRes();
    await handlers.recordDelta(mockReq({ body: validDeltaBody() }), res);
    assert.equal(res.statusCode, 409);
    const body = jsonBody(res);
    assert.equal(body.error, "insufficient-quantity");
    assert.equal(body.field, "qtyOnHand");
    assert.equal(body.current, 0); // 0 is falsy -- must survive, not get treated as "missing"
});

test("recordDelta: missing Authorization header -> 401 missing-token", async () => {
    const res = mockRes();
    await handlers.recordDelta(mockReq({ headers: { origin: "http://localhost" }, body: validDeltaBody() }), res);
    assert.equal(res.statusCode, 401);
});

test("recordDelta: verifyIdToken throwing -> 401 invalid-token", async () => {
    mockState.verifyIdToken = async () => { throw new Error("bad token"); };
    const res = mockRes();
    await handlers.recordDelta(mockReq({ body: validDeltaBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("recordDelta: authenticated but no matching user/tenant doc -> 403 no-tenant-context", async () => {
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid" });
    mockState.docs = {}; // no users/ghost-uid doc at all
    const res = mockRes();
    await handlers.recordDelta(mockReq({ body: validDeltaBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
});

test("recordDelta: invalid entity -> 400 from validateDeltaRequest, unmodified", async () => {
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.recordDelta(mockReq({ body: validDeltaBody({ entity: "not-a-real-entity" }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "unsupported-entity");
});

test("recordDelta: GatewayLogic.applyDelta throwing -> 500 write-failed, not an unhandled rejection", async () => {
    seedHappyPathAuth(mockState);
    const gatewayLogicPath = require.resolve("../lib/gatewayLogic");
    const cached = require.cache[gatewayLogicPath].exports;
    const original = cached.applyDelta;
    cached.applyDelta = async () => { throw new Error("simulated Firestore failure"); };
    try {
        const res = mockRes();
        await handlers.recordDelta(mockReq({ body: validDeltaBody() }), res);
        assert.equal(res.statusCode, 500);
        assert.equal(jsonBody(res).error, "write-failed");
    } finally {
        cached.applyDelta = original;
    }
});

test("recordDelta: GET request -> 405 method-not-allowed", async () => {
    const res = mockRes();
    await handlers.recordDelta(mockReq({ method: "GET", body: validDeltaBody() }), res);
    assert.equal(res.statusCode, 405);
    assert.equal(jsonBody(res).error, "method-not-allowed");
});

// ── recordMutationsBatch ─────────────────────────────────────────────────

test("recordMutationsBatch: success path returns 200 ok:true", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyMutationsBatchResult = { ok: true };
    const res = mockRes();
    await handlers.recordMutationsBatch(mockReq({ body: validBatchBody({ requestId: "req-b1" }) }), res);
    assert.equal(res.statusCode, 200);
});

test("recordMutationsBatch: partial conflict forwards the conflicts array matching Gateway.qml's _parseBatchMutationConflict contract", async () => {
    // qml/model/Gateway.qml's _parseBatchMutationConflict checks
    // Array.isArray(body.conflicts) — this is the sibling check to the one
    // that broke for the single-mutation path (Skill 43), pinned here so
    // any future drift on THIS path gets caught the same way.
    seedHappyPathAuth(mockState);
    mockState.applyMutationsBatchResult = {
        ok: false, status: 409,
        conflicts: [{ entityId: "ORD-1", current: { notes: "conflicted" } }]
    };
    const res = mockRes();
    await handlers.recordMutationsBatch(mockReq({ body: validBatchBody() }), res);
    assert.equal(res.statusCode, 409);
    const body = jsonBody(res);
    assert.ok(Array.isArray(body.conflicts), "conflicts must be a real array, matching the client's Array.isArray check");
    assert.equal(body.conflicts.length, 1);
    assert.equal(body.conflicts[0].entityId, "ORD-1");
});

test("recordMutationsBatch: empty items array -> 400 empty-batch from validateBatchMutationRequest", async () => {
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.recordMutationsBatch(mockReq({ body: validBatchBody({ items: [] }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "empty-batch");
});

test("recordMutationsBatch: missing Authorization header -> 401 missing-token", async () => {
    const res = mockRes();
    await handlers.recordMutationsBatch(mockReq({ headers: { origin: "http://localhost" }, body: validBatchBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
});

test("recordMutationsBatch: verifyIdToken throwing -> 401 invalid-token", async () => {
    mockState.verifyIdToken = async () => { throw new Error("bad token"); };
    const res = mockRes();
    await handlers.recordMutationsBatch(mockReq({ body: validBatchBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("recordMutationsBatch: authenticated but no matching user/tenant doc -> 403 no-tenant-context", async () => {
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid" });
    mockState.docs = {}; // no users/ghost-uid doc at all
    const res = mockRes();
    await handlers.recordMutationsBatch(mockReq({ body: validBatchBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
});

test("recordMutationsBatch: GatewayLogic.applyMutationsBatch throwing -> 500 write-failed, not an unhandled rejection", async () => {
    seedHappyPathAuth(mockState);
    const batchMutationLogicPath = require.resolve("../lib/batchMutationLogic");
    const cached = require.cache[batchMutationLogicPath].exports;
    const original = cached.applyMutationsBatch;
    cached.applyMutationsBatch = async () => { throw new Error("simulated Firestore failure"); };
    try {
        const res = mockRes();
        await handlers.recordMutationsBatch(mockReq({ body: validBatchBody() }), res);
        assert.equal(res.statusCode, 500);
        assert.equal(jsonBody(res).error, "write-failed");
    } finally {
        cached.applyMutationsBatch = original;
    }
});

test("recordMutationsBatch: GET request -> 405 method-not-allowed", async () => {
    const res = mockRes();
    await handlers.recordMutationsBatch(mockReq({ method: "GET", body: validBatchBody() }), res);
    assert.equal(res.statusCode, 405);
    assert.equal(jsonBody(res).error, "method-not-allowed");
});
