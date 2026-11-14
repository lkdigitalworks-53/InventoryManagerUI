"use strict";

// Atomic-ops R4: the REAL bodies of InventoryStore.restock, _applyRestock, _restockFailureText,
// onRestockApplied and onRestockRejected (extracted from qml/model/InventoryStore.qml and run in a vm),
// with fake stores around them and the REAL server code (operationLogic) answering the operation the
// function queued. Gateway's rule is mirrored in the fake: the waiting callback fires first, the
// operationApplied/operationRejected signal after it, always. tests/tst_InventoryStore_restock.qml has the
// same cases for CI's qmltestrunner (the QML engine is the oracle for the glue this sandbox cannot see).

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const OL = require("../lib/operationLogic");
const { TS, strictDb } = require("./testSupport/strictDb");
const { load, plain, extractFunction } = require("./testSupport/qmlHelpers");

const Keys = load("OperationKeys.js");
const RP = load("RestockPlan.js");
const RF = load("RestockFlow.js");
const FC = load("FailureCause.js");

const T = "tenants/t1/";
const FNS = ["restock", "_restockFailureText", "_applyRestock", "onRestockApplied", "onRestockRejected", "applyRestockResults"];

function sandbox(opts) {
    const o = Object.assign({ online: true, parked: false, queued: false, products: [{ productId: "p1", name: "Tomato", category: "Veg", price: 12.5, stock: 10 }],
        suppliers: [{ supplierId: "SUP-009", name: "Acme Farms" }] }, opts || {});
    const log = { gateway: [], activity: [], legacy: [], adopted: new Set(), stock: [], batch: [], tx: [], supplier: [], resync: [], warn: [] };
    const state = { parked: o.parked, queued: o.queued };
    const ctx = {
        RestockFlow: RF, RestockPlan: RP, FailureCause: FC, console: { warn: (...a) => log.warn.push(a.join(" ")) },
        getById: (id) => o.products.find((p) => p.productId === id) || null,
        hasParkedWrite: () => state.parked, hasQueuedRestock: () => state.queued,
        parkedWriteMessage: "PARKED", restockPendingMessage: "PENDING", restockDiscardedMessage: "DISCARDED",
        _restockSettled: {}, _restockNames: {},
        AuthService: { isOnline: o.online },
        OutboxStore: { items: [] },       // option A reads the stored queue; the fake Gateway feeds it like enqueueOperation does
        SupplierStore: { suppliers: o.suppliers, nameOf: (id) => (o.suppliers.find((s) => s.supplierId === id) || {}).name || "",
            addLocalSupplier: (d) => { log.supplier.push(d.supplierId); o.suppliers.push(d); }, syncFromFirebase: () => log.resync.push("supplier") },
        StockBatchStore: { addLocalBatch: (d) => log.batch.push(d.batchId), syncFromFirebase: () => log.resync.push("batch") },
        TransactionStore: { addLocalEntries: (docs) => log.tx.push(...docs.map((x) => x.txId)), syncFromFirebase: () => log.resync.push("tx") },
        // adopt() is the real function's contract: an id already held is ignored. `legacy` counts the old client-written row.
        ActivityLog: { record: (kind, title, sub, id) => { log.legacy.push(id); log.activity.push({ kind, title, sub, id }); },
                       adopt: (d) => { if (log.adopted.has(d.id)) return false; log.adopted.add(d.id); log.activity.push({ kind: d.kind, title: d.title, sub: d.subtitle, id: d.entityId }); return true; } },
        applyRemoteStock: (id, stock) => log.stock.push([id, stock]),
        syncFromFirebase: () => log.resync.push("inventory"),
        Gateway: { recordOperation: (opType, ops, key, options, cb) => {
            log.gateway.push({ opType, ops: plain(ops), key, options: plain(options), cb });
            state.queued = true;      // enqueueOperation is synchronous: the outbox item exists on return
            ctx.OutboxStore.items.push({ opType, requestId: key, ops: plain(ops) });
            return key;
        } },
    };
    vm.createContext(ctx);
    for (const f of FNS) vm.runInContext(extractFunction("model/InventoryStore.qml", f), ctx);
    return { ctx, log, state, taps: () => log.gateway.length };
}

