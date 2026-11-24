"use strict";

// Atomic-ops NO3a: the REAL bodies of OrdersStore.addOrder, _createFailureText, _applyCreateOrder, applyCreateOrderResults,
// _addLocalOrder, onCreateOrderApplied and onCreateOrderRejected (extracted from qml/model/OrdersStore.qml and run in a vm), with
// fake stores around them and the REAL server code (operationLogic) answering the operation the function queued. Gateway's rule
// is mirrored in the fake: the waiting callback fires first, the operationApplied/operationRejected signal after it, always.
// tests/tst_OrdersStore_addOrder.qml has the same cases for CI's qmltestrunner (the QML engine is the oracle for the glue this
// sandbox cannot see). Design: docs/superpowers/specs/2026-11-23-no3a-create-order-wire-design.md.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const OL = require("../lib/operationLogic");
const { TS, strictDb } = require("./testSupport/strictDb");
const { load, plain, extractFunction, HELPER_DIR } = require("./testSupport/qmlHelpers");

const OP = load("OrderPlan.js");
const OF = load("OrderFlow.js");
const FC = load("FailureCause.js");

const FNS = ["addOrder", "_createFailureText", "_applyCreateOrder", "applyCreateOrderResults", "_addLocalOrder", "onCreateOrderApplied",
    "onCreateOrderRejected", "_clone", "_normalizeOrder", "computeOrderTotals", "parseCurrency", "findIndexById", "_rememberBase", "_snap", "_setOrders"];
const STORE_SRC = fs.readFileSync(path.join(HELPER_DIR, "..", "model", "OrdersStore.qml"), "utf8");
const INV = { "PRD-001": { productId: "PRD-001", taxable: true, taxPercent: 18 } };

