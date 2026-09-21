"use strict";

// Handler-level tests for functions/index.js's recordOperation endpoint, in the
// same shape as recordDelta's block in index.handlers.test.js: auth, request
// wiring, and - the seam that matters - whether the lib/ result is forwarded
// into the HTTP response without dropping or renaming a field (opIndex, field,
// current, conflict, results, idempotentReplay). The transaction logic itself is
// covered by operationLogic.test.js; applyOperation is mocked here.

const test = require("node:test");
const assert = require("node:assert/strict");
const { installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody } = require("./testSupport/handlerHarness");

const { handlers, mockState } = installMocks();

function validOperationBody(overrides) {
    return Object.assign({
        env: "test", requestId: "completeOrder:o1:1", opType: "completeOrder", clientTimestamp: 12345,
        ops: [{ kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 }, floors: { stock: 0 } }]
    }, overrides || {});
}

test("recordOperation: success returns 200 with ok, entryId, results and idempotentReplay:false", async () => {
    seedHappyPathAuth(mockState);
    const results = [{ entity: "inventory", entityId: "p1", kind: "delta", after: { stock: 4 } }];
    mockState.applyOperationResult = { ok: true, results: results };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true, entryId: "completeOrder:o1:1", results: results, idempotentReplay: false });
});

test("recordOperation: a replay is forwarded as idempotentReplay:true with the stored results", async () => {
    seedHappyPathAuth(mockState);
    const results = [{ entity: "inventory", entityId: "p1", kind: "delta", after: { stock: 4 } }];
    mockState.applyOperationResult = { ok: true, idempotentReplay: true, results: results };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(jsonBody(res).idempotentReplay, true);
    assert.deepEqual(jsonBody(res).results, results);
});

test("recordOperation: a floor rejection forwards error/opIndex/field/current unmodified (0 survives)", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyOperationResult = { ok: false, status: 409, error: "insufficient-quantity", opIndex: 0, field: "stock", current: 0 };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 409);
    const body = jsonBody(res);
    assert.equal(body.ok, false);
    assert.equal(body.error, "insufficient-quantity");
    assert.equal(body.opIndex, 0);          // 0 is falsy - must survive
    assert.equal(body.field, "stock");
    assert.equal(body.current, 0);
});

test("recordOperation: a CAS conflict forwards conflict:true and the server's current doc", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyOperationResult = { ok: false, status: 409, error: "conflict", conflict: true, opIndex: 2, current: { status: "completed" } };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 409);
    assert.equal(jsonBody(res).conflict, true);
    assert.equal(jsonBody(res).opIndex, 2);
    assert.deepEqual(jsonBody(res).current, { status: "completed" });
});

test("recordOperation: a rejection without a status falls back to 409", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyOperationResult = { ok: false, error: "conflict" };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 409);
});

test("recordOperation: a 404 from applyOperation is forwarded with its op index", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyOperationResult = { ok: false, status: 404, error: "not-found", opIndex: 3 };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 404);
    assert.equal(jsonBody(res).opIndex, 3);
});

test("recordOperation: missing Authorization header -> 401 missing-token", async () => {
    const res = mockRes();
    await handlers.recordOperation(mockReq({ headers: { origin: "http://localhost" }, body: validOperationBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
});

test("recordOperation: verifyIdToken throwing -> 401 invalid-token", async () => {
    mockState.verifyIdToken = async () => { throw new Error("bad token"); };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("recordOperation: authenticated but no matching user/tenant doc -> 403 no-tenant-context", async () => {
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid" });
    mockState.docs = {};
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
});

test("recordOperation: invalid op -> 400 from validateOperationRequest with the failing opIndex", async () => {
    seedHappyPathAuth(mockState);
    const body = validOperationBody({
        ops: [
            { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 } },
            { kind: "delta", entity: "nope", entityId: "x", deltas: { a: 1 } }
        ]
    });
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: body }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "unsupported-entity");
    assert.equal(jsonBody(res).opIndex, 1);
});

test("recordOperation: empty envelope -> 400 missing-fields", async () => {
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: {} }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "missing-fields");
});

test("recordOperation: GET request -> 405 method-not-allowed", async () => {
    const res = mockRes();
    await handlers.recordOperation(mockReq({ method: "GET" }), res);
    assert.equal(res.statusCode, 405);
    assert.equal(jsonBody(res).error, "method-not-allowed");
});

test("recordOperation: applyOperation throwing -> 500 write-failed, not an unhandled rejection", async () => {
    seedHappyPathAuth(mockState);
    const operationLogicPath = require.resolve("../lib/operationLogic");
    const cached = require.cache[operationLogicPath].exports;
    const original = cached.applyOperation;
    cached.applyOperation = async () => { throw new Error("simulated Firestore failure"); };
    try {
        const res = mockRes();
        await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
        assert.equal(res.statusCode, 500);
        assert.equal(jsonBody(res).error, "write-failed");
    } finally {
        cached.applyOperation = original;
    }
});
