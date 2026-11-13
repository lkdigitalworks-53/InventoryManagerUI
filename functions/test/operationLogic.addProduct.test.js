"use strict";

// AP1: add product with opening stock is ONE operation (opType "addProduct"). Server half only; nothing in the app
// sends it yet (design 2026-11-13-add-product-atomic-operation-design.md, D-AP-1..6). The real server code runs on the
// strict fake DB; the existing operationLogic suites are NOT edited beyond four one-line pins that said "product is
// not a registered counter" or "restock only".

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const OL = require("../lib/operationLogic");
const R = require("../lib/counterRegistry");
const ML = require("../lib/movementLogic");
const Gateway = require("../lib/gatewayLogic");
const { TS, strictDb, pessimisticWrites, rowsOf } = require("./testSupport/strictDb");

const T = "tenants/t1/";
const NOW = new Date("2026-06-15T12:00:00Z");
const NOW_ISO = "2026-06-15T12:00:00.000Z";
const TOKEN = OL.STOCK_TOKEN;

const mint = (counter, bind) => ({ kind: "mint", counter, bind });
const create = (entity, entityId, after) => ({ kind: "mutation", entity, entityId, action: "create", before: null, after });
const productDoc = (over) => Object.assign({
    productId: "{{prd}}", name: "Tomato", sku: "TO-2026-001", category: "Veg", stock: 12, minStock: 2,
    price: 20, sellingPrice: 30, taxable: false, taxPercent: 0, size: "", unit: "kg", description: "",
    photoIds: [], supplierId: ""
}, over || {});
const activityDoc = (over) => Object.assign({
    id: "act-{{prd}}", kind: "product_added", title: "Product added: Tomato", subtitle: "TO-2026-001 · stock 12",
    entityId: "{{prd}}", read: false, dismissed: false
}, over || {});
const activityOp = (docOver, opOver) => Object.assign(create("activity", "act-{{prd}}", activityDoc(docOver)), opOver || {});

// The shape AddProductPlan (AP2) will build: mints first, then supplier, product, batch, "created" row, feed row.
//   stock          opening stock (no batch mint and no batch doc when 0)
//   newSupplier    a supplier created inside the operation
//   supplierId     a known supplier id the product and batch carry
//   activity       an op to use instead of the default one; null = none
function addOps(over) {
    const o = Object.assign({ stock: 12, newSupplier: false, supplierId: "", activity: undefined }, over || {});
    const sup = o.newSupplier ? "{{sup}}" : o.supplierId;
    const ops = [mint("product", "prd")];
    if (o.newSupplier) ops.push(mint("supplier", "sup"));
    if (o.stock > 0) ops.push(mint("stock_batch", "batch"));
    if (o.newSupplier) ops.push(create("supplier", "{{sup}}", { supplierId: "{{sup}}", name: "Newco", contact: "", leadTimeDays: 0, terms: "", notes: "" }));
    ops.push(create("inventory", "{{prd}}", productDoc({ stock: o.stock, supplierId: sup })));
    if (o.stock > 0) ops.push(create("stock_batch", "{{batch}}", {
        batchId: "{{batch}}", productId: "{{prd}}", supplierId: sup, qtyReceived: o.stock, qtyRemaining: o.stock,
        unitCost: 20, note: "Initial stock" }));
    ops.push(create("transaction", "tx-c-{{prd}}", { txId: "tx-c-{{prd}}", kind: "created", productId: "{{prd}}", quantity: o.stock }));
    if (o.activity !== null) ops.push(o.activity || activityOp());
    return ops;
}
const indexOfActivity = (ops) => ops.findIndex((op) => op.entity === "activity");
const body = (ops, opType, id) => ({ requestId: (opType || "addProduct") + ":dev1-" + (id || "a"), opType: opType || "addProduct", clientTimestamp: "CT", ops });
const validated = (b) => { const v = OL.validateOperationRequest(b); assert.equal(v.ok, true, JSON.stringify(v)); return v; };
const invalid = (b) => { const v = OL.validateOperationRequest(b); assert.equal(v.ok, false, "expected a rejection"); return v; };
async function run(db, b, extra) {
    const v = validated(b);
    return OL.applyOperation(db, Object.assign({
        tenantId: "t1", actorUid: "u-actor", actorRole: "owner", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: TS, now: NOW }, extra || {}));
}
const withCounter = (value, more) => strictDb(Object.assign({ [T + "counters/products"]: { value } }, more || {}));

