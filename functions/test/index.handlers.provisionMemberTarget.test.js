"use strict";

// S2f-7 (2026-10-26): provisionMember only ADDS members; it never changes an existing member doc.
//
// Why: the endpoint writes with the Admin SDK, which skips firestore.rules. Before this slice it merged
// into whatever member doc the target had, so (PR #159 sweep, finding 6, probes P2 and P3):
//   - an ADMIN could send {uid: <owner>, role: "staff"} and the owner's member doc became staff;
//   - a SUSPENDED member who was "invited" again came back as `status: "active"`;
//   - an admin could demote a peer admin (rules and client forbid it since D-1);
//   - joinedAt and invitedBy were overwritten on every call.
// Role and status changes of an existing member are the rules path (canManageTarget). The one thing
// kept: an exact repeat of a successful call (same role, already active) answers 200 without a write,
// so a client retry after a lost response still works.
//
// Real vs mocked: see testSupport/handlerHarness.js. The handler, deriveContext and canAssignRole are
// REAL index.js code; the Firestore transaction is the harness double (no isolation), so the
// concurrent-create case is proved by the emulator test in test/e2e/recordOperation.e2e.test.js.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody } = require("./testSupport/handlerHarness");

const { handlers, mockState } = installMocks();

const TENANT = "home-tenant";
const ACTOR = "actor-uid";
const TARGET = "target-uid";
const MEMBER = (uid, tenant) => "tenants/" + (tenant || TENANT) + "/members/" + uid;

function reset() {
    mockState.docs = {};
    mockState.setCalls = [];
    mockState.logWarnings.length = 0;
    mockState.runTransactionError = null;
    mockState.getUserByEmail = async () => { throw Object.assign(new Error("none"), { code: "auth/user-not-found" }); };
    mockState.getUser = async (uid) => ({ uid: uid, email: uid + "@example.com" });
    mockState.createUser = async () => { throw new Error("createUser must not be reached in this test"); };
}

// One provisionMember call as `actorRole`, inviting an existing Auth account by uid.
async function provision(actorRole, body) {
    seedHappyPathAuth(mockState, { uid: ACTOR, tenantId: TENANT, role: actorRole });
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: Object.assign({ env: "test", uid: TARGET, role: "staff" }, body || {}) }), res);
    return res;
}

function seedMember(uid, doc) {
    mockState.docs[MEMBER(uid)] = doc;
}

const snapshot = (p) => JSON.parse(JSON.stringify(mockState.docs[p]));
const memberWrites = () => mockState.setCalls.filter((c) => c.path.indexOf("/members/") >= 0);

// ---------------------------------------------------------------- the two probes from the sweep

test("probe P2: an ADMIN naming the OWNER's uid is refused 409 member-exists and the owner doc is untouched", async () => {
    reset();
    seedHappyPathAuth(mockState, { uid: ACTOR, tenantId: TENANT, role: "admin" });
    seedMember("owner-uid", { uid: "owner-uid", role: "owner", status: "active", joinedAt: "2020-01-01T00:00:00.000Z" });
    const before = snapshot(MEMBER("owner-uid"));
    mockState.setCalls = [];
    const res = await provision("admin", { uid: "owner-uid", role: "staff" });
    assert.equal(res.statusCode, 409);
    assert.deepEqual(jsonBody(res), { ok: false, error: "member-exists" });
    assert.deepEqual(mockState.docs[MEMBER("owner-uid")], before, "owner member doc unchanged");
    assert.equal(mockState.setCalls.length, 0, "no write of any kind, not even users/{uid}");
});

test("probe P3: re-inviting a SUSPENDED member is refused and the status stays suspended", async () => {
    reset();
    seedMember(TARGET, { uid: TARGET, role: "staff", status: "suspended", joinedAt: "2020-01-01T00:00:00.000Z" });
    const before = snapshot(MEMBER(TARGET));
    const res = await provision("owner", { role: "staff" });
    assert.equal(res.statusCode, 409);
    assert.equal(jsonBody(res).error, "member-exists");
    assert.deepEqual(mockState.docs[MEMBER(TARGET)], before);
    assert.equal(memberWrites().length, 0);
});

// ---------------------------------------------------------------- role hierarchy (D-1) cannot be bypassed

test("an owner or an admin cannot re-role THEMSELVES through provisionMember (self-demotion)", async () => {
    for (const [actor, role] of [["owner", "admin"], ["admin", "staff"]]) {
        reset();
        seedHappyPathAuth(mockState, { uid: ACTOR, tenantId: TENANT, role: actor });
        const before = snapshot(MEMBER(ACTOR));
        mockState.setCalls = [];
        const res = await provision(actor, { uid: ACTOR, role: role });
        assert.equal(res.statusCode, 409, actor);
        assert.deepEqual(mockState.docs[MEMBER(ACTOR)], before, actor + " doc unchanged");
        assert.equal(mockState.setCalls.length, 0);
    }
});

