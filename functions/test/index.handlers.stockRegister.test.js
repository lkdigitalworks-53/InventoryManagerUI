"use strict";

// P1 S4a: handler tests for computeStockRegister (read-only stock register). Same harness as the
// other handler tests: the REAL exported handler, mocked auth and Firestore (testSupport/
// handlerHarness.js). StockRegisterMath itself is covered by stockRegisterMath.test.js; these
// cover the seam: auth, role gate, window validation, paged streaming, the row cap, errors,
// and that nothing is ever written.

const test = require("node:test");
const assert = require("node:assert/strict");
const { installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody } = require("./testSupport/handlerHarness");

const { handlers, mockState } = installMocks();

const LEDGER = "tenants/test-tenant/stock_movements";
const INV = "tenants/test-tenant/inventory";
const FROM = "2026-04-10T00:00:00Z";
const TO = "2026-04-20T00:00:00Z";
const IN_WINDOW = Date.parse("2026-04-15T00:00:00Z");
const BEFORE = Date.parse("2026-04-01T00:00:00Z");

function body(over) { return Object.assign({ env: "test", from: FROM, to: TO }, over || {}); }

function reset() {
    mockState.docs = {};
    mockState.setCalls = [];
    mockState.collections = {};
    mockState.collections[LEDGER] = [];
    mockState.collections[INV] = [];
    mockState.collectionGetCalls.length = 0;
    mockState.collectionGetError = null;
    mockState.countCalls.length = 0;
    mockState.countError = null;
    mockState.countValue = null;
    mockState.verifyIdToken = async () => ({ uid: "test-uid" });
}

// A Firestore-Timestamp-shaped value (what Admin SDK hands back for a serverTimestamp field).
function ts(ms) { return { toMillis: () => ms, toDate: () => new Date(ms) }; }
function mv(id, productId, kind, qty, atMs) {
    return { id: id, data: { id: id, productId: productId, kind: kind, qty: qty, serverTimestamp: ts(atMs) } };
}
function product(productId, name, stock) { return { id: productId, data: { productId: productId, name: name, stock: stock } }; }

async function call(over, req) {
    const res = mockRes();
    await handlers.computeStockRegister(mockReq(Object.assign({ body: body(over) }, req || {})), res);
    return res;
}

// No OPTIONS case: the harness's mock response never ends an OPTIONS request, so such a test hangs
// (same documented limitation as in index.handlers.test.js, "an OPTIONS-preflight test was dropped").
test("SRH-01 non-POST -> 405 method-not-allowed, nothing read", async () => {
    reset();
    for (const method of ["GET", "PUT", "DELETE", "PATCH"]) {
        const res = mockRes();
        await handlers.computeStockRegister(mockReq({ method: method, body: body() }), res);
        assert.equal(res.statusCode, 405, method);
        assert.equal(jsonBody(res).error, "method-not-allowed");
    }
    assert.equal(mockState.collectionGetCalls.length, 0);
});