// ------------------------------------------------------------------ registry and op type

test("R-1 the product counter: id space, doc and format are those of InventoryStore.nextProductId, whatever the year", () => {
    assert.equal(R.isKnownCounter("product"), true);
    for (const year of ["2026", "2031"]) {
        const d = R.describe("product", year);
        assert.deepEqual(d, { key: "product", entity: "inventory", collection: "inventory", counterName: "products", prefix: "PRD-" });
    }
    assert.equal(R.formatId("PRD-", 7), "PRD-007");
    assert.equal(R.formatId("PRD-", 1000), "PRD-1000", "padStart never truncates");
    assert.equal(R.numberOf("PRD-", "PRD-007"), 7);
    for (const junk of ["PRD-", "PRD-7x", "prd-7", "SUP-007", "PRD--1", 7, null]) assert.equal(R.numberOf("PRD-", junk), null, String(junk));
});

test("R-2 the other two counters did not move (supplier and stock_batch keep their exact registry entries)", () => {
    assert.equal(R.describe("supplier", "2026").prefix, "SUP-");
    assert.equal(R.describe("stock_batch", "2026").prefix, "BAT-2026-");
    assert.equal(R.describe("stock_batch", "2026").counterName, "stockBatches-2026");
    assert.equal(Gateway.ENTITY_COLLECTIONS.inventory, R.describe("product", "2026").collection);
});

test("V-1 addProduct is an operation type; its request id must carry the addProduct: namespace", () => {
    assert.ok(OL.OP_TYPES.indexOf("addProduct") >= 0);
    assert.deepEqual(OL.OP_TYPES.slice(0, 2), ["completeOrder", "restock"], "the older two are untouched");
    assert.equal(invalid({ requestId: "restock:x", opType: "addProduct", ops: addOps() }).error, "invalid-request-id");
    assert.equal(invalid({ requestId: "addProduct:a~b", opType: "addProduct", ops: addOps() }).error, "invalid-request-id");
    assert.equal(invalid({ requestId: "addproduct:x", opType: "addproduct", ops: addOps() }).error, "unsupported-op-type");
    assert.equal(invalid({ requestId: "addProducts:x", opType: "addProducts", ops: addOps() }).error, "unsupported-op-type");
});

// ------------------------------------------------------------------ validation: accepted

test("V-2 the full operation is accepted and kept as a template (ids and tokens are not resolved yet)", () => {
    const v = validated(body(addOps({ newSupplier: true })));
    assert.equal(v.ops[0].kind, "mint");
    assert.deepEqual([v.ops[0].counter, v.ops[0].entity, v.ops[0].collection], ["product", "inventory", "inventory"]);
    const inv = v.ops.find((o) => o.kind === "mutation" && o.entity === "inventory");   // a mint op names its entity too
    assert.equal(inv.entityId, "{{prd}}");
    assert.equal(inv.after.supplierId, "{{sup}}");
    const act = v.ops[indexOfActivity(v.ops)];
    assert.equal(act.collection, "activity_log");
    assert.equal(act.entityId, "act-{{prd}}");
});

test("V-3 the smallest operation (no stock, no supplier) is accepted: one mint, three creates", () => {
    const ops = addOps({ stock: 0 });
    assert.equal(ops.filter((o) => o.kind === "mint").length, 1);
    validated(body(ops));
});

test("V-4 a literal-id create needs no mint (the activity op then names the literal id)", () => {
    const ops = [create("inventory", "PRD-500", productDoc({ productId: "PRD-500" })),
                 create("activity", "act-PRD-500", activityDoc({ id: "act-PRD-500", entityId: "PRD-500" }))];
    validated(body(ops));
});

// ------------------------------------------------------------------ validation: refused

