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

    // ── toLocalPath / toFileUrl (PR #84 device-test fix) ────────────────────

    function test_toLocalPath_windows_file_url_becomes_drive_path() {
        compare(PU.toLocalPath("file:///C:/Users/Dell/AppData/Local/Karobar/photos/photo-1.jpg"),
                "C:/Users/Dell/AppData/Local/Karobar/photos/photo-1.jpg")
    }
    function test_toLocalPath_unix_file_url_keeps_leading_slash() {
        compare(PU.toLocalPath("file:///data/user/0/app/photos/p.jpg"), "/data/user/0/app/photos/p.jpg")
    }
    function test_toLocalPath_bare_paths_pass_through() {
        compare(PU.toLocalPath("C:/x/p.jpg"), "C:/x/p.jpg")
        compare(PU.toLocalPath("/data/p.jpg"), "/data/p.jpg")
    }
    function test_toLocalPath_decodes_percent_escapes() {
        compare(PU.toLocalPath("file:///D:/My%20Photos/p.jpg"), "D:/My Photos/p.jpg")
    }
    function test_toLocalPath_malformed_escape_does_not_throw() {
        compare(PU.toLocalPath("file:///D:/100%/p.jpg"), "D:/100%/p.jpg")
    }
    function test_toLocalPath_empty_like_inputs_give_empty_string_data() {
        return [ { tag: "empty", v: "" }, { tag: "null", v: null }, { tag: "undefined", v: undefined },
                 { tag: "number", v: 42 }, { tag: "object", v: {} } ]
    }
    function test_toLocalPath_empty_like_inputs_give_empty_string(data) {
        compare(PU.toLocalPath(data.v), "")
    }
    function test_toLocalPath_is_idempotent() {
        var once = PU.toLocalPath("file:///C:/a/b.jpg")
        compare(PU.toLocalPath(once), once)
    }
    function test_toFileUrl_bare_windows_path() { compare(PU.toFileUrl("C:/a/b.jpg"), "file:///C:/a/b.jpg") }
    function test_toFileUrl_bare_unix_path() { compare(PU.toFileUrl("/data/b.jpg"), "file:///data/b.jpg") }
    function test_toFileUrl_does_not_double_prefix_an_existing_file_url() {
        compare(PU.toFileUrl("file:///C:/a/b.jpg"), "file:///C:/a/b.jpg")
        verify(PU.toFileUrl("file:///C:/a/b.jpg").indexOf("file://file") === -1)
    }
    function test_toFileUrl_escapes_spaces() { compare(PU.toFileUrl("D:/My Photos/b.jpg"), "file:///D:/My%20Photos/b.jpg") }
    function test_toFileUrl_empty_like_input_gives_empty_string() {
        compare(PU.toFileUrl(""), "")
        compare(PU.toFileUrl(null), "")
        compare(PU.toFileUrl(undefined), "")
    }
    function test_toFileUrl_is_idempotent() {
        var once = PU.toFileUrl("C:/a b/c.jpg")
        compare(PU.toFileUrl(once), once)
    }
    function test_monkey_random_path_like_strings_never_throw() {
        var alphabet = "ab /\\%:.C~#?"
        var seed = 7
        for (var i = 0; i < 300; ++i) {
            var s = (i % 2 === 0) ? "file://" : ""
            for (var j = 0; j < (i % 20); ++j) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; s += alphabet.charAt(seed % alphabet.length) }
            PU.toLocalPath(s)
            PU.toFileUrl(s)
        }
        verify(true)
    }
}
