"use strict";

// Atomic-ops R3, the client surface around RestockPlan: FailureCause.forRestock, the restock label in
// DescribeItem, and the two QML hooks (SupplierStore.addLocalSupplier, InventoryStore.applyRestockResults).
// The helpers run with their real text; the hooks' real function bodies are cut out of the .qml files and
// run in a sandbox with fake stores. tests/tst_FailureCause.qml, tst_DescribeItem.qml,
// tst_SupplierStore_addLocal.qml and tst_InventoryStore_applyRestockResults.qml carry the same cases for CI.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load, plain, extractFunction } = require("./testSupport/qmlHelpers");

const FC = load("FailureCause.js");
const DI = load("DescribeItem.js");
const RP = load("RestockPlan.js");

const ISO = "2026-06-15T12:00:00.000Z";
const planOf = (over) => plain(RP.build(Object.assign({ key: "restock:k1", productId: "p1", productName: "Tomato", category: "Veg", qty: 3, unitCost: 2,
    reason: "", now: ISO, date: "2026-06-15", supplier: { newName: "Acme" } }, over || {})));

// ------------------------------------------------------------------ FailureCause

test("FC-1 forRejection: every code that was a 'bug' before still is, with the same wording", () => {
    const old = ["missing-fields", "unsupported-op-type", "invalid-request-id", "empty-operation", "unsupported-kind", "invalid-entity-id", "cascade-delete-not-allowed"];
    for (const code of old) {
        const r = plain(FC.forRejection({ error: code }, "x"));
        assert.deepEqual(r, { kind: "bug", text: "The server cannot accept this request. This is an app problem, please report it (" + code + ")" }, code);
    }
});

test("FC-2 forRejection: the mint and placeholder codes of R2 are app problems too", () => {
    for (const code of ["too-many-mints", "unknown-counter", "invalid-bind-name", "duplicate-bind-name", "unused-mint", "unbound-placeholder", "placeholder-not-allowed", "placeholder-entity-mismatch", "movement-qty-mismatch"]) {
        const r = plain(FC.forRejection({ error: code }, ""));
        assert.equal(r.kind, "bug", code);
        assert.ok(r.text.endsWith("(" + code + ")"), code);
    }
});

test("FC-3 forRejection: unchanged for the completion causes and for unknown or hostile codes", () => {
    assert.equal(FC.forRejection({ error: "insufficient-quantity" }, "W").text, "W: stock ran out before this order could complete");
    assert.equal(FC.forRejection({ error: "conflict" }).kind, "conflict");
    assert.equal(FC.forRejection({ error: "not-found" }).kind, "missing");
    assert.equal(FC.forRejection({ error: "mint-exhausted" }).kind, "unknown");   // restock-only code: generic here
    assert.equal(FC.forRejection({ error: "<script>alert(1)</script>" }).text, "The server rejected this change");
    assert.equal(FC.forRejection({ error: "toString" }).kind, "unknown", "an inherited property name is not a bug code");
    assert.equal(FC.forRejection({ error: "constructor" }).kind, "unknown");
    assert.equal(FC.forRejection(null).text, "The server rejected this change");
});

test("FC-4 forRestock: the four restock causes say nothing was added; stock/limit codes are app problems", () => {
    const nf = plain(FC.forRestock({ error: "not-found" }, "Tomato"));
    assert.equal(nf.kind, "missing");
    assert.ok(nf.text.startsWith("Tomato: ") && nf.text.endsWith("Nothing was added"));
    assert.equal(plain(FC.forRestock({ error: "not-found" }, "")).text.startsWith("this product"), true);
    const cf = plain(FC.forRestock({ error: "conflict" }));
    assert.equal(cf.kind, "conflict");
    assert.equal(cf.text, "Another device changed this at the same time. Nothing was added. Try again");
    const me = plain(FC.forRestock({ error: "mint-exhausted" }));
    assert.equal(me.kind, "limit");
    assert.ok(me.text.includes("(mint-exhausted)") && me.text.includes("Nothing was added"));
    assert.equal(plain(FC.forRestock({ error: "request-id-in-use" })).kind, "duplicate");
    for (const code of ["insufficient-quantity", "operation-too-large"]) {
        const r = plain(FC.forRestock({ error: code }));
        assert.equal(r.kind, "bug", code);
        assert.ok(!/order/i.test(r.text), "no order wording in a restock message: " + r.text);
    }
});

test("FC-5 forRestock falls back to forRejection for everything else and never throws or returns empty text", () => {
    assert.deepEqual(plain(FC.forRestock({ error: "unused-mint" }, "x")), plain(FC.forRejection({ error: "unused-mint" }, "x")));
    for (const junk of [null, undefined, 0, "", "x", [], {}, { error: 5 }, { error: {} }, { error: "  " }, { error: "A".repeat(200) }]) {
        const r = plain(FC.forRestock(junk, junk));
        assert.equal(typeof r.text, "string"); assert.ok(r.text.length > 0); assert.equal(typeof r.kind, "string");
    }
});

