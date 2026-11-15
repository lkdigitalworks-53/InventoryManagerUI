"use strict";

// Picker v2, slice S5a (KNOWN-ISSUES 34): an order built with the product picker's REAL client code completes
// through the REAL recordOperation endpoint, against the Firebase Local Emulator Suite. The picker helpers
// (PickerSheetModel, PickerDraft, NewOrderPicker, EditOrderPicker) and the planner (CompletionPlan) are the files
// the app ships, loaded as text; the server is the real function on real Firestore. Nothing here is a copy of a rule.
//
// What this proves that the Node unit tests cannot: the lines the picker produces make an operation the SERVER
// accepts (FIFO over two batches, stock, order CAS, sale docs), a replay applies once, and a stock change by another
// device between "pick" and "complete" is refused as a whole and recovers after the sheet re-reads.
//
// NOT covered (no Node-reachable path): Edit Order on a COMPLETED order. Its save goes
// adjustRequested -> ConfirmReturnSheet -> DataModel._tryAdjustOrder, a QML-only sequential chain (KNOWN-ISSUES 29, 34).
// The Felgo layer (sheet, row, dialogs) is device-only.
//
// Run inside the same `firebase emulators:exec` as the other E2E files, AFTER test/e2e/seed.js has written
// .fixture.json (see .github/workflows/checks.yml). Uses its own ids (prefix "pkE2E") and deletes what it creates.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { load, plain } = require("../../functions/test/testSupport/qmlHelpers");

const PM = load("PickerSheetModel.js");
const PD = load("PickerDraft.js");
const NP = load("NewOrderPicker.js");
const EP = load("EditOrderPicker.js");
const CP = load("CompletionPlan.js");

const PROJECT_ID = "inventorymanager-48392";   // must match seed.js and FirebaseService.qml
const FUNCTIONS_BASE = "http://127.0.0.1:5001/" + PROJECT_ID + "/asia-south1";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
    console.error("pickerOrder.e2e: FIRESTORE_EMULATOR_HOST is not set -- refusing to run " +
                  "against what might be real Firestore.");
    process.exit(1);
}

const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, ".fixture.json"), "utf8"));
const T = "tenants/" + fixture.tenantId + "/";
const app = initializeApp({ projectId: PROJECT_ID }, "pickerOrderE2E");
const db = getFirestore(app);

const createdPaths = new Set();

async function seed(relPath, data) {
    await db.doc(T + relPath).set(data);
    createdPaths.add(T + relPath);
}
async function read(relPath) {
    const snap = await db.doc(T + relPath).get();
    return snap.exists ? snap.data() : null;
}
async function post(body) {
    let lastError;
    for (let attempt = 0; attempt < 4; attempt++) {
        try {
            const res = await fetch(FUNCTIONS_BASE + "/recordOperation", {
                method: "POST",
                headers: { "Content-Type": "application/json", "Authorization": "Bearer " + fixture.idToken },
                body: JSON.stringify(body),
                signal: AbortSignal.timeout(60000)
            });
            let json = null;
            try { json = await res.json(); } catch (e) { json = null; }
            return { status: res.status, body: json };
        } catch (e) {
            lastError = e;
            await new Promise((resolve) => setTimeout(resolve, 2000));
        }
    }
    throw lastError;
}

test.after(async () => {
    for (const p of createdPaths) await db.doc(p).delete();
    // the server also writes one audit row per op and one stock movement per stock change, keyed by the request id
    for (const coll of ["audit_log", "stock_movements"])
        for (const ref of await db.collection(T + coll).listDocuments())
            if (ref.id.startsWith("completeOrder:pkE2E")) await ref.delete();
});

// ---- what the dialogs hand the sheet and the planner, built from the shipped helpers ----
const NOW = "2026-11-15T10:00:00.000Z";

