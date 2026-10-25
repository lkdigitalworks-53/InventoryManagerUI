"use strict";

// S2f-1 (2026-10-24): the gateway trusts the MEMBER doc, never users/{uid}.
//
// Why: users/{uid} is writable by its own user, field by field (firestore.rules), and the old
// deriveContext fell back to users/{uid}.role when no member doc existed. A signed-in account
// could write {tenantId: <victim>, role: "owner"} to its own doc and the gateway then acted as
// that tenant's owner; a removed member whose users doc survived kept full access (AuthService.
// cleanupStaffAuthDocs cannot delete another user's doc, the rules forbid it).
//
// deriveContext is the single choke point for ten handlers, so every scenario runs against every
// handler. A new handler that calls deriveContext must be added to HANDLERS or this file says
// nothing about it (the last test counts the call sites in index.js to catch that).
//
// Real vs mocked: see testSupport/handlerHarness.js. deriveContext is REAL index.js code.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody } = require("./testSupport/handlerHarness");

const { handlers, mockState } = installMocks();

const VICTIM = "victim-tenant";
const HOME = "home-tenant";
const UID = "attacker-uid";

const HANDLERS = [
    { name: "recordMutation", body: { env: "test", entity: "order", entityId: "ORD-1", action: "update", requestId: "r1", before: { n: "" }, after: { n: "x" }, clientTimestamp: 1 } },
    { name: "recordDelta", body: { env: "test", entity: "stock_batch", entityId: "BAT-1", requestId: "r2", deltas: { qtyOnHand: -1 }, clientTimestamp: 1 } },
    { name: "recordMutationsBatch", body: { env: "test", entity: "order", requestId: "r3", items: [{ entityId: "ORD-1", action: "update", before: {}, after: {} }] } },
    { name: "recordOperation", body: { env: "test", requestId: "completeOrder:o1:1", opType: "completeOrder", clientTimestamp: 1, ops: [{ kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 }, floors: { stock: 0 } }] } },
    { name: "acquireLock", body: { env: "test", entity: "order", entityId: "ORD-1", requestId: "r4" } },
    { name: "releaseLock", body: { env: "test", entity: "order", entityId: "ORD-1" } },
    { name: "provisionMember", body: { env: "test", email: "newhire@example.com", displayName: "New Hire", password: "s3cret!", role: "staff" } },
    { name: "computeAnalysis", body: { env: "test", viewMode: "revenue" } },
    { name: "uploadProductPhoto", body: { env: "test", productId: "PRD-1", photoId: "photo-1", requestId: "photo-1", imageBase64: "AAAA", thumbBase64: "AAAA" } },
    { name: "deleteProductPhoto", body: { env: "test", productId: "PRD-1", photoId: "photo-1", requestId: "del-1" } }
];

const LOCK = HANDLERS.find((h) => h.name === "acquireLock");

function reset() {
    mockState.docs = {};
    mockState.setCalls = [];
    mockState.verifyIdToken = async () => ({ uid: UID });
    mockState.applyMutationResult = { ok: true };
    mockState.applyDeltaResult = { ok: true };
    mockState.applyOperationResult = { ok: true, results: [] };
    mockState.acquireLockResult = { ok: true, acquiredAt: 1000, expiresAt: 91000 };
    mockState.releaseLockResult = { ok: true };
}

// users/{uid} as the attacker writes it: points at a tenant, claims owner.
function seedUserDoc(tenantId, role) {
    mockState.docs["users/" + UID] = { tenantId: tenantId, role: role || "owner", name: "Mallory" };
    mockState.docs["tenants/" + tenantId] = { name: "Tenant " + tenantId };
}

async function call(h) {
    const res = mockRes();
    await handlers[h.name](mockReq({ body: h.body }), res);
    return res;
}

async function assertRefused(h, why) {
    const res = await call(h);
    assert.equal(res.statusCode, 403, h.name + ": " + why + " -> status " + res.statusCode + " " + JSON.stringify(jsonBody(res)));
    assert.equal(jsonBody(res).error, "no-tenant-context", h.name + ": " + why);
    assert.equal(mockState.setCalls.length, 0, h.name + ": " + why + " must write nothing");
}

for (const h of HANDLERS) {
    test("F3 " + h.name + ": users doc names a tenant + role owner but there is NO member doc -> 403 no-tenant-context, nothing written", async () => {
        reset();
        seedUserDoc(VICTIM, "owner");
        await assertRefused(h, "non-member with a self-written users doc");
    });

    test("F3 " + h.name + ": member of another tenant points users doc at a tenant they do not belong to -> 403", async () => {
        reset();
        seedUserDoc(VICTIM, "owner");
        mockState.docs["tenants/" + HOME + "/members/" + UID] = { role: "owner", status: "active" };
        await assertRefused(h, "membership of " + HOME + " must not open " + VICTIM);
    });

    test("F3 " + h.name + ": removed member (users doc survives, member doc deleted) -> 403", async () => {
        reset();
        seedUserDoc(HOME, "admin");
        // the member doc was deleted by the owner; AuthService cannot delete another user's users doc
        await assertRefused(h, "removed member");
    });

    for (const status of ["suspended", "inactive", "banned"]) {
        test("F2 " + h.name + ": member with status '" + status + "' -> 403 no-tenant-context", async () => {
            reset();
            seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "owner" });
            mockState.docs["tenants/" + HOME + "/members/" + UID].status = status;
            await assertRefused(h, "status " + status);
        });
    }

    test("F3 " + h.name + ": unsafe tenantId in the users doc ('a/b', '..', '') -> 403, nothing written", async () => {
        for (const bad of ["a/b", "..", "tenant/staff/S1", "a b", "x\\y"]) {
            reset();
            seedUserDoc(bad, "owner");
            mockState.docs["tenants/" + bad + "/members/" + UID] = { role: "owner", status: "active" };
            await assertRefused(h, "tenantId '" + bad + "'");
        }
    });

    test("control " + h.name + ": a real active member is NOT refused with no-tenant-context (the body is valid, the table is not vacuous)", async () => {
        reset();
        seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "owner" });
        const res = await call(h);
        assert.notEqual(jsonBody(res).error, "no-tenant-context", h.name + " refused a legitimate owner: " + res.statusCode + " " + JSON.stringify(jsonBody(res)));
        assert.notEqual(res.statusCode, 401, h.name);
    });
}

