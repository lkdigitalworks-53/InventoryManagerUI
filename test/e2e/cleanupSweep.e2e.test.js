"use strict";

// Emulator end-to-end check of the PH3b scheduled sweeper (functions/index.js `cleanupPendingMarkers`).
// The functions suite runs the SAME code against in-memory doubles; this file is the one place it meets
// real Firestore semantics (collection-group read, cursor paging WITHOUT orderBy, update() on a missing
// doc, real server Timestamps) and the real Storage emulator (prefix delete).
// Design: docs/superpowers/specs/2026-09-30-photos-s3-s4-design.md "PH3b". Plan: section 3 of
// docs/superpowers/test-plans/2026-10-05-ph3b-scheduled-cleanup-test-plan.md (E1-E5; E0 + E6 added in S-C).
//
// HOW IT RUNS: the scheduled function is NOT triggered by the functions emulator (no clock), so this
// file requires functions/index.js IN-PROCESS and calls `cleanupPendingMarkers.run({})`, exactly what
// Cloud Scheduler would invoke. firebase-admin here (root, v14) seeds and asserts; the one inside
// functions/ (v12) is what the sweeper uses. They are separate module instances; both reach the same
// emulators through the env vars. Run inside the same `firebase emulators:exec` as the other e2e files:
//   firebase emulators:exec --only firestore,auth,functions,storage \
//     "node --test test/e2e/cleanupSweep.e2e.test.js"
//
// Safety: refuses to run unless BOTH the Firestore and the Storage emulator hosts are set (the sweep
// deletes Storage objects; it must never be pointed at the real bucket by accident).
// Isolation: own ids (tenants "ph3bE2E-*"), everything created is deleted afterwards. Markers live in
// "(default)" = env "prd", so Storage prefixes are "prd/tenants/ph3bE2E-*/products/...".
// UNVERIFIED until the first CI run (no emulator in the sandbox): that the Firestore emulator serves the
// named databases "dev1" and "test" (the sweeper reads all three; E0 isolates that), that GCLOUD_PROJECT
// is enough for functions' admin.initializeApp(), and that two admin majors coexist in one process.

const { test, afterEach } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, Timestamp, FieldValue } = require("firebase-admin/firestore");
const { getStorage } = require("firebase-admin/storage");

const PROJECT_ID = "inventorymanager-48392";                       // must match seed.js
const BUCKET = "inventorymanager-48392.firebasestorage.app";       // must match functions/index.js PHOTO_BUCKET_NAME

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_STORAGE_EMULATOR_HOST) {
    console.error("cleanupSweep.e2e: FIRESTORE_EMULATOR_HOST and FIREBASE_STORAGE_EMULATOR_HOST must both be set " +
                  "-- refusing to run against what might be real Firestore / Storage.");
    process.exit(1);
}
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || PROJECT_ID;

const FUNCTIONS_DIR = path.join(__dirname, "..", "..", "functions");
const PH = require(path.join(FUNCTIONS_DIR, "lib", "photoCleanup.js"));
// The SAME logger module instance index.js uses (resolved from functions/node_modules), so a spy sees its logs.
const logger = require(require.resolve("firebase-functions/logger", { paths: [FUNCTIONS_DIR] }));
const sweeper = require(path.join(FUNCTIONS_DIR, "index.js")).cleanupPendingMarkers;

const app = initializeApp({ projectId: PROJECT_ID, storageBucket: BUCKET }, "ph3b-e2e");
const db = getFirestore(app);                 // "(default)" = env prd, like seed.js
const bucket = getStorage(app).bucket();

const TEN_MIN_AGO = () => Timestamp.fromMillis(Date.now() - 10 * 60_000);
const createdDocs = new Set();
const createdObjects = new Set();

async function putDoc(p, data) { await db.doc(p).set(data); createdDocs.add(p); }
async function readDoc(p) { const s = await db.doc(p).get(); return s.exists ? s.data() : null; }
async function putObject(p) { await bucket.file(p).save(Buffer.from("x"), { contentType: "image/jpeg" }); createdObjects.add(p); }
async function objectExists(p) { return (await bucket.file(p).exists())[0]; }

function prefixOf(tenant, product) { return PH.buildSweepPrefix("prd", tenant, product); }

// A marker as the delete handler writes it today (buildMarker), already old enough to be due.
function marker(tenant, product, extra) {
    return Object.assign(PH.buildMarker({
        envPrefix: "prd", tenantId: tenant, productId: product, prefix: prefixOf(tenant, product),
        createdAt: TEN_MIN_AGO(), actorUid: "u-e2e", actorRole: "owner", requestId: "req-e2e"
    }), extra || {});
}