test("V-5 the kind is tied to the op type: product_added only in addProduct, product_restocked only in restock", () => {
    const wrong = addOps({ activity: activityOp({ kind: "product_restocked" }) });
    const r = invalid(body(wrong));
    assert.equal(r.error, "invalid-activity");
    assert.equal(r.opIndex, indexOfActivity(wrong));
    // the same row inside a restock-shaped operation is refused for the mirror reason
    const restock = [mint("stock_batch", "batch"),
        create("stock_batch", "{{batch}}", { batchId: "{{batch}}", productId: "p1" }),
        { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: 5 }, floors: {}, clamps: {}, movements: [{ kind: "receipt", qty: 5, reason: "" }] },
        create("activity", "act-{{batch}}", { id: "act-{{batch}}", kind: "product_added", title: "Product added: Tomato", subtitle: "x", entityId: "p1", read: false, dismissed: false })];
    assert.equal(invalid(body(restock, "restock")).error, "invalid-activity");
    for (const kind of ["", "order", "PRODUCT_ADDED", "product_updated", null, undefined, 7, ["product_added"]])
        assert.equal(invalid(body(addOps({ activity: activityOp({ kind }) }))).error, "invalid-activity", String(kind));
});

test("V-6 completeOrder still cannot carry an activity op at all", () => {
    const r = invalid(body(addOps(), "completeOrder"));
    assert.equal(r.error, "unsupported-entity");
});

test("V-7 the row must name a product THIS operation creates, earlier in the list", () => {
    const base = addOps();
    const at = indexOfActivity(base);
    // (a) no inventory create at all
    const noCreate = base.filter((o) => o.entity !== "inventory");
    assert.equal(invalid(body(noCreate)).error, "invalid-activity");
    // (b) the create comes AFTER the row
    const reordered = base.slice();
    const inv = reordered.findIndex((o) => o.entity === "inventory");
    const [row] = reordered.splice(at, 1);
    reordered.splice(inv, 0, row);
    assert.equal(invalid(body(reordered)).error, "invalid-activity");
    // (c) the row names another product
    assert.equal(invalid(body(addOps({ activity: activityOp({ entityId: "PRD-999" }) }))).error, "invalid-activity");
    assert.equal(invalid(body(addOps({ activity: activityOp({ entityId: "{{other}}" }) }))).error, "invalid-activity");
    // (d) an inventory UPDATE or a stock delta for the product is not "created"
    const upd = [{ kind: "mutation", entity: "inventory", entityId: "PRD-500", action: "update", before: productDoc({ productId: "PRD-500" }), after: productDoc({ productId: "PRD-500", stock: 3 }) },
                 create("activity", "act-PRD-500", activityDoc({ id: "act-PRD-500", entityId: "PRD-500" }))];
    assert.equal(invalid(body(upd)).error, "invalid-activity");
    const delta = [{ kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: 5 }, floors: {}, clamps: {}, movements: [{ kind: "receipt", qty: 5, reason: "" }] },
                   create("activity", "act-p1", activityDoc({ id: "act-p1", entityId: "p1" }))];
    assert.equal(invalid(body(delta)).error, "invalid-activity");
    // (e) a CREATE of another entity under the same id does not count
    const batchOnly = [mint("stock_batch", "batch"), create("stock_batch", "{{batch}}", { batchId: "{{batch}}", productId: "x" }),
                       create("activity", "act-{{batch}}", activityDoc({ id: "act-{{batch}}", entityId: "{{batch}}" }))];
    assert.equal(invalid(body(batchOnly)).error, "invalid-activity");
});

test("V-8 the stock token is meaningless for an added product: refused in the subtitle and in the title", () => {
    assert.equal(invalid(body(addOps({ activity: activityOp({ subtitle: "stock " + TOKEN }) }))).error, "invalid-activity");
    assert.equal(invalid(body(addOps({ activity: activityOp({ title: "Added " + TOKEN }) }))).error, "invalid-activity");
});

test("V-9 the placeholder rules hold for the product id: it can only be an inventory id", () => {
    const asBatch = [mint("product", "prd"), create("stock_batch", "{{prd}}", { batchId: "{{prd}}" })];
    const r = invalid(body(asBatch));
    assert.equal(r.error, "placeholder-entity-mismatch");
    assert.equal(r.opIndex, 1);
    const batchAsProduct = [mint("stock_batch", "batch"), create("inventory", "{{batch}}", productDoc({ productId: "{{batch}}" }))];
    assert.equal(invalid(body(batchAsProduct)).error, "placeholder-entity-mismatch");
    // a product mint nothing uses is refused, not burned
    const unused = invalid(body([mint("product", "prd"), create("inventory", "PRD-500", productDoc({ productId: "PRD-500" }))]));
    assert.equal(unused.error, "unused-mint");
    assert.equal(unused.opIndex, 0);
});

