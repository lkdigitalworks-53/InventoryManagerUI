"use strict";

// P1 S4a follow-ups, slice 2 (D-R2): every ledger row carries a `productName` snapshot so the stock
// register can still name a DELETED product (its inventory doc is gone, the ledger row is not).
//
// Layers: pure (cleanProductName, nameFor, buildRows), the four real writers against an in-memory
// transaction double (applyMutation, applyDelta, applyMutationsBatch, applyOperation), the register
// (StockRegisterMath) reading the rows the REAL builder wrote, and a seeded monkey run.

const test = require("node:test");
const assert = require("node:assert/strict");
const M = require("../lib/movementLogic");
const G = require("../lib/gatewayLogic");
const B = require("../lib/batchMutationLogic");
const O = require("../lib/operationLogic");
const Reg = require("../lib/stockRegisterMath");

const T = "tenants/t1/";
function makeDb(docs) {
    const store = Object.assign({}, docs || {});
    const writes = [];
    return {
        store, writes,
        doc(path) { return { path }; },
        async runTransaction(fn) {
            return fn({
                async get(ref) {
                    const has = Object.prototype.hasOwnProperty.call(store, ref.path);
                    return { exists: has, data: () => (has ? store[ref.path] : undefined) };
                },
                set(ref, data) { writes.push({ path: ref.path, data }); store[ref.path] = data; },
                delete(ref) { writes.push({ path: ref.path, deleted: true }); delete store[ref.path]; }
            });
        }
    };
}
const rowsOf = (db) => db.writes.filter((w) => w.path.indexOf("/stock_movements/") >= 0).map((w) => w.data);
const base = { tenantId: "t1", actorUid: "u1", actorRole: "owner", serverTimestamp: "TS", clientTimestamp: 5 };
// An inventory DELETE needs the handler-validated sweep prefix (applyMutation throws without it).
const CLEANUP = { cleanupEnvPrefix: "dev1", cleanupPrefix: "dev1/tenants/t1/products/p1/" };

// ── cleanProductName / nameFor ──────────────────────────────────────────────

test("PN-01 cleanProductName keeps a non-empty string, trimmed", () => {
    assert.equal(M.cleanProductName("Rice"), "Rice");
    assert.equal(M.cleanProductName("  Basmati Rice \n"), "Basmati Rice");
    assert.equal(M.cleanProductName("a"), "a");
});

test("PN-02 cleanProductName drops everything that is not a usable name (undefined, never ''/null)", () => {
    for (const v of ["", "   ", "\t\n", undefined, null, 0, 42, NaN, true, false, {}, [], ["Rice"], { name: "x" }, () => "x", Symbol("s")]) {
        assert.equal(M.cleanProductName(v), undefined, String(typeof v) + ":" + String(v && v.toString && v.toString()));
    }
});

test("PN-03 cleanProductName caps at MAX_PRODUCT_NAME (200) and leaves no trailing blank from the cut", () => {
    assert.equal(M.MAX_PRODUCT_NAME, 200);
    assert.equal(M.cleanProductName("x".repeat(300)).length, 200);
    assert.equal(M.cleanProductName("x".repeat(200)).length, 200);
    assert.equal(M.cleanProductName("x".repeat(199) + " tail").length, 199, "a cut that lands on a space is trimmed");
    assert.equal(M.cleanProductName("x".repeat(201)).length, 200);
});

test("PN-04 nameFor prefers the AFTER document, falls back to BEFORE, else undefined", () => {
    assert.equal(M.nameFor({ name: "Old" }, { name: "New" }), "New");
    assert.equal(M.nameFor({ name: "Old" }, null), "Old", "a delete has no after");
    assert.equal(M.nameFor({ name: "Old" }, undefined), "Old");
    assert.equal(M.nameFor({ name: "Old" }, { stock: 1 }), "Old", "after without a name falls back");
    assert.equal(M.nameFor({ name: "Old" }, { name: "  " }), "Old", "a blank after name never hides the real one");
    assert.equal(M.nameFor(null, { name: "New" }), "New", "a create has no before");
    assert.equal(M.nameFor(null, null), undefined);
    assert.equal(M.nameFor(undefined, undefined), undefined);
    assert.equal(M.nameFor("str", 5), undefined, "non-object documents carry no name");
    assert.equal(M.nameFor({ name: 7 }, { name: {} }), undefined);
});

