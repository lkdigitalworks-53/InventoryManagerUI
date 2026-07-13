"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const CutoverLogic = require("../lib/cutoverLogic");

// ── validateCutoverRequest ───────────────────────────────────────────────────

test("validateCutoverRequest rejects a non-owner", () => {
    const result = CutoverLogic.validateCutoverRequest({ role: "staff" }, { confirm: "CUTOVER" });
    assert.equal(result.ok, false);
    assert.equal(result.status, 403);
    assert.equal(result.error, "owner-only");
});

test("validateCutoverRequest rejects a missing tenant context with a distinct error", () => {
    const result = CutoverLogic.validateCutoverRequest(null, { confirm: "CUTOVER" });
    assert.equal(result.ok, false);
    assert.equal(result.status, 403);
    assert.equal(result.error, "no-tenant-context");
});

test("validateCutoverRequest rejects a missing/incorrect confirmation string", () => {
    const result = CutoverLogic.validateCutoverRequest({ role: "owner" }, {});
    assert.equal(result.ok, false);
    assert.equal(result.status, 400);
    assert.equal(result.error, "confirmation-required");

    const result2 = CutoverLogic.validateCutoverRequest({ role: "owner" }, { confirm: "cutover" });
    assert.equal(result2.ok, false);
    assert.equal(result2.error, "confirmation-required");
});

test("validateCutoverRequest accepts an owner with the exact confirmation string", () => {
    const result = CutoverLogic.validateCutoverRequest({ role: "owner" }, { confirm: "CUTOVER" });
    assert.equal(result.ok, true);
});

// ── buildCutoverMarker ───────────────────────────────────────────────────────

test("buildCutoverMarker produces the correct audit_log shape", () => {
    const marker = CutoverLogic.buildCutoverMarker({
        markerId: "cutover-123",
        tenantId: "tenant-1",
        actorUid: "uid-1",
        actorRole: "owner",
        serverTimestamp: "SERVER_TIMESTAMP_SENTINEL",
        clientTimestamp: 999
    });
    assert.equal(marker.entryId, "cutover-123");
    assert.equal(marker.requestId, "cutover-123");
    assert.equal(marker.tenantId, "tenant-1");
    assert.equal(marker.actorUid, "uid-1");
    assert.equal(marker.actorRole, "owner");
    assert.equal(marker.action, "cutover");
    assert.equal(marker.entity, "tenant");
    assert.equal(marker.entityId, "tenant-1");
    assert.equal(marker.before, null);
    assert.match(marker.after.note, /Fresh-start cutover/);
    assert.equal(marker.serverTimestamp, "SERVER_TIMESTAMP_SENTINEL");
    assert.equal(marker.clientTimestamp, 999);
});

// ── fake batched-write Firestore double ─────────────────────────────────────

function makeFakeDb(collections) {
    const commits = []; // array of committed op-batches, in commit order
    return {
        commits,
        collection(path) {
            return {
                async get() {
                    const docs = (collections[path] || []).map((d) => ({ ref: { path: path + "/" + d.id } }));
                    return { docs, size: docs.length };
                }
            };
        },
        batch() {
            const ops = [];
            return {
                delete(ref) { ops.push({ type: "delete", path: ref.path }); },
                update(ref, data) { ops.push({ type: "update", path: ref.path, data }); },
                async commit() { commits.push(ops.splice(0, ops.length)); }
            };
        }
    };
}

function docs(ids) {
    return ids.map((id) => ({ id }));
}

// ── deleteCollection ─────────────────────────────────────────────────────────

test("deleteCollection deletes every doc in a single commit when under the batch size", async () => {
    const db = makeFakeDb({ "tenants/t1/transactions": docs(["a", "b", "c"]) });
    const count = await CutoverLogic.deleteCollection(db, "tenants/t1/transactions", 400);

    assert.equal(count, 3);
    assert.equal(db.commits.length, 1);
    assert.equal(db.commits[0].length, 3);
    assert.ok(db.commits[0].every((op) => op.type === "delete"));
});

test("deleteCollection chunks commits at the batch size boundary", async () => {
    const db = makeFakeDb({ "tenants/t1/stock_batches": docs(["1", "2", "3", "4", "5"]) });
    const count = await CutoverLogic.deleteCollection(db, "tenants/t1/stock_batches", 2);

    assert.equal(count, 5);
    assert.equal(db.commits.length, 3, "5 docs at batchSize 2 -> commits of 2, 2, 1");
    assert.deepEqual(db.commits.map((c) => c.length), [2, 2, 1]);
});

test("deleteCollection is a no-op (zero commits) for an empty collection", async () => {
    const db = makeFakeDb({ "tenants/t1/stock_movements": [] });
    const count = await CutoverLogic.deleteCollection(db, "tenants/t1/stock_movements", 400);

    assert.equal(count, 0);
    assert.equal(db.commits.length, 0);
});

// ── zeroInventoryStock ───────────────────────────────────────────────────────

test("zeroInventoryStock updates every inventory doc's stock to 0", async () => {
    const db = makeFakeDb({ "tenants/t1/inventory": docs(["sku-1", "sku-2", "sku-3"]) });
    const count = await CutoverLogic.zeroInventoryStock(db, "tenants/t1", 400);

    assert.equal(count, 3);
    assert.equal(db.commits.length, 1);
    assert.equal(db.commits[0].length, 3);
    assert.ok(db.commits[0].every((op) => op.type === "update" && op.data.stock === 0));
});

test("zeroInventoryStock chunks commits at the batch size boundary", async () => {
    const db = makeFakeDb({ "tenants/t1/inventory": docs(["1", "2", "3"]) });
    const count = await CutoverLogic.zeroInventoryStock(db, "tenants/t1", 2);

    assert.equal(count, 3);
    assert.deepEqual(db.commits.map((c) => c.length), [2, 1]);
});
