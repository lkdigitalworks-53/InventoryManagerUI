"use strict";

// P1 S2d-2, the CLIENT half of the kind hint (design docs/superpowers/specs/2026-11-18-p1-s2d2-derived-kind-hint-design.md).
// None of the QML here can run in this sandbox (no Qt, by rule), so these tests run the REAL text of the client code in a vm:
// the helper qml/helper/StockMovements.js as it is, and the REAL bodies of Gateway.recordDelta, OutboxStore.enqueueDelta,
// InventoryStore.deductStock / _kindHintFor, then feed the result to the REAL server. tests/tst_*.qml carry the same cases
// for CI's qmltestrunner.
//   KC-1..3 helper parity with the server       KC-4 coalescing        KC-5 Gateway.recordDelta
//   KC-6 OutboxStore.enqueueDelta               KC-7 InventoryStore    KC-8 client -> server, imported-order case
//   KC-9 wiring pins (text)                     KC-10 FailureCause     KC-11 monkey

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const G = require("../lib/gatewayLogic");
const M = require("../lib/movementLogic");
const { TS, strictDb, rowsOf } = require("./testSupport/strictDb");
const { load, plain, extractFunction, HELPER_DIR } = require("./testSupport/qmlHelpers");

const SM = load("StockMovements.js");
const SW = load("StuckWrites.js");
const FC = load("FailureCause.js");
const QML = (rel) => fs.readFileSync(path.join(HELPER_DIR, "..", rel), "utf8");
const T = "tenants/t1/";

// ── helper parity ───────────────────────────────────────────────────────────
test("KC-1 HINT_KINDS mirrors the server list exactly", () => {
    assert.deepEqual(plain(SM.HINT_KINDS), M.HINT_KINDS);
});

// What the server decides for one recordDelta body (request validation only; applying is KH-*).
const serverSays = (entity, deltas, movements, kindHint) => {
    const body = { entity, entityId: "p1", requestId: "r1", deltas };
    if (movements !== undefined) body.movements = movements;
    if (kindHint !== undefined) body.kindHint = kindHint;
    const v = G.validateDeltaRequest(body);
    return v.ok ? "" : v.error;
};
// The client: the movement check first, then the hint check, like Gateway.recordDelta.
const clientSays = (entity, deltas, movements, kindHint) =>
    SM.validate(entity, deltas, {}, movements) || SM.validateKindHint(entity, deltas, movements, kindHint);

test("KC-2 validateKindHint: no hint is fine; same code as the server for every fault, in the same order", () => {
    const ok = [{ kind: "sale", qty: -3, reason: "" }];
    const cases = [
        ["inventory", { stock: -3 }, undefined, undefined, ""],
        ["inventory", { stock: -3 }, undefined, null, ""],
        ["inventory", { stock: -3 }, undefined, "sale", ""],
        ["inventory", { stock: -3 }, undefined, "receipt", ""],
        ["inventory", { stock: -3, minStock: 1 }, undefined, "sales_return", ""],
        ["inventory", { stock: -3 }, undefined, "adjustment", ""],
        ["inventory", { stock: -3 }, undefined, "loss", "invalid-kind-hint"],
        ["inventory", { stock: -3 }, undefined, "gift", "invalid-kind-hint"],
        ["inventory", { stock: -3 }, undefined, "free_sample", "invalid-kind-hint"],
        ["inventory", { stock: -3 }, undefined, "", "invalid-kind-hint"],
        ["inventory", { stock: -3 }, undefined, "toString", "invalid-kind-hint"],
        ["inventory", { stock: -3 }, undefined, "__proto__", "invalid-kind-hint"],
        ["inventory", { stock: -3 }, undefined, 5, "invalid-kind-hint"],
        ["inventory", { stock: -3 }, undefined, {}, "invalid-kind-hint"],
        ["inventory", { stock: -3 }, undefined, ["sale"], "invalid-kind-hint"],
        ["inventory", { stock: -3 }, ok, "sale", "kind-hint-with-movements"],
        ["inventory", { stock: -3 }, ok, "loss", "invalid-kind-hint"],
        ["inventory", { stock: -3 }, ok, undefined, ""],
        ["stock_batch", { qtyRemaining: -3 }, undefined, "sale", "invalid-kind-hint"],
        ["inventory", { minStock: 1 }, undefined, "sale", "invalid-kind-hint"],
        ["order", { stock: -1 }, undefined, "sale", "invalid-kind-hint"],
        ["inventory", { stock: -3 }, [{ kind: "bogus", qty: -3 }], "sale", "invalid-movement-kind"]
    ];
    for (const [entity, deltas, movements, hint, want] of cases) {
        const label = JSON.stringify([entity, deltas, movements, hint]);
        assert.equal(clientSays(entity, deltas, movements, hint), want, "client " + label);
        assert.equal(serverSays(entity, deltas, movements, hint), want, "server " + label);
    }
});