async function catalog(ids) {
    const out = [];
    for (const id of ids) out.push(await read("inventory/" + id));
    return out;
}
async function batchesFor(productId, ids) {
    const out = [];
    for (const id of ids) {
        const b = await read("stock_batches/" + id);
        if (b && b.productId === productId) out.push({ batchId: b.batchId, supplierId: b.supplierId || "", qtyRemaining: b.qtyRemaining, unitCost: b.unitCost });
    }
    return out;
}
function lookupFor(products, batchMap) {
    return {
        productOf: (id) => products.filter((p) => p.productId === id)[0] || null,
        batchesOf: (id) => batchMap[id] || []
    };
}
// The New Order dialog's hooks (NewOrderDialog._pickerHooks), over a cart.
function newOrderHooks(cart, lookup) {
    return {
        hasPendingMint: () => false,
        hasQueuedRestock: () => false,
        unsyncedState: () => "",
        hasPrice: (p) => NP.priceOf(p) !== null,
        inOrderQty: (id) => NP.cartQty(cart, id),
        availableFor: (p) => NP.availableFor(p, cart),
        commitCheck: (plan) => NP.opsCheck(cart, plan, lookup)
    };
}
// The Edit Order dialog's hooks (OrderDetailDialog._pickerHooks), over its rows and saved state.
function editOrderHooks(rows, ctx, lookup) {
    return {
        hasPendingMint: () => false,
        hasQueuedRestock: () => false,
        unsyncedState: () => "",
        hasPrice: (p) => NP.priceOf(p) !== null,
        inOrderQty: (id) => NP.cartQty(EP.linesOf(rows), id),
        availableFor: (p) => EP.availableFor(p, EP.linesOf(rows), ctx),
        commitCheck: (plan) => EP.commitCheck(EP.linesOf(rows), plan, ctx, lookup)
    };
}
function view(products, hooks, orderLines, draft) {
    return plain(PM.build({ products: products, hooks: hooks, orderLines: orderLines, draft: draft || {}, query: "", category: "All", inStockOnly: false }));
}
const byId = (v, id) => v.rows.filter((r) => r.productId === id)[0];

// The completion plan the dialog would send for these order lines (qty = line quantity), against these server docs.
function completionOf(orderId, orderBefore, lineObjs, products, batchMap) {
    const stock = {};
    products.forEach((p) => { stock[p.productId] = p.stock; });
    return plain(CP.build({
        orderId: orderId, epoch: 1, now: NOW, clampStock: false,
        lines: lineObjs.map((l) => ({ line: l, productId: l.productId, name: l.name, qty: l.quantity !== undefined ? l.quantity : l.qty })),
        stockByProduct: stock, batchesByProduct: batchMap
    }, {
        orderUpdate: (lines) => ({ before: orderBefore, after: { orderId: orderId, status: "completed", products: lines } }),
        saleDocs: (after) => after.products.map((l, i) => ({ txId: "tx-s-" + orderId + "-" + i, kind: "sale", orderId: orderId, productId: l.productId }))
    }));
}
function bodyOf(plan) {
    return { requestId: plan.key, opType: plan.opType, clientTimestamp: new Date().toISOString(), ops: plan.ops };
}
function trackSaleDocs(plan) {
    plan.ops.filter((o) => o.entity === "transaction").forEach((o) => createdPaths.add(T + "transactions/" + o.entityId));
}

