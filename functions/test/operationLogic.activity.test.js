"use strict";

// R5b: the feed row (`activity_log/act-<batch id>`) is written INSIDE the restock operation
// (design 2026-11-12-r5b-activity-in-operation-design.md, D-R5b-1..6). The real server code runs on the
// strict fake DB; operationLogic.test.js and operationLogic.mint.test.js are NOT edited by this slice.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const OL = require("../lib/operationLogic");
const Gateway = require("../lib/gatewayLogic");
const Lock = require("../lib/lockLogic");
const { TS, strictDb } = require("./testSupport/strictDb");

const T = "tenants/t1/";
const NOW = new Date("2026-06-15T12:00:00Z");
const NOW_ISO = "2026-06-15T12:00:00.000Z";
const TOKEN = OL.STOCK_TOKEN;

const mint = (counter, bind) => ({ kind: "mint", counter, bind });
const create = (entity, entityId, after) => ({ kind: "mutation", entity, entityId, action: "create", before: null, after });
const delta = (id, n) => ({ kind: "delta", entity: "inventory", entityId: id, deltas: { stock: n }, floors: {}, clamps: {},
                            movements: [{ kind: "receipt", qty: n, reason: "" }] });
const activityDoc = (over) => Object.assign({
    id: "act-{{batch}}", kind: "product_restocked", title: "Restocked: Tomato",
    subtitle: "+5 · now " + TOKEN + " in stock", entityId: "p1", read: false, dismissed: false
}, over || {});
const activityOp = (docOver, opOver) => Object.assign(create("activity", "act-{{batch}}", activityDoc(docOver)), opOver || {});

// batch mint + batch doc + stock delta + purchase + activity: the shape RestockPlan builds.
function restockOps(over) {
    const o = over || {};
    return [
        mint("stock_batch", "batch"),
        create("stock_batch", "{{batch}}", { batchId: "{{batch}}", productId: "p1", qtyRemaining: 5 }),
        delta("p1", 5),
        create("transaction", "tx-p-{{batch}}", { txId: "tx-p-{{batch}}" }),
        o.activity === null ? null : (o.activity || activityOp())
    ].filter(Boolean);
}
const body = (ops, opType, id) => ({ requestId: (opType || "restock") + ":dev1-" + (id || "a"), opType: opType || "restock", clientTimestamp: "CT", ops });
const validated = (b) => { const v = OL.validateOperationRequest(b); assert.equal(v.ok, true, JSON.stringify(v)); return v; };
const invalid = (b) => { const v = OL.validateOperationRequest(b); assert.equal(v.ok, false, "expected a rejection"); return v; };
async function run(db, b, extra) {
    const v = validated(b);
    return OL.applyOperation(db, Object.assign({
        tenantId: "t1", actorUid: "u-actor", actorRole: "owner", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: TS, now: NOW }, extra || {}));
}
const baseDb = () => strictDb({ [T + "inventory/p1"]: { productId: "p1", name: "Tomato", stock: 10 } });

// ------------------------------------------------------------------ validation: accepted

test("A-1 an activity op after the delta is accepted and kept as a template (id and token are not resolved yet)", () => {
    const v = validated(body(restockOps()));
    const a = v.ops[4];
    assert.equal(a.entity, "activity");
    assert.equal(a.collection, "activity_log");
    assert.equal(a.entityId, "act-{{batch}}");
    assert.equal(a.after.subtitle, "+5 · now " + TOKEN + " in stock");
});

test("A-2 an operation WITHOUT an activity op behaves as before (older clients keep working)", async () => {
    const db = baseDb();
    const r = await run(db, body(restockOps({ activity: null })));
    assert.equal(r.ok, true);
    assert.equal(db.writes.some((w) => w.path.indexOf("activity_log") >= 0), false);
});

// ------------------------------------------------------------------ validation: refused