// Run the operation the function queued through the REAL server, as the server would answer.
async function serve(call, db) {
    const d = db || strictDb({ [T + "inventory/p1"]: { productId: "p1", name: "Tomato", stock: 10 } });
    const v = OL.validateOperationRequest({ requestId: call.key, opType: call.opType, clientTimestamp: "c", ops: call.ops });
    assert.equal(v.ok, true, JSON.stringify(v));
    const r = await OL.applyOperation(d, { tenantId: "t1", actorUid: "u", actorRole: "owner", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: "c", serverTimestamp: TS, now: new Date("2026-06-15T12:00:00Z") });
    assert.equal(r.ok, true, JSON.stringify(r));
    return { db: d, answer: { ok: true, results: plain(r.results), idempotentReplay: r.idempotentReplay === true } };
}

// What the Gateway does at a terminal outcome: waiters first, then the signal.
function finish(h, call, res, awaited) {
    h.ctx.OutboxStore.items = h.ctx.OutboxStore.items.filter((i) => i.requestId !== call.key);   // a terminal outcome removes the item first
    if (awaited) call.cb(res);
    if (res.ok) h.ctx.onRestockApplied(call.key, res.results, res.idempotentReplay === true);
    else return h.ctx.onRestockRejected(call.key, res);
    return undefined;
}
function tap(h, args) {
    const out = { calls: [] };
    const a = Object.assign({ id: "p1", qty: 5, party: "", cost: 10, reason: "weekly" }, args || {});
    h.ctx.restock(a.id, a.qty, a.party, a.cost, a.reason, (ok, queued, refusal) => out.calls.push({ ok, queued, refusal }));
    out.call = h.log.gateway[h.log.gateway.length - 1];
    return out;
}

// ---------------------------------------------------------------------------- the happy and offline paths

test("W-1 online, answered in time: callback (true,false), everything applied ONCE even though the signal follows", async () => {
    const h = sandbox();
    const t = tap(h, { party: "Newco" });
    assert.equal(t.calls.length, 0, "an awaiting caller is not answered before the server is");
    assert.equal(t.call.options.awaitServer, true);
    const { answer } = await serve(t.call);
    finish(h, t.call, answer, true);
    assert.deepEqual(t.calls, [{ ok: true, queued: false, refusal: undefined }]);
    assert.deepEqual(h.log.stock, [["p1", 15]]);
    assert.deepEqual(h.log.supplier, ["SUP-001"]); assert.deepEqual(h.log.batch, ["BAT-2026-001"]); assert.deepEqual(h.log.tx, ["tx-p-BAT-2026-001"]);
    assert.equal(h.log.activity.length, 1, "one Activity entry, not two");
    assert.deepEqual(plain(h.log.activity[0]), { kind: "product_restocked", title: "Restocked: Tomato", sub: "+5 · now 15 in stock · from Newco · weekly", id: "p1" });
    assert.deepEqual(h.log.resync, []);
    assert.deepEqual(plain(h.ctx._restockSettled), {}, "the settled flag is consumed by the signal");
    assert.deepEqual(plain(h.ctx._restockNames), {});
});

test("W-2 offline: the caller is told (true,true) at once, nothing changes locally, the later signal applies it once", async () => {
    const h = sandbox({ online: false });
    const t = tap(h, { party: "SUP-009" });
    assert.equal(t.call.options.awaitServer, false);
    t.call.cb({ ok: true, queued: true, requestId: t.call.key });
    assert.deepEqual(t.calls, [{ ok: true, queued: true, refusal: undefined }]);
    assert.deepEqual([h.log.stock, h.log.batch, h.log.tx, h.log.activity], [[], [], [], []]);
    const { answer } = await serve(t.call);
    finish(h, t.call, answer, false);
    assert.deepEqual(h.log.stock, [["p1", 15]]);
    assert.equal(h.log.activity.length, 1);
    assert.equal(h.log.activity[0].sub, "+5 · now 15 in stock · from Acme Farms · weekly");
    assert.deepEqual(h.log.supplier, [], "a known supplier adds none");
    assert.equal(t.calls.length, 1, "the caller is not called a second time");
});

