"use strict";

// Atomic-ops AP3a: the REAL bodies of InventoryStore.addProduct, _addFailureText, _applyAddProduct, applyAddProductResults,
// _addLocalProduct, onAddProductApplied and onAddProductRejected (extracted from qml/model/InventoryStore.qml and run in a vm),
// with fake stores around them and the REAL server code (operationLogic) answering the operation the function queued. Gateway's
// rule is mirrored in the fake: the waiting callback fires first, the operationApplied/operationRejected signal after it, always.
// tests/tst_InventoryStore_addProduct.qml has the same cases for CI's qmltestrunner (the QML engine is the oracle for the glue this
// sandbox cannot see). Design: docs/superpowers/specs/2026-11-16-ap3a-add-product-wire-design.md.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const OL = require("../lib/operationLogic");
const { TS, strictDb } = require("./testSupport/strictDb");
const { load, plain, extractFunction, HELPER_DIR } = require("./testSupport/qmlHelpers");

const AP = load("AddProductPlan.js");
const AF = load("AddProductFlow.js");
const RF = load("RestockFlow.js");
const FC = load("FailureCause.js");

const T = "tenants/t1/";
const FNS = ["addProduct", "_addFailureText", "_applyAddProduct", "applyAddProductResults", "_addLocalProduct", "onAddProductApplied",
    "onAddProductRejected", "_clone", "_newProductDoc", "findIndexById"];
const TOO_LARGE = "TOO-LARGE";

function sandbox(opts) {
    const o = Object.assign({ online: true, products: [], suppliers: [{ supplierId: "SUP-009", name: "Acme Farms" }] }, opts || {});
    const log = { gateway: [], activity: [], adopted: new Set(), batch: [], tx: [], supplier: [], resync: [], warn: [] };
    const ctx = {
        AddProductFlow: AF, AddProductPlan: AP, RestockFlow: RF, FailureCause: FC, console: { warn: (...a) => log.warn.push(a.join(" ")) },
        products: o.products, tooLargeMessage: TOO_LARGE,
        addOfflineMessage: AF.OFFLINE_TEXT, addQueuedMessage: AF.QUEUED_TEXT, addUnconfirmedMessage: AF.UNCONFIRMED_TEXT, addDiscardedMessage: AF.DISCARDED_TEXT,
        _addSettled: {}, _addNames: {},
        AuthService: { isOnline: o.online },
        OutboxStore: { items: [] },
        SupplierStore: { suppliers: o.suppliers, addLocalSupplier: (d) => { log.supplier.push(d.supplierId); o.suppliers.push(d); }, syncFromFirebase: () => log.resync.push("supplier") },
        StockBatchStore: { addLocalBatch: (d) => log.batch.push(d.batchId), syncFromFirebase: () => log.resync.push("batch") },
        TransactionStore: { addLocalEntries: (docs) => log.tx.push(...docs.map((x) => x.txId)), syncFromFirebase: () => log.resync.push("tx") },
        ActivityLog: { adopt: (d) => { if (log.adopted.has(d.id)) return false; log.adopted.add(d.id); log.activity.push({ kind: d.kind, title: d.title, sub: d.subtitle, id: d.entityId }); return true; } },
        syncFromFirebase: () => log.resync.push("inventory"),
        Gateway: { recordOperation: (opType, ops, key, options, cb) => {
            log.gateway.push({ opType, ops: plain(ops), key, options: plain(options), cb });
            ctx.OutboxStore.items.push({ opType, requestId: key, ops: plain(ops) });
            return key;
        } },
    };
    vm.createContext(ctx);
    for (const f of FNS) vm.runInContext(extractFunction("model/InventoryStore.qml", f), ctx);
    return { ctx, log, ids: () => plain(ctx.products).map((p) => p.productId) };
}

async function serve(call, db) {
    const d = db || strictDb({});
    const v = OL.validateOperationRequest({ requestId: call.key, opType: call.opType, clientTimestamp: "c", ops: call.ops });
    assert.equal(v.ok, true, JSON.stringify(v));
    const r = await OL.applyOperation(d, { tenantId: "t1", actorUid: "u", actorRole: "owner", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: "c", serverTimestamp: TS, now: new Date("2026-06-15T12:00:00Z") });
    assert.equal(r.ok, true, JSON.stringify(r));
    return { db: d, answer: { ok: true, results: plain(r.results), idempotentReplay: r.idempotentReplay === true } };
}