test("A-3 the entity exists only for a restock mutation: other op types, delta and unknown spellings are 'unsupported-entity'", () => {
    const withActivity = restockOps();
    assert.equal(invalid(body(withActivity, "completeOrder")).error, "unsupported-entity");
    assert.equal(invalid(body(withActivity, "completeOrder")).opIndex, 4);
    const asDelta = restockOps({ activity: { kind: "delta", entity: "activity", entityId: "act-x", deltas: { stock: 1 } } });
    assert.equal(invalid(body(asDelta)).error, "unsupported-entity");
    // Not listed: "toString" / "constructor" / "__proto__". The single-record validators accept those today
    // (KNOWN-ISSUES 24, found while writing this test); the activity lookup below uses hasOwnProperty and is not affected.
    for (const name of ["activity_log", "Activity", "activity ", undefined, null, 5]) {
        const op = Object.assign(activityOp(), { entity: name });
        assert.equal(invalid(body(restockOps({ activity: op }))).error, "unsupported-entity", String(name));
    }
});

test("A-4 only create, with before null", () => {
    for (const over of [{ action: "update" }, { action: "delete" }, { action: "opening_balance" }, { before: {} }, { before: activityDoc() }]) {
        const r = invalid(body(restockOps({ activity: activityOp(null, over) })));
        assert.ok(["invalid-activity", "unsupported-action"].indexOf(r.error) >= 0, JSON.stringify(over) + " -> " + r.error);
        assert.equal(r.opIndex, 4);
    }
});

test("A-5 the doc has exactly the seven client keys: no actorUid, no timestamp, nothing extra, nothing missing", () => {
    for (const extra of [{ actorUid: "someone-else" }, { timestamp: "2020-01-01T00:00:00.000Z" }, { extra: 1 }, { __proto__x: 1 }])
        assert.equal(invalid(body(restockOps({ activity: activityOp(extra) }))).error, "invalid-activity", JSON.stringify(extra));
    for (const key of Object.keys(activityDoc())) {
        const doc = activityDoc(); delete doc[key];
        assert.equal(invalid(body(restockOps({ activity: Object.assign(create("activity", "act-{{batch}}", doc)) }))).error, "invalid-activity", "missing " + key);
    }
    for (const after of [null, [], "x", 5, undefined]) {
        const op = Object.assign(create("activity", "act-{{batch}}", after));
        assert.equal(invalid(body(restockOps({ activity: op }))).error, "invalid-activity", String(after));
    }
});

test("A-6 field rules: kind allowlist, id equals entityId and starts with act-, strings and limits, read and dismissed false", () => {
    const bad = [
        { kind: "order" }, { kind: "" }, { kind: undefined }, { id: "act-other" }, { id: "x-{{batch}}" },
        { title: "" }, { title: 5 }, { title: "x".repeat(201) }, { subtitle: 5 }, { subtitle: "x".repeat(1001) },
        { entityId: "" }, { entityId: 5 }, { entityId: "x".repeat(201) },
        { read: true }, { dismissed: true }, { read: "false" }, { dismissed: 0 }, { read: undefined }
    ];
    for (const over of bad) assert.equal(invalid(body(restockOps({ activity: activityOp(over) }))).error, "invalid-activity", JSON.stringify(over));
    // entity id that does not start with act-, even when the doc id matches it
    const op = create("activity", "plain-{{batch}}", activityDoc({ id: "plain-{{batch}}" }));
    assert.equal(invalid(body(restockOps({ activity: op }))).error, "invalid-activity");
    // the limits are inclusive
    const ok = activityOp({ title: "t".repeat(200), subtitle: TOKEN + "x".repeat(1000 - TOKEN.length), entityId: "p1" });
    assert.equal(OL.validateOperationRequest(body(restockOps({ activity: ok }))).ok, true);
});

test("A-7 the stock token needs an EARLIER delta op with a stock field for the same product", () => {
    const [m, batch, d, tx, a] = restockOps();
    assert.equal(invalid(body([m, batch, tx, a, d])).error, "activity-stock-missing", "delta after the activity op");
    assert.equal(invalid(body([m, batch, delta("p2", 5), tx, a])).error, "activity-stock-missing", "delta for another product");
    const noStock = { kind: "delta", entity: "inventory", entityId: "p1", deltas: { qty: 1 }, floors: {}, clamps: {} };
    assert.equal(invalid(body([m, batch, noStock, tx, a])).error, "activity-stock-missing", "no stock field");
    assert.equal(invalid(body([m, batch, tx, a])).error, "activity-stock-missing", "no delta at all");
    // PR #197 review F2: without the token a delta is still needed, but its stock field is not (see A-12)
    const plain = activityOp({ subtitle: "plain text" });
    assert.equal(invalid(body([m, batch, tx, plain])).error, "invalid-activity", "no delta, no token");
    assert.equal(OL.validateOperationRequest(body([m, batch, noStock, tx, plain])).ok, true, "a delta without stock is enough when no token is used");
});