// ------------------------------------------------------------------ DescribeItem

test("DI-1 a restock item reads 'Restock', quantity and product name", () => {
    const d = plain(DI.describe({ opType: "restock", ops: planOf().ops }));
    assert.deepEqual(d, { title: "Restock", detail: "3 × Tomato" });
    assert.deepEqual(plain(DI.describe({ opType: "restock", ops: planOf({ supplier: null }).ops })), { title: "Restock", detail: "3 × Tomato" });
});

test("DI-2 a restock falls back to the product id, then to nothing, and never throws", () => {
    const noName = planOf({ productName: "" }).ops;
    assert.equal(DI.describe({ opType: "restock", ops: noName }).detail, "3 × p1");
    const noTx = planOf().ops.filter((o) => o.entity !== "transaction");
    assert.equal(DI.describe({ opType: "restock", ops: noTx }).detail, "3 × p1");
    assert.equal(DI.describe({ opType: "restock", ops: [{ kind: "mint", counter: "stock_batch", bind: "batch" }] }).detail, "");
    for (const ops of [[null], [undefined, 1, "x", []], [{ entity: "inventory", deltas: null }], [{ entity: "inventory", deltas: { stock: "3" }, entityId: 5 }], [{ entity: "transaction", after: null }]]) {
        const d = plain(DI.describe({ opType: "restock", ops }));
        assert.equal(d.title, "Restock"); assert.equal(typeof d.detail, "string");
    }
    assert.equal(DI.describe({ opType: "restock", ops: [{ entity: "inventory", entityId: "p9", deltas: { stock: -2 } }] }).detail, "p9", "a non-positive quantity is not shown");
    assert.equal(DI.describe({ opType: "restock", ops: [{ entity: "inventory", entityId: "p9", deltas: { stock: 0 } }] }).detail, "p9", "a zero quantity is not shown");
});

test("DI-3 completeOrder and unknown operation labels are unchanged", () => {
    assert.equal(DI.describe({ opType: "completeOrder", ops: [{ entity: "order", entityId: "o1", after: { customer: "Ann" } }] }).title, "Order completion");
    assert.equal(DI.describe({ opType: "mystery", ops: [{ entity: "order", entityId: "o1" }] }).title, "Multi-step change");
});

// ------------------------------------------------------------------ hooks (real bodies from the QML files)

function supplierSandbox(initial) {
    const ctx = { suppliers: initial || [] };
    vm.runInNewContext(extractFunction("model/SupplierStore.qml", "addLocalSupplier"), ctx);
    return ctx;
}

test("H-1 addLocalSupplier adds once, keeps the list sorted by name, refuses a repeat id or a doc without one", () => {
    const ctx = supplierSandbox([{ supplierId: "SUP-001", name: "Mango" }]);
    assert.equal(ctx.addLocalSupplier({ supplierId: "SUP-002", name: "Apple" }), true);
    assert.deepEqual(plain(ctx.suppliers).map((s) => s.name), ["Apple", "Mango"]);
    assert.equal(ctx.addLocalSupplier({ supplierId: "SUP-002", name: "Other" }), false, "replay of the same id");
    assert.equal(ctx.suppliers.length, 2);
    for (const bad of [null, undefined, {}, { supplierId: "" }, { name: "x" }, 5, "SUP-9"]) assert.equal(ctx.addLocalSupplier(bad), false, String(bad));
    assert.equal(ctx.suppliers.length, 2);
});

test("H-2 addLocalSupplier does not change the array it was given in place (bindings need a new array)", () => {
    const before = [{ supplierId: "SUP-001", name: "Mango" }];
    const ctx = supplierSandbox(before);
    ctx.addLocalSupplier({ supplierId: "SUP-002", name: "Apple" });
    assert.equal(before.length, 1);
    assert.notEqual(ctx.suppliers, before);
});