// ── buildRows ───────────────────────────────────────────────────────────────

function ctx(extra) {
    return Object.assign({ baseId: "b", productId: "p1", actorUid: "u", actorRole: "owner", serverTimestamp: 1, clientTimestamp: 1, requestId: "r" }, extra || {});
}

test("PN-05 buildRows writes productName only when it is a usable string, and never an undefined-valued field", () => {
    const withName = M.buildRows(M.deriveMovement(-1, "sale"), ctx({ productName: " Rice " }))[0].data;
    assert.equal(withName.productName, "Rice");
    for (const v of [undefined, "", "  ", null, 5, {}]) {
        const d = M.buildRows(M.deriveMovement(-1, "sale"), ctx({ productName: v }))[0].data;
        assert.equal(Object.prototype.hasOwnProperty.call(d, "productName"), false, "no field for " + String(v));
    }
    const noKey = M.buildRows(M.deriveMovement(-1, "sale"), ctx())[0].data;
    assert.equal(Object.prototype.hasOwnProperty.call(noKey, "productName"), false);
    for (const v of Object.values(withName)) assert.notEqual(v, undefined, "Firestore rejects undefined values");
});

test("PN-06 buildRows caps a 300-char name and writes the same name on every row of one write", () => {
    const rows = M.buildRows(M.validateMovements([{ kind: "loss", qty: -1, reason: "a" }, { kind: "loss", qty: -2, reason: "b" }]).movements, ctx({ productName: "n".repeat(300) }));
    assert.equal(rows.length, 2);
    for (const r of rows) assert.equal(r.data.productName.length, 200);
});

test("PN-07 the row's other fields are untouched by the new one (same keys plus productName)", () => {
    const a = M.buildRows(M.deriveMovement(-1, "sale"), ctx())[0].data;
    const b = M.buildRows(M.deriveMovement(-1, "sale"), ctx({ productName: "Rice" }))[0].data;
    const keys = Object.keys(b).filter((k) => k !== "productName");
    assert.deepEqual(keys.sort(), Object.keys(a).sort());
    for (const k of keys) assert.deepEqual(b[k], a[k], k);
});

// ── the four real writers ───────────────────────────────────────────────────

test("PN-08 applyMutation: create writes the name; update (rename) writes the NEW name; delete writes the BEFORE name", async () => {
    const mut = (action, before, after) => Object.assign({}, base, action === "delete" ? CLEANUP : {}, { entity: "inventory", entityId: "p1", action: action, requestId: "r-" + action, before: before, after: after, collection: "inventory" });
    let db = makeDb();
    assert.equal((await G.applyMutation(db, mut("create", null, { name: "Rice", stock: 5 }))).ok, true);
    assert.equal(rowsOf(db)[0].productName, "Rice");

    db = makeDb({ [T + "inventory/p1"]: { name: "Rice", stock: 5 } });
    assert.equal((await G.applyMutation(db, mut("update", { name: "Rice", stock: 5 }, { name: "Basmati", stock: 4 }))).ok, true);
    assert.equal(rowsOf(db)[0].productName, "Basmati");

    db = makeDb({ [T + "inventory/p1"]: { name: "Basmati", stock: 4 } });
    const r = await G.applyMutation(db, mut("delete", { name: "Basmati", stock: 4 }, null));
    assert.equal(r.ok, true, JSON.stringify(r));
    assert.equal(rowsOf(db)[0].productName, "Basmati", "the doc is gone but the row still names it");
});

test("PN-09 applyMutation: a delete that wrongly carries an `after` still names the product from BEFORE", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { name: "Rice", stock: 2 } });
    await G.applyMutation(db, Object.assign({}, base, CLEANUP, { entity: "inventory", entityId: "p1", action: "delete", requestId: "r-d", before: { name: "Rice", stock: 2 }, after: { name: "Ghost", stock: 0 }, collection: "inventory" }));
    assert.equal(rowsOf(db)[0].productName, "Rice");
});

