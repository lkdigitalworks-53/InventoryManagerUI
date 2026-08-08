"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const LockLogic = require("../lib/lockLogic");

// Fake Firestore double tracking real document data (locks are tiny docs,
// always need to be read before being written/rejected — no existence-only
// fake would be useful here, unlike the original gatewayLogic fake).
function makeFakeLockDb(docs) {
    const writes = [];
    const store = Object.assign({}, docs || {});
    return {
        writes,
        store,
        doc(path) {
            return { path };
        },
        async runTransaction(fn) {
            const txn = {
                async get(ref) {
                    const has = Object.prototype.hasOwnProperty.call(store, ref.path);
                    return { exists: has, data: () => (has ? store[ref.path] : undefined) };
                },
                set(ref, data) {
                    writes.push({ type: "set", path: ref.path, data });
                    store[ref.path] = data;
                },
                delete(ref) {
                    writes.push({ type: "delete", path: ref.path });
                    delete store[ref.path];
                }
            };
            return fn(txn);
        }
    };
}

function acquireParams(overrides) {
    return Object.assign({
        tenantId: "tenant-1",
        entity: "order",
        entityId: "o1",
        requestId: "req-1",
        ttlMs: 90000,
        now: 1000000,
        actorUid: "uid-priya",
        actorName: "Priya",
        actorRole: "staff"
    }, overrides || {});
}

// ── acquireLock ───────────────────────────────────────────────────────────────

test("acquireLock grants when no lock doc exists", async () => {
    const db = makeFakeLockDb({});
    const result = await LockLogic.acquireLock(db, acquireParams());

    assert.equal(result.ok, true);
    const write = db.writes.find((w) => w.path === "tenants/tenant-1/locks/order_o1");
    assert.ok(write, "expected a lock doc to be written");
    assert.equal(write.data.holderUid, "uid-priya");
});

test("acquireLock grants when the existing lock has expired", async () => {
    const db = makeFakeLockDb({
        "tenants/tenant-1/locks/order_o1": {
            holderUid: "uid-other", holderName: "Someone Else", holderRole: "owner",
            acquiredAt: 500, expiresAt: 900000 // expires well before now (1000000)
        }
    });
    const result = await LockLogic.acquireLock(db, acquireParams());

    assert.equal(result.ok, true);
    const write = db.writes.find((w) => w.path === "tenants/tenant-1/locks/order_o1");
    assert.equal(write.data.holderUid, "uid-priya", "the new caller takes over an expired lock");
});

test("acquireLock renews when the existing lock is held by the same caller", async () => {
    const db = makeFakeLockDb({
        "tenants/tenant-1/locks/order_o1": {
            holderUid: "uid-priya", holderName: "Priya", holderRole: "staff",
            acquiredAt: 990000, expiresAt: 1080000 // not expired yet
        }
    });
    const result = await LockLogic.acquireLock(db, acquireParams({ now: 1000000, ttlMs: 90000 }));

    assert.equal(result.ok, true);
    assert.equal(result.expiresAt, 1090000, "renewal pushes expiresAt out from NOW, not the old value");
});

test("acquireLock rejects, writing nothing, when held by a different caller and not expired", async () => {
    const db = makeFakeLockDb({
        "tenants/tenant-1/locks/order_o1": {
            holderUid: "uid-other", holderName: "Manoj", holderRole: "manager",
            acquiredAt: 990000, expiresAt: 1080000
        }
    });
    const result = await LockLogic.acquireLock(db, acquireParams({ now: 1000000 }));

    assert.equal(result.ok, false);
    assert.equal(result.status, 409);
    assert.equal(result.holder.name, "Manoj");
    assert.equal(result.holder.role, "manager");
    assert.equal(result.holder.expiresAt, 1080000);
    assert.equal(db.writes.length, 0, "a rejected acquire must not touch the lock doc at all");
});

test("acquireLock treats expiresAt exactly equal to now as expired (grants)", async () => {
    const db = makeFakeLockDb({
        "tenants/tenant-1/locks/order_o1": {
            holderUid: "uid-other", holderName: "Someone Else", holderRole: "owner",
            acquiredAt: 910000, expiresAt: 1000000 // exactly equal to `now` below
        }
    });
    const result = await LockLogic.acquireLock(db, acquireParams({ now: 1000000 }));

    assert.equal(result.ok, true, "expiresAt <= now must count as expired, not still-valid");
});

// ── releaseLock ─────────────────────────────────────────────────────────────