function sandbox(opts) {
    const o = Object.assign({ online: true, orders: [] }, opts || {});
    const log = { gateway: [], resync: 0, counts: 0, warn: [] };
    const ctx = {
        OrderPlan: OP, OrderFlow: OF, FailureCause: FC, console: { warn: (...a) => log.warn.push(a.join(" ")) },
        Qt: { formatDate: () => "2000-01-01" }, orders: o.orders, revision: 0, _serverBase: {}, _internalOrdersWrite: false,
        createOfflineMessage: OF.OFFLINE_TEXT, _createSettled: {}, _createNames: {},
        AuthService: { isOnline: o.online },
        InventoryStore: { getById: (id) => INV[id] || null },
        _refreshCounts: () => { log.counts++; },
        syncFromFirebase: () => { log.resync++; },
        Gateway: { recordOperation: (opType, ops, key, options, cb) => { log.gateway.push({ opType, ops: plain(ops), key, options: plain(options), cb }); return key; } },
    };
    vm.createContext(ctx);
    for (const f of FNS) vm.runInContext(extractFunction("model/OrdersStore.qml", f), ctx);
    return { ctx, log, ids: () => plain(ctx.orders).map((x) => x.orderId) };
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

// What Gateway does: the waiter first (when the caller still waits), then the signal, always.
function finish(h, call, res, awaited) {
    if (awaited) call.cb(res);
    return res.ok ? h.ctx.onCreateOrderApplied(call.key, res.results, res.idempotentReplay === true) : h.ctx.onCreateOrderRejected(call.key, res);
}

const LINE = { productId: "PRD-001", name: "Tomato", qty: 3, price: 19.99, discountType: "flat", discountValue: 0 };
function tap(h, args) {
    const out = { calls: [] };
    const a = Object.assign({ customer: "  Asha ", date: new Date(2026, 5, 15), email: "", phone: "", products: [LINE], channel: "Online", staff: "S-1" }, args || {});
    h.ctx.addOrder(a.customer, a.date, a.email, a.phone, a.products, a.channel, a.staff, (ok, id, refusal, status) => out.calls.push({ ok, id, refusal, status }));
    out.call = h.log.gateway[h.log.gateway.length - 1];
    return out;
}

// ---------------------------------------------------------------------------- the happy and slow paths

test("W-1 online, answered in time: (true, id, undefined, 'applied'); the server's order is in the list ONCE even though the signal follows", async () => {
    const h = sandbox();
    const t = tap(h);
    assert.equal(t.calls.length, 0, "an awaiting caller is not answered before the server is");
    assert.equal(t.call.opType, "createOrder");
    assert.deepEqual(t.call.options, { awaitServer: true });
    assert.match(t.call.key, /^createOrder:/);
    assert.deepEqual(t.call.ops.map((o) => o.kind), ["mint", "mutation"]);
    assert.deepEqual(h.ids(), [], "nothing is shown locally before the server answers (no optimistic order)");
    const { answer } = await serve(t.call);
    const added = finish(h, t.call, answer, true);
    assert.deepEqual(t.calls, [{ ok: true, id: "ORD-001", refusal: undefined, status: "applied" }]);
    assert.equal(added, "", "the signal after a live settle does nothing (no second auto-approve)");
    assert.deepEqual(h.ids(), ["ORD-001"]);
    const server = plain(answer.results[1].after);
    assert.deepEqual(plain(h.ctx.orders[0]), server, "the local order IS the server's order");
    assert.deepEqual(plain(h.ctx._serverBase["ORD-001"]), server, "the server image is the CAS base for the next edit");
    assert.equal(h.ctx.revision, 1);
    assert.equal(h.log.counts, 1);
    assert.equal(h.log.resync, 0);
    assert.deepEqual([plain(h.ctx._createSettled), plain(h.ctx._createNames)], [{}, {}], "the settled flag is consumed by the signal, the name dropped");
    assert.equal(server.customer, "Asha", "typed text is trimmed (KNOWN-ISSUES 108)");
    assert.equal(server.status, "pending");
    assert.equal(server.date, "2026-06-15", "the day the caller gave, in local time (not the store's fallback)");
    assert.deepEqual([server.subtotal, server.tax, server.total, server.items], [59.97, 10.79, 70.76, 3], "totals come from the store's own computeOrderTotals (tax from inventory, 18%)");
});

test("W-2 the removed per-line loop changed nothing: `qty` and `quantity` lines give the same order; tax is resolved from inventory like before", async () => {
    const a = sandbox(), b = sandbox();
    const ta = tap(a, { products: [{ productId: "PRD-001", name: "Tomato", qty: 2, price: 100 }] });
    const tb = tap(b, { products: [{ productId: "PRD-001", name: "Tomato", quantity: 2, price: 100, taxable: undefined }] });
    const strip = (c) => c.ops.map((o) => (o.after ? Object.assign({}, o.after, { updatedAt: "x" }) : o));
    assert.deepEqual(strip(ta.call), strip(tb.call));
    const after = ta.call.ops[1].after;
    assert.deepEqual([after.products[0].taxable, after.products[0].taxPercent, after.subtotal, after.tax, after.total, after.items], [true, 18, 200, 36, 236, 2]);
    const { answer } = await serve(ta.call);
    finish(a, ta.call, answer, true);
    assert.equal(ta.calls[0].status, "applied");
});

test("W-3 the await window ran out: (true, '', undefined, 'queued'), nothing local; the later signal adds it once and returns its id; the caller is not called twice", async () => {
    const h = sandbox();
    const t = tap(h);
    t.call.cb({ ok: false, pending: true, error: "timeout", requestId: t.call.key });
    assert.deepEqual(t.calls, [{ ok: true, id: "", refusal: undefined, status: "queued" }]);
    assert.deepEqual([h.ids(), h.ctx.revision], [[], 0]);
    const { answer } = await serve(t.call);
    const added = finish(h, t.call, answer, false);
    assert.equal(added, "ORD-001", "the caller of the signal gets the id so it can auto-approve");
    assert.deepEqual(h.ids(), ["ORD-001"]);
    assert.equal(t.calls.length, 1);
    assert.equal(h.log.resync, 0);
    assert.deepEqual(plain(h.ctx._createNames), {});
});

test("W-4 a replayed answer (live or later) adds NO order locally, re-reads the list, and never asks for an auto-approve", async () => {
    for (const awaited of [true, false]) {
        const h = sandbox();
        const t = tap(h);
        const first = await serve(t.call);
        const again = await serve(t.call, first.db);
        assert.equal(again.answer.idempotentReplay, true);
        const added = finish(h, t.call, again.answer, awaited);
        assert.deepEqual(h.ids(), [], "a replayed order is as of the FIRST application and could be stale");
        assert.equal(h.log.resync, 1);
        assert.equal(added, "");
        if (awaited) assert.deepEqual(t.calls, [{ ok: true, id: "ORD-001", refusal: undefined, status: "replayed" }], "its own status: the caller must not be able to mistake it for a first application");
    }
});

test("W-5 a sync landed the order first: it is not added twice and the synced copy is kept; the id is still returned for the auto-approve", async () => {
    const synced = { orderId: "ORD-001", customer: "Asha (from sync)", status: "pending", products: [{ productId: "PRD-001", name: "Tomato", price: 19.99, quantity: 3 }], date: "2026-06-15" };
    const h = sandbox({ orders: [synced] });
    const t = tap(h);
    const { answer } = await serve(t.call);
    finish(h, t.call, answer, false);
    assert.deepEqual(h.ids(), ["ORD-001"]);
    assert.equal(h.ctx.orders[0].customer, "Asha (from sync)");
    assert.equal(h.ctx.revision, 0);
    const t2 = tap(h);
    t2.call.cb({ ok: true, results: answer.results, idempotentReplay: false });
    assert.equal(t2.calls[0].id, "ORD-001");
});

// ---------------------------------------------------------------------------- refusals before anything is queued

test("W-6 offline: refused at once with the connection text, nothing queued, no name kept", () => {
    const h = sandbox({ online: false });
    const t = tap(h);
    assert.deepEqual(t.calls, [{ ok: false, id: "", refusal: OF.OFFLINE_TEXT, status: undefined }]);
    assert.equal(h.log.gateway.length, 0);
    assert.deepEqual(plain(h.ctx._createNames), {});
    const h2 = sandbox();
    h2.ctx.AuthService = undefined;
    const t2 = tap(h2);
    assert.equal(t2.calls[0].refusal, OF.OFFLINE_TEXT, "no AuthService at all reads as offline, never as online");
    for (const odd of [undefined, null, "yes", 1, {}]) {
        const h3 = sandbox();
        h3.ctx.AuthService = { isOnline: odd };
        assert.equal(tap(h3).calls[0].refusal, OF.OFFLINE_TEXT, "only a real `true` is online: " + String(odd));
        assert.equal(h3.log.gateway.length, 0);
    }
});

test("W-7 a bad value is refused with ITS OWN text even offline (pure checks come before the connection check); an oversize doc says so", () => {
    const h = sandbox({ online: false });
    const big = "a".repeat(1100000);
    const cases = [
        [{ customer: "   " }, OF.refusalText("bad-customer")],
        [{ products: [] }, "Add at least one product"],
        [{ products: null }, "Add at least one product"],
        [{ products: [Object.assign({}, LINE, { price: 2e9 })] }, OF.refusalText("bad-line", 0, ["Tomato"])],
        [{ products: [LINE, Object.assign({}, LINE, { name: "Onion", qty: 0 })] }, OF.refusalText("bad-line", 1, ["Tomato", "Onion"])],
        [{ products: [Object.assign({}, LINE, { name: big })] }, OF.TOO_LARGE_TEXT],
    ];
    for (const [over, text] of cases) {
        const t = tap(h, over);
        assert.deepEqual(t.calls, [{ ok: false, id: "", refusal: text, status: undefined }], JSON.stringify(Object.keys(over)));
    }
    assert.match(cases[3][1], /^Line 1 \(Tomato\): .*1000000000$/);
    assert.match(cases[4][1], /^Line 2 \(Onion\): /);
    assert.equal(h.log.gateway.length, 0, "a refusal queues nothing");
    assert.ok(h.log.warn.length >= cases.length);
});

test("W-8 a bad date is not invented: the store falls back to today as it always did, so the planner never sees it, and the order is made", async () => {
    const h = sandbox();
    const t = tap(h, { date: new Date(NaN) });
    assert.equal(t.call.ops[1].after.date, "2000-01-01", "the store's own fallback (today), not an invented day");
    const { answer } = await serve(t.call);
    finish(h, t.call, answer, true);
    assert.equal(t.calls[0].status, "applied");
});

// ---------------------------------------------------------------------------- rejections, unconfirmed, two taps

test("W-9 rejections: the cause is in the text; a settled-live rejection is not announced again; a late one is announced once with the customer's name; a discard is silent", () => {
    for (const [code, re] of [["conflict", /another device created an order with the same number.*Nothing was saved/], ["request-id-in-use", /already used/], ["invalid-order", /Please report this|report/i]]) {
        const h = sandbox();
        const t = tap(h);
        const rej = { ok: false, error: code };
        t.call.cb(rej);
        assert.equal(t.calls.length, 1);
        assert.equal(t.calls[0].ok, false);
        assert.match(t.calls[0].refusal, re, code);
        assert.equal(h.ctx.onCreateOrderRejected(t.call.key, rej), "", "no second announcement for a live caller");
        assert.deepEqual([h.ids(), plain(h.ctx._createSettled), plain(h.ctx._createNames)], [[], {}, {}]);
    }
    const h = sandbox();
    const t = tap(h, { customer: "Zed" });
    const late = h.ctx.onCreateOrderRejected(t.call.key, { ok: false, error: "conflict" });
    assert.match(late, /^A queued order was not placed\. Zed: another device/);
    const t2 = tap(h);
    assert.equal(h.ctx.onCreateOrderRejected(t2.call.key, { ok: false, discarded: true }), "", "a discard on purpose says nothing");
    const t3 = tap(h);
    t3.call.cb({ ok: false, discarded: true });
    assert.equal(t3.calls[0].refusal, OF.DISCARDED_TEXT);
});

test("W-10 an answer that cannot be read is 'unconfirmed': nothing applied, the list is re-read, NO plain retry is offered", () => {
    for (const results of [[], null, [{ kind: "mint", id: "ORD-001", bind: "ord" }], [{ kind: "mint", id: "x", bind: "ord" }, { kind: "mutation", entity: "order", entityId: "x", after: {} }]]) {
        const h = sandbox();
        const t = tap(h);
        t.call.cb({ ok: true, results });
        assert.deepEqual(t.calls, [{ ok: true, id: "", refusal: undefined, status: "unconfirmed" }], JSON.stringify(results));
        assert.deepEqual([h.ids(), h.log.resync], [[], 1]);
        assert.equal(h.ctx.onCreateOrderApplied(t.call.key, results, false), "", "the signal after it does nothing");
        assert.equal(h.log.resync, 1, "re-read once, not twice");
    }
    const h = sandbox();
    assert.equal(h.ctx.onCreateOrderApplied("createOrder:late", [], false), "", "a late unreadable answer re-reads and auto-approves nothing");
    assert.equal(h.log.resync, 1);
});

test("W-11 two taps are two keys and two orders, numbered by the server (no number is burned by a refusal)", async () => {
    const h = sandbox();
    const db = strictDb({});
    tap(h, { customer: "" });                     // refused: queues nothing, burns nothing
    const t1 = tap(h, { customer: "A" }), t2 = tap(h, { customer: "B" });
    assert.notEqual(t1.call.key, t2.call.key);
    const r1 = await serve(t1.call, db), r2 = await serve(t2.call, db);
    finish(h, t1.call, r1.answer, true);
    finish(h, t2.call, r2.answer, true);
    assert.deepEqual(h.ids(), ["ORD-001", "ORD-002"]);
    assert.deepEqual(t1.calls.concat(t2.calls).map((c) => c.id), ["ORD-001", "ORD-002"]);
});

// ---------------------------------------------------------------------------- monkey + source pins

function prng(seed) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }

