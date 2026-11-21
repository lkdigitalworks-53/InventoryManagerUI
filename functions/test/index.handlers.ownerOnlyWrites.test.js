"use strict";

// KNOWN-ISSUES 42 (found in the PR #199 sweep, 2026-11-15): three writes are owner/admin only, and EVERY endpoint that can carry an
// entity write must say so. recordMutation always did. recordOperation and recordMutationsBatch did not: their validators accept
// `staff` delete and the `removed_staff` tombstone, and their handlers derived the role and never looked at it, so a token with the
// lowest role could delete a staff record, or plant a tombstone, through either of them.
//
// Real vs mocked: see testSupport/handlerHarness.js. The role gate, deriveContext and the validators are REAL; the apply step is
// mocked and COUNTED (a refused request must never reach it: zero writes).

const test = require("node:test");
const assert = require("node:assert/strict");
const { installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody } = require("./testSupport/handlerHarness");
const { ENTITY_COLLECTIONS } = require("../lib/gatewayLogic");

const { handlers, mockState } = installMocks();

const HOME = "home-tenant";
const UID = "caller-uid";
const ROLES = ["owner", "admin", "manager", "staff"];
const ALLOWED = { owner: true, admin: true, manager: false, staff: false };

// Written independently of index.js on purpose: if the rule in the code drifts, this table does not move with it.
const OWNER_ONLY = (entity, action) => (entity === "staff" && action === "delete") || entity === "removed_staff" || (entity === "inventory" && action === "delete");

const calls = { mutation: 0, batch: 0, operation: 0 };
function reset(role) {
    mockState.docs = {};
    mockState.setCalls = [];
    mockState.verifyIdToken = async () => ({ uid: UID });
    calls.mutation = 0; calls.batch = 0; calls.operation = 0;
    const counted = (key, counter, value) => Object.defineProperty(mockState, key, { configurable: true, enumerable: true, get() { calls[counter]++; return value; } });
    counted("applyMutationResult", "mutation", { ok: true });
    counted("applyMutationsBatchResult", "batch", { ok: true, results: [] });
    counted("applyOperationResult", "operation", { ok: true, results: [] });
    mockState.applyDeltaResult = { ok: true };
    seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: role });
}

let seq = 0;
const docs = (action) => action === "create" ? { before: null, after: { a: 1 } }
                       : action === "delete" ? { before: { a: 1 }, after: null }
                       : { before: { a: 1 }, after: { a: 2 } };

const sendMutation = (entity, action) => ({ handler: "recordMutation", counter: "mutation",
    body: Object.assign({ env: "test", entity: entity, entityId: "X1", action: action, requestId: "req-m" + (++seq), clientTimestamp: 1 }, docs(action)) });
const sendBatch = (entity, action) => ({ handler: "recordMutationsBatch", counter: "batch",
    body: { env: "test", entity: entity, requestId: "req-b" + (++seq), items: [Object.assign({ entityId: "X1", action: action }, docs(action))] } });
const sendOperation = (opType) => (entity, action) => ({ handler: "recordOperation", counter: "operation",
    body: { env: "test", requestId: opType + ":t" + (++seq), opType: opType, clientTimestamp: 1,
            ops: [Object.assign({ kind: "mutation", entity: entity, entityId: "X1", action: action }, docs(action))] } });

const ENDPOINTS = [
    { label: "recordMutation", make: sendMutation },
    { label: "recordMutationsBatch", make: sendBatch },
    { label: "recordOperation (completeOrder)", make: sendOperation("completeOrder") },
    { label: "recordOperation (restock)", make: sendOperation("restock") }
    // createOrder is not in this grid: since the PR #208 review its structure is fixed (a mint and ONE order create), so it cannot carry
    // a staff delete or a tombstone at all. The two tests at the end of this file pin that, for every role.
];

async function call(req) {
    const res = mockRes();
    await handlers[req.handler](mockReq({ body: req.body }), res);
    return res;
}

// What a request for (entity, action) must do on this endpoint. The product delete is refused earlier, by the validator, inside an
// operation and a batch (cascade-delete-not-allowed, 400 for every role); recordMutation's own product-delete path has its own tests.
function expectedFor(label, entity, action, role) {
    if (entity === "inventory" && action === "delete" && label !== "recordMutation") return { status: 400, error: "cascade-delete-not-allowed", reaches: false };
    if (OWNER_ONLY(entity, action) && !ALLOWED[role]) return { status: 403, error: "role-not-allowed", reaches: false };
    return { status: 200, reaches: true };
}

const SENSITIVE = [["staff", "delete"], ["removed_staff", "create"], ["removed_staff", "update"], ["removed_staff", "delete"]];

for (const ep of ENDPOINTS) {
    test("owner-only writes on " + ep.label + ": staff delete and the removed_staff tombstone are 403 role-not-allowed for manager and staff, allowed for owner and admin, and a refusal reaches no write", async () => {
        for (const [entity, action] of SENSITIVE) {
            for (const role of ROLES) {
                reset(role);
                const req = ep.make(entity, action);
                const res = await call(req);
                const want = expectedFor(ep.label, entity, action, role);
                const label = ep.label + " " + entity + ":" + action + " as " + role;
                assert.equal(res.statusCode, want.status, label + " -> " + JSON.stringify(jsonBody(res)));
                if (want.error) assert.equal(jsonBody(res).error, want.error, label);
                assert.equal(calls[req.counter], want.reaches ? 1 : 0, label + ": the apply step is reached exactly when the request is allowed");
            }
        }
    });
}

