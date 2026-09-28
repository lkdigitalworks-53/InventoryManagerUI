import QtQuick
import QtTest

// PR #84 device-test bugs 1 and 4 (2026-09-28), as decisive experiments in the style of
// tst_RepeaterModelReactivity.qml. ProductPhotoGallery.qml imports Felgo (dp()/sp()/Icon) and can't
// load under qmltestrunner, so these reproduce ITS structure with plain QtQuick and fixed sizes.
// They prove the Qt semantics the fix relies on; they do not load the real file. The real gallery
// is covered by the on-device section of docs/superpowers/test-plans/2026-09-28-photo-gallery-
// cover-scroll-list-test-plan.md.
// NOT RUN IN THIS SANDBOX (no Qt toolchain, standing instruction) -- CI is the proof.
TestCase {
    id: tc
    name: "PhotoGalleryLayout"
    visible: true
    width: 320; height: 400

    // ── Bug 1: "Cover" label on every tile ───────────────────────────────
    // Fixed pattern: the delegate declares `required property int index`, exactly as the gallery
    // does now. (Without that declaration Qt does not inject `index` once a delegate has any
    // required property, `index === 0` throws, and `visible` keeps its default of true.)
    Item {
        id: coverHost
        width: 300; height: 100
        property var ids: ["a", "b", "c", "d", "e"]
        Row {
            Repeater {
                id: coverRepeater
                model: coverHost.ids
                delegate: Rectangle {
                    required property string modelData
                    required property int index
                    width: 20; height: 20
                    property alias coverLabel: label
                    Rectangle { id: label; visible: index === 0; width: 5; height: 5 }
                }
            }
        }
    }

    function _coverCount() {
        var n = 0
        for (var i = 0; i < coverRepeater.count; ++i)
            if (coverRepeater.itemAt(i).coverLabel.visible) n++
        return n
    }

    function test_cover_label_shows_on_the_first_tile_only() {
        compare(coverRepeater.count, 5)
        compare(_coverCount(), 1, "exactly one Cover label")
        verify(coverRepeater.itemAt(0).coverLabel.visible, "on the first tile")
        for (var i = 1; i < coverRepeater.count; ++i)
            verify(!coverRepeater.itemAt(i).coverLabel.visible, "not on tile #" + i)
    }

    function test_cover_label_single_photo_still_covers_it() {
        coverHost.ids = ["only"]
        compare(coverRepeater.count, 1)
        compare(_coverCount(), 1)
    }

    function test_cover_label_no_photos_no_label() {
        coverHost.ids = []
        compare(coverRepeater.count, 0)
    }

    function test_cover_label_moves_to_new_first_after_the_cover_is_removed() {
        coverHost.ids = ["a", "b", "c"]
        coverHost.ids = ["b", "c"]
        compare(_coverCount(), 1)
        compare(coverRepeater.itemAt(0).modelData, "b")
        verify(coverRepeater.itemAt(0).coverLabel.visible)
    }

    // ── Bug 4: strip ran off-screen, + tile unreachable ──────────────────
    // Flow with the gallery's tile size (72) and spacing (8) at a phone-ish 300 px content width.
    Item {
        id: flowHost
        width: 300
        implicitHeight: strip.implicitHeight
        property int tiles: 5
        property bool addTile: true
        property int wideFailedTiles: 0
        Flow {
            id: strip
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 8
            Repeater {
                id: tileRepeater
                model: flowHost.tiles
                delegate: Rectangle { width: 72; height: 72 }
            }
            Repeater {
                id: wideRepeater
                model: flowHost.wideFailedTiles
                delegate: Rectangle { width: 160; height: 72 + 8 + 40 }
            }
            Rectangle { id: addTileItem; visible: flowHost.addTile; width: 72; height: 72 }
        }
    }

    function _allInsideWidth() {
        for (var i = 0; i < strip.children.length; ++i) {
            var c = strip.children[i]
            if (!c.visible || c.width === 0) continue
            if (c.x < 0 || c.x + c.width > flowHost.width + 0.5) return false
        }
        return true
    }

    // Positioners re-lay-out on the next polish pass, not synchronously with the property change.
    function _settle() { wait(60) }

    function init() {
        flowHost.width = 300
        flowHost.tiles = 5
        flowHost.addTile = true
        flowHost.wideFailedTiles = 0
        coverHost.ids = ["a", "b", "c", "d", "e"]
        _settle()
    }

    function test_five_photos_wrap_and_the_add_tile_stays_reachable() {
        // 5 tiles + add tile = 6 items; 3 fit per 300 px row -> 2 rows.
        verify(_allInsideWidth(), "nothing past the right edge (the reported bug)")
        verify(addTileItem.x + addTileItem.width <= flowHost.width, "+ tile inside the visible width")
        compare(flowHost.implicitHeight, 72 * 2 + 8, "two rows")
    }

    function test_ten_photos_wrap_into_rows_without_overflow() {
        flowHost.tiles = 9        // 9 photos + add tile = the 10-item ceiling incl. the + tile
        _settle()
        verify(_allInsideWidth())
        compare(flowHost.implicitHeight, 72 * 4 + 8 * 3, "ten items at 3 per row -> 4 rows")
    }

    function test_single_row_when_it_fits() {
        flowHost.tiles = 2
        _settle()
        compare(flowHost.implicitHeight, 72, "2 tiles + add tile fit one row")
        verify(_allInsideWidth())
    }

    function test_no_photos_only_the_add_tile() {
        flowHost.tiles = 0
        _settle()
        compare(flowHost.implicitHeight, 72)
        compare(addTileItem.x, 0)
    }

    function test_read_only_no_add_tile_no_photos_has_no_height() {
        flowHost.tiles = 0
        flowHost.addTile = false
        _settle()
        compare(flowHost.implicitHeight, 0)
    }

    function test_wide_failed_tile_wraps_instead_of_overflowing() {
        flowHost.tiles = 2
        flowHost.wideFailedTiles = 1
        _settle()
        verify(_allInsideWidth(), "160-wide failed tile with Retry/Discard row stays inside")
    }

    function test_narrow_container_relayouts_live() {
        flowHost.tiles = 3
        flowHost.width = 160       // 2 per row
        _settle()
        verify(_allInsideWidth())
        verify(flowHost.implicitHeight >= 72 * 2 + 8, "grew taller instead of wider")
        flowHost.width = 300
        _settle()
        verify(_allInsideWidth())
    }

    function test_monkey_random_counts_and_widths_never_overflow() {
        for (var i = 0; i < 100; ++i) {
            flowHost.tiles = (i * 5) % 10
            flowHost.wideFailedTiles = (i % 4 === 0) ? 1 : 0
            flowHost.addTile = (i % 5) !== 0
            flowHost.width = 180 + ((i * 37) % 160)      // 180..339 px, always >= widest tile (160)
            wait(10)
            verify(_allInsideWidth(), "iteration " + i)
        }
    }
}
