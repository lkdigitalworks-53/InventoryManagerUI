import QtQuick
import QtTest
import "../../qml/model"
import "E2EHelpers.js" as E2EHelpers

// E2E — product photos in Firebase Storage, against the real Firebase Local Emulator Suite
// (Firestore + Auth + Functions + Storage). Design:
// docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md
// Plan: docs/superpowers/plans/2026-09-21-product-photos-firebase-storage.md Task 13
//
// WHAT THIS DOES NOT COVER, AND WHY: the client's real upload path is StorageService.
// addProductPhoto -> NativeFile.toReadablePath/ImageProcessor.compressForUpload+persistLocalCopy
// -> PhotoQueue.enqueue -> PhotoQueue._upload -> NativeFile.readFileBase64 -> XHR. NativeFile and
// ImageProcessor are root context properties (main.cpp setContextProperty), not QML singletons --
// undefined under qmltestrunner, same as every other place this feature (and StorageService
// before it) hits this wall. There is no way to exercise that client-side path from any automated
// test in this repository; a real device build is the only proof for it.
//
// What this DOES cover: the server side, end to end, exactly the way tst_InventoryE2E.qml's own
// test_recordMutation_function_accepts_seeded_credentials diagnostic already bypasses Gateway/
// OutboxStore with a raw POST to prove the function itself, independent of the client machinery
// that would normally call it. Every test below POSTs directly to the emulated
// uploadProductPhoto/deleteProductPhoto functions (E2EHelpers.postDirect, same helper, same
// pattern) and verifies against both the Firestore emulator (photoIds on the product doc) and the
// Storage emulator (the actual object), independently of each other and independently of any
// client-side cache -- proving the real server code path, not just that the client's own
// optimistic state looks right.
//
// NOT RUN IN THIS SANDBOX -- no network egress here to Firebase's emulator distribution, same as
// every other file in this directory before its first real CI attempt.
TestCase {
    name: "ProductPhotosE2E"

    readonly property string emulatorFirestoreHost: "http://127.0.0.1:8080"
    readonly property string emulatorFunctionsBase: "http://127.0.0.1:5001/inventorymanager-48392/asia-south1"
    readonly property string emulatorStorageHost: "http://127.0.0.1:9199"
    readonly property string bucket: "inventorymanager-48392.firebasestorage.app"
    readonly property string realUploadUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/uploadProductPhoto"
    readonly property string realDeleteUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/deleteProductPhoto"

    // 1x1 white-pixel JPEG, base64 -- small, real, and passes photoValidation's JPEG-magic-byte
    // check without needing an actual asset file on disk (this directory's XHR file:// reads need
    // QML_XHR_ALLOW_FILE_READ, already required for .fixture.json -- a literal constant here
    // avoids adding a second file dependency for one tiny fixture image).
    readonly property string tinyJpegBase64: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAj/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCdABmX/9k="
    readonly property string notJpegBase64: "AAECAw=="

    property var fixture: null
    readonly property string fixtureUrl: Qt.resolvedUrl("../../test/e2e/.fixture.json")

    function _loadFixture() {
        return E2EHelpers.loadFixture(this, fixtureUrl)
    }
    function _postDirect(url, payload, timeoutMs, timeoutMessage) {
        return E2EHelpers.postDirect(this, url, payload, timeoutMs, timeoutMessage)
    }
    function _pollDoc(docPath, entityId, predicateFn, timeoutMs, message) {
        return E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, docPath, entityId,
                                           predicateFn, timeoutMs, message)
    }
    function _pollStorageObject(objectPath, timeoutMs, message) {
        return E2EHelpers.pollEmulatorStorageObject(this, emulatorStorageHost, bucket,
                                                      objectPath, timeoutMs, message)
    }
    function _pollStorageObjectAbsent(objectPath, timeoutMs, message) {
        E2EHelpers.pollEmulatorStorageObjectAbsent(this, emulatorStorageHost, bucket,
                                                     objectPath, timeoutMs, message)
    }

    function initTestCase() {
        fixture = _loadFixture()

        // Same construction-order fix tst_InventoryE2E.qml's initTestCase() documents at length:
        // AuthService's Component.onCompleted calls AuthStore.loadSession() -> clear()
        // unconditionally, the FIRST time AuthService is referenced at all. PhotoQueue.drainNow()
        // now calls AuthService.ensureFreshToken() (added during this feature's own review sweep)
        // -- if that turned out to be AuthService's first reference in a run, it would fire
        // construction AFTER init() already set a real idToken, wiping it. This file doesn't
        // currently call drainNow() itself (see the file header for why), but forces the same
        // construction here anyway, defensively, since qmltestrunner does not guarantee ordering
        // across files and a future addition to this file easily could call it.
        AuthService.ensureFreshToken() // no-op (not authenticated yet); forces construction only

        // uploadProductPhoto and deleteProductPhoto are separate Cloud Functions from
        // recordMutation -- the emulator cold-starts each one independently, on its own first
        // invocation (documented at length in tst_InventoryE2E.qml's initTestCase() for
        // recordMutation specifically; the same mechanism applies here). Warming up
        // recordMutation elsewhere in the suite does not warm these up. Pay both cold starts
        // here, once, with real payloads against a product that doesn't exist -- doubles as an
        // early smoke check that both functions are reachable and returning the expected shape,
        // not just "some" response.
        var warmupProductId = "warmup-product-" + Date.now()
        var warmupPhotoId = "warmup-photo-" + Date.now()
        var uploadResult = _postDirect(emulatorFunctionsBase + "/uploadProductPhoto", {
            env: "prd", productId: warmupProductId, photoId: warmupPhotoId, requestId: warmupPhotoId,
            imageBase64: tinyJpegBase64, thumbBase64: tinyJpegBase64
        }, 20000, "Cloud Functions emulator never responded to the uploadProductPhoto warm-up call")
        compare(uploadResult.status, 404,
                "uploadProductPhoto warm-up expected product-not-found (warmupProductId was never "
                + "created on purpose) -- got: " + uploadResult.text)

        var deleteResult = _postDirect(emulatorFunctionsBase + "/deleteProductPhoto", {
            env: "prd", productId: warmupProductId, photoId: warmupPhotoId, requestId: "del-" + warmupPhotoId
        }, 20000, "Cloud Functions emulator never responded to the deleteProductPhoto warm-up call")
        compare(deleteResult.status, 200,
                "deleteProductPhoto warm-up rejected -- response: " + deleteResult.text
                + " (deleteProductPhoto tolerates a missing product doc by design, so this should "
                + "always be 200, unlike the upload warm-up above)")
    }

    function init() {
        fixture = _loadFixture()
        FirebaseService.emulatorHost = emulatorFirestoreHost
        AuthStore.idToken = fixture.idToken
        AuthStore.uid = fixture.uid
        AuthStore.tenantId = fixture.tenantId
        InventoryStore.products = []
    }

    function cleanup() {
        FirebaseService.emulatorHost = ""
        AuthStore.idToken = ""
        AuthStore.tenantId = ""
    }

    function _createProduct(name, sku) {
        var createdId = "", done = false
        InventoryStore.addProduct(
            name, sku, "General", "", 100, "pc", 10, 2,
            120, false, 0, fixture.supplierName, 80, "",
            function(ok, id) { done = true; createdId = ok ? id : "" }
        )
        tryVerify(function() { return done }, 5000, "addProduct callback never fired")
        verify(createdId.length > 0, "addProduct did not return a productId")
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + createdId
        _pollDoc(docPath, createdId, function(d) { return d !== null }, 5000,
                 "product doc never appeared before the photo test could run")
        return createdId
    }

    function _uploadPhoto(productId, photoId) {
        return _postDirect(emulatorFunctionsBase + "/uploadProductPhoto", {
            env: "prd", productId: productId, photoId: photoId, requestId: photoId,
            imageBase64: tinyJpegBase64, thumbBase64: tinyJpegBase64
        }, 10000, "uploadProductPhoto never responded")
    }

    // ── uploadProductPhoto: the real server path, end to end ───────────────

    function test_upload_writes_the_storage_objects_and_appends_photoIds() {
        var productId = _createProduct("E2E Photo Widget", "SKU-E2E-PHOTO-1")
        var photoId = "e2e-photo-" + Date.now()

        var result = _uploadPhoto(productId, photoId)
        compare(result.status, 200, "uploadProductPhoto rejected the request -- response: " + result.text)
        var parsed = JSON.parse(result.text)
        compare(parsed.photoIds.length, 1)
        compare(parsed.photoIds[0], photoId)

        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + productId
        var doc = _pollDoc(docPath, productId, function(d) {
            return d !== null && d.fields.photoIds && d.fields.photoIds.arrayValue
                && d.fields.photoIds.arrayValue.values
                && d.fields.photoIds.arrayValue.values.length === 1
        }, 5000, "photoIds never appeared on the product doc in the emulator")
        compare(doc.fields.photoIds.arrayValue.values[0].stringValue, photoId)

        var mainPath = "prd/tenants/" + fixture.tenantId + "/products/" + productId + "/" + photoId + ".jpg"
        var thumbPath = "prd/tenants/" + fixture.tenantId + "/products/" + productId + "/" + photoId + "_t.jpg"
        _pollStorageObject(mainPath, 5000, "main photo object never appeared in the Storage emulator")
        _pollStorageObject(thumbPath, 5000, "thumbnail photo object never appeared in the Storage emulator")
    }

    function test_upload_is_idempotent_on_replay() {
        var productId = _createProduct("E2E Photo Idempotent", "SKU-E2E-PHOTO-2")
        var photoId = "e2e-photo-replay-" + Date.now()

        var first = _uploadPhoto(productId, photoId)
        compare(first.status, 200, "first upload rejected -- response: " + first.text)

        var second = _uploadPhoto(productId, photoId)
        compare(second.status, 200, "replay rejected -- response: " + second.text)
        var parsedSecond = JSON.parse(second.text)
        compare(parsedSecond.already, true, "a replay with the same requestId must report already:true")
        compare(parsedSecond.photoIds.length, 1, "a replay must not duplicate the id")
    }

    function test_upload_rejects_a_non_jpeg_payload() {
        var productId = _createProduct("E2E Photo Bad Image", "SKU-E2E-PHOTO-3")
        var result = _postDirect(emulatorFunctionsBase + "/uploadProductPhoto", {
            env: "prd", productId: productId, photoId: "e2e-bad-" + Date.now(),
            requestId: "e2e-bad-" + Date.now(),
            imageBase64: notJpegBase64, thumbBase64: notJpegBase64
        }, 10000, "uploadProductPhoto never responded to the bad-image request")
        compare(result.status, 400)
        compare(JSON.parse(result.text).error, "invalid-image")
    }

    function test_upload_rejects_a_productId_containing_a_path_traversal_slash() {
        // Regression test for the path-traversal fix found in this feature's own review sweep
        // (PhotoValidation.isSafePathSegment) -- proves the real deployed function rejects it,
        // not just the mocked handlerHarness unit tests.
        var result = _postDirect(emulatorFunctionsBase + "/uploadProductPhoto", {
            env: "prd", productId: "../other-tenant/inventory/x", photoId: "e2e-traversal-" + Date.now(),
            requestId: "e2e-traversal-" + Date.now(),
            imageBase64: tinyJpegBase64, thumbBase64: tinyJpegBase64
        }, 10000, "uploadProductPhoto never responded to the traversal-id request")
        compare(result.status, 400)
        compare(JSON.parse(result.text).error, "invalid-request")
    }

    function test_upload_rejects_an_eleventh_photo() {
        var productId = _createProduct("E2E Photo Limit", "SKU-E2E-PHOTO-4")
        for (var i = 0; i < 10; ++i) {
            var r = _uploadPhoto(productId, "e2e-limit-" + i + "-" + Date.now())
            compare(r.status, 200, "photo " + i + " of 10 was rejected -- response: " + r.text)
        }
        var eleventh = _uploadPhoto(productId, "e2e-limit-11th-" + Date.now())
        compare(eleventh.status, 409)
        compare(JSON.parse(eleventh.text).error, "photo-limit")
    }

    // ── deleteProductPhoto: the real server path, end to end ───────────────

    function test_delete_removes_the_id_and_both_storage_objects() {
        var productId = _createProduct("E2E Photo Delete", "SKU-E2E-PHOTO-5")
        var photoId = "e2e-photo-delete-" + Date.now()
        var uploadResult = _uploadPhoto(productId, photoId)
        compare(uploadResult.status, 200, "setup upload failed -- response: " + uploadResult.text)

        var mainPath = "prd/tenants/" + fixture.tenantId + "/products/" + productId + "/" + photoId + ".jpg"
        var thumbPath = "prd/tenants/" + fixture.tenantId + "/products/" + productId + "/" + photoId + "_t.jpg"
        _pollStorageObject(mainPath, 5000, "setup: main object never appeared before delete")

        var deleteResult = _postDirect(emulatorFunctionsBase + "/deleteProductPhoto", {
            env: "prd", productId: productId, photoId: photoId, requestId: "del-" + photoId
        }, 10000, "deleteProductPhoto never responded")
        compare(deleteResult.status, 200, "deleteProductPhoto rejected -- response: " + deleteResult.text)
        compare(JSON.parse(deleteResult.text).photoIds.length, 0)

        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + productId
        var doc = _pollDoc(docPath, productId, function(d) {
            return d !== null && (!d.fields.photoIds || !d.fields.photoIds.arrayValue.values
                || d.fields.photoIds.arrayValue.values.length === 0)
        }, 5000, "photoIds never emptied on the product doc after delete")

        _pollStorageObjectAbsent(mainPath, 5000, "main object was not actually deleted from Storage")
        _pollStorageObjectAbsent(thumbPath, 5000, "thumbnail object was not actually deleted from Storage")
    }

    function test_delete_tolerates_removing_an_id_that_is_already_absent() {
        var productId = _createProduct("E2E Photo Delete Noop", "SKU-E2E-PHOTO-6")
        var result = _postDirect(emulatorFunctionsBase + "/deleteProductPhoto", {
            env: "prd", productId: productId, photoId: "never-existed-" + Date.now(),
            requestId: "del-never-existed-" + Date.now()
        }, 10000, "deleteProductPhoto never responded to the no-such-id request")
        compare(result.status, 200, "removing an absent id must be a no-op, not an error -- response: " + result.text)
    }
}