async function putBatches(tenant, product, ids) {
    for (const id of ids) await putDoc("tenants/" + tenant + "/stock_batches/" + id, { productId: product, quantity: 5, costPrice: 10 });
}

// One scheduler tick; resolves with the "PH3B summary" log of env prd (the database markers live in).
async function tick(t) {
    const logs = [];
    t.mock.method(logger, "write", (entry) => { logs.push(entry); });
    await sweeper.run({});
    const summary = logs.find((l) => l.message === "PH3B summary" && l.env === "prd") || null;
    return { logs, summary };
}

afterEach(async () => {
    const writer = db.bulkWriter();
    for (const p of createdDocs) writer.delete(db.doc(p));
    await writer.close();
    for (const p of createdObjects) await bucket.file(p).delete({ ignoreNotFound: true });
    createdDocs.clear();
    createdObjects.clear();
});

test("E0 a tick over all three databases completes (dev1 / test / (default) all reachable)", async (t) => {
    const { summary } = await tick(t);   // run() throws if any env could not be read
    assert.ok(summary, "the prd summary line was logged");
});

test("E1 stuck markers in two tenants: batches + photos + markers all gone, a live product untouched", async (t) => {
    for (const tenant of ["ph3bE2E-a", "ph3bE2E-b"]) {
        await putDoc("tenants/" + tenant + "/pending_cleanup/p1", marker(tenant, "p1"));
        await putBatches(tenant, "p1", ["b1", "b2", "b3"]);
        await putObject(prefixOf(tenant, "p1") + "ph1.jpg");
        await putObject(prefixOf(tenant, "p1") + "ph1_t.jpg");
        for (const b of ["b1", "b2", "b3"]) createdDocs.add("tenants/" + tenant + "/audit_log/" + PH.buildCascadeAuditId("p1", b));
    }
    // Control: another product of tenant a with a batch and a photo, no marker. Must survive.
    await putDoc("tenants/ph3bE2E-a/inventory/p2", { name: "live" });
    await putBatches("ph3bE2E-a", "p2", ["c1"]);
    await putObject(prefixOf("ph3bE2E-a", "p2") + "keep.jpg");

    await tick(t);

    for (const tenant of ["ph3bE2E-a", "ph3bE2E-b"]) {
        assert.equal(await readDoc("tenants/" + tenant + "/pending_cleanup/p1"), null, tenant + ": marker removed");
        for (const b of ["b1", "b2", "b3"]) {
            assert.equal(await readDoc("tenants/" + tenant + "/stock_batches/" + b), null, tenant + ": batch " + b + " removed");
            const audit = await readDoc("tenants/" + tenant + "/audit_log/" + PH.buildCascadeAuditId("p1", b));
            assert.ok(audit, tenant + ": audit entry for " + b);
            assert.equal(audit.actorUid, "u-e2e");
            assert.equal(audit.cascadeOf, "req-e2e");
        }
        assert.equal(await objectExists(prefixOf(tenant, "p1") + "ph1.jpg"), false, tenant + ": photo removed");
        assert.equal(await objectExists(prefixOf(tenant, "p1") + "ph1_t.jpg"), false, tenant + ": thumb removed");
    }
    assert.ok(await readDoc("tenants/ph3bE2E-a/stock_batches/c1"), "other product's batch untouched");
    assert.ok(await readDoc("tenants/ph3bE2E-a/inventory/p2"), "live product untouched");
    assert.equal(await objectExists(prefixOf("ph3bE2E-a", "p2") + "keep.jpg"), true, "other product's photo untouched");
});

test("E2 (P1) a marker with only the fields PR #113 wrote is found and swept; batch audit is attributed to system", async (t) => {
    const tenant = "ph3bE2E-a";
    await putDoc("tenants/" + tenant + "/pending_cleanup/p1", {
        productId: "p1", envPrefix: "prd", prefix: prefixOf(tenant, "p1"),
        createdAt: TEN_MIN_AGO(), attempts: 0, lastError: null      // no actor fields, no lastAttemptAtMs, no nextAttemptAt
    });
    await putBatches(tenant, "p1", ["b1"]);
    await putObject(prefixOf(tenant, "p1") + "ph1.jpg");

    await tick(t);

    assert.equal(await readDoc("tenants/" + tenant + "/pending_cleanup/p1"), null);
    assert.equal(await readDoc("tenants/" + tenant + "/stock_batches/b1"), null);
    const auditId = PH.buildCascadeAuditId("p1", "b1");
    createdDocs.add("tenants/" + tenant + "/audit_log/" + auditId);
    assert.equal((await readDoc("tenants/" + tenant + "/audit_log/" + auditId)).actorUid, "system");
    assert.equal(await objectExists(prefixOf(tenant, "p1") + "ph1.jpg"), false);
});