test("V-10 the seven-key shape, create-only and ONE row per operation hold for the new kind too", () => {
    const withActivity = (docOver, opOver) => body(addOps({ activity: activityOp(docOver, opOver) }));
    assert.equal(invalid(withActivity({ actorUid: "evil" })).error, "invalid-activity");
    assert.equal(invalid(withActivity({ timestamp: "2020-01-01T00:00:00Z" })).error, "invalid-activity");
    assert.equal(invalid(withActivity({ read: true })).error, "invalid-activity");
    assert.equal(invalid(withActivity({ title: "" })).error, "invalid-activity");
    assert.equal(invalid(withActivity({ id: "act-other" })).error, "invalid-activity");
    assert.equal(invalid(withActivity(null, { action: "update", before: activityDoc() })).error, "invalid-activity");
    const two = addOps().concat([activityOp()]);
    assert.equal(invalid(body(two)).error, "invalid-activity");
});

test("V-11 monkey: 400 random single-field corruptions of the feed row never throw and never let a bad row through", () => {
    let seed = 20261113;
    const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
    const junk = [null, undefined, "", " ", 0, -1, 1.5, NaN, Infinity, true, false, [], {}, [1], { a: 1 }, "x".repeat(1200), "{{prd}}", TOKEN, "act-", "📦".repeat(120), "product_restocked"];
    const keys = Object.keys(activityDoc());
    let accepted = 0;
    for (let i = 0; i < 400; i++) {
        const doc = activityDoc();
        const k = keys[Math.floor(rnd() * keys.length)];
        doc[k] = junk[Math.floor(rnd() * junk.length)];
        const ops = addOps({ activity: activityOp(doc) });
        const v = OL.validateOperationRequest(body(ops));
        if (!v.ok) continue;
        accepted++;
        const a = v.ops[indexOfActivity(v.ops)].after;
        assert.deepEqual(Object.keys(a).sort(), keys.slice().sort());
        assert.equal(a.kind, "product_added");
        assert.ok(typeof a.title === "string" && a.title.length > 0 && a.title.length <= 200);
        assert.ok(typeof a.subtitle === "string" && a.subtitle.length <= 1000 && a.subtitle.indexOf(TOKEN) < 0);
        assert.ok(typeof a.entityId === "string" && a.entityId.length > 0);
        assert.equal(a.read, false); assert.equal(a.dismissed, false);
    }
    assert.ok(accepted > 0 && accepted < 400, "the monkey reaches both outcomes: " + accepted);
});

test("V-12 REGRESSION: restock keeps its exact rules (a delta names the product, a mere create does not satisfy it)", () => {
    const delta = { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: 5 }, floors: {}, clamps: {}, movements: [{ kind: "receipt", qty: 5, reason: "" }] };
    const restockRow = (over) => create("activity", "act-{{batch}}", Object.assign({
        id: "act-{{batch}}", kind: "product_restocked", title: "Restocked: Tomato", subtitle: "+5 · now " + TOKEN + " in stock",
        entityId: "p1", read: false, dismissed: false }, over || {}));
    const batch = [mint("stock_batch", "batch"), create("stock_batch", "{{batch}}", { batchId: "{{batch}}", productId: "p1" })];
    validated(body(batch.concat([delta, restockRow()]), "restock"));
    // a CREATE of the inventory doc does not satisfy the restock rule (F2 of PR #197 stays as strict as it was)
    const createdOnly = batch.concat([create("inventory", "p1", productDoc({ productId: "p1" })), restockRow({ subtitle: "x" })]);
    assert.equal(invalid(body(createdOnly, "restock")).error, "invalid-activity");
    // and the token is still allowed there
    assert.equal(validated(body(batch.concat([delta, restockRow()]), "restock")).ok, true);
});

// ------------------------------------------------------------------ apply