test("A-8 the id placeholder rules: an unbound or undeclared name is refused, with or without a mint op", () => {
    const noMint = [delta("p1", 5), activityOp()];
    assert.equal(invalid(body(noMint)).error, "unbound-placeholder");
    const plainId = create("activity", "act-plain-1", activityDoc({ id: "act-plain-1" }));
    assert.equal(OL.validateOperationRequest(body([delta("p1", 5), plainId])).ok, true, "a literal id needs no mint");
    const wrongName = create("activity", "act-{{nope}}", activityDoc({ id: "act-{{nope}}" }));
    assert.equal(invalid(body([mint("stock_batch", "batch"), create("stock_batch", "{{batch}}", { batchId: "{{batch}}" }), delta("p1", 5), wrongName])).error, "unbound-placeholder");
    // the stock token is never a bind name: a mint cannot be named with a `$`
    assert.equal(invalid(body([mint("stock_batch", "$stock")])).error, "invalid-bind-name");
});

test("A-9 monkey: 400 random single-field corruptions never throw and never let a bad doc through", () => {
    let seed = 20261112;
    const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
    const junk = [null, undefined, "", " ", 0, -1, 1.5, NaN, Infinity, true, false, [], {}, [1], { a: 1 }, "x".repeat(1200), "{{batch}}", TOKEN, "act-", "📦".repeat(120)];
    const keys = Object.keys(activityDoc());
    let accepted = 0;
    for (let i = 0; i < 400; i++) {
        const doc = activityDoc();
        const k = keys[Math.floor(rnd() * keys.length)];
        doc[k] = junk[Math.floor(rnd() * junk.length)];
        const v = OL.validateOperationRequest(body(restockOps({ activity: activityOp(doc) })));
        if (!v.ok) continue;
        accepted++;
        // independent oracle for what an accepted doc must look like
        const a = v.ops[4].after;
        assert.deepEqual(Object.keys(a).sort(), keys.slice().sort());
        assert.equal(a.kind, "product_restocked");
        assert.ok(typeof a.title === "string" && a.title.length > 0 && a.title.length <= 200);
        assert.ok(typeof a.subtitle === "string" && a.subtitle.length <= 1000);
        assert.ok(typeof a.entityId === "string" && a.entityId.length > 0 && a.entityId.length <= 200);
        assert.equal(a.read, false); assert.equal(a.dismissed, false);
        assert.equal(a.id, v.ops[4].entityId);
    }
    assert.ok(accepted > 0 && accepted < 400, "the monkey reaches both outcomes: " + accepted);
});

test("A-10 (PR #197 review F1) ONE feed row per operation: a second activity op is refused, wherever it sits and whatever its id", () => {
    const [m, batch, d, tx, a] = restockOps();
    const second = (id) => create("activity", id, activityDoc({ id, subtitle: "plain" }));
    for (const [label, ops] of [["right after", [m, batch, d, tx, a, second("act-extra")]],
                                ["same id twice", [m, batch, d, tx, a, activityOp()]],
                                ["literal first, template second", [m, batch, d, tx, second("act-lit"), a]],
                                ["many", [m, batch, d, tx, a, second("act-s1"), second("act-s2"), second("act-s3")]]]) {
        const r = invalid(body(ops));
        assert.equal(r.error, "invalid-activity", label);
        assert.ok(r.opIndex >= 4 && r.opIndex <= 5, label + " opIndex " + r.opIndex);
    }
    // the refusal names the SECOND row, not the first
    assert.equal(invalid(body([m, batch, d, tx, a, second("act-extra")])).opIndex, 5);
    // exactly one still passes, with or without the token
    assert.equal(OL.validateOperationRequest(body([m, batch, d, tx, second("act-only")])).ok, true);
});