test("PN-10 applyMutation: a product with no name writes a row with NO productName field (no undefined, no blank)", async () => {
    const db = makeDb();
    await G.applyMutation(db, Object.assign({}, base, { entity: "inventory", entityId: "p1", action: "create", requestId: "r-n", before: null, after: { stock: 3 }, collection: "inventory" }));
    assert.equal(Object.prototype.hasOwnProperty.call(rowsOf(db)[0], "productName"), false);
});

test("PN-11 applyDelta: the row carries the stored doc's name (a delta never changes it)", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { name: "Rice", stock: 10 } });
    const r = await G.applyDelta(db, Object.assign({}, base, { entity: "inventory", entityId: "p1", requestId: "d1", deltas: { stock: -3 }, floors: {}, clamps: {}, movements: [], collection: "inventory" }));
    assert.equal(r.ok, true);
    assert.equal(rowsOf(db)[0].productName, "Rice");
    assert.equal(db.store[T + "inventory/p1"].name, "Rice", "the stored name is untouched");
});

test("PN-12 applyDelta: several FIFO movements all carry the same name; a nameless doc carries none", async () => {
    let db = makeDb({ [T + "inventory/p1"]: { name: "Rice", stock: 10 } });
    const v = G.validateDeltaRequest({ entity: "inventory", entityId: "p1", requestId: "d2", deltas: { stock: -3 },
        movements: [{ kind: "sale", qty: -1 }, { kind: "sale", qty: -2 }] });
    await G.applyDelta(db, Object.assign({}, base, { entity: "inventory", entityId: "p1", requestId: "d2", deltas: v.deltas, floors: {}, clamps: {}, movements: v.movements, collection: "inventory" }));
    assert.deepEqual(rowsOf(db).map((r) => r.productName), ["Rice", "Rice"]);
    db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    await G.applyDelta(db, Object.assign({}, base, { entity: "inventory", entityId: "p1", requestId: "d3", deltas: { stock: -1 }, floors: {}, clamps: {}, movements: [], collection: "inventory" }));
    assert.equal(Object.prototype.hasOwnProperty.call(rowsOf(db)[0], "productName"), false);
});

test("PN-13 applyMutationsBatch: create / rename / delete items each carry their own name", async () => {
    const db = makeDb({ [T + "inventory/b" ]: { name: "Beta", stock: 2 }, [T + "inventory/c"]: { name: "Gamma", stock: 4 } });
    const r = await B.applyMutationsBatch(db, Object.assign({}, base, { entity: "inventory", collection: "inventory", requestId: "bt", items: [
        { entityId: "a", action: "create", before: null, after: { name: "Alpha", stock: 1 }, clientTimestamp: 1 },
        { entityId: "b", action: "update", before: { name: "Beta", stock: 2 }, after: { name: "Beta 2", stock: 1 }, clientTimestamp: 1 },
        { entityId: "c", action: "delete", before: { name: "Gamma", stock: 4 }, after: null, clientTimestamp: 1 }
    ] }));
    assert.equal(r.ok, true, JSON.stringify(r));
    const byProduct = {};
    for (const x of rowsOf(db)) byProduct[x.productId] = x.productName;
    assert.deepEqual(byProduct, { a: "Alpha", b: "Beta 2", c: "Gamma" });
});

test("PN-14 applyMutationsBatch: a non-inventory entity writes no ledger rows (so no names either)", async () => {
    const db = makeDb();
    await B.applyMutationsBatch(db, Object.assign({}, base, { entity: "order", collection: "orders", requestId: "bt2", items: [
        { entityId: "o1", action: "create", before: null, after: { name: "Order 1" }, clientTimestamp: 1 }] }));
    assert.equal(rowsOf(db).length, 0);
});

const RID = "completeOrder:o1:1";
function opParams(ops) {
    const v = O.validateOperationRequest({ requestId: RID, opType: "completeOrder", ops: ops, clientTimestamp: 7 });
    assert.equal(v.ok, true, JSON.stringify(v));
    return { tenantId: "t1", actorUid: "u1", actorRole: "staff", requestId: v.requestId, opType: v.opType, ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: "TS" };
}