// ---- E1: New Order -> picker -> complete ----
test("PK-E1: a New Order built from the picker (two batches, a no-price product shown disabled) completes on the real server; a replay applies once", async () => {
    await seed("inventory/pkE2E-p1", { productId: "pkE2E-p1", name: "Pk One", category: "E2E", stock: 10, sellingPrice: 5, price: 3 });
    await seed("inventory/pkE2E-p2", { productId: "pkE2E-p2", name: "Pk Two", category: "E2E", stock: 3, sellingPrice: 8, price: 4 });
    await seed("inventory/pkE2E-p3", { productId: "pkE2E-p3", name: "Pk Three", category: "E2E", stock: 4 });   // no price at all
    await seed("stock_batches/pkE2E-b1", { batchId: "pkE2E-b1", productId: "pkE2E-p1", qtyRemaining: 6, unitCost: 2 });
    await seed("stock_batches/pkE2E-b2", { batchId: "pkE2E-b2", productId: "pkE2E-p1", qtyRemaining: 4, unitCost: 3 });
    await seed("stock_batches/pkE2E-b3", { batchId: "pkE2E-b3", productId: "pkE2E-p2", qtyRemaining: 3, unitCost: 4 });
    await seed("stock_batches/pkE2E-b4", { batchId: "pkE2E-b4", productId: "pkE2E-p3", qtyRemaining: 4, unitCost: 1 });
    const orderBefore = { orderId: "pkE2E-o1", status: "pending" };
    await seed("orders/pkE2E-o1", orderBefore);

    const products = await catalog(["pkE2E-p1", "pkE2E-p2", "pkE2E-p3"]);
    const batchMap = { "pkE2E-p1": await batchesFor("pkE2E-p1", ["pkE2E-b1", "pkE2E-b2"]), "pkE2E-p2": await batchesFor("pkE2E-p2", ["pkE2E-b3"]), "pkE2E-p3": await batchesFor("pkE2E-p3", ["pkE2E-b4"]) };
    const lookup = lookupFor(products, batchMap);
    const cart = [];

    // the sheet: priced products addable, the one without a price disabled with words (S5a), nothing hidden
    const v0 = view(products, newOrderHooks(cart, lookup), cart);
    assert.deepEqual([byId(v0, "pkE2E-p1").canAdd, byId(v0, "pkE2E-p1").maxQty], [true, 10]);
    assert.deepEqual([byId(v0, "pkE2E-p2").canAdd, byId(v0, "pkE2E-p2").maxQty], [true, 3]);
    assert.deepEqual([byId(v0, "pkE2E-p3").canAdd, byId(v0, "pkE2E-p3").reasonText, byId(v0, "pkE2E-p3").maxQty], [false, "No selling price", 0]);
    assert.equal(v0.hiddenCount, 0);

    // the person sets 8 of p1 (spans both batches) and all 3 of p2; the gate and the dry run say go
    let draft = PD.step({}, "pkE2E-p1", 8, 10);
    draft = PD.step(draft, "pkE2E-p2", 3, 3);
    const v1 = view(products, newOrderHooks(cart, lookup), cart, draft);
    assert.deepEqual(v1.canCommit, { ok: true, reason: "" });
    const applied = plain(NP.applyPlan(cart, PD.commitPlan(v1.draft, cart), lookup));
    assert.deepEqual(applied.skipped, []);
    assert.deepEqual(applied.lines.map((l) => [l.productId, l.qty, l.price]), [["pkE2E-p1", 8, 5], ["pkE2E-p2", 3, 8]]);

    const plan = completionOf("pkE2E-o1", orderBefore, applied.lines.map((l) => ({ productId: l.productId, name: l.name, quantity: l.qty, price: l.price, discountType: l.discountType, discountValue: l.discountValue })), products, batchMap);
    assert.equal(plan.ok, true, JSON.stringify(plan));
    trackSaleDocs(plan);
    const r = await post(bodyOf(plan));
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.ok, true);
    assert.equal(r.body.idempotentReplay, false);

    assert.equal((await read("inventory/pkE2E-p1")).stock, 2);
    assert.equal((await read("stock_batches/pkE2E-b1")).qtyRemaining, 0, "FIFO: the older batch is drained first");
    assert.equal((await read("stock_batches/pkE2E-b2")).qtyRemaining, 2);
    assert.equal((await read("inventory/pkE2E-p2")).stock, 0);
    assert.equal((await read("stock_batches/pkE2E-b3")).qtyRemaining, 0);
    assert.equal((await read("inventory/pkE2E-p3")).stock, 4, "the product that could not be picked is untouched");
    assert.equal((await read("stock_batches/pkE2E-b4")).qtyRemaining, 4);
    const order = await read("orders/pkE2E-o1");
    assert.equal(order.status, "completed");
    assert.equal(order.products.length, 2);
    assert.deepEqual(order.products[0].consumption.map((c) => [c.batchId, c.qtyConsumed]), [["pkE2E-b1", 6], ["pkE2E-b2", 2]]);
    for (let i = 0; i < 2; ++i) assert.equal((await read("transactions/tx-s-pkE2E-o1-" + i)).kind, "sale");

    const again = await post(bodyOf(plan));
    assert.equal(again.status, 200);
    assert.equal(again.body.idempotentReplay, true);
    assert.equal((await read("inventory/pkE2E-p1")).stock, 2, "applied once");
    assert.equal((await read("stock_batches/pkE2E-b2")).qtyRemaining, 2);
});