test("S2f-6 a member doc WITHOUT a status field is refused (no legacy tolerance; every member doc is created with a status)", async () => {
    for (const h of HANDLERS) {
        reset();
        seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "owner" });
        delete mockState.docs["tenants/" + HOME + "/members/" + UID].status;
        await assertRefused(h, "missing status");
    }
});

test("S2f-6 actorName comes from the member doc (displayName, then name); the self-writable users doc never names the actor", async () => {
    reset();
    seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "owner" });
    mockState.docs["users/" + UID].name = "Mallory";
    const memberPath = "tenants/" + HOME + "/members/" + UID;
    const last = () => mockState.acquireLockCalls[mockState.acquireLockCalls.length - 1];
    mockState.acquireLockCalls = [];

    mockState.docs[memberPath] = { role: "owner", status: "active", displayName: "Real Owner" };
    let res = await call(LOCK);
    assert.notEqual(res.statusCode, 403);
    assert.equal(last().actorName, "Real Owner");

    mockState.docs[memberPath] = { role: "owner", status: "active", name: "Member Name" };
    await call(LOCK);
    assert.equal(last().actorName, "Member Name");

    mockState.docs[memberPath] = { role: "owner", status: "active" };
    await call(LOCK);
    assert.equal(last().actorName, "", "no member name -> empty, never the users doc name");
});

test("F3b role comes from the member doc only: users.role owner + member.role staff -> product delete 403 role-not-allowed", async () => {
    reset();
    seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "staff" });
    mockState.docs["users/" + UID].role = "owner"; // the lie
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: { env: "test", entity: "inventory", entityId: "PRD-1", action: "delete", requestId: "d1", before: { name: "W" }, after: null, clientTimestamp: 1 } }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "role-not-allowed");
});

test("F3b staff delete: users.role owner + member.role manager -> 403 role-not-allowed", async () => {
    reset();
    seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "manager" });
    mockState.docs["users/" + UID].role = "owner";
    const res = mockRes();
    await handlers.recordMutation(mockReq({ body: { env: "test", entity: "staff", entityId: "S1", action: "delete", requestId: "d2", before: { name: "S" }, after: null, clientTimestamp: 1 } }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "role-not-allowed");
});

test("F3b provisionMember: users.role owner + member.role staff -> 403 not-authorized (cannot mint accounts)", async () => {
    reset();
    seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "staff" });
    mockState.docs["users/" + UID].role = "owner";
    const res = await call(HANDLERS.find((h) => h.name === "provisionMember"));
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "not-authorized");
    assert.equal(mockState.setCalls.length, 0);
});

test("F3b empty member role + users.role owner -> no privilege (fails closed, no fallback to the users doc)", async () => {
    reset();
    seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "staff" });
    mockState.docs["tenants/" + HOME + "/members/" + UID].role = "";
    mockState.docs["users/" + UID].role = "owner";
    const res = await call(HANDLERS.find((h) => h.name === "provisionMember"));
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "not-authorized");
});

test("edge: users doc missing, or tenantId empty/absent -> 403 (unchanged behaviour)", async () => {
    for (const userDoc of [undefined, {}, { tenantId: "" }, { role: "owner" }]) {
        reset();
        if (userDoc) mockState.docs["users/" + UID] = userDoc;
        await assertRefused(HANDLERS[0], "users doc " + JSON.stringify(userDoc));
    }
});

test("monkey: every handler x every refusal state in one sweep, 3 passes, never a 200 and never a write", async () => {
    const states = [
        () => { seedUserDoc(VICTIM, "owner"); },
        () => { seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "owner" }); mockState.docs["tenants/" + HOME + "/members/" + UID].status = "suspended"; },
        () => { seedUserDoc("a/b", "owner"); },
        () => { seedUserDoc(HOME, "admin"); }
    ];
    for (let pass = 0; pass < 3; pass++) {
        for (const h of HANDLERS) {
            for (const seed of states) {
                reset();
                seed();
                const res = await call(h);
                assert.notEqual(res.statusCode, 200, h.name);
                assert.equal(mockState.setCalls.length, 0, h.name);
            }
        }
    }
});

test("guard: every deriveContext call site in index.js belongs to a handler in HANDLERS (add new handlers here)", () => {
    const src = fs.readFileSync(path.join(__dirname, "..", "index.js"), "utf8");
    const sites = (src.match(/await deriveContext\(/g) || []).length;
    assert.equal(sites, HANDLERS.length, "index.js has " + sites + " deriveContext call sites, this file covers " + HANDLERS.length);
});
