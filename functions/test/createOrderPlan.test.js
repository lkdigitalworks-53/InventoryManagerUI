"use strict";

// Atomic-ops NO2: qml/helper/OrderPlan.js, the create-order ids in OperationKeys.js, FailureCause.forCreateOrder and the
// DescribeItem label (design 2026-11-22-no2-create-order-client-plan-design.md; server contract: NO1 design D-NO-5b). The QML
// helpers run here with their REAL text (testSupport/qmlHelpers.js), the order docs come from the REAL OrdersStore
// `_normalizeOrder` + `computeOrderTotals` bodies (extracted from the QML file and run in a vm), and every plan goes through the
// REAL server code (validateOperationRequest + applyOperation on the strict fake DB), so "the client plans what the server
// accepts" is proven, not assumed. tests/tst_OrderPlan.qml carries the unit cases for CI's qmltestrunner.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const OL = require("../lib/operationLogic");
const { strictDb, rowsOf } = require("./testSupport/strictDb");
const { load, plain, extractFunction, HELPER_DIR } = require("./testSupport/qmlHelpers");

const Keys = load("OperationKeys.js");
const OP = load("OrderPlan.js");
const FC = load("FailureCause.js");
const DI = load("DescribeItem.js");
const AP = load("AddProductPlan.js");

const T = "tenants/t1/";
const NOW = new Date("2026-06-15T12:00:00Z");
const ISO = "2026-06-15T12:00:00.000Z";
const NONCE = "1781000000000-abcdefabcdef";
const KEY = "createOrder:" + NONCE;
const QML_ROOT = path.join(HELPER_DIR, "..");

// The REAL store functions that build an order doc (the doc the planner must accept for every cart the app can make).
const store = {};
{
    const ctx = { InventoryStore: { getById: () => null }, Qt: { formatDate: () => "2026-06-15" }, Date };
    vm.createContext(ctx);
    for (const f of ["parseCurrency", "computeOrderTotals", "_normalizeOrder"]) vm.runInContext(extractFunction("model/OrdersStore.qml", f), ctx);
    store.normalize = (raw) => plain(ctx._normalizeOrder(raw));
}

const lineIn = (over) => Object.assign({ productId: "PRD-001", name: "Tomato", qty: 3, price: 19.99, taxable: true, taxPercent: 5, discountType: "flat", discountValue: 0 }, over || {});
// What OrdersStore.addOrder hands to _normalizeOrder, then the doc it stores.
function orderDoc(over, lines) {
    return store.normalize(Object.assign({
        orderId: "ORD-OLD", customer: "  Asha ", email: " a@b.c ", phone: "123", status: "pending", date: "2026-06-15", notes: "",
        orderChannel: "Online", staffId: "S-1", updatedAt: ISO,
        products: (lines || [lineIn()]).map((l) => Object.assign({ quantity: l.qty }, l)), items: 0, total: 0
    }, over || {}));
}
const input = (over, ord) => Object.assign({ key: KEY, order: ord || orderDoc() }, over || {});
const build = (over, ord) => plain(OP.build(input(over, ord)));
const withCounter = (value, more) => strictDb(Object.assign({ [T + "counters/orders"]: { value } }, more || {}));
async function apply(db, plan, extra) {
    const v = OL.validateOperationRequest({ requestId: plan.key, opType: plan.opType, clientTimestamp: "CT", ops: plan.ops });
    assert.equal(v.ok, true, "the server must accept the plan: " + JSON.stringify(v));
    return OL.applyOperation(db, Object.assign({
        tenantId: "t1", actorUid: "u-actor", actorRole: "owner", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: { __transform: "serverTimestamp" }, now: NOW
    }, extra || {}));
}
const textsOf = (ops) => {
    const out = [];
    (function walk(v) {
        if (typeof v === "string") out.push(v);
        else if (Array.isArray(v)) v.forEach(walk);
        else if (v && typeof v === "object") Object.values(v).forEach(walk);
    })(ops.filter((o) => o.kind === "mutation").map((o) => o.after));
    return out;
};
function prng(seed) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }
const seq = (values) => { let i = 0; return () => values[i++ % values.length]; };

// ---------------------------------------------------------------------------- keys

test("K-1 createOrderNonce: the restock nonce (time + two padded draws), deterministic for a fixed random", () => {
    assert.equal(Keys.createOrderNonce(1781000000000, seq([0, 0.5])), Keys.restockNonce(1781000000000, seq([0, 0.5])));
    assert.match(Keys.createOrderNonce(1781000000000.9, Math.random), /^1781000000000-[0-9a-z]{12}$/);
});