// ---- E2: another device sold the stock between pick and complete ----
test("PK-E2: stock sold elsewhere after the pick: the server refuses the WHOLE operation, nothing is written; after the sheet re-reads, the clamped draft completes", async () => {
    await seed("inventory/pkE2E-p4", { productId: "pkE2E-p4", name: "Pk Four", category: "E2E", stock: 5, sellingPrice: 6 });
    await seed("inventory/pkE2E-p5", { productId: "pkE2E-p5", name: "Pk Five", category: "E2E", stock: 5, sellingPrice: 7 });
    await seed("stock_batches/pkE2E-b5", { batchId: "pkE2E-b5", productId: "pkE2E-p4", qtyRemaining: 5, unitCost: 2 });
    await seed("stock_batches/pkE2E-b6", { batchId: "pkE2E-b6", productId: "pkE2E-p5", qtyRemaining: 5, unitCost: 2 });
    const orderBefore = { orderId: "pkE2E-o2", status: "pending" };
    await seed("orders/pkE2E-o2", orderBefore);
    const ids = ["pkE2E-p4", "pkE2E-p5"];

    const pick = async (draftSteps) => {
        const products = await catalog(ids);
        const batchMap = { "pkE2E-p4": await batchesFor("pkE2E-p4", ["pkE2E-b5"]), "pkE2E-p5": await batchesFor("pkE2E-p5", ["pkE2E-b6"]) };
        const lookup = lookupFor(products, batchMap);
        let draft = {};
        for (const s of draftSteps) draft = PD.step(draft, s[0], s[1], s[2]);
        const v = view(products, newOrderHooks([], lookup), [], draft);
        const applied = plain(NP.applyPlan([], PD.commitPlan(v.draft, []), lookup));
        const lines = applied.lines.map((l) => ({ productId: l.productId, name: l.name, quantity: l.qty, price: l.price, discountType: l.discountType, discountValue: l.discountValue }));
        return { v: v, plan: completionOf("pkE2E-o2", orderBefore, lines, products, batchMap) };
    };

    const first = await pick([["pkE2E-p4", 4, 5], ["pkE2E-p5", 2, 5]]);
    assert.equal(first.plan.ok, true, JSON.stringify(first.plan));
    trackSaleDocs(first.plan);

    // the other device sells 4 of p4 (stock 5 -> 1) after the pick
    await db.doc(T + "inventory/pkE2E-p4").update({ stock: 1 });

    const refused = await post(bodyOf(first.plan));
    assert.equal(refused.status, 409, JSON.stringify(refused.body));
    assert.equal(refused.body.error, "insufficient-quantity");
    assert.equal(refused.body.field, "stock");
    assert.equal(refused.body.current, 1);
    assert.equal((await read("stock_batches/pkE2E-b5")).qtyRemaining, 5, "the valid batch change must NOT have applied");
    assert.equal((await read("stock_batches/pkE2E-b6")).qtyRemaining, 5, "the other line must NOT have applied");
    assert.equal((await read("inventory/pkE2E-p5")).stock, 5);
    assert.equal((await read("orders/pkE2E-o2")).status, "pending");
    assert.equal(await read("audit_log/" + first.plan.key), null, "a rejection leaves no marker");

    // the sheet re-reads: p4 now offers 1, a draft of 4 is clamped to 1 (reconcile), and the order completes
    const products = await catalog(ids);
    const lookup = lookupFor(products, { "pkE2E-p4": await batchesFor("pkE2E-p4", ["pkE2E-b5"]), "pkE2E-p5": await batchesFor("pkE2E-p5", ["pkE2E-b6"]) });
    const reread = view(products, newOrderHooks([], lookup), [], { "pkE2E-p4": 4, "pkE2E-p5": 2 });
    assert.equal(byId(reread, "pkE2E-p4").maxQty, 1);
    assert.deepEqual(reread.draft, { "pkE2E-p4": 1, "pkE2E-p5": 2 });
    const second = await pick([["pkE2E-p4", 1, 1], ["pkE2E-p5", 2, 5]]);
    assert.equal(second.plan.ok, true, JSON.stringify(second.plan));
    assert.equal(second.plan.key, first.plan.key, "the rejected request id is re-planned, not replaced");
    const ok = await post(bodyOf(second.plan));
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal((await read("inventory/pkE2E-p4")).stock, 0);
    assert.equal((await read("stock_batches/pkE2E-b5")).qtyRemaining, 4, "the batch ledger is the ledger of record: only the 1 unit this order took");
    assert.equal((await read("inventory/pkE2E-p5")).stock, 3);
    assert.equal((await read("orders/pkE2E-o2")).status, "completed");
});