test("KC-3 monkey: 4000 random delta calls, client and server never disagree on accept vs reject, and give the same code", () => {
    let s = 7;
    const rnd = () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    for (let n = 0; n < 4000; n++) {
        const entity = pick(["inventory", "inventory", "inventory", "stock_batch", "order"]);
        const deltas = pick([{ stock: -3 }, { stock: 2 }, { stock: -3, minStock: 1 }, { minStock: 1 }, { qtyRemaining: -1 }]);
        const sum = deltas.stock || 0;
        const movements = pick([undefined, undefined, undefined, [{ kind: sum < 0 ? "sale" : "receipt", qty: sum || 1, reason: "" }], [{ kind: "bogus", qty: 1 }], []]);
        const hint = pick([undefined, null, "sale", "receipt", "sales_return", "adjustment", "loss", "gift", "free_sample", "", "x", "__proto__", 5, {}, []]);
        const c = clientSays(entity, deltas, movements, hint);
        const sv = serverSays(entity, deltas, movements, hint);
        // `validate` also checks the sum against deltas.stock, which the server checks at apply time.
        if (c === "movement-qty-mismatch") continue;
        const label = JSON.stringify([entity, deltas, movements, hint]);
        // A movement fault: both sides refuse, but they check the pieces of `movements` in a different ORDER (the server
        // reads each movement first, the client the entity and the stock delta first), so the code may differ. Pre-existing
        // (KNOWN-ISSUES S2d-2 item 6); not a hint matter.
        if (SM.validate(entity, deltas, {}, movements) !== "") { assert.notEqual(sv, "", label); continue; }
        assert.equal(c, sv, label);
    }
});

// ── coalescing ──────────────────────────────────────────────────────────────
test("KC-4 canCoalesce: derived calls merge only with an EQUAL hint (none equals none); explicit rules unchanged", () => {
    const d = (kindHint) => ({ deltas: { stock: -1 }, floors: {}, clamps: { stock: 0 }, kindHint });
    assert.equal(SM.canCoalesce(d(undefined), d(undefined)), true, "old behaviour: two unlabelled calls still merge");
    assert.equal(SM.canCoalesce(d("sale"), d("sale")), true);
    assert.equal(SM.canCoalesce(d("sale"), d(undefined)), false, "merging would mislabel one of them");
    assert.equal(SM.canCoalesce(d(undefined), d("sale")), false);
    assert.equal(SM.canCoalesce(d("sale"), d("receipt")), false);
    assert.equal(SM.canCoalesce(d(""), d(undefined)), true, "an empty or missing hint is no hint");
    const ex = (extra) => Object.assign({ movements: [{ kind: "receipt", qty: 1 }], floors: {}, clamps: {} }, extra || {});
    assert.equal(SM.canCoalesce(ex(), ex()), true);
    assert.equal(SM.canCoalesce(ex(), { deltas: { stock: 1 }, floors: {}, clamps: {} }), false, "explicit next to derived still queues apart");
});

