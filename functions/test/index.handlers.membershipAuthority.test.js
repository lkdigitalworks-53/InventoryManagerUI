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
// Also pinned here (sweep 2026-10-25): the role must be one of owner/admin/manager/staff (an unknown
// role is refused at the identity step, on every endpoint), every refusal logs one warning with a
// reason code, and only provisionMember reads the tenant doc.
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

    test("S2f-1 " + h.name + ": a role outside owner/admin/manager/staff (empty, unknown, wrong case, number, object, null, missing) -> 403 no-tenant-context, nothing written", async () => {
        for (const role of ["", "viewer", "Owner", "OWNER", " owner", "staff,admin", 7, {}, [], null, undefined]) {
            reset();
            seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "owner" });
            const memberPath = "tenants/" + HOME + "/members/" + UID;
            if (role === undefined) delete mockState.docs[memberPath].role; else mockState.docs[memberPath].role = role;
            mockState.docs["users/" + UID].role = "owner"; // the lie must not rescue it
            await assertRefused(h, "role " + JSON.stringify(role));
        }
    });

    test("S2f-1 " + h.name + ": each of the four valid roles gets past the identity step (the allow-list is not too tight)", async () => {
        for (const role of ["owner", "admin", "manager", "staff"]) {
            reset();
            seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: role });
            const res = await call(h);
            assert.notEqual(jsonBody(res).error, "no-tenant-context", h.name + " refused valid role " + role);
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

test("edge: users doc missing, or tenantId empty/absent -> 403 (unchanged behaviour)", async () => {
    for (const userDoc of [undefined, {}, { tenantId: "" }, { role: "owner" }]) {
        reset();
        if (userDoc) mockState.docs["users/" + UID] = userDoc;
        await assertRefused(HANDLERS[0], "users doc " + JSON.stringify(userDoc));
    }
});

// Seeded PRNG (LCG) so a failure is reproducible: same seed, same sequence.
function lcg(seed) {
    let x = seed >>> 0;
    return () => { x = (Math.imul(x, 1664525) + 1013904223) >>> 0; return x / 4294967296; };
}

test("fuzz (seeded): random users-doc / member-doc shapes x random handler -> allowed iff active member + valid role + tenant named by the users doc, else 403 and no write", async () => {
    const rnd = lcg(20261025);
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    const VALID = ["owner", "admin", "manager", "staff"];
    const TENANT_IDS = [HOME, HOME, HOME, HOME, HOME, HOME, VICTIM, "a/b", "", "..", "x".repeat(65), 123, null, undefined];
    const STATUSES = ["active", "active", "active", "active", "active", "suspended", "inactive", "Active", undefined, null, true];
    const ROLES = ["owner", "admin", "manager", "staff", "owner", "admin", "manager", "staff", "", "viewer", "Owner", undefined, 7, {}];
    let allowedSeen = 0;
    let refusedSeen = 0;
    for (let i = 0; i < 400; i++) {
        reset();
        const tenantId = pick(TENANT_IDS);
        const hasUserDoc = rnd() < 0.9;
        const hasMember = rnd() < 0.85;
        const status = pick(STATUSES);
        const role = pick(ROLES);
        if (hasUserDoc) {
            const u = { role: "owner", name: "Mallory" };
            if (tenantId !== undefined) u.tenantId = tenantId;
            mockState.docs["users/" + UID] = u;
        }
        if (hasMember) {
            const m = {};
            if (status !== undefined) m.status = status;
            if (role !== undefined) m.role = role;
            mockState.docs["tenants/" + HOME + "/members/" + UID] = m; // the only member doc that exists
        }
        // independent oracle: the rule written out, not the code under test
        const allowed = hasUserDoc && tenantId === HOME && hasMember && status === "active" && VALID.indexOf(role) >= 0;
        const h = pick(HANDLERS);
        const label = "i=" + i + " " + h.name + " " + JSON.stringify({ hasUserDoc, tenantId, hasMember, status, role });
        if (allowed) {
            allowedSeen++;
            const res = await call(h);
            assert.notEqual(jsonBody(res).error, "no-tenant-context", label);
        } else {
            refusedSeen++;
            await assertRefused(h, label);
        }
    }
    assert.ok(allowedSeen > 20 && refusedSeen > 100, "the generator must hit both sides (" + allowedSeen + " allowed, " + refusedSeen + " refused)");
});

test("S2f-1 tenantId types in the users doc: number, boolean, object, array, 65 chars, non-ASCII, dot, newline, encoded slash -> refused on every handler", async () => {
    for (const bad of [123, true, {}, [], "x".repeat(65), "t\u00eanant", "a.b", "t\n1", "a%2Fb"]) {
        for (const h of HANDLERS) {
            reset();
            mockState.docs["users/" + UID] = { tenantId: bad, role: "owner" };
            await assertRefused(h, "tenantId " + JSON.stringify(bad));
        }
    }
});

test("S2f-1 Q3 every refusal logs exactly one warning (uid + reason code), the answer stays one no-tenant-context, a legitimate member logs nothing", async () => {
    const memberPath = "tenants/" + HOME + "/members/" + UID;
    const happy = () => seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "owner" });
    const cases = [
        ["no-user-doc", () => {}],
        ["no-tenant", () => { mockState.docs["users/" + UID] = { role: "owner" }; }],
        ["unsafe-tenant", () => { seedUserDoc("a/b", "owner"); }],
        ["no-member", () => { seedUserDoc(VICTIM, "owner"); }],
        ["not-active", () => { happy(); mockState.docs[memberPath].status = "suspended"; }],
        ["not-active", () => { happy(); delete mockState.docs[memberPath].status; }],
        ["invalid-role", () => { happy(); mockState.docs[memberPath].role = "viewer"; }]
    ];
    for (const c of cases) {
        reset();
        mockState.logWarnings.length = 0;
        c[1]();
        await assertRefused(LOCK, c[0]);
        assert.equal(mockState.logWarnings.length, 1, c[0] + ": exactly one warning");
        const w = mockState.logWarnings[0];
        assert.equal(w.msg, "deriveContext refused");
        assert.equal(w.uid, UID);
        assert.equal(w.reason, c[0]);
    }
    reset();
    mockState.logWarnings.length = 0;
    happy();
    const res = await call(LOCK);
    assert.notEqual(jsonBody(res).error, "no-tenant-context");
    assert.equal(mockState.logWarnings.length, 0, "a legitimate member must not log a refusal");
});

