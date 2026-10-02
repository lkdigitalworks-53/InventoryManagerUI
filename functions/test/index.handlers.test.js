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

test("recordMutation: staff delete refused for a non-owner/admin role -> 403 role-not-allowed", async () => {
    // Security-weight check added 2026-09-21 (DELETE-FEATURE-ROADMAP item 2):
    // staff delete can cascade-revoke a teammate's login
    // (AuthService.cleanupStaffAuthDocs), and the client-side
    // DataModel.onDeleteStaff role check is not a trust boundary by itself
    // -- anyone with a valid ID token could otherwise call this endpoint
    // directly. Scoped to staff/delete only, see functions/index.js.
    seedHappyPathAuth(mockState, { role: "manager" });
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody({ entity: "staff", entityId: "S-1", action: "delete" }) }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "role-not-allowed");
});

test("recordMutation: staff delete succeeds for an admin role", async () => {
    seedHappyPathAuth(mockState, { role: "admin" });
    mockState.applyMutationResult = { ok: true };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody({ entity: "staff", entityId: "S-1", action: "delete" }) }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(jsonBody(res).ok, true);
});

test("recordMutation: staff delete succeeds for the owner role", async () => {
    seedHappyPathAuth(mockState, { role: "owner" });
    mockState.applyMutationResult = { ok: true };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody({ entity: "staff", entityId: "S-1", action: "delete" }) }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(jsonBody(res).ok, true);
});

test("recordMutation: the staff role check is scoped to staff/delete -- a staff UPDATE by a non-owner/admin is unaffected", async () => {
    // Guards against a fix that accidentally blocks all staff mutations
    // instead of only delete.
    seedHappyPathAuth(mockState, { role: "manager" });
    mockState.applyMutationResult = { ok: true };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody({ entity: "staff", entityId: "S-1", action: "update" }) }), res);
    assert.equal(res.statusCode, 200);
});

test("recordMutation: the staff role check is scoped to staff/delete -- an ORDER delete by a non-owner/admin is unaffected", async () => {
    // Guards against a fix that accidentally blocks delete for every
    // entity instead of only staff.
    seedHappyPathAuth(mockState, { role: "manager" });
    mockState.applyMutationResult = { ok: true };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody({ entity: "order", entityId: "ORD-1", action: "delete" }) }), res);
    assert.equal(res.statusCode, 200);
});

test("recordMutation: removed_staff tombstone create refused for a non-owner/admin role -> 403 role-not-allowed", async () => {
    // The tombstone is written only as part of a staff delete, so it carries
    // the same owner/admin restriction (see functions/index.js).
    seedHappyPathAuth(mockState, { role: "manager" });
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody({ entity: "removed_staff", entityId: "S-1", action: "create", before: null, after: { staffId: "S-1", name: "Ravi" } }) }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "role-not-allowed");
});

test("recordMutation: removed_staff tombstone create refused for the staff role", async () => {
    seedHappyPathAuth(mockState, { role: "staff" });
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody({ entity: "removed_staff", entityId: "S-1", action: "create", before: null, after: { staffId: "S-1", name: "Ravi" } }) }), res);
    assert.equal(res.statusCode, 403);
});

test("recordMutation: removed_staff tombstone create succeeds for admin and owner", async () => {
    for (const role of ["admin", "owner"]) {
        seedHappyPathAuth(mockState, { role: role });
        mockState.applyMutationResult = { ok: true };
        const res = mockRes();
        await handlers.recordMutation(mockReq({ body: validMutationBody({ entity: "removed_staff", entityId: "S-1", action: "create", before: null, after: { staffId: "S-1", name: "Ravi" } }) }), res);
        assert.equal(res.statusCode, 200, role);
        assert.equal(jsonBody(res).ok, true, role);
    }
});

test("recordMutation: a tombstone re-create for an id that already has one surfaces as a 409 conflict (first name wins, never overwritten)", async () => {
    seedHappyPathAuth(mockState, { role: "admin" });
    mockState.applyMutationResult = { ok: false, status: 409, conflict: true, current: { staffId: "S-1", name: "Ravi" } };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: validMutationBody({ entity: "removed_staff", entityId: "S-1", action: "create", before: null, after: { staffId: "S-1", name: "Someone Else" } }) }), res);
    assert.equal(res.statusCode, 409);
    assert.equal(jsonBody(res).conflict, true);
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

