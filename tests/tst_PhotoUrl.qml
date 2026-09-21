import QtQuick
import QtTest
import "../qml/helper/PhotoUrl.js" as PU

// Headless tests for the pure product-photo download URL builder. Pure JS, no singletons.
// Design: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md
// A plain-Node mirror of this same logic runs for real under node --test
// (functions/test/photoUrl.parity.test.js) -- this file proves the QML copy stays in sync and
// loads correctly, verified by CI (qmltestrunner is not available in this sandbox).
TestCase {
    name: "PhotoUrl"

    property var base: ({
        bucket: "inventorymanager-48392.firebasestorage.app",
        env: "prd",
        tenantId: "tenant1",
        productId: "prod1",
        photoId: "abc123"
    })

    function _merge(overrides) {
        var out = {}
        for (var k in base) out[k] = base[k]
        for (var k2 in overrides) out[k2] = overrides[k2]
        return out
    }

    function test_builds_the_main_image_public_download_url() {
        var url = PU.buildPhotoDownloadUrl(base)
        compare(url,
            "https://firebasestorage.googleapis.com/v0/b/inventorymanager-48392.firebasestorage.app/o/" +
            "prd%2Ftenants%2Ftenant1%2Fproducts%2Fprod1%2Fabc123.jpg?alt=media")
    }

    function test_builds_the_thumbnail_url_with_the_t_suffix_when_thumb_is_true() {
        var url = PU.buildPhotoDownloadUrl(_merge({ thumb: true }))
        verify(url.indexOf("abc123_t.jpg?alt=media") === url.length - "abc123_t.jpg?alt=media".length)
    }

    function test_url_encodes_slashes_in_the_path() {
        var url = PU.buildPhotoDownloadUrl(base)
        var count = (url.match(/%2F/g) || []).length
        compare(count, 5)
        verify(url.indexOf("/o/prd/tenants") === -1)
    }

    function test_differs_by_env_so_prd_test_dev1_never_collide() {
        var prd = PU.buildPhotoDownloadUrl(base)
        var testEnv = PU.buildPhotoDownloadUrl(_merge({ env: "test" }))
        var dev1 = PU.buildPhotoDownloadUrl(_merge({ env: "dev1" }))
        verify(prd !== testEnv)
        verify(prd !== dev1)
        verify(testEnv !== dev1)
    }

    function test_throws_on_a_missing_required_field() {
        var threw = false
        try { PU.buildPhotoDownloadUrl(_merge({ photoId: undefined })) }
        catch (e) { threw = true }
        verify(threw, "missing photoId should throw")

        threw = false
        try { PU.buildPhotoDownloadUrl(_merge({ tenantId: "" })) }
        catch (e) { threw = true }
        verify(threw, "empty tenantId should throw")
    }

    function test_main_and_thumb_urls_for_the_same_photo_differ_only_by_suffix() {
        var main = PU.buildPhotoDownloadUrl(base)
        var thumb = PU.buildPhotoDownloadUrl(_merge({ thumb: true }))
        verify(main !== thumb)
        compare(main.replace(".jpg", "_t.jpg"), thumb)
    }
}
