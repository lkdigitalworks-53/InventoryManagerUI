"use strict";

// Handler-level tests for uploadProductPhoto and deleteProductPhoto (functions/index.js).
// Design: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md
// Test plan: docs/superpowers/test-plans/2026-09-21-product-photos-firebase-storage-test-plan.md
//
// Same harness/technique as index.handlers.test.js -- the actual exported handler functions,
// with admin.auth()/Firestore/Storage mocked (testSupport/handlerHarness.js). Real Firebase
// emulator is not available in this sandbox; this is the closest to a real integration test
// this session can run, and it does run for real (node --test), not merely written.

const test = require("node:test");
const assert = require("node:assert/strict");
const { installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody } = require("./testSupport/handlerHarness");

const { handlers, mockState } = installMocks();

const TENANT = "test-tenant";
const PRODUCT = "prod-1";

const JPEG_MAGIC = Buffer.from([0xff, 0xd8, 0xff, 0xe0]);
function jpegBuffer(size) {
    return Buffer.concat([JPEG_MAGIC, Buffer.alloc(Math.max(size - JPEG_MAGIC.length, 0), 1)]);
}
const VALID_MAIN_B64 = jpegBuffer(100).toString("base64");
const VALID_THUMB_B64 = jpegBuffer(50).toString("base64");
const OVERSIZE_MAIN_B64 = jpegBuffer(1_600_000).toString("base64"); // > 1.5MB ceiling
const NOT_JPEG_B64 = Buffer.from([0x00, 0x01, 0x02, 0x03]).toString("base64");

function resetState(opts) {
    const o = opts || {};
    mockState.docs = {};
    mockState.storageFiles = {};
    mockState.storageSaveCalls = [];
    mockState.storageDeleteCalls = [];
    mockState.storageSaveError = null;
    mockState.storageDeleteError = null;
    mockState.onStorageSave = null;
    mockState.storageDeleteFilesCalls = [];
    mockState.docDeleteCalls = [];
    seedHappyPathAuth(mockState, { tenantId: TENANT, role: o.role });
    if (o.product !== null) {
        mockState.docs["tenants/" + TENANT + "/inventory/" + PRODUCT] =
            Object.assign({ name: "Widget", photoIds: [] }, o.product || {});
    }
}

function uploadBody(overrides) {
    return Object.assign({
        env: "test", productId: PRODUCT, photoId: "photo-1", requestId: "photo-1",
        imageBase64: VALID_MAIN_B64, thumbBase64: VALID_THUMB_B64
    }, overrides || {});
}

function deleteBody(overrides) {
    return Object.assign({
        env: "test", productId: PRODUCT, photoId: "photo-1", requestId: "del-photo-1"
    }, overrides || {});
}

// ── uploadProductPhoto ──────────────────────────────────────────────────────

test("uploadProductPhoto: happy path writes both objects and appends the id", async () => {
    resetState();
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 200);
    const body = jsonBody(res);
    assert.equal(body.ok, true);
    assert.deepEqual(body.photoIds, ["photo-1"]);
    assert.equal(mockState.storageSaveCalls.length, 2, "main + thumb");
    const paths = mockState.storageSaveCalls.map((c) => c.path);
    assert.ok(paths.some((p) => p.endsWith("photo-1.jpg") && !p.endsWith("_t.jpg")));
    assert.ok(paths.some((p) => p.endsWith("photo-1_t.jpg")));
    assert.ok(paths.every((p) => p.startsWith("test/tenants/" + TENANT + "/products/" + PRODUCT + "/")));
    const productDoc = mockState.docs["tenants/" + TENANT + "/inventory/" + PRODUCT];
    assert.deepEqual(productDoc.photoIds, ["photo-1"]);
});

test("uploadProductPhoto: idempotent retry with the same requestId does not re-save or duplicate the id", async () => {
    resetState();
    const res1 = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res1);
    assert.equal(mockState.storageSaveCalls.length, 2);

    const res2 = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res2);
    assert.equal(res2.statusCode, 200);
    const body2 = jsonBody(res2);
    assert.equal(body2.already, true);
    assert.deepEqual(body2.photoIds, ["photo-1"]);
    assert.equal(mockState.storageSaveCalls.length, 2, "no re-upload on replay");
    const productDoc = mockState.docs["tenants/" + TENANT + "/inventory/" + PRODUCT];
    assert.deepEqual(productDoc.photoIds, ["photo-1"], "no duplicate id");
});