// ── real function bodies ────────────────────────────────────────────────────
function gatewayCtx() {
    const enq = [];
    const out = { enq, drained: 0, callbacks: [] };
    const ctx = {
        console: { warn() {} }, StockMovements: SM, Date,
        _collectionFor: (e) => ({ inventory: "inventory", stock_batch: "stock_batches" })[e] || "",
        _nextRequestId: () => "rid-" + (enq.length + 1),
        _deltaCallbacks: {}, Object,
        OutboxStore: { enqueueDelta(call) { enq.push(call); return { requestId: call.requestId }; } },
        drainNow() { out.drained++; }
    };
    vm.createContext(ctx);
    vm.runInContext(extractFunction("model/Gateway.qml", "recordDelta"), ctx);
    out.recordDelta = ctx.recordDelta;
    return out;
}

test("KC-5 Gateway.recordDelta: a good hint is queued; a bad hint is refused BEFORE queueing with bad-request + detail", () => {
    const g = gatewayCtx();
    let answer = null;
    const id = g.recordDelta("inventory", "p1", { stock: -3 }, {}, { stock: 0 }, (r) => { answer = r; }, undefined, "sale");
    assert.equal(id, "rid-1");
    assert.equal(g.enq.length, 1);
    assert.equal(g.enq[0].kindHint, "sale");
    assert.deepEqual(plain(g.enq[0].clamps), { stock: 0 });
    assert.equal(g.drained, 1);
    for (const [hint, movements, detail] of [["loss", undefined, "invalid-kind-hint"], [5, undefined, "invalid-kind-hint"],
        ["sale", [{ kind: "sale", qty: -3, reason: "" }], "kind-hint-with-movements"]]) {
        answer = null;
        const before = g.enq.length;
        const r = g.recordDelta("inventory", "p1", { stock: -3 }, {}, {}, (x) => { answer = x; }, movements, hint);
        assert.equal(r, "", "no request id");
        assert.deepEqual(plain(answer), { ok: false, error: "bad-request", detail });
        assert.equal(g.enq.length, before, "nothing queued");
    }
    answer = null;
    g.recordDelta("stock_batch", "b1", { qtyRemaining: -1 }, {}, {}, (x) => { answer = x; }, undefined, "sale");
    assert.equal(answer.detail, "invalid-kind-hint", "a hint on a batch delta is refused");
});

test("KC-5b Gateway.recordDelta without a hint is exactly as before (every existing caller)", () => {
    const g = gatewayCtx();
    g.recordDelta("inventory", "p1", { stock: -3 }, { stock: 0 }, {}, null);
    assert.equal(g.enq[0].kindHint, undefined);
    g.recordDelta("stock_batch", "b1", { qtyRemaining: -1 }, { qtyRemaining: 0 }, {}, null);
    assert.equal(g.enq[1].kindHint, undefined);
});

function outboxCtx() {
    const ctx = { console: { warn() {} }, StockMovements: SM, StuckWrites: SW, Date, Object, items: [], _inFlightKeys: {}, saves: 0,
        _save() { ctx.saves++; } };
    vm.createContext(ctx);
    vm.runInContext(extractFunction("model/OutboxStore.qml", "_keyFor") + "\n" + extractFunction("model/OutboxStore.qml", "enqueueDelta"), ctx);
    return ctx;
}
const call = (id, stock, extra) => Object.assign({ requestId: id, entity: "inventory", entityId: "p1", deltas: { stock }, floors: {}, clamps: { stock: 0 } }, extra || {});