test("A-11 (PR #197 review F3) the stock token belongs in the subtitle only: in the title it is refused, not stored raw", () => {
    for (const title of [TOKEN, "Restocked: " + TOKEN, TOKEN + TOKEN])
        assert.equal(invalid(body(restockOps({ activity: activityOp({ title }) }))).error, "invalid-activity", title);
    // text that merely looks like it is fine: braces without the dollar, a dollar without braces
    assert.equal(OL.validateOperationRequest(body(restockOps({ activity: activityOp({ title: "Restocked: {{stock}} $stock {$stock}" }) }))).ok, true);
});

test("A-12 (PR #197 review F2) the row names a product THIS operation changed, token or not", () => {
    const [m, batch, d, tx] = restockOps();
    const other = (over) => activityOp(Object.assign({ entityId: "p2", subtitle: "plain" }, over || {}));
    assert.equal(invalid(body([m, batch, d, tx, other()])).error, "invalid-activity", "delta is for p1, row says p2");
    assert.equal(invalid(body([m, batch, d, tx, other({ subtitle: "now " + TOKEN })])).error, "activity-stock-missing", "token keeps its own code");
    assert.equal(OL.validateOperationRequest(body([m, batch, d, delta("p2", 1), tx, other()])).ok, true, "a delta for p2 earlier makes p2 right");
    // the row is checked against EARLIER ops only
    assert.equal(invalid(body([m, batch, tx, other(), delta("p2", 1)])).error, "invalid-activity", "delta for p2 comes after the row");
    // a mutation on the same id is not a delta
    const asMutation = create("inventory", "p2", { productId: "p2" });
    assert.equal(invalid(body([m, batch, d, asMutation, tx, other()])).error, "invalid-activity", "an inventory mutation is not a stock delta");
    // the row of a REAL restock (planner shape) is untouched by the rule
    assert.equal(OL.validateOperationRequest(body(restockOps())).ok, true);
});

test("A-13 (PR #197 review) none of F1-F3 reaches an operation without an activity op, or applyOperation on its own", async () => {
    const db = baseDb();
    assert.equal((await run(db, body(restockOps({ activity: null })))).ok, true);
    // an operation that carries two delta ops for one product and ONE row is fine (the last delta fills the token, B-4)
    const [m, batch, d, tx, a] = restockOps();
    assert.equal(OL.validateOperationRequest(body([m, batch, d, delta("p1", 2), tx, a])).ok, true);
});

// ------------------------------------------------------------------ apply

test("B-1 the activity doc is stored with server-stamped actorUid and timestamp, the token filled with the delta's stock, the id from the batch", async () => {
    const db = baseDb();
    const r = await run(db, body(restockOps()));
    assert.equal(r.ok, true, JSON.stringify(r));
    const doc = db.store[T + "activity_log/act-BAT-2026-001"];
    assert.deepEqual(doc, {
        id: "act-BAT-2026-001", kind: "product_restocked", title: "Restocked: Tomato", subtitle: "+5 · now 15 in stock",
        entityId: "p1", read: false, dismissed: false, actorUid: "u-actor", timestamp: NOW_ISO
    });
    const res = r.results[4];
    assert.deepEqual(res, { entity: "activity", entityId: "act-BAT-2026-001", kind: "mutation", after: doc });
    assert.equal(db.store[T + "inventory/p1"].stock, 15);
});

test("B-2 the server's clock and caller win: a client cannot choose who or when (it cannot even send them)", async () => {
    const db = baseDb();
    await run(db, body(restockOps()), { actorUid: "u-real", now: new Date("2031-01-02T03:04:05Z") });
    const doc = db.store[T + "activity_log/act-BAT-2031-001"] || db.store[T + "activity_log/act-BAT-2026-001"];
    assert.equal(doc.actorUid, "u-real");
    assert.equal(doc.timestamp, "2031-01-02T03:04:05.000Z");
});

