"use strict";

// PR #183 review sweep, finding D-1: an edit or a delete of a product whose restock is still queued.
//
// The hazard (H-*): the restock is queued, so the local copy of the product does not hold its stock yet. An edit
// or a delete written meanwhile is a whole-record write whose `before` is that local copy. It is sent AFTER the
// restock landed (the outbox is single-flight per record), the server's compare-and-swap no longer matches and
// answers 409, and the person is left with a stuck change. These tests run the REAL server code to prove the
// hazard, then run the REAL bodies of the new client guard (restockHoldMessage, updateRefusal, deleteProduct)
// in a vm to prove the hold, then pin that no other client path writes a whole inventory record.
// tests/tst_InventoryStore_restockHold.qml has the same cases for CI's qmltestrunner.

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const path = require("node:path");
const OL = require("../lib/operationLogic");
const GL = require("../lib/gatewayLogic");
const { TS, strictDb } = require("./testSupport/strictDb");
const { load, plain, extractFunction, HELPER_DIR } = require("./testSupport/qmlHelpers");

const RP = load("RestockPlan.js");
const RF = load("RestockFlow.js");
const DocLimits = load("DocLimits.js");

const T = "tenants/t1/";
const PRODUCT = { productId: "p1", name: "Tomato", category: "Veg", price: 12.5, stock: 10 };
const QML = path.join(HELPER_DIR, "..", "model", "InventoryStore.qml");
const SRC = fs.readFileSync(QML, "utf8");

// ------------------------------------------------------------------------------ the hazard, on the real server

async function restockOnServer(db) {
    const made = RF.makeInput({ key: RF.newKey(1, () => 0.5), product: PRODUCT, qty: 5, unitCost: 10, reason: "weekly",
        party: "", suppliers: [], now: new Date("2026-06-15T12:00:00Z") });
    assert.equal(made.ok, true);
    const plan = RP.build(made.input);
    assert.equal(plan.ok, true, JSON.stringify(plan));
    const v = OL.validateOperationRequest({ requestId: plan.key, opType: "restock", clientTimestamp: "c", ops: plan.ops });
    assert.equal(v.ok, true, JSON.stringify(v));
    const r = await OL.applyOperation(db, { tenantId: "t1", actorUid: "u", actorRole: "owner", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: "c", serverTimestamp: TS, now: new Date("2026-06-15T12:00:00Z") });
    assert.equal(r.ok, true, JSON.stringify(r));
}

function editParams(overrides) {
    return Object.assign({ tenantId: "t1", actorUid: "u", actorRole: "owner", entity: "inventory", entityId: "p1", action: "update",
        requestId: "edit-1", before: plain(PRODUCT), after: Object.assign(plain(PRODUCT), { name: "Tomato 2" }),
        clientTimestamp: 1, collection: "inventory", serverTimestamp: TS }, overrides || {});
}

test("H-1 an edit whose `before` lacks a restock that landed first is refused by the server with a conflict (409)", async () => {
    const db = strictDb({ [T + "inventory/p1"]: plain(PRODUCT) });
    await restockOnServer(db);
    assert.equal(db.store[T + "inventory/p1"].stock, 15, "the restock landed");
    const r = await GL.applyMutation(db, editParams());
    assert.equal(r.ok, false);
    assert.equal(r.status, 409);
    assert.equal(r.conflict, true);
});

test("H-2 control: the same edit sent BEFORE the restock is accepted, and the restock then lands on the edited record", async () => {
    const db = strictDb({ [T + "inventory/p1"]: plain(PRODUCT) });
    const r = await GL.applyMutation(db, editParams());
    assert.equal(r.ok, true, JSON.stringify(r));
    await restockOnServer(db);
    assert.equal(db.store[T + "inventory/p1"].stock, 15);
    assert.equal(db.store[T + "inventory/p1"].name, "Tomato 2");
});