test("K-2 createOrderKey accepts a plain token and refuses everything the server would or could mishandle", () => {
    assert.equal(Keys.createOrderKey(NONCE), KEY);
    for (const bad of ["", "a/b", "a~b", "a b", "x".repeat(101), null, undefined, 5, {}, "é"]) assert.equal(Keys.createOrderKey(bad), "", String(bad));
    assert.equal(Keys.createOrderKey("x".repeat(100)).length, 112);
});

test("K-3 isCreateOrderKey: only a well-formed create key; every other operation's key is not one, and the reverse", () => {
    assert.equal(Keys.isCreateOrderKey(KEY), true);
    for (const bad of ["", "createOrder:", "createOrder:a/b", "restock:" + NONCE, "addProduct:" + NONCE, "completeOrder:ORD-001:1", "CreateOrder:" + NONCE, " createOrder:" + NONCE, null, 5])
        assert.equal(Keys.isCreateOrderKey(bad), false, String(bad));
    assert.equal(Keys.isRestockKey(KEY), false);
    assert.equal(Keys.isAddProductKey(KEY), false);
    assert.equal(Keys.isCreateOrderKey("restock:" + NONCE), false);
});

test("K-4 the other keys are unchanged by the new one (regression)", () => {
    assert.equal(Keys.restockKey(NONCE), "restock:" + NONCE);
    assert.equal(Keys.addProductKey(NONCE), "addProduct:" + NONCE);
    assert.equal(Keys.completeOrderKey("ORD-001", 2), "completeOrder:ORD-001:2");
});

test("K-5 a generated key passes the server's request-id rule for opType createOrder, and a restock key does not", () => {
    const k = Keys.createOrderKey(Keys.createOrderNonce(Date.now(), Math.random));
    const body = (id) => ({ requestId: id, opType: "createOrder", clientTimestamp: "c", ops: build().ops });
    assert.equal(OL.validateOperationRequest(body(k)).ok, true);
    assert.equal(OL.validateOperationRequest(body("restock:" + NONCE)).ok, false);
});

// ---------------------------------------------------------------------------- the shared time checks (AddProductPlan)

test("T-1 isIsoInstant / isIsoDate: real instants and days only (the add-product planner uses the same two)", () => {
    for (const ok of [ISO, "2024-02-29T23:59:59Z", "2026-12-31T00:00:00.5Z"]) assert.equal(AP.isIsoInstant(ok), true, ok);
    for (const bad of ["2026-13-45T10:00:00Z", "2026-02-31T10:00:00Z", "2026-06-15T24:00:00Z", "2026-06-15", "", null, 5, undefined]) assert.equal(AP.isIsoInstant(bad), false, String(bad));
    for (const ok of ["2026-06-15", "2024-02-29", "2026-12-31"]) assert.equal(AP.isIsoDate(ok), true, ok);
    for (const bad of ["2026-02-29", "2026-13-01", "2026-6-15", ISO, "", null, 5]) assert.equal(AP.isIsoDate(bad), false, String(bad));
});

// ---------------------------------------------------------------------------- build

test("B-1 two ops: the order mint, then ONE create of order/{{ord}} with before null; the id is the bare token", () => {
    const p = build();
    assert.equal(p.ok, true);
    assert.deepEqual([p.key, p.opType, p.at], [KEY, "createOrder", { mint: 0, create: 1 }]);
    assert.equal(p.ops.length, 2);
    assert.deepEqual(p.ops[0], { kind: "mint", counter: "order", bind: "ord" });
    const c = p.ops[1];
    assert.deepEqual([c.kind, c.entity, c.entityId, c.action, c.before, c.after.orderId], ["mutation", "order", "{{ord}}", "create", null, "{{ord}}"]);
});

test("B-2 the doc keeps every field of the store's doc, trimmed; the input object is never changed; the input id is ignored", () => {
    const ord = orderDoc();
    const copy = JSON.stringify(ord);
    const p = plain(OP.build({ key: KEY, order: ord }));
    assert.equal(JSON.stringify(ord), copy);
    const a = p.ops[1].after;
    assert.deepEqual([a.customer, a.email, a.phone, a.orderChannel, a.staffId], ["Asha", "a@b.c", "123", "Online", "S-1"]);
    assert.deepEqual([a.items, a.subtotal, a.discount, a.tax, a.total, a.status, a.date, a.updatedAt], [3, 59.97, 0, 3, 62.97, "pending", "2026-06-15", ISO]);
    assert.deepEqual(a.taxBreakdown, [{ rate: 5, amount: 2.9985 }]);
    assert.deepEqual([a.adjustments, a.completionEpoch, a.notes], [[], 0, ""]);
    assert.deepEqual(a.products, [{ productId: "PRD-001", name: "Tomato", price: 19.99, quantity: 3, taxable: true, taxPercent: 5, discountType: "flat", discountValue: 0, consumption: [] }]);
});