function inventorySandbox() {
    const calls = [];
    const ctx = {
        RestockPlan: RP, console: { warn: (...a) => calls.push(["warn", a.join(" ")]) },
        SupplierStore: { addLocalSupplier: (d) => calls.push(["supplier", d.supplierId]) },
        StockBatchStore: { addLocalBatch: (d) => calls.push(["batch", d.batchId]) },
        TransactionStore: { addLocalEntries: (docs) => calls.push(["tx", docs.map((x) => x.txId)]) },
        applyRemoteStock: (id, stock) => calls.push(["stock", id, stock]),
    };
    vm.runInNewContext(extractFunction("model/InventoryStore.qml", "applyRestockResults"), ctx);
    return { ctx, calls };
}
async function serverResults(over) {
    const OL = require("../lib/operationLogic");
    const { TS, strictDb } = require("./testSupport/strictDb");
    const plan = planOf(over);
    const v = OL.validateOperationRequest({ requestId: plan.key, opType: "restock", clientTimestamp: "c", ops: plan.ops });
    const db = strictDb({ "tenants/t1/inventory/p1": { stock: 10 } });
    const r = await OL.applyOperation(db, { tenantId: "t1", actorUid: "u", actorRole: "owner", requestId: v.requestId, opType: "restock", ops: v.ops, clientTimestamp: "c", serverTimestamp: TS, now: new Date("2026-06-15T12:00:00Z") });
    assert.equal(r.ok, true);
    return plain(r.results);
}

test("H-3 applyRestockResults: a live answer fills the supplier, batch, purchase and stock, in that order", async () => {
    const { ctx, calls } = inventorySandbox();
    const out = ctx.applyRestockResults(await serverResults());
    assert.equal(out.ok, true);
    assert.deepEqual(plain(calls), [["supplier", "SUP-001"], ["batch", "BAT-2026-001"], ["tx", ["tx-p-BAT-2026-001"]], ["stock", "p1", 13]]);
});

test("H-4 applyRestockResults: a known supplier adds no supplier; a replay leaves the stock alone but still fills the gaps", async () => {
    let h = inventorySandbox();
    h.ctx.applyRestockResults(await serverResults({ supplier: { id: "SUP-009" } }));
    assert.deepEqual(plain(h.calls).map((c) => c[0]), ["batch", "tx", "stock"]);
    h = inventorySandbox();
    h.ctx.applyRestockResults(await serverResults(), { replay: true });
    assert.deepEqual(plain(h.calls).map((c) => c[0]), ["supplier", "batch", "tx"]);
    h = inventorySandbox();
    h.ctx.applyRestockResults(await serverResults(), { replay: false });
    assert.equal(plain(h.calls).filter((c) => c[0] === "stock").length, 1);
    h = inventorySandbox();
    h.ctx.applyRestockResults(await serverResults(), {});
    assert.equal(plain(h.calls).filter((c) => c[0] === "stock").length, 1);
});

test("H-5 applyRestockResults: an answer that is not exactly one restock applies NOTHING and says why", async () => {
    for (const bad of [null, undefined, [], {}, [{ kind: "zap" }], (await serverResults()).slice(1), (await serverResults()).filter((r) => r.kind !== "delta")]) {
        const { ctx, calls } = inventorySandbox();
        const out = plain(ctx.applyRestockResults(bad));
        assert.equal(out.ok, false);
        assert.deepEqual(calls.filter((c) => c[0] !== "warn"), [], "nothing applied for " + JSON.stringify(bad));
        assert.equal(calls.filter((c) => c[0] === "warn").length, 1);
    }
});

// ------------------------------------------------------------------ source pins (what Node cannot execute)

const qml = (f) => fs.readFileSync(path.join(__dirname, "..", "..", "qml", f), "utf8");

test("P-1 R4 wiring: restock is the ONLY caller of the planner and goes through one operation, no legacy writes", () => {
    assert.match(qml("model/InventoryStore.qml"), /import "\.\.\/helper\/RestockPlan\.js" as RestockPlan/);
    const callers = [];
    const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).forEach((e) => {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p);
        else if (/\.(qml|js)$/.test(e.name) && /RestockPlan\.build\(/.test(fs.readFileSync(p, "utf8"))) callers.push(path.relative(path.join(__dirname, "..", ".."), p));
    });
    walk(path.join(__dirname, "..", "..", "qml"));
    assert.deepEqual(callers, ["qml/model/InventoryStore.qml"]);
    const body = extractFunction("model/InventoryStore.qml", "restock");
    assert.match(body, /RestockPlan\.build\(/);
    assert.match(body, /Gateway\.recordOperation\("restock"/);
    for (const legacy of [/Gateway\.recordDelta/, /StockBatchStore\.addBatch\(/, /_resolveSupplierId\(/, /TransactionStore\.recordPurchase\(/, /SupplierStore\.addSupplier\(/])
        assert.doesNotMatch(body, legacy, "the two-write path is gone: " + legacy);
});


test("P-2 RestockPlan and OperationKeys stay QML pragma-library files (no QML/singleton imports)", () => {
    for (const f of ["helper/RestockPlan.js", "helper/OperationKeys.js"]) {
        const src = qml(f);
        assert.match(src, /^\.pragma library\s*$/m, f);
        assert.deepEqual((src.match(/^\.import .*$/gm) || []).filter((l) => !/"[A-Za-z]+\.js" as \w+$/.test(l)), [], f);
    }
});