test("W-3 the await window ran out: (true,true), then the signal applies it", async () => {
    const h = sandbox();
    const t = tap(h);
    t.call.cb({ ok: false, pending: true, error: "timeout", requestId: t.call.key });
    assert.deepEqual(t.calls, [{ ok: true, queued: true, refusal: undefined }]);
    const { answer } = await serve(t.call);
    finish(h, t.call, answer, false);
    assert.deepEqual(h.log.stock, [["p1", 15]]);
    assert.equal(h.log.activity.length, 1);
});

test("W-4 a replayed answer (live or later) leaves stock alone and re-reads the inventory and the batches", async () => {
    for (const awaited of [true, false]) {
        const h = sandbox();
        const t = tap(h, { party: "Newco" });
        const first = await serve(t.call);
        const again = await serve(t.call, first.db);
        assert.equal(again.answer.idempotentReplay, true);
        finish(h, t.call, again.answer, awaited);
        assert.deepEqual(h.log.stock, [], "replayed stock is as of the first application");
        assert.deepEqual(h.log.resync, ["inventory", "batch"]);
        assert.equal(h.log.activity.length, 1);
        assert.deepEqual(h.log.batch, ["BAT-2026-001"], "the docs still fill the gaps");
    }
});

test("W-5 an answer that is not exactly one restock: callback still (true,false), nothing applied, everything re-read", () => {
    for (const bad of [[], [{ kind: "zap" }], null]) {
        const h = sandbox();
        const t = tap(h);
        finish(h, t.call, { ok: true, results: bad, idempotentReplay: false }, true);
        assert.deepEqual(t.calls, [{ ok: true, queued: false, refusal: undefined }]);
        assert.deepEqual([h.log.stock, h.log.batch, h.log.tx, h.log.supplier, h.log.activity], [[], [], [], [], []]);
        assert.deepEqual(h.log.resync, ["inventory", "batch", "supplier", "tx"]);
        assert.equal(h.log.warn.length, 1);
    }
});

// ---------------------------------------------------------------------------- rejections

test("W-6 rejected while the caller waits: (false,false,cause), nothing applied, the signal adds no second message", () => {
    const h = sandbox();
    const t = tap(h);
    const rej = { ok: false, error: "conflict", opIndex: 4, conflict: true };
    const announce = finish(h, t.call, rej, true);
    assert.deepEqual(t.calls, [{ ok: false, queued: false, refusal: "Another device changed this at the same time. Nothing was added. Try again" }]);
    assert.equal(announce, "", "the caller already heard it");
    assert.deepEqual([h.log.stock, h.log.batch, h.log.tx, h.log.activity, h.log.resync], [[], [], [], [], []]);
    assert.deepEqual(plain(h.ctx._restockNames), {});
    assert.deepEqual(plain(h.ctx._restockSettled), {});
});

test("W-7 rejected after the caller left (queued first): the signal returns ONE message with the cause and the product name", () => {
    const h = sandbox();
    const t = tap(h);
    t.call.cb({ ok: true, queued: true, requestId: t.call.key });
    const msg = finish(h, t.call, { ok: false, error: "not-found", opIndex: 3 }, false);
    assert.equal(msg, "A queued restock was not saved. Tomato: this product is no longer on the server (probably deleted on another device). Nothing was added");
    assert.equal(t.calls.length, 1);
    assert.deepEqual(plain(h.ctx._restockNames), {});
});

test("W-8 Discard: silent after a queued restock, its own text for a caller still waiting", () => {
    let h = sandbox();
    let t = tap(h);
    t.call.cb({ ok: true, queued: true, requestId: t.call.key });
    assert.equal(finish(h, t.call, { ok: false, error: "discarded", discarded: true }, false), "");
    h = sandbox();
    t = tap(h);
    finish(h, t.call, { ok: false, error: "discarded", discarded: true }, true);
    assert.deepEqual(t.calls, [{ ok: false, queued: false, refusal: "DISCARDED" }]);
});

test("W-9 a rejection after a relaunch has no product name but still a cause; a second signal for the key changes nothing", () => {
    const h = sandbox();
    const msg = h.ctx.onRestockRejected("restock:1-aaaaaaaaaaaa", { ok: false, error: "not-found" });
    assert.match(msg, /^A queued restock was not saved\. this product is no longer on the server/);
    assert.equal(h.ctx.onRestockRejected("restock:1-aaaaaaaaaaaa", { ok: false, error: "conflict" }).startsWith("A queued"), true, "no settled flag, so it is announced again; the Gateway fires one signal per outcome");
});