function releaseParams(overrides) {
    return Object.assign({
        tenantId: "tenant-1",
        entity: "order",
        entityId: "o1",
        holderUid: "uid-priya"
    }, overrides || {});
}

test("releaseLock deletes the lock when the caller's holderUid matches", async () => {
    const db = makeFakeLockDb({
        "tenants/tenant-1/locks/order_o1": { holderUid: "uid-priya", holderName: "Priya", holderRole: "staff" }
    });
    const result = await LockLogic.releaseLock(db, releaseParams());

    assert.equal(result.ok, true);
    assert.equal(db.writes.length, 1);
    assert.equal(db.writes[0].type, "delete");
    assert.equal(Object.prototype.hasOwnProperty.call(db.store, "tenants/tenant-1/locks/order_o1"), false);
});

test("releaseLock is a silent no-op when the caller's holderUid doesn't match (stale/duplicate call)", async () => {
    const db = makeFakeLockDb({
        "tenants/tenant-1/locks/order_o1": { holderUid: "uid-someone-new", holderName: "New Holder", holderRole: "owner" }
    });
    const result = await LockLogic.releaseLock(db, releaseParams({ holderUid: "uid-priya" }));

    assert.equal(result.ok, true, "must not surface as an error to a caller whose lock already expired and got taken");
    assert.equal(db.writes.length, 0, "must not delete someone else's freshly re-acquired lock");
    assert.equal(db.store["tenants/tenant-1/locks/order_o1"].holderUid, "uid-someone-new",
                 "the new holder's lock must be completely untouched");
});

test("releaseLock is a silent no-op when there is no lock doc to release", async () => {
    const db = makeFakeLockDb({});
    const result = await LockLogic.releaseLock(db, releaseParams());

    assert.equal(result.ok, true);
    assert.equal(db.writes.length, 0);
});

// ── validateAcquireRequest / validateReleaseRequest ─────────────────────────

test("validateAcquireRequest rejects missing entity/entityId", () => {
    const result = LockLogic.validateAcquireRequest({ requestId: "r1", ttlMs: 90000 });
    assert.equal(result.ok, false);
    assert.equal(result.status, 400);
    assert.equal(result.error, "missing-fields");
});

test("validateAcquireRequest rejects a missing requestId", () => {
    const result = LockLogic.validateAcquireRequest({ entity: "order", entityId: "o1", ttlMs: 90000 });
    assert.equal(result.ok, false);
    assert.equal(result.error, "missing-fields");
});

test("validateAcquireRequest rejects a non-positive ttlMs", () => {
    const result = LockLogic.validateAcquireRequest({ entity: "order", entityId: "o1", requestId: "r1", ttlMs: 0 });
    assert.equal(result.ok, false);
    assert.equal(result.error, "invalid-ttl");
});

test("validateAcquireRequest accepts a valid request", () => {
    const result = LockLogic.validateAcquireRequest({ entity: "order", entityId: "o1", requestId: "r1", ttlMs: 90000 });
    assert.equal(result.ok, true);
    assert.equal(result.entity, "order");
    assert.equal(result.ttlMs, 90000);
});

// review I3: entity wasn't checked against the known allowlist — any string
// was accepted, letting a buggy/malicious client create junk lock docs under
// an entity name nothing else recognizes.
test("validateAcquireRequest rejects an entity outside the known allowlist", () => {
    const result = LockLogic.validateAcquireRequest({ entity: "not-a-real-entity", entityId: "x1", requestId: "r1", ttlMs: 90000 });
    assert.equal(result.ok, false);
    assert.equal(result.status, 400);
    assert.equal(result.error, "unsupported-entity");
});

test("validateReleaseRequest rejects missing entity/entityId", () => {
    const result = LockLogic.validateReleaseRequest({});
    assert.equal(result.ok, false);
    assert.equal(result.error, "missing-fields");
});

test("validateReleaseRequest accepts a valid request", () => {
    const result = LockLogic.validateReleaseRequest({ entity: "order", entityId: "o1" });
    assert.equal(result.ok, true);
});

// review I3: same allowlist gap existed in validateReleaseRequest.
test("validateReleaseRequest rejects an entity outside the known allowlist", () => {
    const result = LockLogic.validateReleaseRequest({ entity: "not-a-real-entity", entityId: "x1" });
    assert.equal(result.ok, false);
    assert.equal(result.status, 400);
    assert.equal(result.error, "unsupported-entity");
});