test("recordMutation: terminal (permission-denied) Firestore error -> still 500, error write-rejected", async () => {
    seedHappyPathAuth(mockState);
    const cached = require.cache[require.resolve("../lib/gatewayLogic")].exports;
    const original = cached.applyMutation;
    cached.applyMutation = async () => { throw Object.assign(new Error("simulated"), { code: 7 }); };
    try {
        const res = mockRes();
        await handlers.recordMutation(mockReq({ body: validMutationBody() }), res);
        assert.equal(res.statusCode, 500, "status must stay 500 so the client never sees a 4xx and drops the write");
        assert.equal(jsonBody(res).error, "write-rejected");
    } finally {
        cached.applyMutation = original;
    }
});

test("recordMutation: transient (unavailable) Firestore error -> still 500, error write-unavailable", async () => {
    seedHappyPathAuth(mockState);
    const cached = require.cache[require.resolve("../lib/gatewayLogic")].exports;
    const original = cached.applyMutation;
    cached.applyMutation = async () => { throw Object.assign(new Error("simulated"), { code: 14 }); };
    try {
        const res = mockRes();
        await handlers.recordMutation(mockReq({ body: validMutationBody() }), res);
        assert.equal(res.statusCode, 500, "status must stay 500 so the client never sees a 4xx and drops the write");
        assert.equal(jsonBody(res).error, "write-unavailable");
    } finally {
        cached.applyMutation = original;
    }
});

test("recordDelta: terminal (permission-denied) Firestore error -> still 500, error write-rejected", async () => {
    seedHappyPathAuth(mockState);
    const cached = require.cache[require.resolve("../lib/gatewayLogic")].exports;
    const original = cached.applyDelta;
    cached.applyDelta = async () => { throw Object.assign(new Error("simulated"), { code: 7 }); };
    try {
        const res = mockRes();
        await handlers.recordDelta(mockReq({ body: validDeltaBody() }), res);
        assert.equal(res.statusCode, 500, "status must stay 500 so the client never sees a 4xx and drops the write");
        assert.equal(jsonBody(res).error, "write-rejected");
    } finally {
        cached.applyDelta = original;
    }
});

test("recordDelta: transient (unavailable) Firestore error -> still 500, error write-unavailable", async () => {
    seedHappyPathAuth(mockState);
    const cached = require.cache[require.resolve("../lib/gatewayLogic")].exports;
    const original = cached.applyDelta;
    cached.applyDelta = async () => { throw Object.assign(new Error("simulated"), { code: 14 }); };
    try {
        const res = mockRes();
        await handlers.recordDelta(mockReq({ body: validDeltaBody() }), res);
        assert.equal(res.statusCode, 500, "status must stay 500 so the client never sees a 4xx and drops the write");
        assert.equal(jsonBody(res).error, "write-unavailable");
    } finally {
        cached.applyDelta = original;
    }
});

test("recordMutationsBatch: terminal (permission-denied) Firestore error -> still 500, error write-rejected", async () => {
    seedHappyPathAuth(mockState);
    const cached = require.cache[require.resolve("../lib/batchMutationLogic")].exports;
    const original = cached.applyMutationsBatch;
    cached.applyMutationsBatch = async () => { throw Object.assign(new Error("simulated"), { code: 7 }); };
    try {
        const res = mockRes();
        await handlers.recordMutationsBatch(mockReq({ body: validBatchBody() }), res);
        assert.equal(res.statusCode, 500, "status must stay 500 so the client never sees a 4xx and drops the write");
        assert.equal(jsonBody(res).error, "write-rejected");
    } finally {
        cached.applyMutationsBatch = original;
    }
});