test("E3 id-reused marker is dropped; the live product, its batch and its photos are untouched", async (t) => {
    const tenant = "ph3bE2E-a";
    await putDoc("tenants/" + tenant + "/pending_cleanup/p1", marker(tenant, "p1"));
    await putDoc("tenants/" + tenant + "/inventory/p1", { name: "re-created" });
    await putBatches(tenant, "p1", ["b1"]);
    await putObject(prefixOf(tenant, "p1") + "ph1.jpg");

    await tick(t);

    assert.equal(await readDoc("tenants/" + tenant + "/pending_cleanup/p1"), null, "stale marker dropped");
    assert.ok(await readDoc("tenants/" + tenant + "/inventory/p1"), "live product intact");
    assert.ok(await readDoc("tenants/" + tenant + "/stock_batches/b1"), "live product's batch intact (money data)");
    assert.equal(await objectExists(prefixOf(tenant, "p1") + "ph1.jpg"), true, "live product's photo intact");
});

test("E4 a parked marker is left untouched; after un-park (parked=false, attempts=0) it is swept", async (t) => {
    const tenant = "ph3bE2E-a";
    const markerPath = "tenants/" + tenant + "/pending_cleanup/p1";
    await putDoc(markerPath, marker(tenant, "p1", { parked: true, parkedAtMs: Date.now() - 60_000, attempts: PH.PARK_AT, lastError: "boom" }));
    await putObject(prefixOf(tenant, "p1") + "ph1.jpg");

    await tick(t);
    const kept = await readDoc(markerPath);
    assert.ok(kept, "parked marker kept");
    assert.equal(kept.parked, true);
    assert.equal(kept.attempts, PH.PARK_AT);
    assert.equal(await objectExists(prefixOf(tenant, "p1") + "ph1.jpg"), true, "parked marker's photo untouched");

    await db.doc(markerPath).update({ parked: false, attempts: 0 });   // the documented un-park runbook step
    await tick(t);
    assert.equal(await readDoc(markerPath), null, "un-parked marker swept");
    assert.equal(await objectExists(prefixOf(tenant, "p1") + "ph1.jpg"), false);
});

test("E5 (R1) paging at real Firestore semantics: PAGE_SIZE*2+50 markers over 3 tenants, one tick, no skip, no repeat",
    { timeout: 280_000 }, async (t) => {
    const tenants = ["ph3bE2E-a", "ph3bE2E-b", "ph3bE2E-c"];
    const n = PH.PAGE_SIZE * 2 + 50;
    const writer = db.bulkWriter();
    for (let i = 0; i < n; i++) {
        const tenant = tenants[i % tenants.length];
        const p = "tenants/" + tenant + "/pending_cleanup/pg" + i;
        createdDocs.add(p);
        writer.set(db.doc(p), marker(tenant, "pg" + i));
    }
    await writer.close();
    const totalBefore = (await db.collectionGroup("pending_cleanup").get()).size;   // ours + any leftover
    assert.ok(totalBefore >= n && totalBefore <= PH.MAX_SCAN, "precondition: " + totalBefore + " markers, under MAX_SCAN");

    const { summary } = await tick(t);

    assert.ok(summary, "prd summary logged");
    assert.equal(summary.backlog, false, "the whole collection group fit under MAX_SCAN");
    assert.equal(summary.scanned, totalBefore, "every marker read exactly once: no skip (<) and no repeat (>)");
    assert.ok(summary.swept >= n, "every due marker of ours swept (swept=" + summary.swept + ")");
    const left = (await db.collectionGroup("pending_cleanup").get()).docs.filter((d) => tenants.some((x) => d.ref.path.indexOf("tenants/" + x + "/") === 0));
    assert.equal(left.length, 0, "none of our markers left");
});

test("E6 a fresh marker (real server Timestamp, inside the 90 s grace) is not swept", async (t) => {
    const tenant = "ph3bE2E-a";
    const markerPath = "tenants/" + tenant + "/pending_cleanup/p1";
    await putDoc(markerPath, marker(tenant, "p1", { createdAt: FieldValue.serverTimestamp() }));
    await putObject(prefixOf(tenant, "p1") + "ph1.jpg");

    await tick(t);

    assert.ok(await readDoc(markerPath), "fresh marker left for the handler's own sweep");
    assert.equal(await objectExists(prefixOf(tenant, "p1") + "ph1.jpg"), true);
});