function finish(h, call, res, awaited) {
    h.ctx.OutboxStore.items = h.ctx.OutboxStore.items.filter((i) => i.requestId !== call.key);
    if (awaited) call.cb(res);
    if (res.ok) h.ctx.onAddProductApplied(call.key, res.results, res.idempotentReplay === true);
    else return h.ctx.onAddProductRejected(call.key, res);
    return undefined;
}

function tap(h, args) {
    const out = { calls: [] };
    const a = Object.assign({ name: " Tomato ", sku: "TO-1", category: "Veg", description: "Red", price: 20, unit: "kg", stock: 12, minStock: 2, sellingPrice: 30,
        taxable: true, taxPercent: 5, party: "", unitCost: 18, size: "" }, args || {});
    h.ctx.addProduct(a.name, a.sku, a.category, a.description, a.price, a.unit, a.stock, a.minStock, a.sellingPrice, a.taxable, a.taxPercent, a.party, a.unitCost, a.size,
        (ok, id, refusal, status) => out.calls.push({ ok, id, refusal, status }));
    out.call = h.log.gateway[h.log.gateway.length - 1];
    return out;
}

// ---------------------------------------------------------------------------- the happy and slow paths

test("W-1 online, answered in time: callback (true, id, undefined, 'applied'), everything applied ONCE even though the signal follows", async () => {
    const h = sandbox();
    const t = tap(h, { party: "Newco" });
    assert.equal(t.calls.length, 0, "an awaiting caller is not answered before the server is");
    assert.equal(t.call.opType, "addProduct");
    assert.deepEqual(t.call.options, { awaitServer: true });
    assert.equal(h.ctx.products.length, 0, "nothing is shown locally before the server answers (no optimistic product)");
    const { answer } = await serve(t.call);
    finish(h, t.call, answer, true);
    assert.deepEqual(t.calls, [{ ok: true, id: "PRD-001", refusal: undefined, status: "applied" }]);
    assert.deepEqual(h.ids(), ["PRD-001"]);
    const p = plain(h.ctx.products[0]);
    assert.deepEqual(Object.keys(p).sort(), ["category", "description", "minStock", "name", "photoIds", "price", "productId", "sellingPrice", "size", "sku",
        "stock", "supplierId", "taxPercent", "taxable", "unit"].sort(), "the shape _clone and _newProductDoc have always had");
    assert.deepEqual([p.name, p.stock, p.supplierId, p.photoIds], ["Tomato", 12, "SUP-001", []]);
    assert.deepEqual(h.log.supplier, ["SUP-001"]);
    assert.deepEqual(h.log.batch, ["BAT-2026-001"]);
    assert.equal(h.log.tx.length, 1);
    assert.match(h.log.tx[0], /^tx-c-PRD-001-/);
    assert.equal(h.log.activity.length, 1, "one Activity entry, not two");
    assert.deepEqual(plain(h.log.activity[0]), { kind: "product_added", title: "Product added: Tomato", sub: "TO-1 · stock 12", id: "PRD-001" });
    assert.deepEqual(h.log.resync, []);
    assert.deepEqual(plain(h.ctx._addSettled), {}, "the settled flag is consumed by the signal");
    assert.deepEqual(plain(h.ctx._addNames), {});
});

test("W-2 stock 0 and no supplier: product and history row only; known supplier by name adds none", async () => {
    const h = sandbox();
    const t = tap(h, { stock: 0, party: "acme farms" });
    const { answer } = await serve(t.call);
    finish(h, t.call, answer, true);
    assert.equal(t.calls[0].status, "applied");
    assert.deepEqual([h.log.batch, h.log.supplier], [[], []]);
    assert.equal(plain(h.ctx.products[0]).supplierId, "SUP-009");
});

test("W-3 the await window ran out: (true, '', undefined, 'queued'), nothing local; the later signal applies it once; the caller is not called twice", async () => {
    const h = sandbox();
    const t = tap(h);
    t.call.cb({ ok: false, pending: true, error: "timeout", requestId: t.call.key });
    assert.deepEqual(t.calls, [{ ok: true, id: "", refusal: undefined, status: "queued" }]);
    assert.deepEqual([h.ids(), h.log.batch, h.log.tx, h.log.activity], [[], [], [], []]);
    const { answer } = await serve(t.call);
    finish(h, t.call, answer, false);
    assert.deepEqual(h.ids(), ["PRD-001"]);
    assert.equal(h.log.activity.length, 1);
    assert.equal(t.calls.length, 1);
    assert.deepEqual(h.log.resync, []);
});