test("recordMutationsBatch: transient (unavailable) Firestore error -> still 500, error write-unavailable", async () => {
    seedHappyPathAuth(mockState);
    const cached = require.cache[require.resolve("../lib/batchMutationLogic")].exports;
    const original = cached.applyMutationsBatch;
    cached.applyMutationsBatch = async () => { throw Object.assign(new Error("simulated"), { code: 14 }); };
    try {
        const res = mockRes();
        await handlers.recordMutationsBatch(mockReq({ body: validBatchBody() }), res);
        assert.equal(res.statusCode, 500, "status must stay 500 so the client never sees a 4xx and drops the write");
        assert.equal(jsonBody(res).error, "write-unavailable");
    } finally {
        cached.applyMutationsBatch = original;
    }
});

// -- PH3 product-delete cascade (design Q4/Q5/Q11/Q13; test plan F18-F28, F30, F41) ---------------
// applyMutation is mocked in this harness, so the atomicity of "marker in the SAME transaction" is
// proven in gatewayLogic.test.js (F18/F19/F22/F23); here we prove what index.js itself decides: the
// prefix it hands to applyMutation, and when (and only when) it sweeps after the commit.
const CASCADE_TENANT = "tenant-cascade";
const CASCADE_PREFIX = "test/tenants/" + CASCADE_TENANT + "/products/PRD-1/";
const MARKER_PATH = "tenants/" + CASCADE_TENANT + "/pending_cleanup/PRD-1";
const PRODUCT_PATH = "tenants/" + CASCADE_TENANT + "/inventory/PRD-1";

function cascadeReset(opts) {
    const o = opts || {};
    mockState.docs = {};
    mockState.setCalls = [];
    mockState.applyMutationCalls = [];
    mockState.applyMutationResult = { ok: true };
    mockState.storageFiles = {};
    mockState.storageDeleteFilesCalls = [];
    mockState.storageDeleteFilesError = null;
    mockState.storageBucketError = null;
    mockState.docDeleteCalls = [];
    mockState.docDeleteError = null;
    seedHappyPathAuth(mockState, { tenantId: CASCADE_TENANT, role: o.role });
    // Stand-in for what the (mocked) transaction would have committed.
    if (o.marker !== false) {
        mockState.docs[MARKER_PATH] = { productId: "PRD-1", envPrefix: "test", prefix: CASCADE_PREFIX, attempts: 0, lastError: null };
    }
    mockState.storageFiles[CASCADE_PREFIX + "photo-1.jpg"] = Buffer.from("a");
    mockState.storageFiles[CASCADE_PREFIX + "photo-1_t.jpg"] = Buffer.from("b");
    mockState.storageFiles["test/tenants/" + CASCADE_TENANT + "/products/PRD-10/photo-9.jpg"] = Buffer.from("other");
}

function deleteBody(overrides) {
    return validMutationBody(Object.assign({
        entity: "inventory", entityId: "PRD-1", action: "delete", before: { name: "Widget" }, after: null,
        requestId: "del-req-" + Math.random()
    }, overrides || {}));
}

test("F19 recordMutation inventory delete: passes the exact prefix + env prefix to applyMutation (dev, test, prd, unknown)", async () => {
    const expectEnv = { dev: "dev1", test: "test", prd: "prd", bogus: "prd" };
    for (const env of Object.keys(expectEnv)) {
        cascadeReset();
        const res = mockRes();
        await handlers.recordMutation(mockReq({ body: deleteBody({ env: env }) }), res);
        assert.equal(res.statusCode, 200, env);
        const p = mockState.applyMutationCalls[0];
        assert.equal(p.cleanupEnvPrefix, expectEnv[env], env);
        assert.equal(p.cleanupPrefix, expectEnv[env] + "/tenants/" + CASCADE_TENANT + "/products/PRD-1/", env);
    }
});

test("F20 recordMutation inventory delete: post-commit sweep deletes exactly the product prefix, marker removed", async () => {
    cascadeReset();
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(mockState.storageDeleteFilesCalls, [{ prefix: CASCADE_PREFIX, force: true }]);
    assert.equal(mockState.docs[MARKER_PATH], undefined, "marker removed after a clean sweep");
    assert.deepEqual(mockState.docDeleteCalls, [MARKER_PATH]);
    assert.equal(Object.keys(mockState.storageFiles).some((k) => k.startsWith(CASCADE_PREFIX)), false, "this product's photos gone");
    assert.equal(Object.keys(mockState.storageFiles).length, 1, "PRD-10's photo untouched (prefix ends with /)");
});