// ---------------------------------------------------------------------------- refusals before anything is queued

test("W-10 bad quantities and costs are refused with a text, queue nothing, remember nothing", () => {
    for (const qty of [0, -3, NaN, Infinity, "5", null, undefined]) {
        const h = sandbox();
        const t = tap(h, { qty });
        assert.deepEqual(t.calls, [{ ok: false, queued: false, refusal: "Quantity must be greater than zero" }], String(qty));
        assert.equal(h.taps(), 0);
        assert.deepEqual(plain(h.ctx._restockNames), {});
    }
    const h = sandbox();
    assert.equal(tap(h, { cost: -1 }).calls[0].refusal, "Unit cost is not a valid amount");
    assert.equal(tap(h, { qty: 1e308, cost: 5 }).calls[0].refusal, "Unit cost is not a valid amount");
    assert.equal(tap(h, { party: "   " }).calls[0].refusal, "Supplier name is not valid");
    assert.equal(h.taps(), 0);
});

test("W-11 an unknown product answers (false) with no text; no callback never throws on any path", async () => {
    const h = sandbox();
    const t = tap(h, { id: "nope" });
    assert.deepEqual(t.calls, [{ ok: false, queued: false, refusal: undefined }]);
    assert.equal(h.taps(), 0);
    const h2 = sandbox();
    h2.ctx.restock("p1", 0, "", 10, "");                      // refusal, no callback
    h2.ctx.restock("p1", 2, "", 10, "");                      // sent, no callback
    const call = h2.log.gateway[0];
    call.cb({ ok: true, queued: true });
    const { answer } = await serve(call);
    call.cb(answer);                                          // applied, no callback
    assert.equal(h2.log.activity.length, 1);
});

test("W-12 a parked write wins over a queued restock; both refuse with their own text and queue nothing", () => {
    let h = sandbox({ parked: true, queued: true });
    assert.deepEqual(tap(h).calls, [{ ok: false, queued: false, refusal: "PARKED" }]);
    h = sandbox({ queued: true });
    assert.deepEqual(tap(h).calls, [{ ok: false, queued: false, refusal: "PENDING" }]);
    assert.equal(h.taps(), 0);
});

test("W-13 double tap: the first queues, the second (same tick) is refused by the durable latch; exactly one operation", () => {
    const h = sandbox({ online: false });
    const first = tap(h), second = tap(h);
    first.call.cb({ ok: true, queued: true });
    assert.equal(h.taps(), 1);
    assert.deepEqual(second.calls, [{ ok: false, queued: false, refusal: "PENDING" }]);
});

// ---------------------------------------------------------------------------- what is sent

test("W-14 the operation sent: opType restock, a restock key, plan ops for none / known / new supplier", () => {
    const shapes = [["", ["mint", "mutation", "delta", "mutation", "mutation"]],
        ["acme farms", ["mint", "mutation", "delta", "mutation", "mutation"]],
        ["SUP-777", ["mint", "mutation", "delta", "mutation", "mutation"]],
        ["Newco", ["mint", "mint", "mutation", "mutation", "delta", "mutation", "mutation"]]];
    for (const [party, kinds] of shapes) {
        const h = sandbox();
        const t = tap(h, { party });
        assert.equal(t.call.opType, "restock");
        assert.equal(Keys.isRestockKey(t.call.key), true);
        assert.deepEqual(t.call.ops.map((x) => x.kind), kinds, party);
    }
    const h = sandbox();
    assert.equal(tap(h, { party: "acme farms" }).call.ops[1].after.supplierId, "SUP-009", "a known name resolves to its id, no duplicate supplier (O1)");
});

test("W-15 default cost = product cost when none is given; an explicit zero is kept", () => {
    let h = sandbox();
    assert.equal(tap(h, { cost: undefined }).call.ops[1].after.unitCost, 12.5);
    h = sandbox();
    assert.equal(tap(h, { cost: 0 }).call.ops[1].after.unitCost, 0);
});