test("PN-15 applyOperation: a delta op names the product from the running doc; a mutation op from its after (an operation cannot delete inventory: cascade-delete-not-allowed)", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { name: "Rice", stock: 10 }, [T + "inventory/p2"]: { name: "Dal", stock: 3 } });
    const r = await O.applyOperation(db, opParams([
        { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -3 }, floors: { stock: 0 } },
        { kind: "mutation", entity: "inventory", entityId: "p2", action: "update", before: { name: "Dal", stock: 3 }, after: { name: "Toor Dal", stock: 2 } }
    ]));
    assert.equal(r.ok, true, JSON.stringify(r));
    const byProduct = {};
    for (const x of rowsOf(db)) byProduct[x.productId] = x.productName;
    assert.deepEqual(byProduct, { p1: "Rice", p2: "Toor Dal" });
});

test("PN-16 applyOperation: two delta ops on the same product in one operation both carry the name", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { name: "Rice", stock: 10 } });
    await O.applyOperation(db, opParams([
        { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 }, floors: { stock: 0 } },
        { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -2 }, floors: { stock: 0 } }]));
    assert.deepEqual(rowsOf(db).map((x) => x.productName), ["Rice", "Rice"]);
});

// ── the register ────────────────────────────────────────────────────────────

const T0 = Date.parse("2026-04-01T00:00:00Z");
const DAY = 24 * 3600 * 1000;
const WIN = { fromMs: T0 + 10 * DAY, toMs: T0 + 20 * DAY };
function row(productId, qty, atMs, productName) {
    const r = { productId: productId, kind: qty > 0 ? "receipt" : "sale", qty: qty, serverTimestamp: new Date(atMs) };
    if (productName !== undefined) r.productName = productName;
    return r;
}
const find = (reg, id) => reg.products.find((p) => p.productId === id);

test("PN-17 register: a deleted product shows the name of its latest named row; deleted stays true", () => {
    const reg = Reg.buildRegister([row("c", 5, T0 + 11 * DAY, "Cumin"), row("c", -5, T0 + 12 * DAY, "Cumin")], [], WIN);
    const c = find(reg, "c");
    assert.equal(c.name, "Cumin");
    assert.equal(c.deleted, true);
});

test("PN-18 register: a rename keeps the LATEST name, whatever order the rows arrive in", () => {
    const rows = [row("p", 5, T0 + 11 * DAY, "Rice"), row("p", -1, T0 + 13 * DAY, "Basmati"), row("p", -1, T0 + 12 * DAY, "Rice Premium")];
    for (const order of [rows, rows.slice().reverse(), [rows[1], rows[0], rows[2]], [rows[2], rows[1], rows[0]]]) {
        assert.equal(find(Reg.buildRegister(order, [], WIN), "p").name, "Basmati");
    }
});

test("PN-19 register: the inventory doc's own name wins while the product exists", () => {
    const reg = Reg.buildRegister([row("p", 5, T0 + 11 * DAY, "Old Name")], [{ productId: "p", name: "Current Name", stock: 5 }], WIN);
    assert.equal(find(reg, "p").name, "Current Name");
    assert.equal(find(reg, "p").deleted, false);
});

test("PN-20 register: old rows without the field and new rows mix: the named one wins, even if older than a nameless row", () => {
    const reg = Reg.buildRegister([row("p", 5, T0 + 11 * DAY, "Rice"), row("p", -1, T0 + 15 * DAY)], [], WIN);
    assert.equal(find(reg, "p").name, "Rice", "a nameless later row never erases an earlier name");
});

test("PN-21 register: all rows nameless and no doc gives name null (as before)", () => {
    const reg = Reg.buildRegister([row("p", 5, T0 + 11 * DAY), row("p", -1, T0 + 12 * DAY)], [], WIN);
    assert.equal(find(reg, "p").name, null);
    assert.equal(find(reg, "p").deleted, true);
});

test("PN-22 register: blank, non-string and over-long ledger names are cleaned the same way the writer cleans them", () => {
    const reg = Reg.buildRegister([row("p", 5, T0 + 11 * DAY, "  "), row("p", -1, T0 + 12 * DAY, 42), row("q", 5, T0 + 11 * DAY, "n".repeat(300))], [], WIN);
    assert.equal(find(reg, "p").name, null);
    assert.equal(find(reg, "q").name.length, 200);
});

test("PN-23 register: two named rows at the SAME instant resolve the same way in every order (greater name)", () => {
    const a = row("p", 5, T0 + 11 * DAY, "Alpha");
    const b = row("p", -1, T0 + 11 * DAY, "Beta");
    assert.equal(find(Reg.buildRegister([a, b], [], WIN), "p").name, "Beta");
    assert.equal(find(Reg.buildRegister([b, a], [], WIN), "p").name, "Beta");
});