test("F21 recordMutation inventory delete: sweep failure -> still 200, marker retained with attempts 1 + lastError", async () => {
    cascadeReset();
    mockState.storageDeleteFilesError = new Error("storage unavailable");
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true, entryId: mockState.applyMutationCalls[0].requestId });
    const marker = mockState.docs[MARKER_PATH];
    assert.equal(marker.attempts, 1);
    assert.equal(marker.lastError, "storage unavailable");
    assert.equal(marker.prefix, CASCADE_PREFIX, "merge-write keeps the rest of the marker");
});

test("F21b recordMutation inventory delete: even admin SDK construction throwing never fails the delete", async () => {
    cascadeReset();
    mockState.storageBucketError = new Error("no bucket");
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.ok(mockState.docs[MARKER_PATH], "marker stays for the PH3b scheduler");
});

test("F22 recordMutation inventory delete: CAS 409 -> no sweep, no storage call, marker never touched", async () => {
    cascadeReset({ marker: false });
    mockState.applyMutationResult = { ok: false, status: 409, conflict: true, current: { name: "server version" } };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 409);
    assert.equal(jsonBody(res).conflict, true);
    assert.equal(mockState.storageDeleteFilesCalls.length, 0);
    assert.equal(mockState.docDeleteCalls.length, 0);
    assert.equal(Object.keys(mockState.storageFiles).length, 3, "photos intact: no destroy-before-ack");
});

test("F23 recordMutation inventory delete: idempotent replay -> 200, no second sweep", async () => {
    cascadeReset();
    mockState.applyMutationResult = { ok: true, idempotentReplay: true };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(mockState.storageDeleteFilesCalls.length, 0);
});

test("F23b recordMutation inventory delete: applyMutation throwing (e.g. missing-cleanup-prefix) -> 500, no sweep", async () => {
    cascadeReset();
    const cached = require.cache[require.resolve("../lib/gatewayLogic")].exports;
    const original = cached.applyMutation;
    cached.applyMutation = async () => { throw new Error("missing-cleanup-prefix"); };
    try {
        const res = mockRes();
        await handlers.recordMutation(mockReq({ body: deleteBody() }), res);
        assert.equal(res.statusCode, 500);
        assert.equal(mockState.storageDeleteFilesCalls.length, 0);
        assert.deepEqual(mockState.docDeleteCalls, []);
    } finally {
        cached.applyMutation = original;
    }
});

test("F23c recordMutation inventory delete: a null applyMutation result is not a commit -> no sweep", async () => {
    cascadeReset();
    mockState.applyMutationResult = null;
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: deleteBody() }), res);
    assert.equal(mockState.storageDeleteFilesCalls.length, 0);
});

test("F24 recordMutation inventory update/create: no cleanup prefix, no sweep", async () => {
    for (const action of ["update", "create"]) {
        cascadeReset();
        const res = mockRes();
        await handlers.recordMutation(mockReq({ body: deleteBody({ action: action, after: { name: "x" } }) }), res);
        assert.equal(res.statusCode, 200, action);
        assert.equal(mockState.applyMutationCalls[0].cleanupPrefix, null, action);
        assert.equal(mockState.storageDeleteFilesCalls.length, 0, action);
    }
});

test("F25 recordMutation stock_batch / order / supplier / staff delete: no prefix, no sweep", async () => {
    for (const entity of ["stock_batch", "order", "supplier", "staff"]) {
        cascadeReset();
        const res = mockRes();
        await handlers.recordMutation(mockReq({ body: deleteBody({ entity: entity }) }), res);
        assert.equal(res.statusCode, 200, entity);
        assert.equal(mockState.applyMutationCalls[0].cleanupPrefix, null, entity);
        assert.equal(mockState.storageDeleteFilesCalls.length, 0, entity);
    }
});