test("W-12 monkey: 150 seeded random carts through the real store bodies, the real planner and the real server; each is applied once and the list equals the server's docs", async () => {
    const rnd = prng(20261123);
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    const h = sandbox();
    const db = strictDb({});
    const served = [];
    for (let n = 0; n < 150; ++n) {
        const lines = [];
        for (let i = 0, k = 1 + Math.floor(rnd() * 4); i < k; ++i) lines.push({
            productId: pick(["PRD-001", "PRD-002", ""]), name: pick(["Tomato", "Onion {{x}}", "  Rice ", "é漢"]), qty: 1 + Math.floor(rnd() * 5),
            price: Math.round(rnd() * 50000) / 100, discountType: pick(["flat", "percent"]), discountValue: pick([0, 5, 10.5, 30]),
            taxable: pick([undefined, true, false]), taxPercent: pick([undefined, 0, 5, 18, 28]) });
        const t = tap(h, { customer: pick(["Asha", " {{ord}} ", "Zed K"]), products: lines, channel: pick(["", "Online"]) });
        assert.equal(t.calls.length, 0, "case " + n + ": " + JSON.stringify(t.calls));
        const { answer } = await serve(t.call, db);
        finish(h, t.call, answer, true);
        assert.equal(t.calls[0].status, "applied", "case " + n);
        served.push(plain(answer.results[1].after));
    }
    assert.equal(new Set(h.ids()).size, 150);
    assert.deepEqual(plain(h.ctx.orders), served, "every local order is exactly the server's order");
    assert.equal(h.log.resync, 0);
});

