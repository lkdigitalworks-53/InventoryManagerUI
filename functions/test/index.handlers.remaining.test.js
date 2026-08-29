"use strict";

// Handler-level tests for functions/index.js's five endpoints deliberately
// left out of index.handlers.test.js's original scope (see that file's
// header comment and docs/superpowers/E2E-TESTING-ROADMAP.md, "Explicitly
// scoped out" -> "functions/index.js handler tests for the other 5
// endpoints"): acquireLock, releaseLock, provisionMember, runCutover,
// computeAnalysis.
//
// Same harness, same philosophy as index.handlers.test.js: exercise the
// REAL exported handler functions with mocked auth/Firestore/lib-module
// dependencies (see testSupport/handlerHarness.js). Two different shapes
// here, split into two sections:
//
//   1. acquireLock / releaseLock / runCutover -- each delegates its actual
//      Firestore-writing work to a lib/ module (LockLogic, CutoverLogic)
//      that already has its own full pure-logic test file. These tests
//      cover the same seam index.handlers.test.js covers for
//      recordMutation/recordDelta/recordMutationsBatch: auth, validation
//      wiring, and translating a lib/ result into the HTTP response --
//      NOT LockLogic/CutoverLogic's own correctness (already proven).
//
//   2. provisionMember / computeAnalysis -- neither delegates to a lib/
//      module. Their auth resolution, request parsing, local helpers
//      (canAssignRole, findOrCreateAuthUser, readAllPaged, the product/
//      supplier/order lookup-map builders), and Firestore transaction/
//      pagination logic all live directly in index.js and had zero
//      coverage anywhere before this file. These tests exercise that
//      logic for real against the harness's in-memory Firestore
//      substitute, not just the response-translation seam.

const test = require("node:test");
const assert = require("node:assert/strict");
const {
    installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody
} = require("./testSupport/handlerHarness");
const realisedFixtures = require("./fixtures/realisedMathFixtures");

const { handlers, mockState } = installMocks();

// ══════════════════════════════════════════════════════════════════════════
// acquireLock / releaseLock
// ══════════════════════════════════════════════════════════════════════════

function validAcquireBody(overrides) {
    return Object.assign({
        env: "test", entity: "order", entityId: "ORD-1", requestId: "req-lock-1"
    }, overrides || {});
}

function validReleaseBody(overrides) {
    return Object.assign({
        env: "test", entity: "order", entityId: "ORD-1"
    }, overrides || {});
}