test("W-4 a replayed answer (live or later) adds NO product locally and re-reads the inventory and the batches", async () => {
    for (const awaited of [true, false]) {
        const h = sandbox();
        const t = tap(h, { party: "Newco" });
        const first = await serve(t.call);
        const again = await serve(t.call, first.db);
        assert.equal(again.answer.idempotentReplay, true);
        finish(h, t.call, again.answer, awaited);
        assert.deepEqual(h.ids(), [], "a replayed product is as of the FIRST application and could be stale");
        assert.deepEqual(h.log.resync, ["inventory", "batch"]);
        assert.deepEqual(h.log.batch, ["BAT-2026-001"], "the batch, supplier and history are still reflected (idempotent in the real stores)");
        if (awaited) assert.deepEqual(t.calls, [{ ok: true, id: "PRD-001", refusal: undefined, status: "applied" }]);
    }
});

test("W-5 a sync landed the product first: it is not added twice, the rest is still reflected", async () => {
    const h = sandbox({ products: [{ productId: "PRD-001", name: "Tomato (from sync)", stock: 12, minStock: 2, price: 20, sellingPrice: 30, taxable: true, taxPercent: 5, size: "", unit: "kg", description: "", photoIds: [], supplierId: "" }] });
    const t = tap(h);
    const { answer } = await serve(t.call);
    finish(h, t.call, answer, true);
    assert.deepEqual(h.ids(), ["PRD-001"]);
    assert.equal(h.ctx.products[0].name, "Tomato (from sync)", "the synced copy is kept");
    assert.deepEqual(h.log.batch, ["BAT-2026-001"]);
});

// ---------------------------------------------------------------------------- refusals before anything is queued

test("W-6 offline: refused at once with the connection text, nothing queued, no key burned, no callback delay", () => {
    const h = sandbox({ online: false });
    const t = tap(h);
    assert.deepEqual(t.calls, [{ ok: false, id: "", refusal: AF.OFFLINE_TEXT, status: undefined }]);
    assert.equal(h.log.gateway.length, 0);
    assert.deepEqual(plain(h.ctx._addNames), {});
});

test("W-7 a bad value is refused with ITS OWN text even offline (pure checks come before the connection check); an oversize doc says so", () => {
    const h = sandbox({ online: false });
    for (const [over, text] of [[{ price: -1 }, AF.refusalText("bad-price")], [{ name: "   " }, AF.refusalText("bad-name")], [{ stock: -3 }, AF.refusalText("bad-stock")],
        [{ taxPercent: 120 }, AF.refusalText("bad-tax")], [{ party: "   " }, AF.refusalText("bad-supplier")], [{ description: "a".repeat(1100000) }, TOO_LARGE]]) {
        const t = tap(h, over);
        assert.deepEqual(t.calls, [{ ok: false, id: "", refusal: text, status: undefined }], JSON.stringify(Object.keys(over)));
    }
    assert.equal(h.log.gateway.length, 0);
});

test("W-8 no callback given: no throw on any path", async () => {
    const h = sandbox();
    assert.doesNotThrow(() => h.ctx.addProduct("A", "S", "C", "", 1, "pc", 1, 0, 2, false, 0));
    assert.doesNotThrow(() => h.ctx.addProduct("A", "S", "C", "", -1, "pc", 1, 0, 2, false, 0));
    const off = sandbox({ online: false });
    assert.doesNotThrow(() => off.ctx.addProduct("A", "S", "C", "", 1, "pc", 1, 0, 2, false, 0));
});

test("W-9 the same NEW supplier name while a restock or an add that creates it is still queued: refused; a known supplier or none is not", () => {
    const h = sandbox();
    const first = tap(h, { party: "Newco" });
    assert.equal(first.calls.length, 0);
    const second = tap(h, { party: "newco" });
    assert.deepEqual(second.calls, [{ ok: false, id: "", refusal: AF.supplierPendingText("newco"), status: undefined }]);
    assert.equal(h.log.gateway.length, 1, "the second add queued nothing");
    assert.equal(tap(h, { party: "SUP-009" }).calls.length, 0, "a known supplier is fine");
    assert.equal(tap(h, { party: "" }).calls.length, 0, "no supplier is fine");
    h.ctx.OutboxStore.items.push({ opType: "restock", requestId: "restock:x", ops: [{ kind: "mutation", entity: "supplier", action: "create", after: { name: "Other Co" } }] });
    assert.equal(tap(h, { party: "other co" }).calls[0].refusal, AF.supplierPendingText("other co"), "a queued RESTOCK that creates it counts too");
});