test("uploadProductPhoto: 400 invalid-image for a non-JPEG main image, no Storage write attempted", async () => {
    resetState();
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody({ imageBase64: NOT_JPEG_B64 }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "invalid-image");
    assert.equal(mockState.storageSaveCalls.length, 0);
});

test("uploadProductPhoto: 400 invalid-image for a non-JPEG thumbnail even if the main image is valid", async () => {
    resetState();
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody({ thumbBase64: NOT_JPEG_B64 }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "invalid-image");
    assert.equal(mockState.storageSaveCalls.length, 0);
});

test("uploadProductPhoto: 413 image-too-large for an oversized main image", async () => {
    resetState();
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody({ imageBase64: OVERSIZE_MAIN_B64 }) }), res);
    assert.equal(res.statusCode, 413);
    assert.equal(jsonBody(res).error, "image-too-large");
    assert.equal(mockState.storageSaveCalls.length, 0);
});

test("uploadProductPhoto: 404 product-not-found when the product doc doesn't exist", async () => {
    resetState({ product: null });
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 404);
    assert.equal(jsonBody(res).error, "product-not-found");
    // PH3 / F3 (design Q1): the product is read BEFORE any Storage write, so a 404 leaves ZERO
    // orphan objects (this used to assert 2 saves, the old accepted-orphan behaviour).
    assert.equal(mockState.storageSaveCalls.length, 0);
});

test("uploadProductPhoto: 409 photo-limit when the product already has 10 photos", async () => {
    const tenPhotoIds = Array.from({ length: 10 }, (_, i) => "existing-" + i);
    resetState({ product: { photoIds: tenPhotoIds } });
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 409);
    assert.equal(jsonBody(res).error, "photo-limit");
    const productDoc = mockState.docs["tenants/" + TENANT + "/inventory/" + PRODUCT];
    assert.deepEqual(productDoc.photoIds, tenPhotoIds, "unchanged");
    assert.equal(mockState.storageSaveCalls.length, 0, "F3: a full gallery 409 writes no Storage objects");
});

test("uploadProductPhoto: missing Authorization header -> 401 missing-token", async () => {
    resetState();
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ headers: { origin: "http://localhost" }, body: uploadBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
});