test("KC-6 OutboxStore.enqueueDelta: the hint is stored, joins an equal hint only, and survives a JSON round trip (the outbox is saved as JSON)", () => {
    let o = outboxCtx();
    const first = o.enqueueDelta(call("a", -2, { kindHint: "sale" }));
    assert.equal(first.kindHint, "sale");
    const merged = o.enqueueDelta(call("b", -3, { kindHint: "sale" }));
    assert.equal(o.items.length, 1);
    assert.equal(merged.requestId, "a");
    assert.equal(merged.deltas.stock, -5);
    assert.equal(merged.kindHint, "sale", "the merged item keeps its label");
    const reloaded = JSON.parse(JSON.stringify(o.items))[0];
    assert.equal(reloaded.kindHint, "sale");

    o = outboxCtx();
    o.enqueueDelta(call("a", -2, { kindHint: "sale" }));
    o.enqueueDelta(call("b", -3));
    assert.equal(o.items.length, 2, "an unlabelled call does not join a hinted item");
    assert.equal(o.items[1].kindHint, undefined);
    assert.equal("kindHint" in o.items[1], false, "no hint key at all (JSON.stringify would drop it anyway)");

    o = outboxCtx();
    o.enqueueDelta(call("a", -2));
    o.enqueueDelta(call("b", -3, { kindHint: "sale" }));
    assert.equal(o.items.length, 2, "and the other way round");

    o = outboxCtx();
    o.enqueueDelta(call("a", -2));
    o.enqueueDelta(call("b", -3));
    assert.equal(o.items.length, 1, "two unlabelled clamped calls still merge, as before");
    assert.equal(o.items[0].deltas.stock, -5);
});

test("KC-6b OutboxStore.enqueueDelta: a hinted item is never a merge target once sent or parked (K11), and a different hint queues apart", () => {
    const o = outboxCtx();
    o.enqueueDelta(call("a", -2, { kindHint: "sale" }));
    o.items[0].attempts = 1;
    o.enqueueDelta(call("b", -3, { kindHint: "sale" }));
    assert.equal(o.items.length, 2, "sent once: no merge");
    const p = outboxCtx();
    p.enqueueDelta(call("a", 2, { kindHint: "receipt", clamps: {} }));
    p.enqueueDelta(call("b", 3, { kindHint: "sales_return", clamps: {} }));
    assert.equal(p.items.length, 2, "different hints never merge");
});

function storeCtx(products) {
    const calls = [];
    const ctx = { console: { warn() {} }, StockMovements: SM, products, Object, JSON,
        _clone() { return JSON.parse(JSON.stringify(ctx.products)); },
        Gateway: { recordDelta(...args) { calls.push(args); } } };
    vm.createContext(ctx);
    vm.runInContext(["_movementsFor", "_kindHintFor", "deductStock"].map((n) => extractFunction("model/InventoryStore.qml", n)).join("\n"), ctx);
    return { ctx, calls };
}
const PRODUCTS = [{ productId: "p1", name: "Shirt", stock: 5 }];

test("KC-7 InventoryStore.deductStock: clamp mode sends the kind as a HINT (no explicit movements); reject mode sends movements and no hint", () => {
    const { ctx, calls } = storeCtx(PRODUCTS);
    ctx.deductStock("p1", 3, () => {}, true, "sale");
    let [entity, id, deltas, floors, clamps, , movements, hint] = calls[0];
    assert.deepEqual([entity, id, plain(deltas), plain(floors), plain(clamps), movements, hint], ["inventory", "p1", { stock: -3 }, {}, { stock: 0 }, undefined, "sale"]);

    ctx.deductStock("p1", 3, () => {}, false, "sale", "Exchange - order O1");
    [, , , floors, clamps, , movements, hint] = calls[1];
    assert.deepEqual([plain(floors), plain(clamps), hint], [{ stock: 0 }, {}, undefined]);
    assert.equal(movements.length, 1);
    assert.deepEqual(plain(movements[0]), { kind: "sale", qty: -3, reason: "Exchange - order O1" });
});