test("W-16 now and date of the purchase come from the same instant (O4)", () => {
    const h = sandbox();
    const purchase = tap(h).call.ops.find((x) => x.entity === "transaction").after;
    const d = new Date(purchase.timestamp);
    const pad = (n) => (n < 10 ? "0" : "") + n;
    assert.equal(purchase.date, d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()));
});

test("W-17 every tap makes its own key (the latch is cleared between taps here)", () => {
    const h = sandbox();
    const keys = new Set();
    for (let i = 0; i < 50; ++i) { h.state.queued = false; keys.add(tap(h).call.key); }
    assert.equal(keys.size, 50);
});

test("W-18 the awaiting flag follows connectivity", () => {
    assert.equal(tap(sandbox({ online: true })).call.options.awaitServer, true);
    assert.equal(tap(sandbox({ online: false })).call.options.awaitServer, false);
});

test("W-19 OutboxStore.hasQueuedOperationFor: only an operation of that type touching that entity counts", () => {
    const items = [
        { requestId: "a", opType: "completeOrder", ops: [{ kind: "delta", entity: "inventory", entityId: "p1" }] },
        { requestId: "b", entity: "inventory", entityId: "p1", action: "update" },
        { requestId: "c", entity: "inventory", entityId: "p1", deltas: { stock: 1 } },
        { requestId: "d", opType: "restock", ops: [{ kind: "mint", counter: "stock_batch", bind: "batch" }, { kind: "delta", entity: "inventory", entityId: "p2" }] },
    ];
    const ctx = { items };
    vm.createContext(ctx);
    vm.runInContext(extractFunction("model/OutboxStore.qml", "hasQueuedOperationFor"), ctx);
    assert.equal(ctx.hasQueuedOperationFor("restock", "inventory", "p1"), false, "another opType, a plain edit and a delta do not count");
    assert.equal(ctx.hasQueuedOperationFor("restock", "inventory", "p2"), true);
    assert.equal(ctx.hasQueuedOperationFor("completeOrder", "inventory", "p1"), true);
    assert.equal(ctx.hasQueuedOperationFor("restock", "stock_batch", "p2"), false, "the entity must match");
    ctx.items = [];
    assert.equal(ctx.hasQueuedOperationFor("restock", "inventory", "p2"), false);
});

test("W-20 DataModel routes both Gateway signals for opType restock, announces a failure, and refuses a sale of a product with a queued restock; the picker hides it", () => {
    const fs = require("node:fs"), path = require("node:path");
    const rd = (f) => fs.readFileSync(path.join(__dirname, "..", "..", "qml", f), "utf8");
    const dm = rd("model/DataModel.qml");
    assert.match(dm, /else if \(opType === "restock"\) InventoryStore\.onRestockApplied\(requestId, results, replay\)/);
    assert.match(dm, /InventoryStore\.onRestockRejected\(requestId, rejection\)[\s\S]{0,200}dispatcher\.errorOccurred\("inventory", failure\)/);
    assert.match(dm, /InventoryStore\.hasQueuedRestock\(parkedInv\.productId\)/);
    assert.match(dm, /InventoryStore\.restockPendingSaleMessage/);
    // S3: the New Order picker hides it through the sheet's hook (the old combo loop is gone)
    assert.match(rd("pages/NewOrderDialog.qml"), /hasQueuedRestock: function\(id\) \{ return InventoryStore\.hasQueuedRestock\(id\) \}/);
    // S4: and the Edit Order picker the same way (its combo, which never had this guard, is gone)
    assert.match(rd("pages/OrderDetailDialog.qml"), /hasQueuedRestock: function\(id\) \{ return InventoryStore\.hasQueuedRestock\(id\) \}/);
    assert.match(rd("pages/RestockDialog.qml"), /function\(ok, queued, refusal\)/);
    assert.doesNotMatch(rd("pages/RestockDialog.qml"), /supplierFailed/);
    assert.doesNotMatch(dm, /supplierFailed/);
});