test("PN-24 register: a skipped row (bad qty, bad time) never lends its name", () => {
    const bad = { productId: "p", kind: "sale", qty: 0, serverTimestamp: new Date(T0 + 19 * DAY), productName: "Ghost" };
    const reg = Reg.buildRegister([row("p", 5, T0 + 11 * DAY, "Rice"), bad], [], WIN);
    assert.equal(find(reg, "p").name, "Rice");
});

test("PN-25 register: names count rows OUTSIDE the window too (a product deleted before the period is still named)", () => {
    const reg = Reg.buildRegister([row("c", 5, T0 + 1 * DAY, "Cumin"), row("c", -5, T0 + 2 * DAY, "Cumin"), row("d", 1, T0 + 12 * DAY, "Dal")], [], WIN);
    assert.equal(find(reg, "c").name, "Cumin");
    assert.equal(find(reg, "c").closing, 0);
});

test("PN-26 rows built by the real writers flow into the register: created, renamed, deleted product keeps its name", async () => {
    const mut = (action, before, after, id, day) => Object.assign({}, base, action === "delete" ? CLEANUP : {}, { entity: "inventory", entityId: "p1", action: action, requestId: id, before: before, after: after, collection: "inventory", serverTimestamp: new Date(T0 + day * DAY) });
    const db = makeDb();
    await G.applyMutation(db, mut("create", null, { name: "Rice", stock: 5 }, "r1", 11));
    await G.applyMutation(db, mut("update", { name: "Rice", stock: 5 }, { name: "Basmati", stock: 4 }, "r2", 12));
    await G.applyMutation(db, mut("delete", { name: "Basmati", stock: 4 }, null, "r3", 13));
    const rows = rowsOf(db);
    assert.deepEqual(rows.map((x) => x.productName), ["Rice", "Basmati", "Basmati"]);
    const p = find(Reg.buildRegister(rows, [], WIN), "p1");
    assert.equal(p.deleted, true);
    assert.equal(p.reconciles, true);
    assert.equal(p.name, "Basmati", "the latest row by time names it");
});

// ── seeded monkey ───────────────────────────────────────────────────────────

function lcg(seed) { let s = seed >>> 0; return function () { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s / 4294967296; }; }

test("PN-27 monkey: 300 random ledgers: the name is the latest valid ledger name (oracle), the doc name wins, shuffling changes nothing", () => {
    const rnd = lcg(20261112);
    const names = ["Rice", "Dal", " Salt ", "", "   ", undefined, 7, null, "n".repeat(250)];
    for (let run = 0; run < 300; run++) {
        const rows = [];
        const n = Math.floor(rnd() * 40);
        for (let i = 0; i < n; i++) {
            const pid = ["a", "b", "c"][Math.floor(rnd() * 3)];
            const qty = rnd() < 0.5 ? 1 + Math.floor(rnd() * 9) : -(1 + Math.floor(rnd() * 9));
            const nm = names[Math.floor(rnd() * names.length)];
            const r = row(pid, qty, T0 + Math.floor(rnd() * 30 * DAY));
            if (nm !== undefined) r.productName = nm;
            rows.push(r);
        }
        const docs = rnd() < 0.3 ? [{ productId: "a", name: "Doc A", stock: 0 }] : [];
        const reg = Reg.buildRegister(rows, docs, WIN);
        for (const pid of ["a", "b", "c"]) {
            const mine = rows.filter((r) => r.productId === pid);
            const p = find(reg, pid);
            if (mine.length === 0) continue;
            let want = null, at = -Infinity;
            for (const r of mine) {
                const c = M.cleanProductName(r.productName);
                const t = r.serverTimestamp.getTime();
                if (c !== undefined && (t > at || (t === at && c > want))) { want = c; at = t; }
            }
            if (pid === "a" && docs.length) want = "Doc A";
            assert.equal(p.name, want, "run " + run + " product " + pid);
        }
        assert.deepEqual(Reg.buildRegister(rows.slice().sort(() => rnd() - 0.5), docs, WIN), reg);
    }
});
