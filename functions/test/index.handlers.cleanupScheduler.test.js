"use strict";

// Functional tests for the PH3b scheduled cleanup binding (functions/index.js `cleanupPendingMarkers`,
// `listPendingMarkers`, `parkPendingMarker`, and the P3 `updateMarker` fix). Design:
// docs/superpowers/specs/2026-09-30-photos-s3-s4-design.md "PH3b". Test plan:
// docs/superpowers/test-plans/2026-10-05-ph3b-scheduled-cleanup-test-plan.md section 2 (FS01-FS10 + FS11-FS15).
//
// Same technique as index.handlers.test.js: the REAL exported function, with admin/Firestore/Storage
// faked by testSupport/handlerHarness.js (no emulator in the sandbox; the emulator e2e is slice S-C).
// The pure decisions (due time, backoff, park cap, budget, alert logs) are unit-tested in
// photoCleanup.test.js / cleanupSweep.test.js; what is proven HERE is the wiring: the collection-group
// read and paging, Timestamp -> ms, the shared sweep, park, logging, and what the run throws.
// The harness keeps ONE document store for all three databases; `mockState.docDb` says which database
// a doc is listed under for collectionGroup scans (default "test").

const test = require("node:test");
const assert = require("node:assert/strict");
const logger = require("firebase-functions/logger");
const { installMocks, seedHappyPathAuth, mockReq, mockRes } = require("./testSupport/handlerHarness");
const C = require("../lib/photoCleanup");

const { handlers, mockState } = installMocks();

const MIN = 60_000;
const T0 = 1_800_000_000_000;
const ENVS = {
    dev: { prefix: "dev1", db: "dev1" },
    test: { prefix: "test", db: "test" },
    prd: { prefix: "prd", db: "(default)" }
};

