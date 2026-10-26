"use strict";

// D-2 (PR #146 review, chosen into S1b): a client requestId / batch entityId must not contain
// `~` or `/` and is capped at 200 chars, so the single-record endpoints can never forge the
// `{requestId}~{i}` audit ids or `...~m{j}` ledger-row ids that recordOperation writes with `set`.
// recordOperation itself keeps `~` ids (its own validator is unchanged and pinned below).

const test = require("node:test");
const assert = require("node:assert/strict");
const { installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody } = require("./testSupport/handlerHarness");
const G = require("../lib/gatewayLogic");
const B = require("../lib/batchMutationLogic");
const O = require("../lib/operationLogic");

const { handlers, mockState } = installMocks();

// ── pure predicate ──────────────────────────────────────────────────────────
test("isClientRequestId: normal client ids pass (req-<ms>-<rand>, uuid-like, colons)", () => {
    for (const ok of ["req-1", "req-1760000000000-ab12", "a:b:c", "x".repeat(200), "A-b_c.d"])
        assert.equal(G.isClientRequestId(ok), true, ok);
});

test("isClientRequestId: `~`, `/`, empty, too long and non-strings are refused", () => {
    for (const bad of ["a~0", "a~m0", "~", "a/b", "/", "", "x".repeat(201), null, undefined, 5, {}, []])
        assert.equal(G.isClientRequestId(bad), false, String(bad));
    assert.equal(G.MAX_REQUEST_ID_LENGTH, 200);
});

// ── batch validator ─────────────────────────────────────────────────────────
const item = (entityId) => ({ entityId, action: "create", before: null, after: { stock: 1 } });
const body = (over) => Object.assign({ entity: "inventory", requestId: "req-b", items: [item("p1")] }, over || {});

test("batch validator: a requestId with `~` or `/` or over 200 chars is invalid-request-id", () => {
    for (const bad of ["completeOrder:o1:1~0", "a/b", "x".repeat(201)]) {
        const r = B.validateBatchMutationRequest(body({ requestId: bad }));
        assert.equal(r.ok, false, bad);
        assert.equal(r.status, 400);
        assert.equal(r.error, "invalid-request-id");
    }
});

test("batch validator: an entityId with `~` or `/` (forges `{requestId}:{entityId}~m0`) is invalid-entity-id, whole batch rejected", () => {
    for (const bad of ["p1~m0", "a/b", "x".repeat(201)]) {
        const r = B.validateBatchMutationRequest(body({ items: [item("p0"), item(bad)] }));
        assert.equal(r.ok, false, bad);
        assert.equal(r.error, "invalid-entity-id");
    }
    assert.equal(B.validateBatchMutationRequest(body({ items: [item("PRD-1"), item("a:b")] })).ok, true);
});

// ── recordOperation is deliberately untouched ───────────────────────────────
test("recordOperation validator still accepts its own ids and still refuses `~` in the requestId", () => {
    const op = { kind: "mutation", entity: "order", entityId: "o1", action: "update", before: {}, after: {} };
    assert.equal(O.validateOperationRequest({ requestId: "completeOrder:o1:1", opType: "completeOrder", ops: [op] }).ok, true);
    assert.equal(O.validateOperationRequest({ requestId: "completeOrder:o1~1", opType: "completeOrder", ops: [op] }).error, "invalid-request-id");
});

test("shared validators stay permissive about `~` (recordOperation passes `{requestId}~{i}` through them)", () => {
    const m = G.validateMutationRequest({ entity: "order", entityId: "o1", action: "update", requestId: "completeOrder:o1:1~0" });
    assert.equal(m.ok, true);
    const d = G.validateDeltaRequest({ entity: "stock_batch", entityId: "b1", requestId: "completeOrder:o1:1~0", deltas: { qtyOnHand: -1 } });
    assert.equal(d.ok, true);
});

// ── handlers ────────────────────────────────────────────────────────────────
const mutBody = (rid) => ({ env: "test", entity: "order", entityId: "ORD-1", action: "update", requestId: rid, before: {}, after: { n: 1 } });
const deltaBody = (rid) => ({ env: "test", entity: "stock_batch", entityId: "BAT-1", requestId: rid, deltas: { qtyOnHand: -1 } });
const batchBody = (rid) => ({ env: "test", entity: "order", requestId: rid, items: [{ entityId: "ORD-1", action: "update", before: {}, after: {} }] });

for (const [name, mk] of [["recordMutation", mutBody], ["recordDelta", deltaBody], ["recordMutationsBatch", batchBody]]) {
    test(name + ": a requestId with `~` is a 400 invalid-request-id and nothing is applied", async () => {
        seedHappyPathAuth(mockState);
        mockState.applyMutationResult = { ok: true };
        const res = mockRes();
        await handlers[name](mockReq({ body: mk("completeOrder:o1:1~0") }), res);
        assert.equal(res.statusCode, 400);
        assert.deepEqual(jsonBody(res), { ok: false, error: "invalid-request-id" });
    });

    test(name + ": a 201-char requestId is a 400 invalid-request-id", async () => {
        seedHappyPathAuth(mockState);
        const res = mockRes();
        await handlers[name](mockReq({ body: mk("r".repeat(201)) }), res);
        assert.equal(res.statusCode, 400);
        assert.equal(jsonBody(res).error, "invalid-request-id");
    });
}

test("recordMutation: a normal client requestId still reaches the write (200)", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyMutationResult = { ok: true };
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: mutBody("req-1760000000000-ab12") }), res);
    assert.equal(res.statusCode, 200);
});