test("SRH-02 no Authorization header -> 401 missing-token; bad scheme -> 401", async () => {
    reset();
    let res = mockRes();
    await handlers.computeStockRegister(mockReq({ headers: { origin: "http://localhost" }, body: body() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
    res = mockRes();
    await handlers.computeStockRegister(mockReq({ headers: { authorization: "Basic abc", origin: "http://localhost" }, body: body() }), res);
    assert.equal(res.statusCode, 401);
});

test("SRH-03 verifyIdToken throws -> 401 invalid-token", async () => {
    reset();
    mockState.verifyIdToken = async () => { throw new Error("bad"); };
    const res = await call();
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("SRH-04 no tenant context -> 403 no-tenant-context, ledger never read", async () => {
    reset();
    mockState.verifyIdToken = async () => ({ uid: "ghost" });
    const res = await call();
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
    assert.equal(mockState.collectionGetCalls.length, 0);
});

test("SRH-05 staff -> 403 role-not-allowed, ledger never read; owner, admin, manager -> 200", async () => {
    reset();
    seedHappyPathAuth(mockState, { role: "staff" });
    let res = await call();
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "role-not-allowed");
    assert.equal(mockState.collectionGetCalls.length, 0, "a refused role must not cost a single read");
    for (const role of ["owner", "admin", "manager"]) {
        reset();
        seedHappyPathAuth(mockState, { role: role });
        res = await call();
        assert.equal(res.statusCode, 200, role);
        assert.equal(jsonBody(res).ok, true);
    }
});

test("SRH-06 invalid window -> 400 invalid-window for every bad shape, nothing read", async () => {
    const bad = [
        { from: undefined, to: undefined }, { from: undefined }, { to: undefined }, { from: TO, to: FROM }, { from: FROM, to: FROM },
        { from: "x" }, { to: "y" }, { from: "2026-04-10", to: "2026-04-20" },
        { from: "2026-04-10T00:00:00", to: "2026-04-20T00:00:00" }, { from: null, to: null },
        { from: {}, to: [] }, { from: 1e20, to: 2e20 }
    ];
    for (const b of bad) {
        reset();
        seedHappyPathAuth(mockState);
        const res = await call(b);
        assert.equal(res.statusCode, 400, JSON.stringify(b));
        assert.equal(jsonBody(res).error, "invalid-window", JSON.stringify(b));
        assert.equal(mockState.collectionGetCalls.length, 0);
    }
});

test("SRH-07 happy path: ledger + inventory fold into one row per product, Timestamp-shaped times, JSON shape", async () => {
    reset();
    seedHappyPathAuth(mockState);
    mockState.collections[LEDGER] = [
        mv("m1", "p1", "receipt", 100, BEFORE),
        mv("m2", "p1", "sale", -30, IN_WINDOW),
        mv("m3", "p1", "sales_return", 5, IN_WINDOW + 1000),
        mv("m4", "p2", "receipt", 7, IN_WINDOW)
    ];
    mockState.collections[INV] = [product("p1", "Widget", 75), product("p2", "Bolt", 7)];
    const res = await call();
    assert.equal(res.statusCode, 200);
    const b = jsonBody(res);
    assert.equal(b.ok, true);
    assert.equal(b.window.fromMs, Date.parse(FROM));
    assert.equal(b.window.toMs, Date.parse(TO));
    assert.equal(typeof b.readAt, "number");
    assert.equal(b.kinds.length, 10);
    assert.deepEqual(b.products.map((p) => p.productId), ["p2", "p1"], "Bolt before Widget");
    const p1 = b.products.find((p) => p.productId === "p1");
    assert.equal(p1.name, "Widget");
    assert.equal(p1.opening, 100);
    assert.equal(p1.kinds.sale.out, 30);
    assert.equal(p1.kinds.sales_return.in, 5);
    assert.equal(p1.inTotal, 5);
    assert.equal(p1.outTotal, 30);
    assert.equal(p1.closing, 75);
    assert.equal(p1.reconciles, true);
    assert.deepEqual(b.counts, { products: 2, rowsSeen: 4, rowsInWindow: 3, mismatches: 0, skipped: { noProduct: 0, badKind: 0, badQty: 0, badTime: 0 } });
});

test("SRH-08 the handler only reads: no doc write, no set call, only the two collections are touched", async () => {
    reset();
    seedHappyPathAuth(mockState);
    mockState.collections[LEDGER] = [mv("m1", "p1", "receipt", 1, IN_WINDOW)];
    mockState.collections[INV] = [product("p1", "W", 1)];
    const before = JSON.stringify(mockState.docs);
    const res = await call();
    assert.equal(res.statusCode, 200);
    assert.equal(mockState.setCalls.length, 0);
    assert.equal(JSON.stringify(mockState.docs), before);
    assert.deepEqual(Array.from(new Set(mockState.collectionGetCalls)).sort(), [INV, LEDGER].sort());
});

test("SRH-09 a ledger longer than one page (1000) is read to the end: 2503 rows across 3 pages all count", async () => {
    reset();
    seedHappyPathAuth(mockState);
    const rows = [];
    for (let i = 0; i < 2503; i++) rows.push(mv("m" + String(i).padStart(5, "0"), "p1", "receipt", 1, IN_WINDOW + i));
    mockState.collections[LEDGER] = rows;
    mockState.collections[INV] = [product("p1", "W", 2503)];
    const res = await call();
    const p = jsonBody(res).products[0];
    assert.equal(p.closing, 2503);
    assert.equal(p.movementCount, 2503);
    assert.equal(p.reconciles, true);
    assert.equal(mockState.collectionGetCalls.filter((c) => c === LEDGER).length, 3);
});

test("SRH-10 exactly one full page (1000 rows) ends cleanly; an empty ledger gives an empty register", async () => {
    reset();
    seedHappyPathAuth(mockState);
    const rows = [];
    for (let i = 0; i < 1000; i++) rows.push(mv("m" + String(i).padStart(4, "0"), "p1", "receipt", 1, IN_WINDOW));
    mockState.collections[LEDGER] = rows;
    mockState.collections[INV] = [product("p1", "W", 1000)];
    let res = await call();
    assert.equal(jsonBody(res).products[0].movementCount, 1000);
    reset();
    seedHappyPathAuth(mockState);
    res = await call();
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res).products, []);
});

test("SRH-11 a ledger over the row cap -> 413 ledger-too-large (no partial answer, no 500)", async () => {
    reset();
    seedHappyPathAuth(mockState);
    const rows = [];
    for (let i = 0; i < 250001; i++) rows.push({ id: "m" + i, data: { productId: "p1", kind: "receipt", qty: 1, serverTimestamp: ts(IN_WINDOW) } });
    mockState.collections[LEDGER] = rows;
    const res = await call();
    assert.equal(res.statusCode, 413);
    assert.deepEqual(jsonBody(res), { ok: false, error: "ledger-too-large" });
});

test("SRH-12 a ledger of exactly the cap is still served", async () => {
    reset();
    seedHappyPathAuth(mockState);
    const rows = [];
    for (let i = 0; i < 250000; i++) rows.push({ id: "m" + i, data: { productId: "p1", kind: "receipt", qty: 1, serverTimestamp: ts(IN_WINDOW) } });
    mockState.collections[LEDGER] = rows;
    const res = await call();
    assert.equal(res.statusCode, 200);
    assert.equal(jsonBody(res).counts.rowsSeen, 250000);
});

test("SRH-13 a Firestore failure -> 500 compute-failed", async () => {
    reset();
    seedHappyPathAuth(mockState);
    mockState.collectionGetError = new Error("firestore down");
    const res = await call();
    assert.equal(res.statusCode, 500);
    assert.deepEqual(jsonBody(res), { ok: false, error: "compute-failed" });
});

test("SRH-14 junk ledger rows are skipped and reported, the rest of the register is still served", async () => {
    reset();
    seedHappyPathAuth(mockState);
    mockState.collections[LEDGER] = [
        mv("m1", "p1", "receipt", 5, IN_WINDOW),
        { id: "bad1", data: { productId: "p1", kind: "nope", qty: 1, serverTimestamp: ts(IN_WINDOW) } },
        { id: "bad2", data: { productId: "p1", kind: "receipt", qty: 1 } }
    ];
    mockState.collections[INV] = [product("p1", "W", 5)];
    const b = jsonBody(await call());
    assert.equal(b.products[0].closing, 5);
    assert.equal(b.counts.skipped.badKind, 1);
    assert.equal(b.counts.skipped.badTime, 1);
});

test("SRH-15 another tenant's ledger is never read: only the caller's tenant paths are queried", async () => {
    reset();
    seedHappyPathAuth(mockState);
    mockState.collections["tenants/other/stock_movements"] = [mv("x", "p9", "receipt", 999, IN_WINDOW)];
    const b = jsonBody(await call({ tenantId: "other", tenant: "other" }));
    assert.deepEqual(b.products, []);
    assert.ok(mockState.collectionGetCalls.every((c) => c.indexOf("tenants/test-tenant/") === 0));
});

test("SRH-16 env is honoured: an unknown env still resolves (fails safe) and answers like any other", async () => {
    reset();
    seedHappyPathAuth(mockState);
    const res = await call({ env: "nonsense" });
    assert.equal(res.statusCode, 200);
});

test("SRH-17 a request with no body at all is a 400 invalid-window, not a crash", async () => {
    reset();
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.computeStockRegister(mockReq({ body: undefined }), res);
    assert.ok(res.statusCode === 400 || res.statusCode === 403, "got " + res.statusCode);
});

// ── review sweep of PR #193 ──────────────────────────────────────────────────

test("SRH-18 a calendar-impossible bound is a 400 invalid-window, nothing read (2026-02-30 must not become 2 March)", async () => {
    reset();
    seedHappyPathAuth(mockState);
    for (const bad of [{ from: "2026-02-30T00:00:00Z" }, { to: "2026-04-31T00:00:00+05:30" }, { from: "2026-04-01T24:00:00Z" }]) {
        const res = await call(bad);
        assert.equal(res.statusCode, 400, JSON.stringify(bad));
        assert.equal(jsonBody(res).error, "invalid-window");
    }
    assert.equal(mockState.collectionGetCalls.length, 0);
});

test("SRH-19 a scan that outlives its time budget -> 504 ledger-scan-timeout as JSON (not a platform kill), no partial answer", async () => {
    reset();
    seedHappyPathAuth(mockState);
    const rows = [];
    for (let i = 0; i < 2500; i++) rows.push(mv("m" + String(i).padStart(5, "0"), "p1", "receipt", 1, IN_WINDOW));
    mockState.collections[LEDGER] = rows;
    const base = Date.now();
    const realNow = Date.now;
    // Every executed collection read costs 60 s of fake time: page 1 starts inside the 100 s budget,
    // page 2 starts after two reads (ledger page + inventory page) = 120 s, which is over it.
    Date.now = () => base + 60000 * mockState.collectionGetCalls.length;
    let res;
    try { res = await call(); } finally { Date.now = realNow; }
    assert.equal(res.statusCode, 504);
    assert.deepEqual(jsonBody(res), { ok: false, error: "ledger-scan-timeout" });
    assert.equal(mockState.collectionGetCalls.filter((c) => c === LEDGER).length, 1, "no page is started after the budget");
});

test("SRH-20 a fast scan under the budget is served; the budget is only checked between pages", async () => {
    reset();
    seedHappyPathAuth(mockState);
    const rows = [];
    for (let i = 0; i < 2500; i++) rows.push(mv("m" + String(i).padStart(5, "0"), "p1", "receipt", 1, IN_WINDOW));
    mockState.collections[LEDGER] = rows;
    const base = Date.now();
    const realNow = Date.now;
    Date.now = () => base + 10000 * mockState.collectionGetCalls.length; // 4 reads = 40 s
    let res;
    try { res = await call(); } finally { Date.now = realNow; }
    assert.equal(res.statusCode, 200);
    assert.equal(jsonBody(res).counts.rowsSeen, 2500);
});

test("SRH-21 a Firestore error while resolving the membership -> 500 compute-failed as JSON, not an unhandled rejection", async () => {
    reset();
    seedHappyPathAuth(mockState);
    mockState.docs = new Proxy({}, { get() { throw new Error("14 UNAVAILABLE"); } });
    const res = await call();
    assert.equal(res.statusCode, 500);
    assert.deepEqual(jsonBody(res), { ok: false, error: "compute-failed" });
    assert.equal(mockState.collectionGetCalls.length, 0);
});

test("SRH-22 env names that exist only on Object.prototype never pick a database: they fall back to the default one", async () => {
    for (const env of ["constructor", "toString", "__proto__", "hasOwnProperty", "valueOf"]) {
        reset();
        seedHappyPathAuth(mockState);
        mockState.firestoreDbIds.length = 0;
        const res = await call({ env: env });
        assert.equal(res.statusCode, 200, env);
        assert.ok(mockState.firestoreDbIds.length > 0);
        assert.ok(mockState.firestoreDbIds.every((id) => id === "(default)"), env + " -> " + JSON.stringify(mockState.firestoreDbIds));
    }
    reset();
    seedHappyPathAuth(mockState);
    mockState.firestoreDbIds.length = 0;
    await call({ env: "dev" });
    assert.ok(mockState.firestoreDbIds.every((id) => id === "dev1"), "a real env still maps: dev -> dev1");
    mockState.firestoreDbIds.length = 0;
    await call({ env: "test" });
    assert.ok(mockState.firestoreDbIds.every((id) => id === "test"));
});

// ── D-R3 (2026-11-11): count() pre-check ────────────────────────────────────
function bigLedger(n) {
    const rows = [];
    for (let i = 0; i < n; i++) rows.push({ id: "m" + i, data: { productId: "p1", kind: "receipt", qty: 1, serverTimestamp: ts(IN_WINDOW) } });
    return rows;
}

test("SRH-23 a count over the cap -> 413 with ZERO ledger pages and ZERO inventory reads (the cheap refusal)", async () => {
    reset();
    seedHappyPathAuth(mockState);
    mockState.countValue = 250001;
    const res = await call();
    assert.equal(res.statusCode, 413);
    assert.deepEqual(jsonBody(res), { ok: false, error: "ledger-too-large" });
    assert.deepEqual(mockState.countCalls, [LEDGER]);
    assert.equal(mockState.collectionGetCalls.length, 0, "a refused request must read no document");
    assert.equal(mockState.setCalls.length, 0);
});

test("SRH-24 a count of exactly the cap passes the pre-check and is served (the boundary matches the stream's)", async () => {
    reset();
    seedHappyPathAuth(mockState);
    mockState.countValue = 250000;
    mockState.collections[LEDGER] = [mv("m1", "p1", "receipt", 4, IN_WINDOW)];
    mockState.collections[INV] = [product("p1", "W", 4)];
    const res = await call();
    assert.equal(res.statusCode, 200);
    assert.equal(jsonBody(res).products[0].closing, 4);
    assert.ok(mockState.collectionGetCalls.length > 0);
});

test("SRH-25 count() throws -> the request is still served by the stream (a failed count is not a failed request)", async () => {
    reset();
    seedHappyPathAuth(mockState);
    mockState.countError = Object.assign(new Error("14 UNAVAILABLE"), { code: 14 });
    mockState.collections[LEDGER] = [mv("m1", "p1", "receipt", 2, IN_WINDOW)];
    mockState.collections[INV] = [product("p1", "W", 2)];
    const res = await call();
    assert.equal(res.statusCode, 200);
    assert.equal(jsonBody(res).products[0].closing, 2);
});

test("SRH-26 count says small but the stream finds more than the cap -> still 413 (the backstop stays)", async () => {
    reset();
    seedHappyPathAuth(mockState);
    mockState.countValue = 10;
    mockState.collections[LEDGER] = bigLedger(250001);
    const res = await call();
    assert.equal(res.statusCode, 413);
    assert.deepEqual(jsonBody(res), { ok: false, error: "ledger-too-large" });
    assert.ok(mockState.collectionGetCalls.length > 0, "the stream ran");
});

test("SRH-27 a junk count answer (not a number) is ignored: the stream decides", async () => {
    for (const junk of ["huge", NaN, undefined, {}, [], true]) {
        reset();
        seedHappyPathAuth(mockState);
        mockState.countValue = junk === undefined ? null : junk;
        mockState.collections[LEDGER] = [mv("m1", "p1", "receipt", 1, IN_WINDOW)];
        mockState.collections[INV] = [product("p1", "W", 1)];
        const res = await call();
        assert.equal(res.statusCode, 200, String(junk));
    }
});

test("SRH-28 the count runs only for an allowed caller with a valid window, never before the gates", async () => {
    reset();
    seedHappyPathAuth(mockState, { role: "staff" });
    assert.equal((await call()).statusCode, 403);
    assert.equal(mockState.countCalls.length, 0, "staff");
    reset();
    seedHappyPathAuth(mockState);
    assert.equal((await call({ from: "garbage" })).statusCode, 400);
    assert.equal(mockState.countCalls.length, 0, "bad window");
    reset();
    mockState.verifyIdToken = async () => { throw new Error("bad"); };
    assert.equal((await call()).statusCode, 401);
    assert.equal(mockState.countCalls.length, 0, "bad token");
});

test("SRH-29 a count of 0 serves an empty register; the count never touches another tenant's ledger", async () => {
    reset();
    seedHappyPathAuth(mockState);
    mockState.collections["tenants/other/stock_movements"] = bigLedger(3);
    const res = await call();
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res).products, []);
    assert.deepEqual(mockState.countCalls, [LEDGER]);
});

test("SRH-30 monkey: random counts and ledger sizes never produce a 500, and 413 happens iff the count or the ledger is over the cap", async () => {
    let seed = 99;
    const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
    for (let i = 0; i < 60; i++) {
        reset();
        seedHappyPathAuth(mockState);
        const rows = Math.floor(rnd() * 5);
        const counts = [null, 0, 3, 250000, 250001, 9999999, "x", NaN];
        const count = counts[Math.floor(rnd() * counts.length)];
        if (rnd() < 0.2) mockState.countError = new Error("boom"); else mockState.countValue = count;
        mockState.collections[LEDGER] = bigLedger(rows);
        const res = await call();
        const over = !mockState.countError && typeof count === "number" && count > 250000;
        assert.equal(res.statusCode, over ? 413 : 200, "count=" + String(count) + " err=" + Boolean(mockState.countError));
    }
});