test("B-3 DRIFT GUARD: the planned doc has exactly the keys OrdersStore._normalizeOrder returns, and each line the keys it returns", () => {
    const ord = orderDoc();
    const a = build().ops[1].after;
    assert.deepEqual(Object.keys(a), Object.keys(ord));
    assert.deepEqual(Object.keys(a.products[0]), Object.keys(ord.products[0]));
});

test("B-4 an extra key on the input, on a line or in a tax row never reaches the server", () => {
    const ord = orderDoc();
    ord.hack = "x"; ord.products[0].extra = 1; ord.taxBreakdown[0].more = 2;
    const a = build({}, ord).ops[1].after;
    assert.equal(a.hack, undefined); assert.equal(a.products[0].extra, undefined); assert.equal(a.taxBreakdown[0].more, undefined);
});

test("B-5 several lines, mixed tax, a percent and a flat discount: the plan carries the store's totals exactly", () => {
    const ord = orderDoc({}, [lineIn({ qty: 2, price: 10.1, discountType: "percent", discountValue: 10 }),
        lineIn({ productId: "PRD-002", name: "Onion", qty: 1, price: 7.77, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 1.5 }),
        lineIn({ productId: "PRD-003", name: "Rice", qty: 5, price: 3.33, taxPercent: 18 })]);
    const p = build({}, ord);
    assert.equal(p.ok, true);
    for (const k of ["items", "subtotal", "discount", "tax", "total"]) assert.equal(p.ops[1].after[k], ord[k], k);
});

test("B-6 a line with no product id (free item) is allowed; its id is stored as an empty string", () => {
    const p = build({}, orderDoc({}, [lineIn({ productId: "" })]));
    assert.equal(p.ok, true);
    assert.equal(p.ops[1].after.products[0].productId, "");
});

// ---------------------------------------------------------------------------- refusals