// ---- E3: Edit Order (pending) -> picker bumps one row, adds one -> complete ----
test("PK-E3: an Edit Order on a PENDING order: the picker bumps the row already there (price kept), adds a new row, refuses the no-price product, and the result completes on the real server", async () => {
    await seed("inventory/pkE2E-p6", { productId: "pkE2E-p6", name: "Pk Six", category: "E2E", stock: 6, sellingPrice: 9 });
    await seed("inventory/pkE2E-p7", { productId: "pkE2E-p7", name: "Pk Seven", category: "E2E", stock: 2, sellingPrice: 4 });
    await seed("inventory/pkE2E-p8", { productId: "pkE2E-p8", name: "Pk Eight", category: "E2E", stock: 9 });   // no price
    await seed("stock_batches/pkE2E-b7", { batchId: "pkE2E-b7", productId: "pkE2E-p6", qtyRemaining: 6, unitCost: 3 });
    await seed("stock_batches/pkE2E-b8", { batchId: "pkE2E-b8", productId: "pkE2E-p7", qtyRemaining: 2, unitCost: 1 });
    await seed("stock_batches/pkE2E-b9", { batchId: "pkE2E-b9", productId: "pkE2E-p8", qtyRemaining: 9, unitCost: 1 });
    // the order already holds 2 of p6 at a price the person negotiated (7, not the catalog's 9) and a 1 flat discount
    const row = { productId: "pkE2E-p6", name: "Pk Six", price: 7, quantity: 2, discountType: "flat", discountValue: 1, taxable: false, taxPercent: 0 };
    const orderBefore = { orderId: "pkE2E-o3", status: "pending", products: [row] };
    await seed("orders/pkE2E-o3", orderBefore);

    const products = await catalog(["pkE2E-p6", "pkE2E-p7", "pkE2E-p8"]);
    const batchMap = { "pkE2E-p6": await batchesFor("pkE2E-p6", ["pkE2E-b7"]), "pkE2E-p7": await batchesFor("pkE2E-p7", ["pkE2E-b8"]), "pkE2E-p8": await batchesFor("pkE2E-p8", ["pkE2E-b9"]) };
    const lookup = lookupFor(products, batchMap);
    const rows = [row];
    const ctx = { status: "pending", original: [] };
    const hooks = editOrderHooks(rows, ctx, lookup);

    const v0 = view(products, hooks, EP.linesOf(rows));
    assert.deepEqual([byId(v0, "pkE2E-p6").canAdd, byId(v0, "pkE2E-p6").maxQty, byId(v0, "pkE2E-p6").inOrderLabel], [true, 4, "In this order: 2 pcs"]);
    assert.deepEqual([byId(v0, "pkE2E-p8").canAdd, byId(v0, "pkE2E-p8").reasonText], [false, "No selling price"]);

    let draft = PD.step({}, "pkE2E-p6", 3, 4);       // bump p6 by 3 -> 5
    draft = PD.step(draft, "pkE2E-p7", 2, 2);        // a new row of 2
    const v1 = view(products, hooks, EP.linesOf(rows), draft);
    assert.deepEqual(v1.canCommit, { ok: true, reason: "" });
    const res = plain(EP.applyPlan(EP.linesOf(rows), PD.commitPlan(v1.draft, EP.linesOf(rows)), ctx, lookup));
    assert.deepEqual(res.skipped, []);
    assert.deepEqual(res.sets, [{ index: 0, productId: "pkE2E-p6", quantity: 5 }]);
    assert.equal(res.appends.length, 1);
    assert.deepEqual([res.appends[0].productId, res.appends[0].quantity, res.appends[0].price], ["pkE2E-p7", 2, 4]);

    // what the dialog's model holds after _applyPicked
    const after = [Object.assign({}, row, { quantity: 5 })].concat(res.appends);
    assert.deepEqual([after[0].price, after[0].discountValue], [7, 1], "the picker never touches an existing row's price or discount");

    const plan = completionOf("pkE2E-o3", orderBefore, after, products, batchMap);
    assert.equal(plan.ok, true, JSON.stringify(plan));
    trackSaleDocs(plan);
    const r = await post(bodyOf(plan));
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal((await read("inventory/pkE2E-p6")).stock, 1);
    assert.equal((await read("stock_batches/pkE2E-b7")).qtyRemaining, 1);
    assert.equal((await read("inventory/pkE2E-p7")).stock, 0);
    assert.equal((await read("inventory/pkE2E-p8")).stock, 9, "the no-price product is untouched");
    const order = await read("orders/pkE2E-o3");
    assert.equal(order.status, "completed");
    assert.deepEqual(order.products.map((l) => [l.productId, l.quantity, l.price]), [["pkE2E-p6", 5, 7], ["pkE2E-p7", 2, 4]]);
});