test("S2f-1 the log never carries more than 64 characters of the self-writable tenantId", async () => {
    reset();
    mockState.logWarnings.length = 0;
    seedUserDoc("x".repeat(5000), "owner");
    await assertRefused(LOCK, "huge tenantId");
    assert.equal(mockState.logWarnings.length, 1);
    assert.equal(mockState.logWarnings[0].reason, "unsafe-tenant");
    assert.ok(mockState.logWarnings[0].tenantId.length <= 64, "tenantId capped in the log");
});

test("S2f-1 lean identity step: only users/{uid} and the member doc are read for the context; the tenant doc is read by provisionMember alone", async () => {
    for (const h of HANDLERS) {
        reset();
        mockState.getUserByEmail = async () => { throw Object.assign(new Error("none"), { code: "auth/user-not-found" }); };
        mockState.createUser = async () => ({ uid: "new-uid-9" }); // let provisionMember get as far as the tenant read
        seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "owner" });
        const reads = [];
        mockState.docs = new Proxy(mockState.docs, {
            get(target, key) {
                if (typeof key === "string") reads.push(key);
                return target[key];
            }
        });
        await call(h);
        assert.ok(reads.indexOf("users/" + UID) >= 0, h.name + " reads the users doc");
        assert.ok(reads.indexOf("tenants/" + HOME + "/members/" + UID) >= 0, h.name + " reads the member doc");
        assert.equal(reads.indexOf("tenants/" + HOME) >= 0, h.name === "provisionMember", h.name + ": tenant doc read only by provisionMember");
    }
});

test("S2f-1 provisionMember stamps the tenant name from the tenant doc, never from the self-writable users doc", async () => {
    const PROV = HANDLERS.find((x) => x.name === "provisionMember");
    for (const tenantDoc of [{ name: "Real Co" }, { tenantName: "Real Co" }, undefined]) {
        reset();
        mockState.getUserByEmail = async () => { throw Object.assign(new Error("none"), { code: "auth/user-not-found" }); };
        mockState.createUser = async () => ({ uid: "new-uid-9" });
        seedHappyPathAuth(mockState, { uid: UID, tenantId: HOME, role: "owner" });
        mockState.docs["users/" + UID].tenantName = "Evil Co";
        if (tenantDoc) mockState.docs["tenants/" + HOME] = tenantDoc; else delete mockState.docs["tenants/" + HOME];
        const res = await call(PROV);
        assert.equal(res.statusCode, 200, JSON.stringify(jsonBody(res)));
        const expected = tenantDoc ? "Real Co" : "";
        const member = mockState.setCalls.find((c) => c.path === "tenants/" + HOME + "/members/new-uid-9");
        const user = mockState.setCalls.find((c) => c.path === "users/new-uid-9");
        assert.equal(member.data.tenantName, expected, "member doc tenantName");
        assert.equal(user.data.tenantName, expected, "new user doc tenantName");
    }
});

test("guard: every deriveContext call site in index.js belongs to a handler in HANDLERS (add new handlers here)", () => {
    const src = fs.readFileSync(path.join(__dirname, "..", "index.js"), "utf8");
    const sites = (src.match(/await deriveContext\(/g) || []).length;
    assert.equal(sites, HANDLERS.length, "index.js has " + sites + " deriveContext call sites, this file covers " + HANDLERS.length);
});