const cents = (x) => Math.round(x * 100) / 100;
function ordWith(f) { const o = orderDoc(); f(o); return o; }
const REFUSALS = [
    ["bad-key", { key: "restock:" + NONCE }],
    ["bad-key", { key: "" }],
    ["bad-order", { order: null }], ["bad-order", { order: "x" }], ["bad-order", { order: [] }], ["bad-order", { order: undefined }],
    ["bad-customer", { order: ordWith((o) => { o.customer = ""; }) }],
    ["bad-customer", { order: ordWith((o) => { o.customer = "  \t "; }) }],
    ["bad-customer", { order: ordWith((o) => { o.customer = 5; }) }],
    ["bad-status", { order: ordWith((o) => { o.status = "completed"; }) }],
    ["bad-status", { order: ordWith((o) => { o.status = ""; }) }],
    ["bad-status", { order: ordWith((o) => { o.completionEpoch = 1; }) }],
    ["bad-status", { order: ordWith((o) => { o.adjustments = [{ x: 1 }]; }) }],
    ["bad-status", { order: ordWith((o) => { o.adjustments = "x"; }) }],
    ["bad-time", { order: ordWith((o) => { o.date = "2026-02-31"; }) }],
    ["bad-time", { order: ordWith((o) => { o.date = ISO; }) }],
    ["bad-time", { order: ordWith((o) => { o.updatedAt = "2026-13-45T10:00:00Z"; }) }],
    ["bad-time", { order: ordWith((o) => { o.updatedAt = undefined; }) }],
    ["bad-line", { order: ordWith((o) => { o.products = []; }) }],
    ["bad-line", { order: ordWith((o) => { o.products = undefined; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].name = " "; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].productId = undefined; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].price = -1; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].price = NaN; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].quantity = 0; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].quantity = 1.5; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].quantity = "2"; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].taxable = "yes"; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].taxPercent = 101; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].taxPercent = -1; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].discountType = "half"; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].discountValue = -0.01; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0].consumption = [{ batchId: "B" }]; }) }],
    ["bad-line", { order: ordWith((o) => { o.products[0] = null; }) }],
    ["bad-totals", { order: ordWith((o) => { o.items = 4; }) }],
    ["bad-totals", { order: ordWith((o) => { o.subtotal = 60; }) }],
    ["bad-totals", { order: ordWith((o) => { o.discount = -1; }) }],
    ["bad-totals", { order: ordWith((o) => { o.discount = 1000; }) }],
    ["bad-totals", { order: ordWith((o) => { o.tax = -3; }) }],
    ["bad-totals", { order: ordWith((o) => { o.tax = Infinity; }) }],
    // each of these keeps the total CONSISTENT with the bad number, so only the field's own bound can refuse it
    ["bad-totals", { order: ordWith((o) => { o.discount = -5; o.total = cents(o.subtotal - o.discount + o.tax); }) }],
    ["bad-totals", { order: ordWith((o) => { o.discount = o.subtotal + 5; o.total = cents(o.subtotal - o.discount + o.tax); }) }],
    ["bad-totals", { order: ordWith((o) => { o.tax = -3; o.total = cents(o.subtotal - o.discount + o.tax); }) }],
    ["bad-totals", { order: ordWith((o) => { o.total = 62.98; }) }],
    ["bad-totals", { order: ordWith((o) => { o.total = 0; }) }],
    ["bad-totals", { order: ordWith((o) => { o.taxBreakdown = {}; }) }],
    ["bad-totals", { order: ordWith((o) => { o.taxBreakdown = [{ rate: 5 }]; }) }],
    ["bad-totals", { order: ordWith((o) => { o.taxBreakdown = [{ rate: 500, amount: 1 }]; }) }],
    ["bad-totals", { order: ordWith((o) => { o.taxBreakdown = [null]; }) }],
    ["bad-totals", { order: ordWith((o) => { o.taxBreakdown = [{ rate: -1, amount: 1 }]; }) }],
    ["bad-totals", { order: ordWith((o) => { o.taxBreakdown = [{ rate: 5, amount: -1 }]; }) }],
    // the money overflows to Infinity although every factor is finite
    ["bad-totals", { order: ordWith((o) => { o.products[0].price = 1e308; o.products[0].quantity = 5; }) }],
];

test("R-1 every refusal reason, with the input that earns it, and nothing is built for it", () => {
    for (const [reason, over] of REFUSALS) {
        const p = plain(OP.build(Object.assign({ key: KEY, order: orderDoc() }, over)));
        assert.equal(p.ok, false, JSON.stringify(over).slice(0, 120));
        assert.equal(p.reason, reason, JSON.stringify(over).slice(0, 160));
        assert.equal(p.ops, undefined); assert.equal(p.at, undefined);
    }
    assert.equal(new Set(REFUSALS.map((r) => r[0])).size, 7, "all seven field reasons are exercised (too-large has its own test)");
});

test("R-2 a bad line names its index; an empty cart is index -1", () => {
    const o = orderDoc({}, [lineIn(), lineIn({ productId: "PRD-002" })]);
    o.products[1].quantity = 0;
    assert.deepEqual(plain(OP.build({ key: KEY, order: o })), { ok: false, reason: "bad-line", index: 1 });
    assert.deepEqual(plain(OP.build({ key: KEY, order: ordWith((x) => { x.products = []; }) })), { ok: false, reason: "bad-line", index: -1 });
});

test("R-3 boundaries that ARE allowed: price 0, tax 0 and 100, a percent discount over 100 (the store clamps it), a flat discount over the gross, an old order without epoch and adjustments", () => {
    for (const l of [{ price: 0 }, { taxPercent: 0, taxable: false }, { taxPercent: 100 }, { discountType: "percent", discountValue: 150 },
                     { discountType: "flat", discountValue: 1e6 }, { qty: 1000000 }]) {
        const p = build({}, orderDoc({}, [lineIn(l)]));
        assert.equal(p.ok, true, JSON.stringify(l));
    }
    const old = orderDoc(); delete old.completionEpoch; delete old.adjustments; delete old.products[0].consumption;
    const a = build({}, old).ops[1].after;
    assert.deepEqual([a.adjustments, a.completionEpoch, a.products[0].consumption], [[], 0, []], "the stored doc always carries the three, whatever the input left out");
});

test("R-4 not an object: refused, never thrown", () => {
    for (const v of [undefined, null, 0, "x", [], () => 1, true]) assert.equal(plain(OP.build(v)).reason, "bad-key");
    assert.equal(plain(OP.build()).ok, false);
});