test("M-1 monkey: 400 random taps and outcomes in random order never throw and never double-apply", async () => {
    let seed = 11;
    const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    for (let i = 0; i < 400; ++i) {
        const h = sandbox({ online: rnd() < 0.5 });
        const t = tap(h, { qty: pick([1, 2.5, 0, -1, NaN, 9999]), party: pick(["", "Newco", "SUP-009", "acme farms", "  "]), cost: pick([0, 3, undefined, -2]), reason: pick(["", "x", "{{batch}}"]) });
        if (!t.call) { assert.equal(t.calls.length, 1); assert.equal(t.calls[0].ok, false); continue; }
        const awaited = h.ctx.AuthService.isOnline;
        if (!awaited) t.call.cb({ ok: true, queued: true });
        else if (rnd() < 0.3) t.call.cb({ ok: false, pending: true, error: "timeout" });
        const outcome = pick(["applied", "applied", "conflict", "discard", "junk"]);
        const stillWaiting = awaited && t.calls.length === 0;
        if (outcome === "applied") { const { answer } = await serve(t.call); finish(h, t.call, answer, stillWaiting); }
        else if (outcome === "junk") finish(h, t.call, { ok: true, results: [{}], idempotentReplay: false }, stillWaiting);
        else finish(h, t.call, outcome === "discard" ? { ok: false, error: "discarded", discarded: true } : { ok: false, error: "conflict", opIndex: 2 }, stillWaiting);
        assert.equal(t.calls.length, 1, "the caller is answered exactly once");
        assert.ok(h.log.activity.length <= 1, "never two Activity entries for one tap");
        assert.ok(h.log.stock.length <= 1);
        assert.deepEqual(plain(h.ctx._restockSettled), {}, "no flag left behind");
        assert.deepEqual(plain(h.ctx._restockNames), {}, "no name left behind");
    }
});

// ---------------------------------------------------------------------------- review pass 3, option A (queued new supplier)

const FOUR = [1, 2, 3, 4].map((n) => ({ productId: "p" + n, name: "Item " + n, category: "Veg", price: 12.5, stock: 10 }));
// hasQueuedRestock as the real OutboxStore.hasQueuedOperationFor derives it: from the stored queue, per product.
function perProductHold(h) {
    h.ctx.hasQueuedRestock = (id) => h.ctx.OutboxStore.items.some((i) => i.opType === "restock" && i.ops.some((o) => o.entity === "inventory" && o.entityId === id));
}
function optionA(opts) { const h = sandbox(Object.assign({ online: false, products: FOUR, suppliers: [{ supplierId: "SUP-009", name: "Bolt & Co" }] }, opts || {})); perProductHold(h); return h; }

test("W-15 a second restock with the same NEW supplier is refused while the first is queued: nothing sent, nothing remembered, one answer", () => {
    const h = optionA();
    const first = tap(h, { id: "p1", party: { newName: "Acme" } });
    assert.equal(h.taps(), 1);
    const namesBefore = Object.keys(plain(h.ctx._restockNames)).length;
    const second = tap(h, { id: "p2", party: { newName: "  acme " } });
    assert.equal(h.taps(), 1, "the Gateway was not called for the second tap");
    assert.deepEqual(second.calls, [{ ok: false, queued: false, refusal: RF.supplierPendingText("acme") }]);
    assert.equal(Object.keys(plain(h.ctx._restockNames)).length, namesBefore, "the refused tap left no trace");
    assert.equal(h.ctx.OutboxStore.items.length, 1);
    assert.deepEqual(first.calls, [], "the first is still waiting for its answer");
});

test("W-16 the plain string form of the same name is held too", () => {
    const h = optionA();
    tap(h, { id: "p1", party: "Acme" });
    const second = tap(h, { id: "p2", party: "ACME" });
    assert.equal(h.taps(), 1);
    assert.equal(second.calls[0].ok, false);
    assert.equal(second.calls[0].refusal, RF.supplierPendingText("ACME"));
});

test("W-17 a different new name, a known supplier and no supplier are not held", () => {
    const h = optionA();
    tap(h, { id: "p1", party: { newName: "Acme" } });
    const b = tap(h, { id: "p2", party: { newName: "Acme Two" } });
    const c = tap(h, { id: "p3", party: { id: "SUP-009" } });
    const d = tap(h, { id: "p4", party: "" });
    assert.equal(h.taps(), 4);
    for (const t of [b, c, d]) assert.deepEqual(t.calls, [], "queued, not refused");
});