test("an admin cannot demote a PEER ADMIN (D-1 parity); an owner cannot demote an admin through this endpoint either", async () => {
    for (const [actor, role] of [["admin", "manager"], ["admin", "staff"], ["owner", "manager"], ["owner", "staff"]]) {
        reset();
        seedMember(TARGET, { uid: TARGET, role: "admin", status: "active" });
        const before = snapshot(MEMBER(TARGET));
        const res = await provision(actor, { role: role });
        assert.equal(res.statusCode, 409, actor + " -> " + role);
        assert.deepEqual(mockState.docs[MEMBER(TARGET)], before);
        assert.equal(memberWrites().length, 0);
        assert.equal(mockState.logWarnings.at(-1).reason, "role-differs");
    }
});

test("promotion through this endpoint is refused too: an existing staff member cannot be raised to manager", async () => {
    reset();
    seedMember(TARGET, { uid: TARGET, role: "staff", status: "active" });
    const res = await provision("owner", { role: "manager" });
    assert.equal(res.statusCode, 409);
    assert.equal(mockState.docs[MEMBER(TARGET)].role, "staff");
});

test("an existing member doc without a status (legacy shape) is refused, not 'repaired'", async () => {
    reset();
    seedMember(TARGET, { uid: TARGET, role: "staff" });
    const res = await provision("owner", { role: "staff" });
    assert.equal(res.statusCode, 409);
    assert.equal(mockState.docs[MEMBER(TARGET)].status, undefined);
});

// ---------------------------------------------------------------- the path that must keep working

test("control: a brand-new member is created active with joinedAt and invitedBy, and users/{uid} gets the tenant", async () => {
    reset();
    const res = await provision("owner", { role: "manager" });
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true, uid: TARGET, created: false });
    const m = mockState.docs[MEMBER(TARGET)];
    assert.equal(m.role, "manager");
    assert.equal(m.status, "active");
    assert.equal(m.invitedBy, ACTOR);
    assert.equal(typeof m.joinedAt, "string");
    assert.deepEqual(mockState.docs["users/" + TARGET].tenants, [TENANT]);
});

test("control: a brand-new email creates the Auth account and the member", async () => {
    reset();
    mockState.createUser = async () => ({ uid: "fresh-uid" });
    seedHappyPathAuth(mockState, { uid: ACTOR, tenantId: TENANT, role: "admin" });
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: { env: "test", email: "fresh@example.com", password: "s3cret!", role: "staff" } }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true, uid: "fresh-uid", created: true });
    assert.equal(mockState.docs[MEMBER("fresh-uid")].role, "staff");
});

test("an exact repeat (same role, member already active) answers 200 with NO write: joinedAt and invitedBy survive", async () => {
    reset();
    assert.equal((await provision("owner", { role: "staff" })).statusCode, 200);
    mockState.docs[MEMBER(TARGET)].joinedAt = "2020-01-01T00:00:00.000Z";
    mockState.docs[MEMBER(TARGET)].invitedBy = "first-inviter";
    const before = snapshot(MEMBER(TARGET));
    mockState.setCalls = [];
    const again = await provision("admin", { role: "staff" });
    assert.equal(again.statusCode, 200);
    assert.deepEqual(jsonBody(again), { ok: true, uid: TARGET, created: false });
    assert.deepEqual(mockState.docs[MEMBER(TARGET)], before);
    assert.equal(mockState.setCalls.length, 0, "a retry must not touch members or users");
});

test("an unknown role string is normalised to staff BEFORE the comparison", async () => {
    reset();
    seedMember(TARGET, { uid: TARGET, role: "staff", status: "active" });
    assert.equal((await provision("owner", { role: "superadmin" })).statusCode, 200, "staff vs staff = repeat");
    reset();
    seedMember(TARGET, { uid: TARGET, role: "admin", status: "active" });
    assert.equal((await provision("owner", { role: "superadmin" })).statusCode, 409, "admin vs staff = refused");
    assert.equal(mockState.docs[MEMBER(TARGET)].role, "admin");
});

test("another tenant's membership is not an existing member here: the target is added, the other tenant is untouched", async () => {
    reset();
    mockState.docs[MEMBER(TARGET, "other-tenant")] = { uid: TARGET, role: "owner", status: "active" };
    mockState.docs["users/" + TARGET] = { uid: TARGET, tenantId: "other-tenant", role: "owner", tenants: ["other-tenant"] };
    const otherBefore = snapshot(MEMBER(TARGET, "other-tenant"));
    const res = await provision("owner", { role: "staff" });
    assert.equal(res.statusCode, 200);
    assert.deepEqual(mockState.docs[MEMBER(TARGET, "other-tenant")], otherBefore);
    assert.equal(mockState.docs["users/" + TARGET].tenantId, "other-tenant", "active tenant not yanked");
    assert.equal(mockState.docs[MEMBER(TARGET)].role, "staff");
});