test("R-5 a doc over Firestore's 1 MiB is refused before anything is queued; a big but legal note is accepted", () => {
    const big = (n) => ordWith((o) => { o.notes = "n".repeat(n); });
    assert.equal(plain(OP.build({ key: KEY, order: big(1100000) })).reason, "too-large");
    assert.equal(plain(OP.build({ key: KEY, order: big(900000) })).ok, true);
});

// ---------------------------------------------------------------------------- placeholders (KNOWN-ISSUES 75)

test("N-1 every typed string is neutralised in the plan: no brace pair survives outside the planner's own token", () => {
    const hostile = "{{ord}} {{$stock}} }}{{ {{{";
    const ord = orderDoc({ customer: hostile, email: hostile, phone: hostile, notes: hostile, orderChannel: hostile, staffId: hostile },
        [lineIn({ name: hostile, productId: hostile })]);
    const p = build({}, ord);
    assert.equal(p.ok, true);
    for (const s of textsOf(p.ops)) {
        const rest = s.replace(/\{\{ord\}\}/g, "");
        assert.equal(rest.indexOf("{{") < 0 && rest.indexOf("}}") < 0, true, s);
    }
    assert.equal(p.ops[1].after.customer, AP.neutralisePlaceholders(hostile));
});

test("N-2 through the real server: a customer typed {{ord}} or {{$stock}} is stored with the one-space change, never as an id", async () => {
    const db = withCounter(6);
    const ord = orderDoc({ customer: "{{ord}} & {{$stock}}", notes: "}}x{{" }, [lineIn({ name: "{{ord}}" })]);
    const r = await apply(db, build({}, ord));
    assert.equal(r.ok, true, JSON.stringify(r));
    const stored = db.store[T + "orders/ORD-007"];
    assert.equal(stored.customer, "{ {ord} } & { {$stock} }");
    assert.equal(stored.notes, "} }x{ {");
    assert.equal(stored.products[0].name, "{ {ord} }");
    assert.equal(stored.orderId, "ORD-007");
});

test("N-3 an ordinary single brace and every other character is stored byte-identical", async () => {
    const db = withCounter(0);
    const r = await apply(db, build({}, orderDoc({ customer: "Joe {Bakery} é😀" })));
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "orders/ORD-001"].customer, "Joe {Bakery} é😀");
});

// ---------------------------------------------------------------------------- through the real server

test("S-1 the plan is accepted and applied: ONE order doc under the minted id, the counter moves, no ledger row, no feed row", async () => {
    const db = withCounter(6);
    const p = build();
    const r = await apply(db, p);
    assert.equal(r.ok, true, JSON.stringify(r));
    const stored = db.store[T + "orders/ORD-007"];
    const want = JSON.parse(JSON.stringify(p.ops[1].after).replace(/\{\{ord\}\}/g, "ORD-007"));
    assert.deepEqual(plain(stored), want);
    assert.equal(db.store[T + "counters/orders"].value, 7);
    assert.equal(rowsOf(db).length, 0);
    assert.equal(Object.keys(db.store).filter((k) => k.indexOf("/activity_log/") >= 0 || k.indexOf("/transactions/") >= 0).length, 0);
});

test("S-2 reflect reads the live answer back into the stored order", async () => {
    const db = withCounter(41);
    const r = await apply(db, build());
    const refl = plain(OP.reflect(plain(r.body ? r.body.results : r.results)));
    assert.equal(refl.ok, true, JSON.stringify(r).slice(0, 300));
    assert.equal(refl.orderId, "ORD-042");
    assert.deepEqual(refl.order, plain(db.store[T + "orders/ORD-042"]));
});

test("S-3 a replay (same key) answers with the same results and the same id, writes nothing, and reflects the same", async () => {
    const db = withCounter(1);
    const p = build();
    const first = await apply(db, p);
    const before = JSON.stringify(db.store);
    const again = await apply(db, p);
    assert.equal(JSON.stringify(db.store), before);
    const a = plain(OP.reflect(plain(first.body ? first.body.results : first.results)));
    const b = plain(OP.reflect(plain(again.body ? again.body.results : again.results)));
    assert.deepEqual(b, a);
    assert.equal(b.orderId, "ORD-002");
});