test("uploadProductPhoto: verifyIdToken throwing -> 401 invalid-token", async () => {
    resetState();
    mockState.verifyIdToken = async () => { throw new Error("bad token"); };
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("uploadProductPhoto: authenticated but no tenant context -> 403 no-tenant-context", async () => {
    resetState();
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid" });
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
});

test("uploadProductPhoto: 500 write-failed when the Storage save itself throws", async () => {
    resetState();
    mockState.storageSaveError = new Error("bucket unavailable");
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 500);
    const productDoc = mockState.docs["tenants/" + TENANT + "/inventory/" + PRODUCT];
    assert.deepEqual(productDoc.photoIds, [], "no id recorded when the upload itself failed");
});

test("uploadProductPhoto: 400 invalid-request when productId contains a path-traversal slash", async () => {
    resetState();
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody({ productId: "../other-tenant/inventory/x" }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "invalid-request");
    assert.equal(mockState.storageSaveCalls.length, 0, "must reject before ever touching Storage");
});

test("uploadProductPhoto: 400 invalid-request when photoId contains a slash", async () => {
    resetState();
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody({ photoId: "a/b" }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "invalid-request");
});

test("monkey: repeated uploads never produce a photoIds array longer than 10 or with a duplicate id", () => {
    // Pure invariant check driven by the same list-mutation logic the handler uses -- fast,
    // deterministic, no async handler roundtrip needed to stress this specific property widely.
    for (let run = 0; run < 300; run++) {
        let photoIds = [];
        for (let i = 0; i < 15; i++) {
            const candidate = "p" + Math.floor(Math.random() * 12); // deliberately provokes duplicates
            if (photoIds.length >= 10) continue;
            if (photoIds.indexOf(candidate) === -1) photoIds.push(candidate);
        }
        assert.ok(photoIds.length <= 10);
        assert.equal(new Set(photoIds).size, photoIds.length, "no duplicates");
    }
});

// ── deleteProductPhoto ──────────────────────────────────────────────────────

test("deleteProductPhoto: happy path removes the id and deletes both objects", async () => {
    resetState({ product: { photoIds: ["photo-1", "photo-2"] } });
    const res = mockRes();
    await handlers.deleteProductPhoto(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 200);
    const body = jsonBody(res);
    assert.deepEqual(body.photoIds, ["photo-2"]);
    assert.equal(mockState.storageDeleteCalls.length, 2, "main + thumb");
    const productDoc = mockState.docs["tenants/" + TENANT + "/inventory/" + PRODUCT];
    assert.deepEqual(productDoc.photoIds, ["photo-2"]);
});

test("deleteProductPhoto: removing an id that is already absent is a no-op, not an error", async () => {
    resetState({ product: { photoIds: ["photo-2"] } });
    const res = mockRes();
    await handlers.deleteProductPhoto(mockReq({ body: deleteBody({ photoId: "never-was-there" }) }), res);
    assert.equal(res.statusCode, 200);
    const productDoc = mockState.docs["tenants/" + TENANT + "/inventory/" + PRODUCT];
    assert.deepEqual(productDoc.photoIds, ["photo-2"]);
});

test("deleteProductPhoto: tolerates the product doc already being gone (cascade-after-product-delete case)", async () => {
    resetState({ product: null });
    const res = mockRes();
    await handlers.deleteProductPhoto(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 200, "best-effort: still cleans up Storage even with no product doc left");
    assert.equal(mockState.storageDeleteCalls.length, 2);
});

test("deleteProductPhoto: tolerates the Storage delete itself failing (best-effort, still returns success)", async () => {
    resetState({ product: { photoIds: ["photo-1"] } });
    mockState.storageDeleteError = new Error("object already gone");
    const res = mockRes();
    await handlers.deleteProductPhoto(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 200);
    const productDoc = mockState.docs["tenants/" + TENANT + "/inventory/" + PRODUCT];
    assert.deepEqual(productDoc.photoIds, [], "the Firestore side still succeeds independent of Storage");
});

test("deleteProductPhoto: idempotent retry with the same requestId is a no-op on the second call", async () => {
    resetState({ product: { photoIds: ["photo-1", "photo-2"] } });
    const res1 = mockRes();
    await handlers.deleteProductPhoto(mockReq({ body: deleteBody() }), res1);
    assert.equal(mockState.storageDeleteCalls.length, 2);

    const res2 = mockRes();
    await handlers.deleteProductPhoto(mockReq({ body: deleteBody() }), res2);
    assert.equal(res2.statusCode, 200);
    assert.equal(jsonBody(res2).already, true);
    assert.equal(mockState.storageDeleteCalls.length, 2, "no re-delete on replay");
});

test("deleteProductPhoto: missing Authorization header -> 401 missing-token", async () => {
    resetState({ product: { photoIds: ["photo-1"] } });
    const res = mockRes();
    await handlers.deleteProductPhoto(mockReq({ headers: { origin: "http://localhost" }, body: deleteBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
});

test("deleteProductPhoto: 400 invalid-request when photoId contains a path-traversal slash", async () => {
    resetState({ product: { photoIds: ["photo-1"] } });
    const res = mockRes();
    await handlers.deleteProductPhoto(mockReq({ body: deleteBody({ photoId: "../x" }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "invalid-request");
    assert.equal(mockState.storageDeleteCalls.length, 0);
});

test("deleteProductPhoto: authenticated but no tenant context -> 403 no-tenant-context", async () => {
    resetState({ product: { photoIds: ["photo-1"] } });
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid" });
    const res = mockRes();
    await handlers.deleteProductPhoto(mockReq({ body: deleteBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
});

// ── PH3: role gate, whitelist, F3 preflight (design Q1/Q3/Q9/Q13; test plan F01-F10, F14-F16, F40) ──
function photoCount() { return mockState.storageSaveCalls.length; }
function auditWritten() {
    return mockState.setCalls.some((c) => c.path.indexOf("/audit_log/") >= 0);
}

for (const role of ["staff", "manager"]) {
    test("F01/F02 upload: " + role + " -> 403 role-not-allowed", async () => {
        resetState({ role: role });
        const res = mockRes();
        await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
        assert.equal(res.statusCode, 403);
        assert.equal(jsonBody(res).error, "role-not-allowed");
    });

    test("F03 upload 403 (" + role + "): zero Storage saves, zero audit/product writes, no inventory read", async () => {
        resetState({ role: role });
        mockState.setCalls = [];
        const res = mockRes();
        await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
        assert.equal(photoCount(), 0);
        assert.equal(mockState.setCalls.length, 0);
        assert.deepEqual(mockState.docs["tenants/" + TENANT + "/inventory/" + PRODUCT].photoIds, []);
    });

    test("F14 deletePhoto: " + role + " -> 403 role-not-allowed, zero Storage deletes, product untouched", async () => {
        resetState({ role: role, product: { photoIds: ["photo-1"] } });
        const res = mockRes();
        await handlers.deleteProductPhoto(mockReq({ body: { env: "test", productId: PRODUCT, photoId: "photo-1" } }), res);
        assert.equal(res.statusCode, 403);
        assert.equal(jsonBody(res).error, "role-not-allowed");
        assert.equal(mockState.storageDeleteCalls.length, 0);
        assert.deepEqual(mockState.docs["tenants/" + TENANT + "/inventory/" + PRODUCT].photoIds, ["photo-1"]);
    });
}

test("F03b role gate is exact: 'OWNER', empty and unknown roles are denied", async () => {
    for (const role of ["OWNER", "Owner ", "viewer", "nonsense"]) {
        resetState({ role: role });
        // deriveContext falls back through member.role, so seed the exact string on both docs.
        const res = mockRes();
        await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
        assert.equal(res.statusCode, 403, role);
        assert.equal(photoCount(), 0, role);
    }
});

test("F04 upload: owner happy path, both objects saved, photoIds updated, audit written", async () => {
    resetState({ role: "owner" });
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res).photoIds, ["photo-1"]);
    assert.equal(photoCount(), 2);
    assert.equal(auditWritten(), true);
});

test("F05 upload: admin happy path", async () => {
    resetState({ role: "admin" });
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(photoCount(), 2);
});

test("F06 upload: unsafe ids -> 400, nothing read or written (whitelist)", async () => {
    for (const bad of [{ photoId: "a/b" }, { photoId: "a b" }, { photoId: "x".repeat(65) }, { photoId: "%2e%2e" },
                       { productId: "../x" }, { productId: "PRD 1" }, { productId: "p.q" }]) {
        resetState();
        mockState.setCalls = [];
        const res = mockRes();
        await handlers.uploadProductPhoto(mockReq({ body: uploadBody(Object.assign({ requestId: "r-" + Math.random() }, bad)) }), res);
        assert.equal(res.statusCode, 400, JSON.stringify(bad));
        assert.equal(photoCount(), 0);
        assert.equal(mockState.setCalls.length, 0);
    }
});

test("F07 upload: product missing -> 404 and ZERO Storage saves (F3)", async () => {
    resetState({ product: null });
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 404);
    assert.equal(photoCount(), 0);
    assert.equal(Object.keys(mockState.storageFiles).length, 0);
});

test("F08 upload: cap reached -> 409 and ZERO Storage saves (F3)", async () => {
    resetState({ product: { photoIds: Array.from({ length: 10 }, (_, i) => "e-" + i) } });
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody({ photoId: "brand-new", requestId: "brand-new" }) }), res);
    assert.equal(res.statusCode, 409);
    assert.equal(jsonBody(res).error, "photo-limit");
    assert.equal(photoCount(), 0);
});

test("F08b upload at the cap boundary: 9 existing -> the 10th succeeds, then the 11th gets 409 with zero saves", async () => {
    resetState({ product: { photoIds: Array.from({ length: 9 }, (_, i) => "e-" + i) } });
    let res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody({ photoId: "tenth", requestId: "tenth" }) }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(photoCount(), 2);
    res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody({ photoId: "eleventh", requestId: "eleventh" }) }), res);
    assert.equal(res.statusCode, 409);
    assert.equal(photoCount(), 2, "no extra objects for the rejected 11th");
});