// ---------------------------------------------------------------- earlier gates still answer first

test("the caller's own gates run before the target is looked at: no existence probing through 409 vs 403", async () => {
    reset();
    seedMember(TARGET, { uid: TARGET, role: "owner", status: "active" });
    const manager = await provision("manager", { role: "staff" });
    assert.equal(manager.statusCode, 403);
    assert.equal(jsonBody(manager).error, "not-authorized");
    const adminAssigningAdmin = await provision("admin", { role: "admin" });
    assert.equal(adminAssigningAdmin.statusCode, 403);
    assert.equal(jsonBody(adminAssigningAdmin).error, "role-not-allowed");
});

test("by email: an existing Auth account that is already a member is refused and no Auth account is created", async () => {
    reset();
    mockState.getUserByEmail = async () => ({ uid: TARGET });
    seedMember(TARGET, { uid: TARGET, role: "manager", status: "active" });
    seedHappyPathAuth(mockState, { uid: ACTOR, tenantId: TENANT, role: "owner" });
    const res = mockRes();
    await handlers.provisionMember(mockReq({ body: { env: "test", email: "x@example.com", password: "s3cret!", role: "staff" } }), res);
    assert.equal(res.statusCode, 409);
    assert.equal(mockState.docs[MEMBER(TARGET)].role, "manager");
});

// ---------------------------------------------------------------- logging

test("a refusal logs one structured warning: actor, target, reason, capped tenant id; the answer carries no reason", async () => {
    reset();
    seedMember(TARGET, { uid: TARGET, role: "owner", status: "active" });
    mockState.logWarnings.length = 0;
    const res = await provision("admin", { role: "staff" });
    const refusals = mockState.logWarnings.filter((w) => w.msg === "provisionMember refused");
    assert.equal(refusals.length, 1);
    assert.equal(refusals[0].actor, ACTOR);
    assert.equal(refusals[0].target, TARGET);
    assert.equal(refusals[0].reason, "owner");
    assert.equal(refusals[0].tenantId, TENANT);
    assert.deepEqual(jsonBody(res), { ok: false, error: "member-exists" }, "reason is log-only");
});

test("success paths log no refusal (create and exact repeat)", async () => {
    reset();
    mockState.logWarnings.length = 0;
    await provision("owner", { role: "staff" });
    await provision("owner", { role: "staff" });
    assert.equal(mockState.logWarnings.filter((w) => w.msg === "provisionMember refused").length, 0);
});

// ---------------------------------------------------------------- reads and failures

test("read order: the target's member doc is read first; users/{target} is read only when a member will be created", async () => {
    for (const [seed, expectUsersRead] of [[null, true], [{ uid: TARGET, role: "owner", status: "active" }, false], [{ uid: TARGET, role: "staff", status: "active" }, false]]) {
        reset();
        seedHappyPathAuth(mockState, { uid: ACTOR, tenantId: TENANT, role: "owner" });
        if (seed) seedMember(TARGET, seed);
        const reads = [];
        mockState.docs = new Proxy(mockState.docs, {
            get(target, key) {
                if (typeof key === "string") reads.push(key);
                return target[key];
            }
        });
        const res = mockRes();
        await handlers.provisionMember(mockReq({ body: { env: "test", uid: TARGET, role: "staff" } }), res);
        assert.ok(reads.indexOf(MEMBER(TARGET)) >= 0, "member doc read");
        assert.equal(reads.indexOf("users/" + TARGET) >= 0, expectUsersRead, JSON.stringify(seed));
    }
});

test("a transaction failure is still a 500 with the write-error class, never a 409", async () => {
    reset();
    mockState.runTransactionError = Object.assign(new Error("14 UNAVAILABLE"), { code: 14 });
    const res = await provision("owner", { role: "staff" });
    assert.equal(res.statusCode >= 500, true);
    assert.notEqual(jsonBody(res).error, "member-exists");
    mockState.runTransactionError = null;
});

// ---------------------------------------------------------------- full matrix against an independent oracle

// The oracle below is written from the policy sentence, not from decideProvision: owner and admin
// callers, every existing-member state, every requested role.
function canAssign(actor, role) {
    if (actor === "owner") return ["admin", "manager", "staff"].indexOf(role) >= 0;
    if (actor === "admin") return ["manager", "staff"].indexOf(role) >= 0;
    return false;
}