test("KC-7b InventoryStore.deductStock: a kind the hint list refuses is dropped (stock change kept, row stays `adjustment`); no kind = no hint", () => {
    const { ctx, calls } = storeCtx(PRODUCTS);
    for (const kind of ["loss", "gift", "free_sample", "theft", "bogus", "", undefined, null]) {
        ctx.deductStock("p1", 2, () => {}, true, kind);
        const args = calls[calls.length - 1];
        assert.equal(args[7], undefined, "hint for " + kind);
        assert.equal(args[6], undefined);
        assert.deepEqual(plain(args[4]), { stock: 0 }, "the deduction itself still goes out, clamped");
    }
    ctx.deductStock("p1", 2, () => {}, true);
    assert.equal(calls[calls.length - 1][7], undefined);
    ctx.deductStock("p1", 2, () => {}, true, "receipt");
    assert.equal(calls[calls.length - 1][7], "receipt", "a listed kind of the wrong direction is the server's call to degrade (KH-9)");
});

test("KC-7c InventoryStore.deductStock of an unknown product still answers not-found and queues nothing", () => {
    const { ctx, calls } = storeCtx(PRODUCTS);
    let r = null;
    ctx.deductStock("nope", 1, (x) => { r = x; }, true, "sale");
    assert.deepEqual(plain(r), { ok: false, error: "not-found" });
    assert.equal(calls.length, 0);
});

// ── client -> server, the imported-order case, end to end ───────────────────
test("KC-8 the app's own calls reach the real server as ONE `sale` row of the applied quantity (imported order, shortfall)", async () => {
    const { ctx, calls } = storeCtx([{ productId: "p1", name: "Shirt", stock: 2 }]);
    const o = outboxCtx();
    // what completeImportedOrder does for a line of 5 with 2 on hand
    ctx.deductStock("p1", 5, () => {}, true, "sale");
    const [entity, entityId, deltas, floors, clamps, , movements, kindHint] = calls[0];
    const item = o.enqueueDelta({ requestId: "imp-1", entity, entityId, deltas, floors, clamps, movements, kindHint });
    // the body Gateway._sendDelta posts (JSON drops undefined fields)
    const wire = JSON.parse(JSON.stringify({ env: "test", entity: item.entity, entityId: item.entityId, deltas: item.deltas, floors: item.floors,
        clamps: item.clamps, movements: item.movements, kindHint: item.kindHint, requestId: item.requestId, clientTimestamp: "c" }));
    assert.equal(wire.kindHint, "sale");
    assert.equal("movements" in wire, false);
    const v = G.validateDeltaRequest(wire);
    assert.equal(v.ok, true, JSON.stringify(v));
    const db = strictDb({ [T + "inventory/p1"]: { stock: 2, name: "Shirt", price: 100 } });
    const r = await G.applyDelta(db, { tenantId: "t1", actorUid: "u1", actorRole: "owner", entity: v.entity, entityId: v.entityId, requestId: v.requestId,
        deltas: v.deltas, floors: v.floors, clamps: v.clamps, movements: v.movements, kindHint: v.kindHint, clientTimestamp: 1, collection: v.collection, serverTimestamp: TS });
    assert.deepEqual(r, { ok: true, after: { stock: 0 } });
    const rows = rowsOf(db).map((w) => w.data);
    assert.equal(rows.length, 1);
    assert.deepEqual([rows[0].kind, rows[0].qty, rows[0].derived], ["sale", -2, true]);
});