test("B-1 one operation: every doc lands with the real ids, one derived receipt row, counters written, marker holds the results", async () => {
    const db = withCounter(6);
    const r = await run(db, body(addOps({ newSupplier: true })));
    assert.equal(r.ok, true, JSON.stringify(r));
    const inv = db.store[T + "inventory/PRD-007"];
    assert.equal(inv.productId, "PRD-007");
    assert.equal(inv.stock, 12);
    assert.equal(inv.supplierId, "SUP-001", "a token inside a stored doc is replaced by the minted id");
    assert.deepEqual(db.store[T + "suppliers/SUP-001"].supplierId, "SUP-001");
    const batch = db.store[T + "stock_batches/BAT-2026-001"];
    assert.deepEqual([batch.batchId, batch.productId, batch.supplierId, batch.qtyReceived, batch.qtyRemaining], ["BAT-2026-001", "PRD-007", "SUP-001", 12, 12]);
    assert.equal(db.store[T + "transactions/tx-c-PRD-007"].productId, "PRD-007");
    assert.deepEqual(db.store[T + "activity_log/act-PRD-007"], {
        id: "act-PRD-007", kind: "product_added", title: "Product added: Tomato", subtitle: "TO-2026-001 · stock 12",
        entityId: "PRD-007", read: false, dismissed: false, actorUid: "u-actor", timestamp: NOW_ISO });
    assert.deepEqual(db.store[T + "counters/products"], { value: 7 });
    assert.deepEqual(db.store[T + "counters/suppliers"], { value: 1 });
    assert.deepEqual(db.store[T + "counters/stockBatches-2026"], { value: 1 });
    const marker = db.store[T + "audit_log/addProduct:dev1-a"];
    assert.equal(marker.opType, "addProduct");
    assert.equal(marker.opCount, 8);
    assert.deepEqual(marker.results[0], { kind: "mint", counter: "product", bind: "prd", id: "PRD-007" });
    assert.deepEqual(r.results[0], marker.results[0]);
});

test("B-2 the opening stock is ledgered by the server: exactly one receipt row, +12, stamped with the caller and the operation", async () => {
    const db = withCounter(6);
    await run(db, body(addOps()));
    const rows = rowsOf(db);
    assert.equal(rows.length, 1);
    const row = rows[0].data;
    assert.deepEqual([row.kind, row.qty, row.productId, row.productName, row.derived], ["receipt", 12, "PRD-007", "Tomato", true]);
    assert.deepEqual([row.opType, row.operationId, row.actorUid, row.actorRole], ["addProduct", "addProduct:dev1-a", "u-actor", "owner"]);
});

test("B-3 exactly the expected docs are written (no stray write), within the write budget", async () => {
    const db = withCounter(6);
    await run(db, body(addOps({ newSupplier: true })));
    const paths = db.writes.map((w) => w.path.replace(T, "")).sort();
    assert.deepEqual(paths, [
        "activity_log/act-PRD-007", "audit_log/addProduct:dev1-a", "audit_log/addProduct:dev1-a~3", "audit_log/addProduct:dev1-a~4",
        "audit_log/addProduct:dev1-a~5", "audit_log/addProduct:dev1-a~6", "audit_log/addProduct:dev1-a~7",
        "counters/products", "counters/stockBatches-2026", "counters/suppliers", "inventory/PRD-007",
        "stock_batches/BAT-2026-001", "stock_movements/addProduct:dev1-a~4~m0", "suppliers/SUP-001", "transactions/tx-c-PRD-007"].sort());
    assert.ok(pessimisticWrites(db.writes) <= ML.MAX_TXN_WRITES);
});

test("B-4 a retry of the same request id is a replay: same answer, no second product, the counter does not move", async () => {
    const db = withCounter(6);
    const b = body(addOps());
    const first = await run(db, b);
    const before = JSON.stringify(db.store);
    const writes = db.writes.length;
    const again = await run(db, b);
    assert.equal(again.ok, true);
    assert.equal(again.idempotentReplay, true);
    assert.deepEqual(again.results, first.results);
    assert.equal(db.writes.length, writes, "a replay writes nothing");
    assert.equal(JSON.stringify(db.store), before);
    assert.deepEqual(db.store[T + "counters/products"], { value: 7 });
});