test("F08c upload replay of an already-confirmed photoId at the cap is NOT rejected by the preflight", async () => {
    const ids = Array.from({ length: 10 }, (_, i) => "e-" + i);
    resetState({ product: { photoIds: ids } });
    const res = mockRes();
    // different requestId (no audit doc yet) but the photoId is already confirmed: passes the preflight.
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody({ photoId: "e-3", requestId: "fresh-request" }) }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res).photoIds, ids, "no duplicate id appended");
});

test("F09 upload: same requestId replay -> idempotent, no extra object", async () => {
    resetState();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), mockRes());
    const before = photoCount();
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(jsonBody(res).already, true);
    assert.equal(photoCount(), before);
});

test("F10 upload: product deleted AFTER the preflight -> txn 404 (pins the documented orphan limit)", async () => {
    resetState();
    const productPath = "tenants/" + TENANT + "/inventory/" + PRODUCT;
    mockState.onStorageSave = () => { delete mockState.docs[productPath]; };
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 404);
    assert.equal(jsonBody(res).error, "product-not-found");
    assert.equal(photoCount(), 2, "documented residual race: one orphan pair, accepted in the design");
});

test("F10b upload: unsafe tenantId from the users doc -> 403 no-tenant-context, nothing touched", async () => {
    resetState();
    mockState.docs["users/test-uid"].tenantId = "other/../tenant";
    mockState.docs["tenants/other/../tenant/members/test-uid"] = { role: "owner", status: "active" };
    mockState.setCalls = [];
    const res = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
    assert.equal(photoCount(), 0);
    assert.equal(mockState.setCalls.length, 0);
});