test("S-4 two creates with two keys give two orders and two numbers; a deleted top order's number is not reused", async () => {
    const db = withCounter(0);
    const k2 = Keys.createOrderKey("1781000000001-bbbbbbbbbbbb");
    const a = await apply(db, build());
    const b = await apply(db, build({ key: k2 }));
    assert.equal(a.ok && b.ok, true);
    assert.deepEqual(Object.keys(db.store).filter((k) => k.indexOf("/orders/") >= 0).sort(), [T + "orders/ORD-001", T + "orders/ORD-002"]);
    delete db.store[T + "orders/ORD-002"];
    const c = await apply(db, build({ key: Keys.createOrderKey("1781000000002-cccccccccccc") }));
    assert.equal(c.ok, true);
    assert.ok(db.store[T + "orders/ORD-003"], "the counter, not the highest surviving id, hands out the number");
});

// ---------------------------------------------------------------------------- reflect refusals

const GOOD = () => [
    { kind: "mint", bind: "ord", counter: "order", id: "ORD-009" },
    { kind: "mutation", entity: "order", entityId: "ORD-009", action: "create", after: Object.assign(orderDoc(), { orderId: "ORD-009" }) }
];

test("F-1 reflect accepts the one good shape (either order of the two results) and refuses everything else", () => {
    assert.equal(plain(OP.reflect(GOOD())).ok, true);
    assert.equal(plain(OP.reflect(GOOD().reverse())).ok, true);
    const cases = {
        "not-a-list": [undefined, null, "x", {}, 5],
        "shape": [[], [GOOD()[0]], [GOOD()[1]], GOOD().concat([GOOD()[0]]), [GOOD()[0], GOOD()[0]], [GOOD()[1], GOOD()[1]]],
        "entry-0": [[null, GOOD()[1]], [5, GOOD()[1]], [[], GOOD()[1]]],
        "kind-1": [[GOOD()[0], { kind: "delta" }], [GOOD()[0], {}]],
        "mint-id": [[{ kind: "mint", bind: "ord", id: 7 }, GOOD()[1]], [{ kind: "mint", bind: "prd", id: "ORD-009" }, GOOD()[1]], [{ kind: "mint", id: "ORD-009" }, GOOD()[1]]],
        "mutation": [[GOOD()[0], { kind: "mutation", entity: "inventory", after: {} }], [GOOD()[0], { kind: "mutation", entity: "order", after: null }], [GOOD()[0], { kind: "mutation", entity: "order", after: [] }]],
        "order-id": [[{ kind: "mint", bind: "ord", id: "ORD-9" }, GOOD()[1]], [{ kind: "mint", bind: "ord", id: "ord-009" }, GOOD()[1]], [{ kind: "mint", bind: "ord", id: "PRD-0009" }, GOOD()[1]], [{ kind: "mint", bind: "ord", id: "" }, GOOD()[1]], [{ kind: "mint", bind: "ord", id: "xORD-009" }, GOOD()[1]], [{ kind: "mint", bind: "ord", id: "ORD-009x" }, GOOD()[1]]],
    };
    for (const [detail, list] of Object.entries(cases)) for (const c of list) {
        const r = plain(OP.reflect(c));
        assert.deepEqual([r.ok, r.reason, r.detail], [false, "malformed-results", detail], detail + " " + String(JSON.stringify(c)).slice(0, 100));
    }
});

test("F-2 reflect refuses a doc that disagrees with its own mint, or is not a fresh pending order", () => {
    const tweak = (f) => { const g = GOOD(); f(g[1], g[0]); return g; };
    for (const g of [
        tweak((m) => { m.after.orderId = "ORD-010"; }), tweak((m) => { m.entityId = "ORD-010"; }), tweak((m) => { m.entityId = undefined; }),
        tweak((m) => { m.after.status = "completed"; }), tweak((m) => { m.after.customer = 5; }),
        tweak((m) => { m.after.products = []; }), tweak((m) => { m.after.products = "x"; }),
    ]) assert.equal(plain(OP.reflect(g)).detail, "order-doc");
});

test("F-3 a result the server could only send for another operation is refused as a create answer", () => {
    const restockish = [{ kind: "mint", bind: "batch", id: "BAT-2026-001" }, { kind: "mutation", entity: "stock_batch", after: {} }];
    assert.equal(plain(OP.reflect(restockish)).ok, false);
    assert.equal(plain(OP.reflect([GOOD()[0], { kind: "delta", entity: "inventory" }])).ok, false);
});

// ---------------------------------------------------------------------------- the chain probe and the monkeys