test("B-5 zero opening stock: the product is created with no batch and no ledger row (nothing moved)", async () => {
    const db = withCounter(6);
    const r = await run(db, body(addOps({ stock: 0, activity: activityOp({ subtitle: "TO-2026-001 · stock 0" }) })));
    assert.equal(r.ok, true, JSON.stringify(r));
    assert.equal(db.store[T + "inventory/PRD-007"].stock, 0);
    assert.equal(rowsOf(db).length, 0);
    assert.equal(Object.keys(db.store).some((k) => k.indexOf("stock_batches") >= 0), false);
    assert.equal(Object.keys(db.store).some((k) => k.indexOf("stockBatches") >= 0), false, "no batch counter moved either");
});

test("B-6 fractional stock (2.5 kg) is ledgered as 2.5", async () => {
    const db = withCounter(6);
    await run(db, body(addOps({ stock: 2.5 })));
    assert.equal(rowsOf(db)[0].data.qty, 2.5);
    assert.equal(db.store[T + "stock_batches/BAT-2026-001"].qtyRemaining, 2.5);
});

test("B-7 a known supplier id is carried as typed: no supplier mint, no supplier doc, counter untouched", async () => {
    const db = withCounter(6, { [T + "suppliers/SUP-009"]: { supplierId: "SUP-009", name: "Old" } });
    await run(db, body(addOps({ supplierId: "SUP-009" })));
    assert.equal(db.store[T + "inventory/PRD-007"].supplierId, "SUP-009");
    assert.equal(db.store[T + "stock_batches/BAT-2026-001"].supplierId, "SUP-009");
    assert.equal(Object.prototype.hasOwnProperty.call(db.store, T + "counters/suppliers"), false);
});

test("B-8 the counter is behind the data: the mint skips an occupied id and never overwrites it", async () => {
    const taken = { productId: "PRD-007", name: "Existing", stock: 1 };
    const db = withCounter(6, { [T + "inventory/PRD-007"]: taken });
    const r = await run(db, body(addOps()));
    assert.equal(r.ok, true, JSON.stringify(r));
    assert.equal(r.results[0].id, "PRD-008");
    assert.deepEqual(db.store[T + "inventory/PRD-007"], taken, "the occupied doc is untouched");
    assert.equal(db.store[T + "inventory/PRD-008"].productId, "PRD-008");
    assert.deepEqual(db.store[T + "counters/products"], { value: 8 });
});

test("B-9 no usable counter doc: the seed is the highest PRD- number among the inventory ids (numeric, junk ignored)", async () => {
    const inv = (id) => ({ [T + "inventory/" + id]: { productId: id, name: id, stock: 0 } });
    const db = strictDb(Object.assign({ [T + "counters/products"]: { value: "oops" } },
        inv("PRD-004"), inv("PRD-999"), inv("PRD-1000"), inv("PRD-x1"), inv("OTHER-99999"), inv("PRD-12345678901234567890")));
    const r = await run(db, body(addOps()));
    assert.equal(r.results[0].id, "PRD-1001", "1000 is a bigger number than 999 although it sorts lower");
    assert.deepEqual(db.store[T + "counters/products"], { value: 1001 });
    const empty = strictDb({});
    assert.equal((await run(empty, body(addOps()))).results[0].id, "PRD-001");
});

test("B-10 the number is padded to three digits and never truncated: 999 -> PRD-1000", async () => {
    const db = withCounter(999);
    assert.equal((await run(db, body(addOps()))).results[0].id, "PRD-1000");
});

test("B-11 two operations in a row hand out two different ids and keep two ledger rows", async () => {
    const db = withCounter(6);
    const a = await run(db, body(addOps(), "addProduct", "a"));
    const b = await run(db, body(addOps({ activity: activityOp({ title: "Product added: Onion" }) }), "addProduct", "b"));
    assert.deepEqual([a.results[0].id, b.results[0].id], ["PRD-007", "PRD-008"]);
    assert.equal(rowsOf(db).length, 2);
    assert.deepEqual(db.store[T + "counters/products"], { value: 8 });
    assert.ok(db.store[T + "activity_log/act-PRD-007"] && db.store[T + "activity_log/act-PRD-008"], "one feed row per product");
});