// ---------------------------------------------------------------------------- rejections

test("W-10 rejected live: (false, '', text naming the typed name), nothing local, and the signal that follows says nothing more", async () => {
    const h = sandbox();
    const t = tap(h, { name: " Tomato " });
    const rej = { ok: false, error: "conflict", requestId: t.call.key };
    const announced = finish(h, t.call, rej, true);
    assert.deepEqual(t.calls, [{ ok: false, id: "", refusal: FC.forAddProduct(rej, "Tomato").text, status: undefined }]);
    assert.match(t.calls[0].refusal, /^Tomato: /);
    assert.match(t.calls[0].refusal, /Nothing was added/);
    assert.equal(announced, "");
    assert.deepEqual([h.ids(), h.log.batch, h.log.tx, h.log.activity, h.log.resync], [[], [], [], [], []]);
    assert.deepEqual(plain(h.ctx._addSettled), {});
    assert.deepEqual(plain(h.ctx._addNames), {});
});

test("W-11 rejected after the caller left (queued first): the signal announces it with the typed name; a discard announces nothing", () => {
    const h = sandbox();
    const t = tap(h, { name: "Mango" });
    t.call.cb({ ok: false, pending: true, requestId: t.call.key });
    const msg = finish(h, t.call, { ok: false, error: "mint-exhausted" }, false);
    assert.match(msg, /^A queued product was not added\. The server could not reserve a new product number/);
    const h2 = sandbox();
    const t2 = tap(h2);
    t2.call.cb({ ok: false, pending: true, requestId: t2.call.key });
    assert.equal(finish(h2, t2.call, { ok: false, error: "discarded", discarded: true }, false), "");
    assert.deepEqual(plain(h2.ctx._addNames), {}, "the name is forgotten");
    const h3 = sandbox();
    const t3 = tap(h3);
    const live = { ok: false, error: "discarded", discarded: true };
    finish(h3, t3.call, live, true);
    assert.equal(t3.calls[0].refusal, AF.DISCARDED_TEXT);
});

test("W-12 after a relaunch nothing remembers the name: a late rejection still reads well, an unknown code is generic and safe", () => {
    const h = sandbox();
    const msg = h.ctx.onAddProductRejected("addProduct:gone", { ok: false, error: "conflict" });
    assert.match(msg, /^A queued product was not added\. another device added something/);
    assert.match(h.ctx.onAddProductRejected("addProduct:gone", { ok: false, error: "weird" }), /^A queued product was not added\. /);
    assert.doesNotThrow(() => h.ctx.onAddProductRejected("addProduct:gone", undefined));
    assert.doesNotThrow(() => h.ctx.onAddProductRejected("addProduct:gone", null));
});

// ---------------------------------------------------------------------------- committed but unreadable (D-AP3-4)

test("W-13 an answer that cannot be read: (true, '', undefined, 'unconfirmed') ONCE, nothing applied, ALL four lists re-read, no retry is invited", async () => {
    const h = sandbox();
    const t = tap(h, { party: "Newco" });
    const { answer } = await serve(t.call);
    const damaged = { ok: true, results: answer.results.filter((r) => !(r.kind === "mutation" && r.entity === "activity")) };
    finish(h, t.call, damaged, true);
    assert.deepEqual(t.calls, [{ ok: true, id: "", refusal: undefined, status: "unconfirmed" }]);
    assert.deepEqual([h.ids(), h.log.supplier, h.log.batch, h.log.tx, h.log.activity], [[], [], [], [], []]);
    assert.deepEqual(h.log.resync, ["inventory", "batch", "supplier", "tx"]);
    assert.ok(h.log.warn.some((w) => /not applied/.test(w)));
    assert.equal(t.calls.length, 1);
    assert.equal(h.log.gateway.length, 1, "nothing was sent again");
});

test("W-14 the same unreadable answer arriving later (signal only) re-reads too and says nothing to the person", async () => {
    const h = sandbox();
    const t = tap(h);
    t.call.cb({ ok: false, pending: true, requestId: t.call.key });
    finish(h, t.call, { ok: true, results: [{ kind: "mint", bind: "prd", id: "PRD-007" }] }, false);
    assert.deepEqual(h.log.resync, ["inventory", "batch", "supplier", "tx"]);
    assert.deepEqual(h.ids(), []);
});