function randomCart(rnd) {
    const prices = [0, 0.01, 0.07, 1, 3.33, 7.77, 10.1, 19.99, 99.995, 1234.56, 0.1 + 0.2];
    const rates = [0, 5, 12, 18, 28, 2.5, 100];
    const lines = [];
    const n = 1 + Math.floor(rnd() * 6);
    for (let i = 0; i < n; ++i) {
        const pct = rnd() < 0.5;
        lines.push({ productId: rnd() < 0.9 ? "PRD-" + String(i + 1).padStart(3, "0") : "", name: "Item " + i,
            qty: 1 + Math.floor(rnd() * (rnd() < 0.9 ? 12 : 5000)), price: prices[Math.floor(rnd() * prices.length)],
            taxable: rnd() < 0.7, taxPercent: rates[Math.floor(rnd() * rates.length)],
            discountType: pct ? "percent" : "flat",
            discountValue: rnd() < 0.4 ? 0 : (pct ? [5, 10, 33.3, 100, 150][Math.floor(rnd() * 5)] : [0.5, 2, 9.99, 5000][Math.floor(rnd() * 4)]) });
    }
    return lines;
}

test("P-1 chain probe: 2500 random carts go through the REAL store normaliser, the planner, the real validator, the real apply and reflect with 0 failures", async () => {
    const rnd = prng(20261122);
    const db = withCounter(0);
    for (let i = 0; i < 2500; ++i) {
        const ord = orderDoc({ customer: "C" + i }, randomCart(rnd));
        const p = plain(OP.build({ key: Keys.createOrderKey("17810000" + String(i).padStart(5, "0") + "-aaaaaaaaaaaa"), order: ord }));
        assert.equal(p.ok, true, "cart " + i + ": " + JSON.stringify(p) + JSON.stringify(ord).slice(0, 400));
        const r = await apply(db, p);
        assert.equal(r.ok, true, JSON.stringify(r).slice(0, 300));
        const refl = plain(OP.reflect(plain(r.body ? r.body.results : r.results)));
        assert.equal(refl.ok, true);
        const id = "ORD-" + String(i + 1).padStart(3, "0");
        assert.equal(refl.orderId, id);
        // the stored doc is what the store would hold for this order under the real id (the round trip the app relies on)
        assert.deepEqual(plain(db.store[T + "orders/" + id]), Object.assign({}, ord, { orderId: id, customer: "C" + i, email: "a@b.c" }));
    }
});

test("M-1 monkey: 3000 random inputs never throw; an accepted plan always passes the real validator and has no stray brace pair", () => {
    const rnd = prng(20261123);
    const junk = [undefined, null, "", " ", "x", "{{ord}}", "{{$stock}}", "}}{{", "{{{", "é", "😀", "a".repeat(300), 0, -1, 1, 2.5, 1e308, -1e308, NaN, Infinity, true, false, {}, [], [{}],
        "2026-13-45T10:00:00Z", "2026-02-31", ISO, "2026-06-15", "pending", "completed", "flat", "percent"];
    const pick = () => junk[Math.floor(rnd() * junk.length)];
    const reasons = new Set(["bad-key", "bad-order", "bad-customer", "bad-status", "bad-time", "bad-line", "bad-totals", "too-large"]);
    let accepted = 0, refused = 0;
    for (let i = 0; i < 3000; ++i) {
        const ord = orderDoc();
        for (const k of Object.keys(ord)) if (rnd() < 0.15) ord[k] = pick();
        if (Array.isArray(ord.products)) for (const l of ord.products) if (l && typeof l === "object") for (const k of Object.keys(l)) if (rnd() < 0.15) l[k] = pick();
        const inp = { key: rnd() < 0.05 ? pick() : KEY, order: rnd() < 0.03 ? pick() : ord };
        const p = plain(OP.build(inp));
        if (p.ok) {
            accepted++;
            const v = OL.validateOperationRequest({ requestId: p.key, opType: p.opType, ops: p.ops });
            assert.equal(v.ok, true, JSON.stringify({ inp, v }).slice(0, 400));
            for (const s of textsOf(p.ops)) {
                const rest = s.replace(/\{\{ord\}\}/g, "");
                assert.equal(rest.indexOf("{{") < 0 && rest.indexOf("}}") < 0, true, s);
            }
            // whatever got through has finite money and whole quantities
            const a = p.ops[1].after;
            for (const k of ["subtotal", "discount", "tax", "total"]) assert.equal(Number.isFinite(a[k]), true, k);
            for (const l of a.products) assert.equal(Number.isInteger(l.quantity) && l.quantity >= 1, true);
        } else {
            refused++;
            assert.equal(reasons.has(p.reason), true, JSON.stringify(p));
        }
    }
    assert.ok(accepted > 50 && refused > 50, "the monkey must reach both sides: " + accepted + "/" + refused);
});