test("B-3 without an injected clock the stamp is the real time, as an ISO string", async () => {
    const db = baseDb();
    const before = Date.now();
    await run(db, body(restockOps()), { now: undefined });
    const stamp = Object.keys(db.store).filter((k) => k.indexOf("/activity_log/") > 0).map((k) => db.store[k].timestamp)[0];
    assert.match(stamp, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    assert.ok(Date.parse(stamp) >= before - 1000 && Date.parse(stamp) <= Date.now() + 1000);
});

test("B-4 every token occurrence is replaced; the LAST delta for the product wins; other brace text stays", async () => {
    const [m, batch, d, tx] = restockOps();
    const act = activityOp({ subtitle: TOKEN + " / " + TOKEN + " / {{stock}} / {{other}}" });
    const db = baseDb();
    const r = await run(db, body([m, batch, d, delta("p1", 2), tx, act]));
    assert.equal(r.ok, true);
    assert.equal(r.results[5].after.subtitle, "17 / 17 / {{stock}} / {{other}}");
});

test("B-5 audit: the activity op has its own audit row carrying the STAMPED doc, and the marker's results replay it", async () => {
    const db = baseDb();
    await run(db, body(restockOps()));
    const audit = db.store[T + "audit_log/restock:dev1-a~4"];
    assert.equal(audit.entity, "activity");
    assert.equal(audit.action, "create");
    assert.equal(audit.before, null);
    assert.equal(audit.after.actorUid, "u-actor");
    assert.equal(audit.operationId, "restock:dev1-a");
    const marker = db.store[T + "audit_log/restock:dev1-a"];
    assert.equal(marker.opCount, 5);
    assert.deepEqual(marker.results[4].after, db.store[T + "activity_log/act-BAT-2026-001"]);
    // no ledger row for a non-inventory entity
    assert.equal(db.writes.filter((w) => w.path.indexOf("stock_movements") >= 0).length, 1);
});

test("B-6 a retry is a replay: same answer (same stamp), no second write, no second activity doc", async () => {
    const db = baseDb();
    const first = await run(db, body(restockOps()));
    const writes = db.writes.length;
    const again = await run(db, body(restockOps()), { now: new Date("2030-01-01T00:00:00Z"), actorUid: "someone-else" });
    assert.equal(again.idempotentReplay, true);
    assert.deepEqual(again.results, first.results);
    assert.equal(db.writes.length, writes);
    assert.equal(Object.keys(db.store).filter((k) => k.indexOf("/activity_log/") > 0).length, 1);
});

test("B-7 a rejected operation leaves NO trace: no feed row, no audit, no marker, no counter, stock unchanged", async () => {
    // stale stock floor: the delta cannot be applied, so the activity op must not land either
    const [m, batch, , tx, act] = restockOps();
    const strict = { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -50 }, floors: { stock: 0 }, clamps: {},
                     movements: [{ kind: "adjustment", qty: -50, reason: "" }] };
    const db = baseDb();
    const r = await run(db, body([m, batch, strict, tx, act]));
    assert.equal(r.ok, false);
    assert.equal(r.error, "insufficient-quantity");
    assert.deepEqual(db.writes, []);
});

test("B-8 an existing doc at the activity id is a conflict (409), never an overwrite", async () => {
    const db = baseDb();
    db.store[T + "activity_log/act-BAT-2026-001"] = { id: "act-BAT-2026-001", title: "old" };
    const r = await run(db, body(restockOps()));
    assert.equal(r.ok, false);
    assert.equal(r.status, 409);
    assert.equal(r.error, "conflict");
    assert.equal(r.opIndex, 4);
    assert.equal(db.writes.length, 0);
    assert.equal(db.store[T + "activity_log/act-BAT-2026-001"].title, "old");
});

test("B-9 applyOperation is safe on its own: an activity op that skipped validation is still refused, not written", async () => {
    const fake = (extra) => Object.assign({ kind: "mutation", entity: "activity", entityId: "act-p1", action: "create", before: null,
                                           after: activityDoc({ id: "act-p1" }), collection: "activity_log" }, extra || {});
    const params = (ops) => ({ tenantId: "t1", actorUid: "u", actorRole: "owner", requestId: "restock:r", opType: "restock", ops, clientTimestamp: "c", serverTimestamp: TS, now: NOW });
    let db = baseDb();
    let r = await OL.applyOperation(db, params([fake({ action: "delete" })]));
    assert.deepEqual([r.ok, r.error, r.opIndex], [false, "invalid-activity", 0]);
    assert.equal(db.writes.length, 0);
    db = baseDb();
    r = await OL.applyOperation(db, params([fake()]));      // token in the subtitle, no delta result before it
    assert.deepEqual([r.ok, r.error, r.opIndex], [false, "activity-stock-missing", 0]);
    assert.equal(db.writes.length, 0);
    db = baseDb();
    r = await OL.applyOperation(db, params([fake({ after: activityDoc({ id: "act-p1", subtitle: "no token" }) })]));
    assert.equal(r.ok, true);
});