test("H-3 a delete whose `before` lacks the restock is refused the same way", async () => {
    const db = strictDb({ [T + "inventory/p1"]: plain(PRODUCT) });
    await restockOnServer(db);
    let out;
    try {
        out = await GL.applyMutation(db, editParams({ action: "delete", after: null, requestId: "del-1",
            cleanupEnvPrefix: "dev1", cleanupPrefix: "dev1/tenants/t1/products/p1/" }));
    } catch (e) { assert.fail("a stale delete must answer 409, not throw: " + e.message); }
    assert.equal(out.ok, false);
    assert.equal(out.status, 409);
    assert.ok(db.store[T + "inventory/p1"], "the product is still there");
});

// ------------------------------------------------------------------------------ the client hold, real bodies

function sandbox(opts) {
    const o = Object.assign({ queued: false, parked: false, products: [plain(PRODUCT)] }, opts || {});
    const log = { mutations: [] };
    const ctx = {
        DocLimits, products: o.products, _pendingDeletes: {},
        tooLargeMessage: "TOO-LARGE", parkedWriteMessage: "PARKED", restockPendingMessage: "PENDING",
        hasQueuedRestock: () => o.queued, hasParkedWrite: () => o.parked,
        findIndexById: (id) => { for (let i = 0; i < ctx.products.length; ++i) if (ctx.products[i].productId === id) return i; return -1; },
        _clone: () => ctx.products.map((p) => Object.assign({}, p)),
        Gateway: { recordMutation: (...a) => log.mutations.push(plain(a)) },
        StockBatchStore: { batches: [{ productId: "p1", batchId: "b1" }, { productId: "p2", batchId: "b2" }] },
    };
    vm.createContext(ctx);
    for (const f of ["restockHoldMessage", "updateRefusal", "deleteProduct"]) vm.runInContext(extractFunction("model/InventoryStore.qml", f), ctx);
    return { ctx, log, o };
}

test("C-1 restockHoldMessage: no queued restock = \"\"; queued = the wait message; queued AND parked = the stuck-change message", () => {
    assert.equal(sandbox().ctx.restockHoldMessage("p1"), "");
    assert.equal(sandbox({ queued: true }).ctx.restockHoldMessage("p1"), "PENDING");
    assert.equal(sandbox({ queued: true, parked: true }).ctx.restockHoldMessage("p1"), "PARKED");
    // a parked write that is NOT a restock is not this guard's business (updateProduct has never refused it)
    assert.equal(sandbox({ queued: false, parked: true }).ctx.restockHoldMessage("p1"), "");
});

test("C-2 updateRefusal: an edit of a product with a queued restock is refused, with the hold message, before the size check", () => {
    const h = sandbox({ queued: true });
    assert.equal(h.ctx.updateRefusal("p1", { name: "x" }), "PENDING");
    assert.equal(h.ctx.updateRefusal("p1", undefined), "PENDING", "no fields object: still refused");
    assert.equal(sandbox({ queued: true, parked: true }).ctx.updateRefusal("p1", { name: "x" }), "PARKED");
    const big = "x".repeat(1100 * 1024);
    assert.equal(h.ctx.updateRefusal("p1", { description: big }), "PENDING", "the hold wins over the size message");
});

test("C-3 updateRefusal: with no queued restock the old behaviour is unchanged (\"\" for a small edit, the size message for a huge one)", () => {
    const h = sandbox();
    assert.equal(h.ctx.updateRefusal("p1", { name: "x" }), "");
    assert.equal(h.ctx.updateRefusal("p1", { description: "x".repeat(1100 * 1024) }), "TOO-LARGE");
});

test("C-4 updateRefusal: an unknown product is \"\" even while a restock id is queued (updateProduct itself returns early for it)", () => {
    assert.equal(sandbox({ queued: true }).ctx.updateRefusal("nope", { name: "x" }), "");
});

test("C-5 deleteProduct: refused while a restock is queued; the list, the pending-delete memory, the batches and the outbox are untouched", () => {
    const h = sandbox({ queued: true });
    assert.equal(h.ctx.deleteProduct("p1"), "PENDING");
    assert.equal(h.ctx.products.length, 1);
    assert.deepEqual(plain(h.ctx._pendingDeletes), {});
    assert.equal(h.ctx.StockBatchStore.batches.length, 2);
    assert.deepEqual(h.log.mutations, []);
});