test("owner-only writes: the product delete inside an operation or a batch is refused for EVERY role, before any role question (unchanged)", async () => {
    for (const ep of ENDPOINTS.filter((e) => e.label !== "recordMutation")) {
        for (const role of ROLES) {
            reset(role);
            const req = ep.make("inventory", "delete");
            const res = await call(req);
            assert.equal(res.statusCode, 400, ep.label + " as " + role);
            assert.equal(jsonBody(res).error, "cascade-delete-not-allowed");
            assert.equal(calls[req.counter], 0);
        }
    }
});

test("REGRESSION: every OTHER entity and action stays open to the lowest role on every endpoint (the gate blocks three writes and nothing else)", async () => {
    let reached = 0;
    for (const ep of ENDPOINTS) {
        for (const entity of Object.keys(ENTITY_COLLECTIONS)) {
            for (const action of ["create", "update", "delete"]) {
                if (OWNER_ONLY(entity, action)) continue;
                reset("staff");
                const req = ep.make(entity, action);
                const res = await call(req);
                const label = ep.label + " " + entity + ":" + action + " as staff -> " + JSON.stringify(jsonBody(res));
                assert.equal(res.statusCode, 200, label);
                assert.equal(calls[req.counter], 1, label);
                reached++;
            }
        }
    }
    assert.ok(reached >= ENDPOINTS.length * 3, "the loop really ran: " + reached);
});

test("REGRESSION: the real operations a staff-role phone sends today (an order completion delta, a restock) still pass the role gate", async () => {
    for (const opType of ["completeOrder", "restock"]) {
        reset("staff");
        const res = await call({ handler: "recordOperation", counter: "operation", body: { env: "test", requestId: opType + ":real1", opType: opType, clientTimestamp: 1,
            ops: [{ kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: opType === "restock" ? 3 : -1 }, floors: { stock: 0 } }] } });
        assert.equal(res.statusCode, 200, opType + " " + JSON.stringify(jsonBody(res)));
        assert.equal(calls.operation, 1);
    }
});

test("REGRESSION (NO1): a staff-role phone can create an order through createOrder (a mint plus one order create is not owner-only)", async () => {
    for (const role of ROLES) {
        reset(role);
        const res = await call({ handler: "recordOperation", counter: "operation", body: { env: "test", requestId: "createOrder:real1", opType: "createOrder", clientTimestamp: 1,
            ops: [{ kind: "mint", counter: "order", bind: "o" },
                  { kind: "mutation", entity: "order", entityId: "{{o}}", action: "create", before: null, after: { orderId: "{{o}}" } }] } });
        assert.equal(res.statusCode, 200, role + " " + JSON.stringify(jsonBody(res)));
        assert.equal(calls.operation, 1, role);
    }
});

test("NO1 review: a createOrder that carries a staff delete or a removed_staff tombstone is refused for EVERY role (400 invalid-order, nothing applied): the op type cannot smuggle the owner-only writes", async () => {
    const order = [{ kind: "mint", counter: "order", bind: "o" },
                   { kind: "mutation", entity: "order", entityId: "{{o}}", action: "create", before: null, after: { orderId: "{{o}}" } }];
    for (const [entity, action] of SENSITIVE) {
        for (const role of ROLES) {
            reset(role);
            const extra = Object.assign({ kind: "mutation", entity: entity, entityId: "X1", action: action }, docs(action));
            const res = await call({ handler: "recordOperation", counter: "operation", body: { env: "test", requestId: "createOrder:smuggle" + (++seq), opType: "createOrder", clientTimestamp: 1, ops: order.concat([extra]) } });
            const label = entity + ":" + action + " as " + role + " -> " + JSON.stringify(jsonBody(res));
            assert.equal(res.statusCode, 400, label);
            assert.equal(jsonBody(res).error, "invalid-order", label);
            assert.equal(jsonBody(res).opIndex, 2, label);
            assert.equal(calls.operation, 0, label);
        }
    }
});

test("a mixed operation is refused as a whole: one staff delete among harmless ops is 403 and NOTHING is applied", async () => {
    reset("staff");
    const res = await call({ handler: "recordOperation", counter: "operation", body: { env: "test", requestId: "completeOrder:mixed", opType: "completeOrder", clientTimestamp: 1, ops: [
        { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 }, floors: { stock: 0 } },
        Object.assign({ kind: "mutation", entity: "order", entityId: "ORD-1", action: "update" }, docs("update")),
        Object.assign({ kind: "mutation", entity: "staff", entityId: "S1", action: "delete" }, docs("delete"))
    ] } });
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "role-not-allowed");
    assert.equal(calls.operation, 0);
});

test("a batch refuses on ANY item: one staff delete among ordinary updates is 403 for a non-owner and nothing is applied", async () => {
    reset("manager");
    const res = await call({ handler: "recordMutationsBatch", counter: "batch", body: { env: "test", entity: "staff", requestId: "req-mixedbatch", items: [
        Object.assign({ entityId: "S1", action: "update" }, docs("update")),
        Object.assign({ entityId: "S2", action: "delete" }, docs("delete"))
    ] } });
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "role-not-allowed");
    assert.equal(calls.batch, 0);
});

test("the role is the MEMBER doc's, never users/{uid}'s: a staff member whose users doc claims owner is still refused on all three endpoints", async () => {
    for (const ep of ENDPOINTS) {
        reset("staff");
        mockState.docs["users/" + UID].role = "owner";   // the lie (S2f-1)
        const req = ep.make("staff", "delete");
        const res = await call(req);
        assert.equal(res.statusCode, 403, ep.label);
        assert.equal(jsonBody(res).error, "role-not-allowed", ep.label);
        assert.equal(calls[req.counter], 0, ep.label);
    }
});