test("W-13 source pins: pure checks before the online check, the settled flag before the apply, no nextOrderId, pending and no totals in the store's own doc", () => {
    const body = extractFunction("model/OrdersStore.qml", "addOrder");
    const at = (s) => { const i = body.indexOf(s); assert.ok(i >= 0, "missing: " + s); return i; };
    assert.ok(at("OrderPlan.build(") < at("AuthService.isOnline"), "the pure refusal comes before the connection check");
    assert.ok(at("AuthService.isOnline") < at("Gateway.recordOperation("));
    assert.ok(at("_createSettled[plan.key] = true") < at("_applyCreateOrder("));
    assert.ok(body.indexOf("nextOrderId") < 0, "the number is minted by the server");
    assert.ok(/status: "pending"/.test(body) && !/\bitems:|\btotal:|\bsubtotal:/.test(body), "one author for every total: _normalizeOrder");
    assert.ok(/function addOrder\(customer, date, email, phone, orderProducts, orderChannel, staffId, callback\)/.test(STORE_SRC));
});

// ---------------------------------------------------------------------------- the DataModel half (real bodies, fakes around them)

const DM_SRC = fs.readFileSync(path.join(HELPER_DIR, "..", "model", "DataModel.qml"), "utf8");
function dmSandbox(o) {
    const opt = Object.assign({ autoApprove: true, orders: { "ORD-001": { orderId: "ORD-001" } }, completes: true }, o || {});
    const log = { emitted: [], completed: [], synced: 0, store: [] };
    const ctx = {
        dispatcher: { orderCreationFailed: (m) => log.emitted.push(["failed", m]), orderCreationDeferred: (s) => log.emitted.push(["deferred", s]),
            orderAdded: (id) => log.emitted.push(["added", id]), orderCompletionFailed: (id, m) => log.emitted.push(["completionFailed", id, m]) },
        dataModel: { stockErrorMsg: "no stock" },
        OrdersStore: { autoApproveEnabled: opt.autoApprove, getById: (id) => opt.orders[id] || null,
            addOrder: (...a) => { log.store.push(a.slice(0, 7)); log.cb = a[7]; } },
        _syncOrdersModel: () => { log.synced++; },
        _tryCompleteOrder: (id, cb) => { log.completed.push(id); cb(opt.completes); },
    };
    vm.createContext(ctx);
    const grab = (name) => { const at = DM_SRC.indexOf("function " + name + "("); const open = DM_SRC.indexOf("{", DM_SRC.indexOf(")", at)); let d = 0, i = open; for (; i < DM_SRC.length; i++) { if (DM_SRC[i] === "{") d++; else if (DM_SRC[i] === "}" && --d === 0) break; } return DM_SRC.substring(at, i + 1); };
    vm.runInContext(grab("_autoApproveNewOrder"), ctx);
    vm.runInContext(grab("onAddOrder"), ctx);
    return { ctx, log };
}

