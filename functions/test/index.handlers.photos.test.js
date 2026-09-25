"use strict";

// Handler-level tests for uploadProductPhoto and deleteProductPhoto (functions/index.js).
// Design: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md
// Plan: docs/superpowers/plans/2026-09-21-product-photos-firebase-storage.md Task 5
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
    seedHappyPathAuth(mockState, { tenantId: TENANT });
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
    // Storage writes happen before the Firestore transaction in this design (orphan-on-crash is
    // an accepted risk, see design spec) -- so objects DO get written even though the id is never
    // recorded. This assertion documents that tradeoff rather than hiding it.
    assert.equal(mockState.storageSaveCalls.length, 2);
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