test("acquireLock: success path returns 200 with ok:true and expiresAt", async () => {
    seedHappyPathAuth(mockState);
    mockState.acquireLockResult = { ok: true, acquiredAt: 1000, expiresAt: 91000 };
    const res = mockRes();
    await handlers.acquireLock(mockReq({ body: validAcquireBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true, expiresAt: 91000 });
});

test("acquireLock: held by another caller forwards holder info with a 409", async () => {
    seedHappyPathAuth(mockState);
    mockState.acquireLockResult = {
        ok: false, status: 409,
        holder: { name: "Other User", role: "staff", expiresAt: 99999 }
    };
    const res = mockRes();
    await handlers.acquireLock(mockReq({ body: validAcquireBody() }), res);
    assert.equal(res.statusCode, 409);
    assert.deepEqual(jsonBody(res).holder, { name: "Other User", role: "staff", expiresAt: 99999 });
});

test("acquireLock: TTL is server-decided -- a client-supplied ttlMs is overridden, never forwarded to LockLogic", async () => {
    // "TTL is server-decided, never client-supplied" per index.js's own
    // comment -- pin that a client cannot influence how long it holds a
    // lock for, regardless of what it puts in the request body.
    seedHappyPathAuth(mockState);
    mockState.acquireLockResult = { ok: true, acquiredAt: 0, expiresAt: 90000 };
    mockState.acquireLockCalls.length = 0;
    const res = mockRes();
    await handlers.acquireLock(mockReq({ body: validAcquireBody({ ttlMs: 999999999 }) }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(mockState.acquireLockCalls.length, 1);
    assert.equal(mockState.acquireLockCalls[0].ttlMs, 90000, "client ttlMs must never reach LockLogic.acquireLock");
});

test("acquireLock: non-POST method -> 405 method-not-allowed", async () => {
    const res = mockRes();
    await handlers.acquireLock(mockReq({ method: "GET", body: validAcquireBody() }), res);
    assert.equal(res.statusCode, 405);
    assert.equal(jsonBody(res).error, "method-not-allowed");
});

test("acquireLock: missing Authorization header -> 401 missing-token", async () => {
    const res = mockRes();
    await handlers.acquireLock(mockReq({ headers: { origin: "http://localhost" }, body: validAcquireBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
});

test("acquireLock: verifyIdToken throwing -> 401 invalid-token", async () => {
    mockState.verifyIdToken = async () => { throw new Error("bad token"); };
    const res = mockRes();
    await handlers.acquireLock(mockReq({ body: validAcquireBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("acquireLock: entity outside the allowlist -> 400 unsupported-entity from the real validateAcquireRequest", async () => {
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.acquireLock(mockReq({ body: validAcquireBody({ entity: "not-a-real-entity" }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "unsupported-entity");
});

test("acquireLock: authenticated but no tenant context -> 403 no-tenant-context", async () => {
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid" });
    mockState.docs = {};
    const res = mockRes();
    await handlers.acquireLock(mockReq({ body: validAcquireBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
});

test("acquireLock: LockLogic.acquireLock throwing -> 500 lock-failed, not an unhandled rejection", async () => {
    seedHappyPathAuth(mockState);
    mockState.acquireLockError = new Error("simulated Firestore failure");
    try {
        const res = mockRes();
        await handlers.acquireLock(mockReq({ body: validAcquireBody() }), res);
        assert.equal(res.statusCode, 500);
        assert.equal(jsonBody(res).error, "lock-failed");
    } finally {
        mockState.acquireLockError = null;
    }
});

test("releaseLock: success path returns 200 ok:true", async () => {
    seedHappyPathAuth(mockState);
    mockState.releaseLockResult = { ok: true };
    const res = mockRes();
    await handlers.releaseLock(mockReq({ body: validReleaseBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true });
});

test("releaseLock: a stale/duplicate release (LockLogic reports skipped) is still a 200 ok:true, not surfaced as an error", async () => {
    // releaseLock's own doc-comment: a mismatched holderUid is a silent
    // no-op, never an error. index.js doesn't even branch on the result --
    // pin that indifference is intentional, not an oversight.
    seedHappyPathAuth(mockState);
    mockState.releaseLockResult = { ok: true, skipped: true };
    const res = mockRes();
    await handlers.releaseLock(mockReq({ body: validReleaseBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true });
});

test("releaseLock: non-POST method -> 405 method-not-allowed", async () => {
    const res = mockRes();
    await handlers.releaseLock(mockReq({ method: "GET", body: validReleaseBody() }), res);
    assert.equal(res.statusCode, 405);
    assert.equal(jsonBody(res).error, "method-not-allowed");
});

test("releaseLock: missing Authorization header -> 401 missing-token", async () => {
    const res = mockRes();
    await handlers.releaseLock(mockReq({ headers: { origin: "http://localhost" }, body: validReleaseBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
});

test("releaseLock: verifyIdToken throwing -> 401 invalid-token", async () => {
    mockState.verifyIdToken = async () => { throw new Error("bad token"); };
    const res = mockRes();
    await handlers.releaseLock(mockReq({ body: validReleaseBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("releaseLock: entity outside the allowlist -> 400 unsupported-entity", async () => {
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.releaseLock(mockReq({ body: validReleaseBody({ entity: "not-a-real-entity" }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "unsupported-entity");
});

test("releaseLock: no tenant context -> 403 no-tenant-context", async () => {
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid-2" });
    mockState.docs = {};
    const res = mockRes();
    await handlers.releaseLock(mockReq({ body: validReleaseBody() }), res);
    assert.equal(res.statusCode, 403);
});

test("releaseLock: LockLogic.releaseLock throwing -> 500 release-failed", async () => {
    seedHappyPathAuth(mockState);
    mockState.releaseLockError = new Error("simulated Firestore failure");
    try {
        const res = mockRes();
        await handlers.releaseLock(mockReq({ body: validReleaseBody() }), res);
        assert.equal(res.statusCode, 500);
        assert.equal(jsonBody(res).error, "release-failed");
    } finally {
        mockState.releaseLockError = null;
    }
});

// ══════════════════════════════════════════════════════════════════════════
// provisionMember
// ══════════════════════════════════════════════════════════════════════════

function validProvisionBody(overrides) {
    return Object.assign({
        env: "test", email: "newhire@example.com", displayName: "New Hire",
        password: "s3cret!", role: "staff"
    }, overrides || {});
}

function resetProvisionAuthMocks() {
    mockState.getUserByEmail = async () => { throw Object.assign(new Error("no such user"), { code: "auth/user-not-found" }); };
    mockState.getUser = async () => { throw Object.assign(new Error("no such user"), { code: "auth/user-not-found" }); };
    mockState.createUser = async () => { throw new Error("mockState.createUser not configured for this test"); };
    mockState.setCalls.length = 0;
}

test("provisionMember: brand-new account via email -> 200 created:true, writes users/ and members/ docs", async () => {
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState); // owner
    mockState.createUser = async (opts) => {
        assert.equal(opts.email, "newhire@example.com");
        return { uid: "new-uid-1" };
    };
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true, uid: "new-uid-1", created: true });

    const userSet = mockState.setCalls.find((c) => c.path === "users/new-uid-1");
    assert.ok(userSet, "expected a users/new-uid-1 doc to be written");
    assert.equal(userSet.data.tenantId, "test-tenant", "brand-new account's active tenant is set to the inviting tenant");
    assert.equal(userSet.data.role, "staff");
    assert.deepEqual(userSet.data.tenants, ["test-tenant"]);

    const memberSet = mockState.setCalls.find((c) => c.path === "tenants/test-tenant/members/new-uid-1");
    assert.ok(memberSet, "expected a tenants/test-tenant/members/new-uid-1 doc to be written");
    assert.equal(memberSet.data.role, "staff");
    assert.equal(memberSet.data.status, "active");
});

test("provisionMember: existing account via email -> created:false, never yanks the user out of their current tenant", async () => {
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState);
    mockState.getUserByEmail = async () => ({ uid: "existing-uid-1" });
    // Existing account is already active somewhere else -- the merge logic
    // must preserve that, not overwrite it with the inviting tenant.
    mockState.docs["users/existing-uid-1"] = {
        uid: "existing-uid-1", email: "existing@example.com",
        tenantId: "other-tenant", tenantName: "Other Co", role: "manager",
        tenants: ["other-tenant"]
    };
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody({ email: "existing@example.com" }) }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true, uid: "existing-uid-1", created: false });

    const userSet = mockState.setCalls.find((c) => c.path === "users/existing-uid-1");
    assert.equal(userSet.data.tenantId, "other-tenant", "existing user's active tenant context must not be reassigned");
    assert.equal(userSet.data.role, "manager", "existing user's own role must not be reassigned");
    assert.deepEqual(userSet.data.tenants.sort(), ["other-tenant", "test-tenant"], "new tenant is appended, not swapped in");
});

test("provisionMember: invite-by-uid resolves the email from the existing Auth user, not the request body", async () => {
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState);
    mockState.getUser = async (uid) => {
        assert.equal(uid, "target-uid-1");
        return { uid: "target-uid-1", email: "resolved@example.com" };
    };
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody({ email: "", uid: "target-uid-1" }) }), res);
    assert.equal(res.statusCode, 200);
    const memberSet = mockState.setCalls.find((c) => c.path === "tenants/test-tenant/members/target-uid-1");
    assert.equal(memberSet.data.email, "resolved@example.com");
});

test("provisionMember: non-POST method -> 405 method-not-allowed", async () => {
    resetProvisionAuthMocks();
    const res = mockRes();
    await handlers.provisionMember(mockReq({ method: "GET", body: validProvisionBody() }), res);
    assert.equal(res.statusCode, 405);
    assert.equal(jsonBody(res).error, "method-not-allowed");
});

test("provisionMember: missing Authorization header -> 401 missing-token", async () => {
    resetProvisionAuthMocks();
    const res = mockRes();
    await handlers.provisionMember(mockReq({ headers: { origin: "http://localhost" }, body: validProvisionBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
});

test("provisionMember: verifyIdToken throwing -> 401 invalid-token", async () => {
    resetProvisionAuthMocks();
    mockState.verifyIdToken = async () => { throw new Error("bad token"); };
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("provisionMember: no tenant context -> 403 no-tenant-context", async () => {
    resetProvisionAuthMocks();
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid-3" });
    mockState.docs = {};
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
});

test("provisionMember: caller role below owner/admin -> 403 not-authorized", async () => {
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState, { role: "staff" });
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "not-authorized");
});

test("provisionMember: an admin caller trying to assign the admin role -> 403 role-not-allowed (canAssignRole)", async () => {
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState, { role: "admin" });
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody({ role: "admin" }) }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "role-not-allowed");
});

test("provisionMember: an owner caller CAN assign admin -- canAssignRole's positive branch", async () => {
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState, { role: "owner" });
    mockState.createUser = async () => ({ uid: "new-admin-uid" });
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody({ role: "admin" }) }), res);
    assert.equal(res.statusCode, 200);
});

test("provisionMember: an unrecognized role string silently falls back to staff", async () => {
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState, { role: "owner" });
    mockState.createUser = async () => ({ uid: "new-uid-fallback" });
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody({ role: "superadmin" }) }), res);
    assert.equal(res.statusCode, 200);
    const memberSet = mockState.setCalls.find((c) => c.path === "tenants/test-tenant/members/new-uid-fallback");
    assert.equal(memberSet.data.role, "staff");
});

test("provisionMember: neither email nor uid provided -> 400 email-or-uid-required", async () => {
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody({ email: "" }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "email-or-uid-required");
});

test("provisionMember: brand-new email with no/short password -> 400 password-required", async () => {
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody({ password: "abc" }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "password-required");
});

test("provisionMember: invite-by-uid where the uid doesn't exist -> 404 user-not-found", async () => {
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState);
    mockState.getUser = async () => { throw Object.assign(new Error("nope"), { code: "auth/user-not-found" }); };
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody({ email: "", uid: "ghost-target" }) }), res);
    assert.equal(res.statusCode, 404);
    assert.equal(jsonBody(res).error, "user-not-found");
});

test("provisionMember: an unexpected Auth SDK error resolving the target -> 500 auth-failed", async () => {
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState);
    mockState.getUser = async () => { throw new Error("auth service unavailable"); };
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: validProvisionBody({ email: "", uid: "some-uid" }) }), res);
    assert.equal(res.statusCode, 500);
    assert.equal(jsonBody(res).error, "auth-failed");
});

test("provisionMember: the Firestore transaction failing -> 500 write-failed", async () => {
    // Note on why this needs its own mockState flag rather than swapping
    // require.cache[firestorePath].exports post-hoc (as tried and reverted
    // here): index.js does `const { getFirestore } = require(...)` at
    // MODULE LOAD time, so its local `getFirestore` binding is fixed to
    // whatever installMocks() installed before index.js was first required
    // -- re-pointing require.cache afterward has no effect on that already-
    // captured reference. mockState.runTransactionError is read live, at
    // call time, by the one runTransaction closure index.js actually holds.
    resetProvisionAuthMocks();
    seedHappyPathAuth(mockState);
    mockState.createUser = async () => ({ uid: "doomed-uid" });
    mockState.runTransactionError = new Error("simulated transaction failure");
    try {
        const res = mockRes();
        await handlers.provisionMember(mockReq({ body: validProvisionBody() }), res);
        assert.equal(res.statusCode, 500);
        assert.equal(jsonBody(res).error, "write-failed");
    } finally {
        mockState.runTransactionError = null;
    }
});

// ══════════════════════════════════════════════════════════════════════════
// runCutover
// ══════════════════════════════════════════════════════════════════════════

function validCutoverBody(overrides) {
    return Object.assign({ env: "test", confirm: "CUTOVER" }, overrides || {});
}

function resetCutoverMocks() {
    mockState.deleteCollectionError = null;
    mockState.zeroInventoryStockError = null;
    mockState.setCalls.length = 0;
}

test("runCutover: success path returns 200 ok:true and writes the cutover marker to audit_log", async () => {
    resetCutoverMocks();
    seedHappyPathAuth(mockState, { role: "owner" });
    const res = mockRes();
    await handlers.runCutover(mockReq({ body: validCutoverBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true });

    const markerSet = mockState.setCalls.find((c) => c.path.startsWith("tenants/test-tenant/audit_log/cutover-"));
    assert.ok(markerSet, "expected a cutover marker written to tenants/test-tenant/audit_log/");
    assert.equal(markerSet.data.action, "cutover");
    assert.equal(markerSet.data.tenantId, "test-tenant");
    assert.equal(markerSet.data.actorRole, "owner");
});

test("runCutover: non-POST method -> 405 method-not-allowed", async () => {
    resetCutoverMocks();
    const res = mockRes();
    await handlers.runCutover(mockReq({ method: "GET", body: validCutoverBody() }), res);
    assert.equal(res.statusCode, 405);
    assert.equal(jsonBody(res).error, "method-not-allowed");
});

test("runCutover: missing Authorization header -> 401 missing-token", async () => {
    resetCutoverMocks();
    const res = mockRes();
    await handlers.runCutover(mockReq({ headers: { origin: "http://localhost" }, body: validCutoverBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
});

test("runCutover: verifyIdToken throwing -> 401 invalid-token", async () => {
    resetCutoverMocks();
    mockState.verifyIdToken = async () => { throw new Error("bad token"); };
    const res = mockRes();
    await handlers.runCutover(mockReq({ body: validCutoverBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("runCutover: no tenant context -> 403 no-tenant-context (validateCutoverRequest handles a null ctx)", async () => {
    resetCutoverMocks();
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid-4" });
    mockState.docs = {};
    const res = mockRes();
    await handlers.runCutover(mockReq({ body: validCutoverBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
});

test("runCutover: non-owner caller -> 403 owner-only", async () => {
    resetCutoverMocks();
    seedHappyPathAuth(mockState, { role: "admin" });
    const res = mockRes();
    await handlers.runCutover(mockReq({ body: validCutoverBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "owner-only");
});

test("runCutover: missing/incorrect confirmation string -> 400 confirmation-required", async () => {
    resetCutoverMocks();
    seedHappyPathAuth(mockState, { role: "owner" });
    const res = mockRes();
    await handlers.runCutover(mockReq({ body: validCutoverBody({ confirm: "yes please" }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "confirmation-required");
});

test("runCutover: CutoverLogic.deleteCollection throwing partway through -> 500 cutover-failed", async () => {
    resetCutoverMocks();
    seedHappyPathAuth(mockState, { role: "owner" });
    mockState.deleteCollectionError = new Error("simulated Firestore failure");
    const res = mockRes();
    await handlers.runCutover(mockReq({ body: validCutoverBody() }), res);
    assert.equal(res.statusCode, 500);
    assert.equal(jsonBody(res).error, "cutover-failed");
});

test("runCutover: CutoverLogic.zeroInventoryStock throwing -> 500 cutover-failed", async () => {
    resetCutoverMocks();
    seedHappyPathAuth(mockState, { role: "owner" });
    mockState.zeroInventoryStockError = new Error("simulated Firestore failure");
    const res = mockRes();
    await handlers.runCutover(mockReq({ body: validCutoverBody() }), res);
    assert.equal(res.statusCode, 500);
    assert.equal(jsonBody(res).error, "cutover-failed");
});

// ══════════════════════════════════════════════════════════════════════════
// computeAnalysis
// ══════════════════════════════════════════════════════════════════════════

function validAnalysisBody(overrides) {
    return Object.assign({ env: "test", viewMode: "revenue" }, overrides || {});
}

function resetAnalysisMocks() {
    mockState.collections = {
        "tenants/test-tenant/transactions": [],
        "tenants/test-tenant/orders": [],
        "tenants/test-tenant/inventory": [],
        "tenants/test-tenant/suppliers": []
    };
    mockState.collectionGetCalls.length = 0;
    mockState.collectionGetError = null;
}

test("computeAnalysis: non-POST method -> 405 method-not-allowed", async () => {
    resetAnalysisMocks();
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ method: "GET", body: validAnalysisBody() }), res);
    assert.equal(res.statusCode, 405);
    assert.equal(jsonBody(res).error, "method-not-allowed");
});

test("computeAnalysis: missing Authorization header -> 401 missing-token", async () => {
    resetAnalysisMocks();
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ headers: { origin: "http://localhost" }, body: validAnalysisBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
});

test("computeAnalysis: verifyIdToken throwing -> 401 invalid-token", async () => {
    resetAnalysisMocks();
    mockState.verifyIdToken = async () => { throw new Error("bad token"); };
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ body: validAnalysisBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("computeAnalysis: no tenant context -> 403 no-tenant-context", async () => {
    resetAnalysisMocks();
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid-5" });
    mockState.docs = {};
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ body: validAnalysisBody() }), res);
    assert.equal(res.statusCode, 403);
});

test("computeAnalysis: unsupported viewMode -> 400 unsupported-view-mode", async () => {
    resetAnalysisMocks();
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ body: validAnalysisBody({ viewMode: "not-a-real-mode" }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "unsupported-view-mode");
});

test("computeAnalysis: revenue wiring -- real RealisedMath fed real Firestore-shaped data via readAllPaged matches the known-good fixture totals", async () => {
    // Reuses the same fixture gatewayLogic-adjacent files already trust
    // (functions/test/fixtures/realisedMathFixtures.js, "sale_plus_return_
    // nets_down", already proven correct in realisedMath.test.js) so this
    // test is checking THIS endpoint's wiring -- readAllPaged actually
    // delivering Firestore docs into RealisedMath.totals correctly -- not
    // re-deriving RealisedMath's own math.
    resetAnalysisMocks();
    seedHappyPathAuth(mockState);
    const fixture = realisedFixtures.find((f) => f.name === "sale_plus_return_nets_down");
    mockState.collections["tenants/test-tenant/transactions"] =
        fixture.entries.map((e, i) => ({ id: "tx" + i, data: e }));
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ body: validAnalysisBody({ viewMode: "revenue" }) }), res);
    assert.equal(res.statusCode, 200);
    const body = jsonBody(res);
    assert.equal(body.ok, true);
    assert.equal(body.totals.net, fixture.expected.totals.net);
    assert.equal(body.totals.cogs, fixture.expected.totals.cogs);
    assert.equal(body.totals.profit, fixture.expected.totals.profit);
    assert.ok(body.byDimension.category, "default dims includes category");
    assert.ok(body.byDimension.supplier, "default dims includes supplier");
    assert.ok(body.bucketWalk.net, "revenue viewMode buckets the 'net' metric");
});

test("computeAnalysis: profit viewMode buckets the 'profit' metric, not 'net'", async () => {
    resetAnalysisMocks();
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ body: validAnalysisBody({ viewMode: "profit" }) }), res);
    assert.equal(res.statusCode, 200);
    const body = jsonBody(res);
    assert.ok(Object.prototype.hasOwnProperty.call(body.bucketWalk, "profit"));
    assert.ok(!Object.prototype.hasOwnProperty.call(body.bucketWalk, "net"));
});

test("computeAnalysis: sold/purchased viewModes never read the orders collection (needsOrders optimization)", async () => {
    resetAnalysisMocks();
    seedHappyPathAuth(mockState);
    mockState.collections["tenants/test-tenant/transactions"] = [
        { id: "tx1", data: { kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 3, consumption: [] } }
    ];
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ body: validAnalysisBody({ viewMode: "sold" }) }), res);
    assert.equal(res.statusCode, 200);
    assert.ok(
        !mockState.collectionGetCalls.includes("tenants/test-tenant/orders"),
        "sold/purchased don't need orders -- readAllPaged for orders must be skipped, not just ignored"
    );
    const body = jsonBody(res);
    assert.equal(body.byDimension.category["(uncategorised)"], 3);
});

test("computeAnalysis: custom dims are respected instead of the ['category','supplier'] default", async () => {
    resetAnalysisMocks();
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ body: validAnalysisBody({ viewMode: "revenue", dims: ["channel"] }) }), res);
    assert.equal(res.statusCode, 200);
    const body = jsonBody(res);
    assert.ok(Object.prototype.hasOwnProperty.call(body.byDimension, "channel"));
    assert.ok(!Object.prototype.hasOwnProperty.call(body.byDimension, "category"));
    assert.ok(!Object.prototype.hasOwnProperty.call(body.byDimension, "supplier"));
});

test("computeAnalysis: readAllPaged actually paginates -- 501 docs in one collection takes 2+ internal pages and all are counted", async () => {
    // ANALYSIS_PAGE_SIZE is 500 -- this is the one on-purpose test of
    // readAllPaged's own cursor loop (orderBy/limit/startAfter), the exact
    // shape of logic where an off-by-one drops or duplicates the boundary
    // doc. Every other test here fits in a single page and would never
    // exercise the startAfter branch at all.
    resetAnalysisMocks();
    seedHappyPathAuth(mockState);
    const docs = [];
    for (let i = 0; i < 501; i++) {
        docs.push({
            id: "tx" + String(i).padStart(4, "0"),
            data: { kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 1, consumption: [] }
        });
    }
    mockState.collections["tenants/test-tenant/transactions"] = docs;
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ body: validAnalysisBody({ viewMode: "sold" }) }), res);
    assert.equal(res.statusCode, 200);
    const body = jsonBody(res);
    assert.equal(body.byDimension.category["(uncategorised)"], 501, "every doc across both pages must be counted exactly once");
    const txPageReads = mockState.collectionGetCalls.filter((p) => p === "tenants/test-tenant/transactions");
    assert.ok(txPageReads.length >= 2, "501 docs at a 500 page size must take at least 2 internal reads");
});

test("computeAnalysis: a Firestore read failure -> 500 compute-failed, not an unhandled rejection", async () => {
    resetAnalysisMocks();
    seedHappyPathAuth(mockState);
    mockState.collectionGetError = new Error("simulated Firestore outage");
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ body: validAnalysisBody() }), res);
    assert.equal(res.statusCode, 500);
    assert.equal(jsonBody(res).error, "compute-failed");
});

test("computeAnalysis: a non-integer period falls back to 0 rather than throwing", async () => {
    resetAnalysisMocks();
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.computeAnalysis(mockReq({ body: validAnalysisBody({ period: "not-a-number" }) }), res);
    assert.equal(res.statusCode, 200);
});