function mulberry32(seed) {
    let a = seed >>> 0;
    return function () {
        a = (a + 0x6d2b79f5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

function reset() {
    mockState.docs = {};
    mockState.collections = {};
    mockState.storageFiles = {};
    mockState.setCalls = [];
    mockState.docUpdateCalls = [];
    mockState.docUpdateError = null;
    mockState.docDeleteCalls = [];
    mockState.docDeleteError = null;
    mockState.storageDeleteFilesCalls = [];
    mockState.storageDeleteFilesError = null;
    mockState.onStorageDeleteFiles = null;
    mockState.storageBucketError = null;
    mockState.batchCommits = [];
    mockState.batchCommitError = null;
    mockState.collectionGetError = null;
    mockState.collectionGetCalls = [];
    mockState.collectionGroupCalls = [];
    mockState.collectionGroupErrors = {};
    mockState.docDb = {};
    mockState.applyMutationCalls = [];
    mockState.applyMutationResult = { ok: true };
}

function useClock(t, startMs) {
    const clock = { now: startMs };
    t.mock.method(Date, "now", () => clock.now);
    return clock;
}

function captureLogs(t) {
    const logs = [];
    t.mock.method(logger, "write", (entry) => { logs.push(entry); });
    return logs;
}

const alertLogs = (logs) => logs.filter((l) => typeof l.message === "string" && l.message.indexOf(C.ALERT_TAG) === 0);
const summaryOf = (logs, env) => logs.find((l) => l.message === "PH3B summary" && l.env === env);
const ts = (ms) => ({ toMillis: () => ms }); // Firestore Timestamp stand-in
const tick = () => handlers.cleanupPendingMarkers.run({});

function markerPath(tenant, product) { return "tenants/" + tenant + "/pending_cleanup/" + product; }
function prefixOf(envKey, tenant, product) { return ENVS[envKey].prefix + "/tenants/" + tenant + "/products/" + product + "/"; }

// Seeds a marker doc (+ its Storage files and stock batches). o: env, tenant, product, createdMs,
// attempts, over (field overrides; a key set to undefined is removed), legacy (no actor fields),
// files (default 2), batches (default 0). Returns {path, prefix, tenant, product}.
function seedMarker(o) {
    const env = o.env || "test";
    const tenant = o.tenant || "tenant-a";
    const product = o.product || "PRD-1";
    const path = markerPath(tenant, product);
    const prefix = prefixOf(env, tenant, product);
    const data = Object.assign({
        productId: product, envPrefix: ENVS[env].prefix, prefix: prefix,
        createdAt: ts(o.createdMs === undefined ? T0 - 60 * MIN : o.createdMs),
        attempts: o.attempts || 0, lastError: null,
        actorUid: "u-owner", actorRole: "owner", requestId: "req-" + product
    }, o.over || {});
    if (o.legacy) { delete data.actorUid; delete data.actorRole; delete data.requestId; }
    for (const k of Object.keys(data)) if (data[k] === undefined) delete data[k];
    mockState.docs[path] = data;
    mockState.docDb[path] = ENVS[env].db;
    const nFiles = o.files === undefined ? 2 : o.files;
    for (let i = 0; i < nFiles; i++) mockState.storageFiles[prefix + "photo-" + i + ".jpg"] = Buffer.from("x");
    const nBatches = o.batches || 0;
    if (nBatches > 0) {
        const coll = "tenants/" + tenant + "/stock_batches";
        const rows = mockState.collections[coll] || [];
        for (let i = 0; i < nBatches; i++) {
            rows.push({ id: product + "-B" + i, data: { batchId: product + "-B" + i, productId: product, qtyRemaining: i + 1 } });
        }
        rows.push({ id: "decoy-" + product, data: { batchId: "decoy-" + product, productId: product + "-OTHER", qtyRemaining: 9 } });
        mockState.collections[coll] = rows;
    }
    return { path: path, prefix: prefix, tenant: tenant, product: product };
}

function auditIds(tenant) {
    return Object.keys(mockState.docs).filter((k) => k.indexOf("tenants/" + tenant + "/audit_log/cascade~") === 0).sort();
}
function filesUnder(prefix) { return Object.keys(mockState.storageFiles).filter((k) => k.indexOf(prefix) === 0); }
function batchIdsOf(tenant) { return (mockState.collections["tenants/" + tenant + "/stock_batches"] || []).map((d) => d.id); }

// ---- FS01 ---------------------------------------------------------------------------------------

test("FS01 cleanupPendingMarkers is exported with the designed trigger metadata", () => {
    const fn = handlers.cleanupPendingMarkers;
    assert.equal(typeof fn, "function");
    assert.equal(typeof fn.run, "function");
    const ep = fn.__endpoint;
    assert.equal(ep.scheduleTrigger.schedule, "every 10 minutes");
    assert.equal(ep.scheduleTrigger.retryConfig.retryCount, 0);
    assert.deepEqual(ep.region, ["asia-south1"]);
    assert.equal(ep.timeoutSeconds, 300);
    assert.equal(ep.maxInstances, 1);
});

// ---- FS02 (regression P3) -----------------------------------------------------------------------

test("FS02 P3 regression: a failed sweep whose marker was deleted meanwhile does NOT re-create it", async (t) => {
    reset(); useClock(t, T0); captureLogs(t);
    const m = seedMarker({ attempts: 2 });
    mockState.storageDeleteFilesError = new Error("storage down");
    // The concurrent sweeper (handler or an earlier run) deletes the marker while this sweep is mid-flight.
    mockState.onStorageDeleteFiles = () => { delete mockState.docs[m.path]; };
    await tick();
    assert.equal(mockState.docs[m.path], undefined, "no zombie marker");
    assert.equal(mockState.setCalls.some((c) => c.path === m.path), false, "marker never written with set()");
    assert.equal(mockState.docUpdateCalls.filter((c) => c.path === m.path).length, 1, "update() was attempted and rejected NOT_FOUND");
});

test("FS02b P3: failed sweep of a LIVE marker updates it in place (attempts+1, lastError, lastAttemptAtMs), keeping every field", async (t) => {
    reset(); const clock = useClock(t, T0); captureLogs(t);
    const m = seedMarker({ attempts: 1 });
    const before = Object.assign({}, mockState.docs[m.path]);
    mockState.storageDeleteFilesError = new Error("storage down");
    await tick();
    const after = mockState.docs[m.path];
    assert.equal(after.attempts, 2);
    assert.equal(after.lastError, "storage down");
    assert.equal(after.lastAttemptAtMs, clock.now);
    for (const k of ["productId", "envPrefix", "prefix", "createdAt", "actorUid", "actorRole", "requestId"]) {
        assert.deepEqual(after[k], before[k], k);
    }
    assert.equal(mockState.setCalls.some((c) => c.path === m.path), false);
});

// ---- FS03 / FS04 / FS12 happy paths -------------------------------------------------------------

test("FS03 run(): marker + 3 batches + 2 Storage files -> all gone, 3 cascade~ audit docs with the marker's actor", async (t) => {
    reset(); useClock(t, T0); const logs = captureLogs(t);
    const m = seedMarker({ batches: 3 });
    await tick();
    assert.equal(mockState.docs[m.path], undefined);
    assert.deepEqual(filesUnder(m.prefix), []);
    assert.deepEqual(batchIdsOf("tenant-a"), ["decoy-PRD-1"], "only the other product's batch survives");
    const audits = auditIds("tenant-a");
    assert.equal(audits.length, 3);
    for (const a of audits) {
        assert.equal(mockState.docs[a].actorUid, "u-owner");
        assert.equal(mockState.docs[a].actorRole, "owner");
        assert.equal(mockState.docs[a].cascadeOf, "req-PRD-1");
    }
    assert.deepEqual(mockState.storageDeleteFilesCalls, [{ prefix: m.prefix, force: true }]);
    assert.equal(summaryOf(logs, "test").swept, 1);
    assert.equal(alertLogs(logs).length, 0);
});

test("FS04 legacy marker from #113 (no actor fields, no lastAttemptAtMs) is swept, audit actor is system", async (t) => {
    reset(); useClock(t, T0); captureLogs(t);
    const m = seedMarker({ legacy: true, batches: 2 });
    assert.equal("actorUid" in mockState.docs[m.path], false);
    await tick();
    assert.equal(mockState.docs[m.path], undefined);
    const audits = auditIds("tenant-a");
    assert.equal(audits.length, 2);
    for (const a of audits) {
        assert.equal(mockState.docs[a].actorUid, "system");
        assert.equal(mockState.docs[a].actorRole, "system");
    }
});

test("FS12 one run drains markers of several tenants in all three databases, each only under its own env prefix", async (t) => {
    reset(); useClock(t, T0); const logs = captureLogs(t);
    const seeded = [
        seedMarker({ env: "dev", tenant: "tenant-dev", batches: 1 }),
        seedMarker({ env: "test", tenant: "tenant-test", batches: 1 }),
        seedMarker({ env: "prd", tenant: "tenant-prd", batches: 1 }),
        seedMarker({ env: "test", tenant: "tenant-test-2", product: "PRD-7" })
    ];
    // Decoys: the same tenant + product under ANOTHER env's prefix must never be touched.
    const decoys = [
        "dev1/tenants/tenant-test/products/PRD-1/d.jpg",
        "prd/tenants/tenant-test/products/PRD-1/d.jpg",
        "test/tenants/tenant-prd/products/PRD-1/d.jpg"
    ];
    for (const d of decoys) mockState.storageFiles[d] = Buffer.from("decoy");
    await tick();
    for (const m of seeded) {
        assert.equal(mockState.docs[m.path], undefined, m.path);
        assert.deepEqual(filesUnder(m.prefix), [], m.prefix);
    }
    for (const d of decoys) assert.ok(mockState.storageFiles[d], "decoy kept: " + d);
    assert.deepEqual(
        mockState.storageDeleteFilesCalls.map((c) => c.prefix).sort(),
        seeded.map((m) => m.prefix).sort());
    assert.equal(summaryOf(logs, "dev").swept, 1);
    assert.equal(summaryOf(logs, "test").swept, 2);
    assert.equal(summaryOf(logs, "prd").swept, 1);
    // collectionGroup was queried once per database, on the right collection id.
    const dbs = mockState.collectionGroupCalls.map((c) => c.db).sort();
    assert.deepEqual(dbs, ["(default)", "dev1", "test"]);
    assert.ok(mockState.collectionGroupCalls.every((c) => c.group === "pending_cleanup" && c.limit === C.PAGE_SIZE));
});

// ---- FS05 (P7) and malformed handling ------------------------------------------------------------

test("FS05 P7: a prd marker inside the test database is PARKED, Storage untouched, ERROR alert", async (t) => {
    reset(); useClock(t, T0); const logs = captureLogs(t);
    const m = seedMarker({ env: "prd" });
    mockState.docDb[m.path] = "test"; // wrong database for its prefix
    await tick();
    assert.equal(mockState.docs[m.path].parked, true);
    assert.equal(mockState.docs[m.path].parkedAtMs, T0);
    assert.match(mockState.docs[m.path].lastError, /^malformed-marker: env-prefix-mismatch/);
    assert.equal(mockState.storageDeleteFilesCalls.length, 0);
    assert.equal(filesUnder(m.prefix).length, 2);
    const alerts = alertLogs(logs);
    assert.equal(alerts.length, 1);
    assert.equal(alerts[0].severity, "ERROR");
    assert.equal(alerts[0].env, "test");
    assert.equal(alerts[0].tenantId, "tenant-a");
    assert.equal(alerts[0].productId, "PRD-1");
});

test("FS15 createdAt garbage (string) -> malformed bad-created-at parked; plain-number createdAt works like a Timestamp", async (t) => {
    reset(); useClock(t, T0); captureLogs(t);
    const bad = seedMarker({ product: "PRD-BAD", over: { createdAt: "yesterday" } });
    const num = seedMarker({ product: "PRD-NUM", over: { createdAt: T0 - 60 * MIN } });
    await tick();
    assert.equal(mockState.docs[bad.path].parked, true);
    assert.match(mockState.docs[bad.path].lastError, /bad-created-at/);
    assert.equal(filesUnder(bad.prefix).length, 2, "malformed marker never swept");
    assert.equal(mockState.docs[num.path], undefined, "number createdAt accepted and swept");
});

test("FS16 an already-parked marker is skipped: never swept, never re-parked, never re-alerted", async (t) => {
    reset(); useClock(t, T0); const logs = captureLogs(t);
    const m = seedMarker({ attempts: 12, over: { parked: true, parkedAtMs: T0 - MIN, lastError: "old" } });
    const before = JSON.parse(JSON.stringify(mockState.docs[m.path]));
    await tick();
    await tick();
    assert.deepEqual(JSON.parse(JSON.stringify(mockState.docs[m.path])), before);
    assert.equal(mockState.docUpdateCalls.length, 0);
    assert.equal(mockState.storageDeleteFilesCalls.length, 0);
    assert.equal(alertLogs(logs).length, 0);
    assert.equal(summaryOf(logs, "test").parked, 1);
});

// ---- FS06 / FS07 error handling -----------------------------------------------------------------

test("FS06 env-level failure: run() REJECTS at the end, after the other envs ran; PH3B_ALERT env-failed", async (t) => {
    reset(); useClock(t, T0); const logs = captureLogs(t);
    mockState.collectionGroupErrors = { dev1: new Error("database dev1 missing") };
    const m = seedMarker({ env: "test", batches: 1 });
    await assert.rejects(() => tick(), /1 env\(s\) failed/);
    assert.equal(mockState.docs[m.path], undefined, "the test env was still swept after dev failed");
    const alerts = alertLogs(logs);
    assert.equal(alerts.length, 1);
    assert.equal(alerts[0].severity, "ERROR");
    assert.equal(alerts[0].env, "dev");
    assert.match(alerts[0].reason, /database dev1 missing/);
    assert.match(summaryOf(logs, "dev").error, /database dev1 missing/);
});

test("FS07 per-marker failures only (Storage down for every marker): run() RESOLVES, markers kept, WARNING only", async (t) => {
    reset(); const clock = useClock(t, T0); const logs = captureLogs(t);
    const a = seedMarker({ product: "PRD-A" });
    const b = seedMarker({ product: "PRD-B", tenant: "tenant-b" });
    mockState.storageDeleteFilesError = new Error("storage down");
    await tick(); // resolves
    for (const m of [a, b]) {
        assert.equal(mockState.docs[m.path].attempts, 1);
        assert.equal(mockState.docs[m.path].lastAttemptAtMs, clock.now);
        assert.equal(mockState.docs[m.path].parked, undefined);
    }
    assert.equal(alertLogs(logs).length, 0, "sub-cap failures never raise PH3B_ALERT");
    assert.equal(logs.filter((l) => l.severity === "WARNING").length, 2);
    assert.equal(summaryOf(logs, "test").failed, 2);
});

test("FS13 park throws at the cap: run() still resolves, marker not parked, PH3B_ALERT park-failed", async (t) => {
    reset(); useClock(t, T0); const logs = captureLogs(t);
    const m = seedMarker({ attempts: C.PARK_AT - 1 });
    mockState.storageDeleteFilesError = new Error("storage down");
    mockState.docUpdateError = new Error("firestore update denied");
    await tick();
    assert.equal(mockState.docs[m.path].parked, undefined);
    const alerts = alertLogs(logs);
    assert.equal(alerts.length, 1);
    assert.match(alerts[0].message, /park-failed/);
    assert.match(alerts[0].reason, /firestore update denied/);
});

test("FS17 a thrown sweep (Storage client cannot even be created) raises ERROR PH3B_ALERT sweep-threw every run, counts failed, never parks, run resolves", async (t) => {
    reset(); useClock(t, T0); const logs = captureLogs(t);
    const m = seedMarker({ attempts: C.PARK_AT - 1 });
    mockState.storageBucketError = new Error("bucket init failed"); // thrown by sweepProductCleanup itself
    await tick();
    assert.equal(mockState.docs[m.path].parked, undefined);
    assert.equal(mockState.docs[m.path].attempts, C.PARK_AT - 1, "a throw does not count as an attempt");
    const alerts = alertLogs(logs);
    assert.equal(alerts.length, 1, "S1 (PR #126 final sweep): a persistent throw must alert, not retry silently");
    assert.equal(alerts[0].message, C.ALERT_TAG + " sweep-threw");
    assert.equal(alerts[0].severity, "ERROR");
    assert.equal(alerts[0].env, "test");
    assert.equal(alerts[0].tenantId, m.tenant);
    assert.equal(alerts[0].productId, m.product);
    assert.match(alerts[0].reason, /bucket init failed/);
    assert.equal(summaryOf(logs, "test").failed, 1);
    await tick(); // still thrown next run: still alerts (it never backs off or parks)
    assert.equal(alertLogs(logs).length, 2);
    assert.equal(mockState.docs[m.path].attempts, C.PARK_AT - 1);
});

// ---- FS08 / FS09 ---------------------------------------------------------------------------------

test("FS08 handler sweep and scheduler sweep of the same marker in parallel: no duplicate audits, no zombie, files gone", async (t) => {
    reset(); useClock(t, T0); captureLogs(t);
    t.mock.method(console, "error", () => {});
    const tenant = "tenant-par";
    seedHappyPathAuth(mockState, { tenantId: tenant, role: "owner" });
    const m = seedMarker({ tenant: tenant, batches: 3, createdMs: T0 - 10 * MIN });
    const res = mockRes();
    const req = mockReq({
        body: {
            env: "test", entity: "inventory", entityId: "PRD-1", action: "delete", requestId: "del-par-1",
            before: { name: "Widget" }, after: null, clientTimestamp: 12345
        }
    });
    await Promise.all([handlers.recordMutation(req, res), tick()]);
    assert.equal(res.statusCode, 200);
    assert.equal(mockState.docs[m.path], undefined, "marker gone, not re-created");
    assert.deepEqual(filesUnder(m.prefix), []);
    assert.deepEqual(batchIdsOf(tenant), ["decoy-PRD-1"]);
    assert.equal(auditIds(tenant).length, 3, "deterministic audit ids: overlap duplicates nothing");
    assert.equal(mockState.setCalls.some((c) => c.path === m.path), false);
});

test("FS09 id reused (product doc exists again): marker dropped, files and batches untouched", async (t) => {
    reset(); useClock(t, T0); const logs = captureLogs(t);
    const m = seedMarker({ batches: 2 });
    mockState.docs["tenants/tenant-a/inventory/PRD-1"] = { name: "Reborn" };
    await tick();
    assert.equal(mockState.docs[m.path], undefined);
    assert.equal(filesUnder(m.prefix).length, 2);
    assert.equal(batchIdsOf("tenant-a").length, 3);
    assert.equal(auditIds("tenant-a").length, 0);
    assert.equal(mockState.storageDeleteFilesCalls.length, 0);
    assert.equal(summaryOf(logs, "test").droppedIdReuse, 1);
});

// ---- FS10 lifecycle ------------------------------------------------------------------------------

test("FS10 lifecycle: backoff, 12th failure ~300 min after the first (not ~410), park, skip, un-park, swept", async (t) => {
    reset(); const clock = useClock(t, T0); const logs = captureLogs(t);
    const m = seedMarker({ createdMs: T0 }); // the handler's own sweep failed at T0
    mockState.storageDeleteFilesError = new Error("storage down");
    // The failure is stamped a few seconds AFTER the tick that ran the sweep (what DUE_SLACK_MS absorbs).
    mockState.onStorageDeleteFiles = () => { clock.now += 5_000; };

    const failedAtMin = [];
    for (let k = 1; k <= 40; k++) {
        clock.now = T0 + k * 10 * MIN;
        const calls = mockState.storageDeleteFilesCalls.length;
        await tick();
        if (mockState.storageDeleteFilesCalls.length > calls) failedAtMin.push(k * 10);
    }
    // 10, then 20 (+10 backoff), 40 (+20), then every 30.
    assert.deepEqual(failedAtMin.slice(0, 5), [10, 20, 40, 70, 100]);
    assert.equal(failedAtMin.length, C.PARK_AT, "swept exactly PARK_AT times, then parked");
    const spanMin = failedAtMin[C.PARK_AT - 1] - failedAtMin[0];
    assert.ok(Math.abs(spanMin - 300) <= 10, "12th failure ~300 min after the first, got " + spanMin);
    assert.ok(spanMin < 400, "NOT the ~410 min of a design without the tick slack");

    const parked = mockState.docs[m.path];
    assert.equal(parked.parked, true);
    assert.equal(parked.attempts, C.PARK_AT);
    assert.ok(Number.isFinite(parked.parkedAtMs));
    assert.equal(alertLogs(logs).filter((l) => /marker-parked/.test(l.message)).length, 1, "alerted once, not every run");
    assert.equal(filesUnder(m.prefix).length, 2, "parked marker: files untouched");

    // Later runs skip it.
    const callsAfterPark = mockState.storageDeleteFilesCalls.length;
    clock.now += 60 * MIN; await tick();
    assert.equal(mockState.storageDeleteFilesCalls.length, callsAfterPark);

    // Un-park runbook: parked=false, attempts=0, and Storage works again.
    mockState.docs[m.path].parked = false;
    mockState.docs[m.path].attempts = 0;
    mockState.storageDeleteFilesError = null;
    mockState.onStorageDeleteFiles = null;
    clock.now += 10 * MIN; await tick();
    assert.equal(mockState.docs[m.path], undefined, "swept after un-park");
    assert.deepEqual(filesUnder(m.prefix), []);
});

// ---- FS11 paging ---------------------------------------------------------------------------------

function seedFreshMarkers(n) {
    for (let i = 0; i < n; i++) {
        seedMarker({ tenant: "tenant-" + (i % 3), product: "P" + i, createdMs: T0 - 1000, files: 0 });
    }
}

test("FS11 paging: 450 markers are read in 3 pages of PAGE_SIZE, cursor = previous page's last doc, none swept (all fresh)", async (t) => {
    reset(); useClock(t, T0); const logs = captureLogs(t);
    seedFreshMarkers(450);
    await tick();
    const calls = mockState.collectionGroupCalls.filter((c) => c.db === "test");
    assert.equal(calls.length, 3);
    assert.ok(calls.every((c) => c.limit === C.PAGE_SIZE));
    const paths = Object.keys(mockState.docs).filter((p) => p.indexOf("/pending_cleanup/") > 0).sort();
    assert.equal(calls[0].afterPath, null);
    assert.equal(calls[1].afterPath, paths[C.PAGE_SIZE - 1]);
    assert.equal(calls[2].afterPath, paths[2 * C.PAGE_SIZE - 1]);
    const s = summaryOf(logs, "test");
    assert.equal(s.scanned, 450);
    assert.equal(s.notDue, 450);
    assert.equal(s.swept, 0);
    assert.equal(s.backlog, false);
    assert.equal(Object.keys(mockState.docs).filter((p) => p.indexOf("/pending_cleanup/") > 0).length, 450, "nothing deleted");
});

test("FS11b paging: MAX_SCAN + 5 markers -> exactly MAX_PAGES reads, backlog:true, PH3B_ALERT backlog", async (t) => {
    reset(); useClock(t, T0); const logs = captureLogs(t);
    seedFreshMarkers(C.MAX_SCAN + 5);
    await tick();
    const calls = mockState.collectionGroupCalls.filter((c) => c.db === "test");
    assert.equal(calls.length, C.MAX_PAGES);
    const s = summaryOf(logs, "test");
    assert.equal(s.scanned, C.MAX_SCAN);
    assert.equal(s.backlog, true);
    const alerts = alertLogs(logs);
    assert.equal(alerts.length, 1);
    assert.match(alerts[0].message, /backlog/);
    assert.equal(alerts[0].severity, "ERROR");
});

// ---- FS14 monkey ---------------------------------------------------------------------------------

test("FS14 MONKEY: 5 seeds x random markers/failures over 25 ticks: protected data survives, no zombie, no set() on markers, cap respected", async (t) => {
    const OTHER = { dev: "test", test: "prd", prd: "dev" };
    for (const seed of [1, 2, 3, 4, 5]) {
        reset();
        const clock = useClock(t, T0);
        captureLogs(t);
        const rnd = mulberry32(seed);
        const envKeys = ["dev", "test", "prd"];
        const protectedPrefixes = [];
        const sweepablePrefixes = new Set();
        const parkedBefore = {};
        for (let i = 0; i < 36; i++) {
            const env = envKeys[Math.floor(rnd() * 3)];
            const flavor = Math.floor(rnd() * 9);
            const o = { env: env, tenant: "t" + (i % 4), product: "P" + i, batches: Math.floor(rnd() * 4) };
            o.createdMs = T0 - Math.floor(rnd() * 90) * MIN;
            if (flavor === 0 || flavor === 8) { o.attempts = 0; o.legacy = flavor === 8; }
            if (flavor === 1) o.attempts = Math.floor(rnd() * C.PARK_AT);
            if (flavor === 2) { o.attempts = 3; o.over = { parked: true, parkedAtMs: T0 - MIN, lastError: "old" }; }
            if (flavor === 3) o.over = { envPrefix: ENVS[OTHER[env]].prefix, prefix: prefixOf(OTHER[env], "t" + (i % 4), "P" + i) };
            if (flavor === 4) o.over = { createdAt: "garbage" };
            if (flavor === 5) o.over = { prefix: undefined };
            if (flavor === 6) o.over = { productId: "SOMETHING-ELSE" };
            const m = seedMarker(o);
            const filesPrefix = flavor === 3 ? prefixOf(OTHER[env], "t" + (i % 4), "P" + i) : m.prefix;
            if (flavor === 3) mockState.storageFiles[filesPrefix + "x.jpg"] = Buffer.from("x");
            if (flavor === 7) mockState.docs["tenants/t" + (i % 4) + "/inventory/P" + i] = { name: "reused" };
            if ([2, 3, 4, 5, 6, 7].indexOf(flavor) >= 0) protectedPrefixes.push(filesPrefix);
            else sweepablePrefixes.add(m.prefix);
            if (flavor === 2) parkedBefore[m.path] = JSON.stringify(mockState.docs[m.path]);
        }
        for (let k = 1; k <= 25; k++) {
            clock.now = T0 + k * 10 * MIN + Math.floor(rnd() * 5000);
            mockState.storageDeleteFilesError = rnd() < 0.4 ? new Error("flaky storage") : null;
            await tick(); // never throws: no database-level failure was injected
        }
        // 1. protected data never touched
        for (const p of protectedPrefixes) assert.ok(filesUnder(p).length > 0, "seed " + seed + " protected files survive: " + p);
        // 2. already-parked markers unchanged
        for (const p of Object.keys(parkedBefore)) assert.equal(JSON.stringify(mockState.docs[p]), parkedBefore[p], "seed " + seed + " parked untouched " + p);
        // 3. nothing ever wrote a marker with set(), and no doc under pending_cleanup lost its productId (zombie)
        assert.equal(mockState.setCalls.some((c) => c.path.indexOf("/pending_cleanup/") > 0), false, "seed " + seed);
        for (const p of Object.keys(mockState.docs).filter((x) => x.indexOf("/pending_cleanup/") > 0)) {
            assert.equal(typeof mockState.docs[p].productId, "string", "seed " + seed + " zombie? " + p);
            assert.ok((mockState.docs[p].attempts || 0) <= C.PARK_AT, "seed " + seed + " attempts capped at PARK_AT: " + p);
        }
        // 4. every Storage sweep targeted a prefix of a sweepable seeded marker, and ends with "/"
        for (const c of mockState.storageDeleteFilesCalls) {
            assert.ok(sweepablePrefixes.has(c.prefix), "seed " + seed + " unexpected sweep prefix " + c.prefix);
            assert.equal(c.prefix.slice(-1), "/");
        }
    }
});