test("B-10 the write budget counts the activity row like any other op (one doc + one audit entry)", () => {
    // n inventory deltas cost 3n + 1 writes (doc, audit, ledger row, plus the marker); one activity op adds 2 more.
    // 166 deltas fit under 500, 166 deltas + an activity op do not.
    const many = [];
    for (let i = 0; i < 166; i++) many.push(delta("p" + i, 1));
    assert.equal(OL.validateOperationRequest(body(many)).ok, true);
    const lit = activityOp({ id: "act-lit", subtitle: "plain" }, { entityId: "act-lit" });
    const r = OL.validateOperationRequest(body(many.concat([lit])));
    assert.equal(r.ok, false);
    assert.equal(r.error, "operation-too-large");
});

// ------------------------------------------------------------------ nothing else gained the entity

test("G-1 ENTITY_COLLECTIONS has no activity entry and every other endpoint refuses it", () => {
    assert.equal(Gateway.ENTITY_COLLECTIONS.activity, undefined);
    assert.equal(Object.values(Gateway.ENTITY_COLLECTIONS).indexOf("activity_log"), -1);
    for (const entity of ["activity", "activity_log"]) {
        assert.equal(Gateway.validateMutationRequest({ entity, entityId: "act-1", action: "create", requestId: "req-1", after: {} }).error, "unsupported-entity");
        assert.equal(Gateway.validateDeltaRequest({ entity, entityId: "act-1", requestId: "req-1", deltas: { a: 1 } }).error, "unsupported-entity");
        assert.equal(Lock.validateAcquireRequest({ entity, entityId: "act-1", requestId: "r", ttlMs: 1000 }).error, "unsupported-entity");
        assert.equal(Lock.validateReleaseRequest({ entity, entityId: "act-1" }).error, "unsupported-entity");
    }
});

test("G-2 source pins: the entity is named in operationLogic.js only, for the restock op type only", () => {
    const lib = path.join(__dirname, "..", "lib");
    const hits = fs.readdirSync(lib).filter((f) => /activity_log/.test(fs.readFileSync(path.join(lib, f), "utf8")));
    assert.deepEqual(hits, ["operationLogic.js"]);
    assert.deepEqual(OL.OPERATION_ONLY_ENTITIES, { activity: { collection: "activity_log", opTypes: ["restock"] } });
    assert.equal(Object.isFrozen(OL.OPERATION_ONLY_ENTITIES), false, "plain object: the guard above is the contract");
});

test("G-3 completeOrder-style operations (no mint, no activity) validate and apply exactly as before", async () => {
    const ops = [{ kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -2 }, floors: {}, clamps: {} }, { kind: "mutation", entity: "order", entityId: "o1", action: "update", before: { a: 1 }, after: { a: 2 } }];
    const v = OL.validateOperationRequest(body(ops, "completeOrder", "c1"));
    assert.equal(v.ok, true);
    const db = strictDb({ [T + "inventory/p1"]: { stock: 10 }, [T + "orders/o1"]: { a: 1 } });
    const r = await run(db, body(ops, "completeOrder", "c1"));
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "orders/o1"].a, 2);
});

test("B-11 applyOperation stamps the CALLER and the server clock even if a doc that skipped validation carries its own actorUid / timestamp", async () => {
    const forged = activityDoc({ id: "act-p1", subtitle: "plain", actorUid: "someone-else", timestamp: "1999-01-01T00:00:00.000Z" });
    const op = { kind: "mutation", entity: "activity", entityId: "act-p1", action: "create", before: null, after: forged, collection: "activity_log" };
    const db = baseDb();
    const r = await OL.applyOperation(db, { tenantId: "t1", actorUid: "u-real", actorRole: "owner", requestId: "restock:r", opType: "restock",
        ops: [op], clientTimestamp: "c", serverTimestamp: TS, now: NOW });
    assert.equal(r.ok, true);
    const doc = db.store[T + "activity_log/act-p1"];
    assert.equal(doc.actorUid, "u-real");
    assert.equal(doc.timestamp, NOW_ISO);
});