test("W-18 the same product keeps its own message (the product hold is checked first)", () => {
    const h = optionA();
    tap(h, { id: "p1", party: { newName: "Acme" } });
    const again = tap(h, { id: "p1", party: { newName: "Acme" } });
    assert.deepEqual(again.calls, [{ ok: false, queued: false, refusal: "PENDING" }]);
    assert.equal(h.taps(), 1);
});

test("W-19 end to end with the REAL server: after the first restock syncs, the same name is the known supplier and creates nothing", async () => {
    const h = optionA({ online: true });
    const first = tap(h, { id: "p1", party: { newName: "Acme" } });
    assert.equal(tap(h, { id: "p2", party: { newName: "Acme" } }).calls[0].ok, false, "held while the first is queued");
    const { answer } = await serve(first.call);
    finish(h, first.call, answer, true);
    assert.deepEqual(h.log.supplier, ["SUP-001"], "the first created the supplier and the local list has it now");
    const second = tap(h, { id: "p2", party: { newName: "Acme" } });
    assert.deepEqual(second.calls, [], "not held any more");
    assert.equal(h.taps(), 2);
    assert.deepEqual(second.call.ops.filter((o) => o.entity === "supplier"), [], "it resolved to SUP-001: no second supplier is created");
    assert.equal(plain(second.call.ops).some((o) => o.after && o.after.supplierId === "SUP-001"), true, "the batch points at the supplier the first one made");
});

test("W-20 a first restock that is discarded frees the name", () => {
    const h = optionA({ online: true });
    const first = tap(h, { id: "p1", party: { newName: "Acme" } });
    assert.equal(tap(h, { id: "p2", party: { newName: "Acme" } }).calls[0].ok, false);
    finish(h, first.call, { ok: false, discarded: true }, true);
    const second = tap(h, { id: "p2", party: { newName: "Acme" } });
    assert.deepEqual(second.calls, [], "queued, not refused");
    assert.equal(h.taps(), 2);
});

// ------------------------------------------------------------------ R5b: the feed row comes from the server

test("W-23 R5b: the answer carries the server's feed row; it is adopted once and no client-written row is made", async () => {
    const h = sandbox();
    const t = tap(h, { party: "Newco" });
    const { answer } = await serve(t.call);
    assert.equal(answer.results.some((r) => r.entity === "activity"), true);
    finish(h, t.call, answer, true);
    assert.equal(h.log.legacy.length, 0, "no client-written row");
    assert.equal(h.log.activity.length, 1);
    assert.deepEqual(plain(h.log.activity[0]), { kind: "product_restocked", title: "Restocked: Tomato", sub: "+5 · now 15 in stock · from Newco · weekly", id: "p1" });
    h.ctx.onRestockApplied(t.call.key, answer.results, true);      // the same answer again (replay, relaunch): nothing twice
    assert.equal(h.log.activity.length, 1);
    assert.equal(h.log.legacy.length, 0);
});

test("W-24 R5b legacy: an answer to a restock queued by the previous build (no feed row) writes the old client row, once", async () => {
    const h = sandbox();
    const t = tap(h, { party: "Newco" });
    const { answer } = await serve(t.call);
    const legacy = Object.assign({}, answer, { results: answer.results.filter((r) => r.entity !== "activity") });
    finish(h, t.call, legacy, true);
    assert.equal(h.log.legacy.length, 1);
    assert.equal(h.log.activity.length, 1);
    assert.deepEqual(plain(h.log.activity[0]), { kind: "product_restocked", title: "Restocked: Tomato", sub: "+5 · now 15 in stock · from Newco · weekly", id: "p1" });
});

test("W-25 R5b: an answer that cannot be read as one restock (damaged feed row) applies nothing, writes no row, and re-reads", async () => {
    const h = sandbox();
    const t = tap(h, { party: "" });
    const { answer } = await serve(t.call);
    const damaged = answer.results.map((r) => (r.entity === "activity" ? Object.assign({}, r, { after: Object.assign({}, r.after, { id: "act-x" }) }) : r));
    finish(h, t.call, Object.assign({}, answer, { results: damaged }), true);
    assert.deepEqual([h.log.stock, h.log.batch, h.log.tx, h.log.activity, h.log.legacy], [[], [], [], [], []]);
    assert.ok(h.log.resync.length > 0, "everything the operation could have touched is re-read");
});