test("matrix: 2 callers x 13 target states x 3 requested roles; every outcome and every doc matches the policy", async () => {
    const states = [null];
    for (const role of ["owner", "admin", "manager", "staff"]) {
        for (const status of ["active", "suspended", undefined]) states.push({ uid: TARGET, role: role, status: status });
    }
    let ran = 0, created = 0, repeated = 0, refused = 0, forbidden = 0;
    for (const actor of ["owner", "admin"]) {
        for (const state of states) {
            for (const want of ["admin", "manager", "staff"]) {
                reset();
                seedHappyPathAuth(mockState, { uid: ACTOR, tenantId: TENANT, role: actor });
                if (state) { seedMember(TARGET, Object.assign({}, state)); if (state.status === undefined) delete mockState.docs[MEMBER(TARGET)].status; }
                const before = state ? snapshot(MEMBER(TARGET)) : null;
                mockState.setCalls = [];
                const res = await provision(actor, { role: want });
                const label = JSON.stringify([actor, state, want]);
                ran++;
                if (!canAssign(actor, want)) {
                    assert.equal(res.statusCode, 403, label);
                    assert.equal(mockState.setCalls.length, 0, label);
                    forbidden++;
                } else if (state === null) {
                    assert.equal(res.statusCode, 200, label);
                    assert.equal(mockState.docs[MEMBER(TARGET)].role, want, label);
                    assert.equal(mockState.docs[MEMBER(TARGET)].status, "active", label);
                    created++;
                } else if (state.status === "active" && state.role === want) {
                    assert.equal(res.statusCode, 200, label);
                    assert.deepEqual(mockState.docs[MEMBER(TARGET)], before, label);
                    assert.equal(mockState.setCalls.length, 0, label);
                    repeated++;
                } else {
                    assert.equal(res.statusCode, 409, label);
                    assert.equal(jsonBody(res).error, "member-exists", label);
                    assert.deepEqual(mockState.docs[MEMBER(TARGET)], before, label);
                    assert.equal(mockState.setCalls.length, 0, label);
                    refused++;
                }
            }
        }
    }
    assert.equal(ran, 78);
    assert.ok(created > 0 && repeated > 0 && refused > 0 && forbidden > 0, [created, repeated, refused, forbidden].join("/"));
});

// ---------------------------------------------------------------- seeded monkey

function rng(seed) {
    let a = seed >>> 0;
    return () => {
        a = (a + 0x6D2B79F5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

test("seeded monkey: 300 random calls never change an existing member doc and never touch the owner", async () => {
    const rand = rng(20261026);
    const pick = (xs) => xs[Math.floor(rand() * xs.length)];
    let changedExisting = 0, creates = 0;
    for (let i = 0; i < 300; i++) {
        reset();
        const actor = pick(["owner", "admin", "admin", "manager", "staff"]);
        seedHappyPathAuth(mockState, { uid: ACTOR, tenantId: TENANT, role: actor });
        const existing = rand() < 0.2 ? null : { uid: TARGET, role: pick(["owner", "admin", "manager", "staff", "viewer"]), status: pick(["active", "suspended", "removed", ""]), joinedAt: "j" + i };
        if (existing) seedMember(TARGET, Object.assign({}, existing));
        const body = { role: pick(["admin", "manager", "staff", "owner", "", "root", undefined]) };
        if (rand() < 0.15) body.uid = ACTOR; // sometimes the caller targets themselves
        const targetUid = body.uid || TARGET;
        const before = mockState.docs[MEMBER(targetUid)] ? snapshot(MEMBER(targetUid)) : null;
        const res = await provision(actor, body);
        const after = mockState.docs[MEMBER(targetUid)] ? snapshot(MEMBER(targetUid)) : null;
        if (before !== null && JSON.stringify(after) !== JSON.stringify(before)) changedExisting++;
        if (before === null && after !== null) {
            creates++;
            assert.equal(after.status, "active");
            assert.notEqual(after.role, "owner", "this endpoint can never mint an owner");
            assert.equal(res.statusCode, 200);
        }
    }
    assert.equal(changedExisting, 0);
    assert.ok(creates > 0, "the generator must reach the create branch");
});

// ---------------------------------------------------------------- structural guard

test("guard: index.js has exactly one writer of member docs, and it sits after the decision", () => {
    const src = fs.readFileSync(path.join(__dirname, "..", "index.js"), "utf8");
    const memberPathLines = src.split("\n").filter((l) => l.indexOf("\"/members/\"") >= 0 && l.trim().indexOf("//") !== 0);
    assert.equal(memberPathLines.length, 2, "one read in deriveContext, one reference in provisionMember: " + memberPathLines.join(" | "));
    const writes = src.split("\n").filter((l) => /\bmemberRef\b/.test(l) && /\.(set|update|delete|create)\(/.test(l));
    assert.equal(writes.length, 1, "a second write to memberRef would bypass the guard");
    const decide = src.indexOf("MemberProvisionLogic.decideProvision(");
    const write = src.indexOf("txn.set(memberRef");
    assert.ok(decide > 0 && write > decide, "the member write must come after decideProvision");
});