test("M-2 monkey: reflect never throws on 3000 randomly damaged answers and refuses every damaged one it can detect", () => {
    const rnd = prng(424243);
    const junk = [undefined, null, "", 5, "ORD-009", "ORD-1", {}, [], "x", true];
    const pick = () => junk[Math.floor(rnd() * junk.length)];
    let refused = 0;
    for (let i = 0; i < 3000; ++i) {
        const g = GOOD();
        const target = g[Math.floor(rnd() * 2)];
        const keys = Object.keys(target);
        const k = keys[Math.floor(rnd() * keys.length)];
        const was = target[k];
        target[k] = pick();
        const r = plain(OP.reflect(rnd() < 0.05 ? pick() : g));
        // accepted only when the damage hit nothing the reader uses (the mint's counter echo, the mutation's action) or changed nothing
        if (r.ok) assert.equal(JSON.stringify(target[k]) === JSON.stringify(was) || k === "counter" || k === "action", true, k);
        else { refused++; assert.equal(r.reason, "malformed-results"); }
    }
    assert.ok(refused > 1500, "refused " + refused);
});

// ---------------------------------------------------------------------------- causes and label

test("C-1 forCreateOrder: person-facing texts for conflict, mint-exhausted, request-id-in-use; app bugs for what a create can never meet", () => {
    const f = (code, name) => plain(FC.forCreateOrder({ error: code }, name));
    assert.deepEqual([f("conflict", "Asha").kind, f("conflict", "Asha").text.indexOf("Asha: ")], ["conflict", 0]);
    assert.ok(f("conflict", "").text.indexOf("Nothing was saved") > 0);
    assert.equal(f("conflict", "").text.indexOf("Asha"), -1);
    assert.equal(f("mint-exhausted").kind, "limit"); assert.ok(f("mint-exhausted").text.indexOf("order number") > 0);
    assert.equal(f("request-id-in-use").kind, "duplicate");
    for (const code of ["not-found", "insufficient-quantity", "operation-too-large", "invalid-order", "unbound-placeholder"]) {
        assert.equal(f(code).kind, "bug", code); assert.ok(f(code).text.indexOf("(" + code + ")") > 0, code);
    }
    assert.equal(plain(FC.forCreateOrder(null, "")).kind, "unknown");
    assert.equal(plain(FC.forCreateOrder({ error: "<b>x</b>" }, "")).text, "The server rejected this change");
});

test("C-2 forCreateOrder answers every code, including the order check's own, with a non-empty text", () => {
    for (const code of ["conflict", "mint-exhausted", "request-id-in-use", "not-found", "invalid-order", "x", undefined]) assert.ok(plain(FC.forCreateOrder({ error: code }, "P")).text.length > 0);
});

test("D-1 DescribeItem labels a create by the typed customer, never by the mint token", () => {
    const p = build();
    assert.deepEqual(plain(DI.describe({ opType: "createOrder", ops: p.ops })), { title: "New order", detail: "Asha" });
    assert.deepEqual(plain(DI.describe({ opType: "createOrder", ops: [{ kind: "mint", counter: "order", bind: "ord" }] })), { title: "New order", detail: "" });
    assert.equal(plain(DI.describe({ opType: "createOrder", ops: [] })).title, "New order");
    assert.equal(plain(DI.describe({ opType: "restock", ops: [] })).title, "Restock");
});

// ---------------------------------------------------------------------------- dormancy guard

test("G-1 dormancy: only the helpers refer to the create-order planner or its keys; no store, page or dialog does (NO3 replaces this with a wiring guard)", () => {
    const hits = [];
    (function walk(dir) {
        for (const f of fs.readdirSync(dir, { withFileTypes: true })) {
            const p = path.join(dir, f.name);
            if (f.isDirectory()) walk(p);
            else if (/\.(qml|js)$/.test(f.name) && !/OrderPlan\.js$|OperationKeys\.js$|FailureCause\.js$|DescribeItem\.js$|AddProductPlan\.js$/.test(f.name)
                     && /OrderPlan|createOrderKey|createOrderNonce|forCreateOrder/.test(fs.readFileSync(p, "utf8"))) hits.push(path.relative(QML_ROOT, p));
        }
    })(QML_ROOT);
    assert.deepEqual(hits, []);
});