test("B-12 a rejected operation leaves NO trace and burns no number; the retry after the fix gets the SAME id", async () => {
    const blocker = { txId: "tx-c-PRD-007" };
    const db = withCounter(6, { [T + "transactions/tx-c-PRD-007"]: blocker });
    const b = body(addOps());
    const r = await run(db, b);
    assert.equal(r.ok, false);
    assert.equal(r.status, 409);
    assert.equal(r.error, "conflict", "a create over an existing doc is a conflict, never an overwrite");
    assert.equal(db.writes.length, 0, "no working doc, audit, ledger row, counter or marker");
    assert.deepEqual(db.store[T + "counters/products"], { value: 6 });
    delete db.store[T + "transactions/tx-c-PRD-007"];
    const retry = await run(db, b);
    assert.equal(retry.ok, true, JSON.stringify(retry));
    assert.equal(retry.results[0].id, "PRD-007");
});

test("B-13 an existing feed row at the id is a conflict (409), never an overwrite", async () => {
    const old = { id: "act-PRD-007", kind: "product_added", title: "old" };
    const db = withCounter(6, { [T + "activity_log/act-PRD-007"]: old });
    const r = await run(db, body(addOps()));
    assert.equal(r.status, 409);
    assert.equal(db.writes.length, 0);
    assert.deepEqual(db.store[T + "activity_log/act-PRD-007"], old);
});

test("B-14 a client cannot choose who or when: the stamp is the caller and the server clock", async () => {
    const db = withCounter(6);
    await run(db, body(addOps()), { actorUid: "u-real", now: new Date("2027-01-02T03:04:05Z") });
    const row = db.store[T + "activity_log/act-PRD-007"];
    assert.equal(row.actorUid, "u-real");
    assert.equal(row.timestamp, "2027-01-02T03:04:05.000Z");
});

test("B-15 the batch id carries the IST year of the server clock (2026-12-31 20:00Z is already 2027 in India)", async () => {
    const db = withCounter(6);
    const r = await run(db, body(addOps()), { now: new Date("2026-12-31T20:00:00Z") });
    assert.equal(r.results[1].id, "BAT-2027-001");
});

test("K-1 DOCUMENTED GAP (KNOWN-ISSUES, not new in AP1): an inventory create with a non-numeric stock leaves NO ledger row", async () => {
    // recordMutation has the same hole today: the server derives the receipt row from `stock` only when it is a finite
    // number. AddProductPlan (AP2) sends a number and its tests prove it. Flip this test when the inventory doc shape
    // is validated server-side (its own slice).
    const db = withCounter(6);
    const ops = addOps({ stock: 0 }).map((o) => o.entity === "inventory" ? create("inventory", "{{prd}}", productDoc({ stock: "12" })) : o);
    const r = await run(db, body(ops));
    assert.equal(r.ok, true, JSON.stringify(r));
    assert.equal(db.store[T + "inventory/PRD-007"].stock, "12");
    assert.equal(rowsOf(db).length, 0);
});

// ------------------------------------------------------------------ guards

test("G-1 dormancy: no QML file sends the addProduct operation yet (AP3 removes this guard when it wires the client)", () => {
    const root = path.join(__dirname, "..", "..", "qml");
    const hits = [];
    (function walk(dir) {
        for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
            const p = path.join(dir, e.name);
            if (e.isDirectory()) walk(p);
            else if (/\.(qml|js)$/.test(e.name) && /["']addProduct["']/.test(fs.readFileSync(p, "utf8"))) hits.push(path.relative(root, p));
        }
    })(root);
    assert.deepEqual(hits, []);
});

test("G-2 source pins: the product counter and the kind table are where the design says", () => {
    const lib = (f) => fs.readFileSync(path.join(__dirname, "..", "lib", f), "utf8");
    assert.match(lib("counterRegistry.js"), /product: \{\s+entity: "inventory",\s+collection: "inventory",\s+counterName: function \(\) \{ return "products"; \},\s+prefix: function \(\) \{ return "PRD-"; \}/);
    assert.match(lib("operationLogic.js"), /ACTIVITY_KIND_BY_OPTYPE = \{ restock: "product_restocked", addProduct: "product_added" \}/);
    assert.deepEqual(OL.OPERATION_ONLY_ENTITIES.activity.opTypes, ["restock", "addProduct"]);
    // the feed is still not reachable through the single-record endpoints
    assert.equal(Object.prototype.hasOwnProperty.call(Gateway.ENTITY_COLLECTIONS, "activity"), false);
});