test("F26 recordMutation inventory delete with an unsafe entityId -> 400 invalid-entity-id, nothing written", async () => {
    for (const bad of ["PRD 1", "a/b", "..", "x.y", "p".repeat(65), "caf\u00e9"]) {
        cascadeReset();
        const res = mockRes();
        await handlers.recordMutation(mockReq({ body: deleteBody({ entityId: bad }) }), res);
        assert.equal(res.statusCode, 400, JSON.stringify(bad));
        assert.equal(jsonBody(res).error, "invalid-entity-id");
        assert.equal(mockState.applyMutationCalls.length, 0, "applyMutation never reached");
        assert.equal(mockState.storageDeleteFilesCalls.length, 0);
    }
});

test("F26b unsafe entityId on a NON-cascade mutation is unchanged (only inventory delete needs a prefix)", async () => {
    cascadeReset();
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: deleteBody({ entity: "order", action: "update", entityId: "ORD 1", after: { a: 1 } }) }), res);
    assert.equal(res.statusCode, 200);
});

test("F27 recordMutation inventory delete of a product with zero photos: marker written, sweep harmless", async () => {
    cascadeReset();
    for (const key of Object.keys(mockState.storageFiles)) delete mockState.storageFiles[key];
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(mockState.storageDeleteFilesCalls.length, 1);
    assert.equal(mockState.docs[MARKER_PATH], undefined);
});

test("F28 id reuse: product recreated before the sweep runs -> marker dropped, photos NOT swept", async () => {
    cascadeReset();
    mockState.docs[PRODUCT_PATH] = { name: "Recreated", photoIds: ["photo-1"] };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(mockState.storageDeleteFilesCalls.length, 0);
    assert.equal(mockState.docs[MARKER_PATH], undefined, "stale marker dropped");
    assert.equal(Object.keys(mockState.storageFiles).length, 3, "new product's photos intact");
});

test("F30 staff-role inventory delete behaves as today (no new role gate; pinned) and still sweeps", async () => {
    cascadeReset({ role: "staff" });
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(mockState.storageDeleteFilesCalls.length, 1);
});

test("F41 delete of a server-absent product with non-null before -> 409 conflict, current null, no marker, no sweep (Q13 pin)", async () => {
    cascadeReset({ marker: false });
    mockState.applyMutationResult = { ok: false, status: 409, conflict: true, current: null };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 409);
    const body = jsonBody(res);
    assert.equal(body.conflict, true);
    assert.equal(body.current, null);
    assert.equal(mockState.storageDeleteFilesCalls.length, 0);
    assert.equal(mockState.docs[MARKER_PATH], undefined);
});

test("MONKEY recordMutation: 200 random entity/action/id combos never sweep unless inventory+delete with a safe id", async () => {
    const entities = ["inventory", "stock_batch", "order", "supplier", "inventory", "inventory"];
    const actions = ["create", "update", "delete", "delete", "delete"];
    const ids = ["PRD-1", "PRD-2", "a/b", "..", "x y", "PRD-1", "p".repeat(70)];
    let seed = 99;
    const rnd = (n) => { seed = (seed * 1664525 + 1013904223) % 4294967296; return Math.floor((seed / 4294967296) * n); };
    for (let i = 0; i < 200; i++) {
        cascadeReset();
        const entity = entities[rnd(entities.length)];
        const action = actions[rnd(actions.length)];
        const id = ids[rnd(ids.length)];
        const res = mockRes();
        await handlers.recordMutation(mockReq({ body: deleteBody({ entity: entity, action: action, entityId: id, after: action === "delete" ? null : { a: 1 } }) }), res);
        const safe = /^[A-Za-z0-9_-]{1,64}$/.test(id);
        const cascade = entity === "inventory" && action === "delete";
        if (cascade && !safe) {
            assert.equal(res.statusCode, 400);
            assert.equal(mockState.storageDeleteFilesCalls.length, 0);
        } else if (cascade) {
            assert.equal(res.statusCode, 200);
            assert.equal(mockState.storageDeleteFilesCalls.length, 1);
            assert.ok(mockState.storageDeleteFilesCalls[0].prefix.endsWith("/products/" + id + "/"));
        } else {
            assert.equal(mockState.storageDeleteFilesCalls.length, 0, entity + "/" + action + "/" + id);
        }
    }
});