// ── wiring pins (text): the QML paths the vm tests cannot reach ──────────────
test("KC-9 wiring: Gateway posts the hint, the import path asks for it, nothing else clamps with a kind", () => {
    const gw = QML("model/Gateway.qml");
    assert.match(gw, /function recordDelta\(entity, entityId, deltas, floors, clamps, callback, movements, kindHint\)/);
    assert.match(gw, /movements: item\.movements,\s*\n\s*kindHint: item\.kindHint,/, "_sendDelta posts the hint");
    assert.match(gw, /movements: movements,\s*\n\s*kindHint: kindHint,/, "recordDelta queues the hint");
    const ob = QML("model/OutboxStore.qml");
    assert.match(ob, /if \(call\.kindHint\) item\.kindHint = call\.kindHint/);
    const dm = QML("model/DataModel.qml");
    const at = dm.indexOf("completeImportedOrder: deductStock did not confirm");
    assert.ok(at > 0);
    const tail = dm.substring(at, at + 700);
    assert.match(tail, /true \/\* clamp[^*]*\*\/,\s*\n\s*"sale"/, "completeImportedOrder: clamp true, kind sale");
    // every InventoryStore.deductStock caller with a clamp (true) must say what it is
    const clampers = [];
    for (const f of ["model/DataModel.qml", "model/InventoryStore.qml", "pages/OrderDetailDialog.qml", "pages/NewOrderDialog.qml"]) {
        const src = QML(f);
        const re = /deductStock\([^\n]*\btrue\b/g;
        let m; while ((m = re.exec(src))) clampers.push(f);
    }
    assert.ok(clampers.length <= 1, "only the imported-order path clamps today: " + JSON.stringify(clampers));
});

test("KC-9b wiring: deductStock hints ONLY in clamp mode, and the hint function is the one place that validates", () => {
    const src = QML("model/InventoryStore.qml");
    assert.match(src, /var kindHint = clampInsteadOfReject \? _kindHintFor\(kind\) : undefined/);
    assert.match(src, /\}, movements, kindHint\)/);
    assert.equal((src.match(/_kindHintFor\(/g) || []).length, 2, "defined once, used once");
    assert.match(extractFunction("model/InventoryStore.qml", "_kindHintFor"), /StockMovements\.validateKindHint\("inventory"/);
});

// ── FailureCause ────────────────────────────────────────────────────────────
test("KC-10 the three new server codes are app problems (never shown as a person's mistake), like every other request-shape code", () => {
    for (const code of ["invalid-kind-hint", "kind-hint-with-movements", "kind-hint-not-supported"]) {
        const f = plain(FC.forRejection({ error: code }, ""));
        assert.equal(f.kind, "bug", code);
        assert.match(f.text, new RegExp(code));
    }
});

// ── monkey on the whole chain ───────────────────────────────────────────────
test("KC-11 monkey: 2000 random imported-order lines through the app's real functions and the real server keep ledger == stock change", async () => {
    let s = 11;
    const rnd = () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    for (let n = 0; n < 2000; n++) {
        const stock = pick([0, 1, 2, 5, 12, 2.5]);
        const qty = pick([1, 2, 3, 7, 20, 0.5]);
        const kind = pick(["sale", "sale", "sale", undefined, "loss", "bogus", "receipt"]);
        const { ctx, calls } = storeCtx([{ productId: "p1", name: "A", stock }]);
        ctx.deductStock("p1", qty, () => {}, true, kind);
        const [entity, entityId, deltas, floors, clamps, , movements, kindHint] = calls[0];
        const wire = JSON.parse(JSON.stringify({ entity, entityId, deltas, floors, clamps, movements, kindHint, requestId: "k-" + n }));
        const v = G.validateDeltaRequest(wire);
        assert.equal(v.ok, true, "the app never builds a request its own server refuses: " + JSON.stringify(wire));
        const db = strictDb({ [T + "inventory/p1"]: { stock, name: "A", price: 3 } });
        const r = await G.applyDelta(db, { tenantId: "t1", actorUid: "u", actorRole: "owner", entity: v.entity, entityId: v.entityId, requestId: v.requestId,
            deltas: v.deltas, floors: v.floors, clamps: v.clamps, movements: v.movements, kindHint: v.kindHint, clientTimestamp: 1, collection: v.collection, serverTimestamp: TS });
        assert.equal(r.ok, true, "a clamped deduction is never refused");
        const applied = r.after.stock - stock;
        const rows = rowsOf(db).map((w) => w.data);
        assert.ok(r.after.stock >= 0);
        assert.ok(Math.abs(rows.reduce((a, x) => a + x.qty, 0) - applied) < 1e-9);
        if (rows.length) assert.equal(rows[0].kind, kind === "sale" || kind === "receipt" ? (M.KIND_DIRECTION[kind] === Math.sign(applied) ? kind : "adjustment") : "adjustment");
    }
});