test("W-15 reflect-level damage never throws out of the wire, whatever the answer looks like", () => {
    for (const results of [undefined, null, "x", 7, {}, [], [null], [{}], [{ kind: "mint" }], [{ kind: "mutation", entity: "inventory" }]]) {
        const h = sandbox();
        const t = tap(h);
        assert.doesNotThrow(() => finish(h, t.call, { ok: true, results }, true), JSON.stringify(results));
        assert.deepEqual(t.calls, [{ ok: true, id: "", refusal: undefined, status: "unconfirmed" }], JSON.stringify(results));
    }
});

// ---------------------------------------------------------------------------- keys, source order, monkey

test("W-16 every tap makes its OWN key (two adds are two operations, never a replay of one another)", () => {
    const h = sandbox();
    const a = tap(h), b = tap(h), c = tap(h, { name: "Other" });
    const keys = [a.call.key, b.call.key, c.call.key];
    assert.equal(new Set(keys).size, 3);
    for (const k of keys) assert.match(k, /^addProduct:[0-9]+-[0-9a-z]+$/);
});

test("W-17 source order inside addProduct: pure checks, then the supplier clash, then the connection check, then the name memory, then the send", () => {
    const body = extractFunction("model/InventoryStore.qml", "addProduct");
    const at = (s) => { const i = body.indexOf(s); assert.ok(i > 0, s); return i; };
    const order = [at("AddProductFlow.makeInput("), at("AddProductPlan.build(made.input)"), at("queuedNewSupplierClash("), at("AuthService.isOnline === true"),
        at("_addNames[plan.key]"), at("Gateway.recordOperation(\"addProduct\"")];
    assert.deepEqual([...order].sort((x, y) => x - y), order);
    assert.ok(body.indexOf("_addSettled[plan.key] = true") > order[5], "the settled flag is set only once an answer exists");
    // the old multi-write path is gone from this function
    for (const gone of ["Gateway.recordMutation(", "ActivityLog.record(", "TransactionStore.recordCreated(", "StockBatchStore.addBatch(", "nextProductId(", "_resolveSupplierId(", "SupplierStore.addSupplier("])
        assert.equal(body.indexOf(gone), -1, gone + " must not be in the atomic add");
});

test("W-18 the removed helpers are really gone and the kept one is documented", () => {
    const src = fs.readFileSync(path.join(HELPER_DIR, "..", "model", "InventoryStore.qml"), "utf8");
    assert.equal(src.indexOf("function _resolveSupplierId("), -1);
    assert.match(src, /NO production caller any more/);
    assert.equal((src.match(/nextProductId\(/g) || []).length, 1, "only its definition remains");
});

test("M-1 monkey: 300 random taps with random answers keep the invariants (callback once per accepted tap, ids unique, no stray state)", async () => {
    let seed = 99;
    const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >>> 8) % n; };
    const h = sandbox();
    let db = strictDb({});
    let acceptedTaps = 0;
    for (let i = 0; i < 300; ++i) {
        const online = rnd(6) !== 0;
        h.ctx.AuthService.isOnline = online;
        const over = {};
        if (rnd(8) === 0) over.price = -1;
        if (rnd(5) === 0) over.party = ["Newco", "SUP-009", "", "Zed"][rnd(4)];
        if (rnd(4) === 0) over.stock = rnd(3);
        const before = h.log.gateway.length;
        const t = tap(h, over);
        if (h.log.gateway.length === before) { assert.equal(t.calls.length, 1, "a refusal answers at once, exactly once"); assert.equal(t.calls[0].ok, false); continue; }
        acceptedTaps++;
        const how = rnd(5);
        if (how === 0) { t.call.cb({ ok: false, pending: true, requestId: t.call.key }); const r = await serve(t.call, db); db = r.db; finish(h, t.call, r.answer, false); }
        else if (how === 1) { finish(h, t.call, { ok: false, error: "conflict" }, true); }
        else if (how === 2) { const r = await serve(t.call, db); db = r.db; finish(h, t.call, r.answer, true); finish(h, t.call, r.answer, false); }
        else if (how === 3) { const r = await serve(t.call, db); db = r.db; finish(h, t.call, { ok: true, results: r.answer.results.slice(1) }, true); }
        else { const r = await serve(t.call, db); db = r.db; finish(h, t.call, r.answer, true); }
        assert.equal(t.calls.length <= 1, true, "never two callbacks for one tap");
        const ids = h.ids();
        assert.equal(new Set(ids).size, ids.length, "no product twice");
    }
    assert.ok(acceptedTaps > 100, "the monkey reached the gateway: " + acceptedTaps);
    assert.equal(Object.keys(plain(h.ctx._addSettled)).length, 0, "no settled flag is left behind: every settled op's signal followed");
});