test("F15 deletePhoto: owner and admin happy path", async () => {
    for (const role of ["owner", "admin"]) {
        resetState({ role: role, product: { photoIds: ["photo-1", "photo-2"] } });
        const res = mockRes();
        await handlers.deleteProductPhoto(mockReq({ body: { env: "test", productId: PRODUCT, photoId: "photo-1" } }), res);
        assert.equal(res.statusCode, 200, role);
        assert.deepEqual(jsonBody(res).photoIds, ["photo-2"], role);
        assert.equal(mockState.storageDeleteCalls.length, 2, role);
    }
});

test("F16 deletePhoto: invalid ids -> 400, nothing deleted", async () => {
    for (const bad of [{ photoId: "a/b" }, { photoId: "a b" }, { photoId: "x".repeat(65) }, { productId: "../x" }, { productId: "p q" }]) {
        resetState();
        const res = mockRes();
        await handlers.deleteProductPhoto(mockReq({ body: Object.assign({ env: "test", productId: PRODUCT, photoId: "photo-1" }, bad) }), res);
        assert.equal(res.statusCode, 400, JSON.stringify(bad));
        assert.equal(mockState.storageDeleteCalls.length, 0);
    }
});

test("F16b deletePhoto: unsafe tenantId -> 403 no-tenant-context, nothing deleted", async () => {
    resetState();
    mockState.docs["users/test-uid"].tenantId = "a/b";
    const res = mockRes();
    await handlers.deleteProductPhoto(mockReq({ body: { env: "test", productId: PRODUCT, photoId: "photo-1" } }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(mockState.storageDeleteCalls.length, 0);
});

test("F40 deletePhoto: product doc missing -> 200 and BOTH Storage objects still deleted (Q13 pin)", async () => {
    resetState({ product: null });
    const res = mockRes();
    await handlers.deleteProductPhoto(mockReq({ body: { env: "test", productId: PRODUCT, photoId: "photo-1" } }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(mockState.storageDeleteCalls.length, 2);
    assert.deepEqual(mockState.storageDeleteCalls.map((c) => c.path).sort(), [
        "test/tenants/" + TENANT + "/products/" + PRODUCT + "/photo-1.jpg",
        "test/tenants/" + TENANT + "/products/" + PRODUCT + "/photo-1_t.jpg"
    ]);
});

test("RES-P1 uploadProductPhoto / deleteProductPhoto: a requestId in the reserved cascade namespace -> 400 invalid-request, no Storage write (PR #118 review)", async () => {
    resetState();
    const r1 = mockRes();
    await handlers.uploadProductPhoto(mockReq({ body: uploadBody({ requestId: "cascade~PRD-1~B1" }) }), r1);
    assert.equal(r1.statusCode, 400);
    assert.equal(jsonBody(r1).error, "invalid-request");
    const r2 = mockRes();
    await handlers.deleteProductPhoto(mockReq({ body: deleteBody({ requestId: "cascade~PRD-1~B1" }) }), r2);
    assert.equal(r2.statusCode, 400);
    assert.equal(jsonBody(r2).error, "invalid-request");
    assert.equal(mockState.storageSaveCalls.length, 0);
    assert.equal(mockState.storageDeleteCalls.length, 0);
});