test("C-6 deleteProduct: a parked write wins over the restock message (the older, more specific check stays first)", () => {
    const h = sandbox({ queued: true, parked: true });
    assert.equal(h.ctx.deleteProduct("p1"), "PARKED");
    assert.deepEqual(h.log.mutations, []);
});

test("C-7 deleteProduct: with no queued restock the delete goes ahead exactly as before", () => {
    const h = sandbox();
    assert.equal(h.ctx.deleteProduct("p1"), undefined);
    assert.equal(h.ctx.products.length, 0);
    assert.equal(h.log.mutations.length, 1);
    assert.deepEqual(h.log.mutations[0].slice(0, 3), ["inventory", "p1", "delete"]);
    assert.deepEqual(h.ctx.StockBatchStore.batches.map((b) => b.productId), ["p2"]);
});

test("C-8 deleteProduct of an unknown id with a restock queued for it: still the hold message (nothing to delete, nothing queued)", () => {
    const h = sandbox({ queued: true, products: [] });
    assert.equal(h.ctx.deleteProduct("p1"), "PENDING");
});

// ------------------------------------------------------------------------------ pins: no way around the hold

test("P-1 updateProduct asks updateRefusal before it clones or mutates anything", () => {
    const body = extractFunction("model/InventoryStore.qml", "updateProduct");
    const at = body.indexOf("updateRefusal(productId, fields)");
    assert.ok(at > 0, "updateProduct must call updateRefusal");
    assert.ok(at < body.indexOf("_clone()"), "the refusal comes before the first clone");
    assert.ok(body.indexOf("return refusal") > at && body.indexOf("return refusal") < body.indexOf("_clone()"), "a refusal returns before any change");
});

test("P-2 the only whole-record inventory writers are updateProduct (update), deleteProduct (delete), addProduct and the import (create)", () => {
    const calls = [];
    for (const f of walk(path.join(HELPER_DIR, ".."))) {
        const text = fs.readFileSync(f, "utf8");
        for (const line of text.split("\n")) {
            if (/^\s*\/\//.test(line)) continue;   // a comment that names the call is not a call
            const m = /Gateway\.(recordEdit|recordMutation|recordMutations)\("inventory"[^\n]*/.exec(line);
            if (m) calls.push(path.relative(path.join(HELPER_DIR, ".."), f) + ": " + m[0].trim());
        }
    }
    assert.equal(calls.length, 4, "a NEW whole-record inventory writer must go through restockHoldMessage first:\n" + calls.join("\n"));
    assert.ok(calls.every((c) => c.startsWith("model/InventoryStore.qml: ")));
    assert.equal(calls.filter((c) => c.includes("recordEdit(\"inventory\", productId, \"update\"")).length, 1);
    assert.equal(calls.filter((c) => c.includes("recordMutation(\"inventory\", productId, \"delete\"")).length, 1);
    assert.equal(calls.filter((c) => c.includes("\"create\"")).length, 1, "addProduct's create");
    assert.equal(calls.filter((c) => c.includes("recordMutations(\"inventory\", mutationItems)")).length, 1);
    // ...and the import's bulk call only ever sends creates; its overwrites go through logic.updateProduct.
    const sync = extractFunction("model/InventoryStore.qml", "_upsertManySync");
    assert.equal((sync.match(/action: "/g) || []).length, 2);
    assert.equal((sync.match(/action: "create"/g) || []).length, 2, "the bulk import must only create");
});

test("P-3 each whole-record writer sits inside the function that holds it", () => {
    assert.ok(extractFunction("model/InventoryStore.qml", "updateProduct").includes("Gateway.recordEdit(\"inventory\""));
    const del = extractFunction("model/InventoryStore.qml", "deleteProduct");
    assert.ok(del.indexOf("hasQueuedRestock(productId)") > 0 && del.indexOf("hasQueuedRestock(productId)") < del.indexOf("Gateway.recordMutation("));
    assert.ok(SRC.includes("function restockHoldMessage(productId)"));
});

function walk(dir) {
    const out = [];
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) out.push(...walk(p));
        else if (/\.(qml|js)$/.test(e.name)) out.push(p);
    }
    return out;
}