test("W-14 DataModel.onAddOrder: the callback's four outcomes reach the dialog as the right signal; auto-approve starts only after an applied answer", () => {
    const run = (res, o) => { const d = dmSandbox(o); d.ctx.onAddOrder("Asha", new Date(0), "e", "p", [LINE], "Online", "S-1"); assert.equal(d.log.completed.length, 0, "nothing completes before the answer"); d.log.cb(...res); return d.log; };
    assert.deepEqual(run([false, "", "No."]).emitted, [["failed", "No."]]);
    assert.deepEqual(run([false, "", undefined]).emitted, [["failed", "Could not add order — try again"]]);
    for (const st of ["queued", "unconfirmed"]) {
        const l = run([true, "", undefined, st]);
        assert.deepEqual(l.emitted, [["deferred", st]]);
        assert.deepEqual([l.completed, l.synced], [[], 0]);
    }
    const ok = run([true, "ORD-001", undefined, "applied"]);
    assert.deepEqual(ok.emitted, [["added", "ORD-001"]]);
    assert.deepEqual([ok.completed, ok.synced], [["ORD-001"], 1]);
    // A replay closes the sheet like an applied order but NEVER auto-approves, even when a sync already put the order in the list
    // (orders has ORD-001 here: the only thing that used to keep a replay from being approved was a race with that sync).
    const rp = run([true, "ORD-001", undefined, "replayed"]);
    assert.deepEqual(rp.emitted, [["added", "ORD-001"]]);
    assert.deepEqual([rp.completed, rp.synced], [[], 1]);
    assert.deepEqual(dmSandbox().log.store, []);
    const d = dmSandbox(); d.ctx.onAddOrder("Asha", new Date(0), "e", "p", [LINE], "Online", "S-1");
    assert.deepEqual(plain(d.log.store[0]).slice(0, 1).concat(plain(d.log.store[0]).slice(2)), ["Asha", "e", "p", plain([LINE]), "Online", "S-1"], "the argument order the store expects");
});

test("W-15 DataModel._autoApproveNewOrder: only for a known id, only when the setting is on, only when the order is in the list; a refused completion is announced with its text", () => {
    const calls = (id, o) => { const d = dmSandbox(o); d.ctx._autoApproveNewOrder(id); return d.log; };
    for (const id of ["", undefined, null]) assert.deepEqual(calls(id).completed, [], String(id));
    assert.deepEqual(calls("ORD-001", { autoApprove: false }).completed, []);
    assert.deepEqual(calls("ORD-009").completed, [], "an order that is not in the list (replay, unconfirmed) is never completed");
    const ok = calls("ORD-001");
    assert.deepEqual([ok.completed, ok.emitted], [["ORD-001"], []]);
    assert.deepEqual(calls("ORD-001", { completes: false }).emitted, [["completionFailed", "ORD-001", "no stock"]]);
});
