import QtQuick
import QtQuick.Layouts
import QtTest

// PR #84 arrangement rework (2026-09-29): ProductPhotoGallery.qml moved from a wrapping Flow grid
// to a horizontal filmstrip ListView with a fixed + tile pinned outside it. It imports Felgo
// (dp()/sp()/Icon) and can't load under qmltestrunner, so this file proves the two load-bearing
// pieces of logic separately: (1) `_refreshAll`'s combined-array construction, mirrored as pure
// JS -- decisive, no delegate/`index`-injection ambiguity to reproduce, unlike the old
// `index === 0` cover check this replaces; (2) the RowLayout+ListView+fixed-tile composition,
// reproduced with real Qt layout types at the gallery's own sizes, proving the + tile's position
// never depends on scroll content. The rounded-corner mask (RoundedThumb.qml, MultiEffect) has no
// meaningful non-visual assertion and is on-device/visual-only -- see the test plan.
// NOT RUN IN THIS SANDBOX (no Qt toolchain, standing instruction) -- CI is the proof.
TestCase {
    id: tc
    name: "PhotoGalleryLayout"
    visible: true
    width: 320; height: 400

    // ── Mirrors of ProductPhotoGallery.qml's own logic ───────────────────
    function buildCombined(photoIds, queued) {
        var out = []
        for (var c = 0; c < photoIds.length; ++c)
            out.push({ kind: "confirmed", photoId: photoIds[c], isCover: c === 0 })
        for (var j = 0; j < queued.length; ++j)
            out.push({ kind: "queued", item: queued[j] })
        return out
    }
    function hasFailedQueued(queued) {
        for (var i = 0; i < queued.length; ++i)
            if (queued[i].state === "failed") return true
        return false
    }
    function rowHeight(tileSize, failedExtra, queued) {
        return tileSize + (hasFailedQueued(queued) ? failedExtra : 0)
    }

    // ── Combined-array ordering and cover flag ────────────────────────────
    function test_confirmed_photos_come_first_cover_first() {
        var out = buildCombined(["a", "b", "c"], [])
        compare(out.length, 3)
        compare(out[0].photoId, "a"); verify(out[0].isCover)
        verify(!out[1].isCover); verify(!out[2].isCover)
    }

    function test_exactly_one_cover_regardless_of_count() {
        for (var n = 1; n <= 10; ++n) {
            var ids = []
            for (var i = 0; i < n; ++i) ids.push("p" + i)
            var out = buildCombined(ids, [])
            var covers = out.filter(function(x) { return x.isCover }).length
            compare(covers, 1, n + " photos -> exactly one cover")
        }
    }

    function test_cover_moves_to_new_first_after_removal() {
        var out = buildCombined(["b", "c"], [])   // "a" already removed by the caller
        verify(out[0].isCover)
        compare(out[0].photoId, "b")
    }

    function test_queued_items_appended_after_all_confirmed() {
        var out = buildCombined(["a", "b"], [{ photoId: "q1", state: "uploading" }, { photoId: "q2", state: "failed" }])
        compare(out.length, 4)
        compare(out[0].kind, "confirmed"); compare(out[1].kind, "confirmed")
        compare(out[2].kind, "queued"); compare(out[2].item.photoId, "q1")
        compare(out[3].kind, "queued"); compare(out[3].item.photoId, "q2")
    }

    function test_no_confirmed_photos_no_cover_queued_only() {
        var out = buildCombined([], [{ photoId: "q1", state: "uploading" }])
        compare(out.length, 1)
        compare(out[0].kind, "queued")
    }

    function test_empty_everything() {
        compare(buildCombined([], []).length, 0)
    }

    // ── Row-height formula (failed tile grows a Retry/Discard row below it) ─
    function test_row_height_no_failed_items() {
        compare(rowHeight(72, 48, [{ state: "uploading" }, { state: "enqueued" }]), 72)
    }
    function test_row_height_one_failed_item() {
        compare(rowHeight(72, 48, [{ state: "uploading" }, { state: "failed" }]), 120)
    }
    function test_row_height_multiple_failed_still_one_row_taller() {
        // A boolean flag, not a count -- N failed tiles still only need ONE extra row height,
        // since they're side by side in the same horizontal row, not stacked.
        compare(rowHeight(72, 48, [{ state: "failed" }, { state: "failed" }, { state: "failed" }]), 120)
    }
    function test_row_height_empty_queue() {
        compare(rowHeight(72, 48, []), 72)
    }

    // ── Fixed + tile: real RowLayout + horizontal ListView composition ────
    // Reproduces ProductPhotoGallery's own structure (filmRow: [ListView Layout.fillWidth][+ tile
    // Layout.preferredWidth]) at its own tile size, proving the + tile's box is allocated by the
    // RowLayout itself and never depends on how much content is in the ListView or how far it's
    // scrolled -- the guarantee the 2026-09-28 test plan asked for when it rejected a scrollable +
    // tile.
    Item {
        id: filmHost
        width: 300
        property int tiles: 5
        property bool addTile: true
        RowLayout {
            id: filmRow
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 8
            ListView {
                id: filmList
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                orientation: ListView.Horizontal
                clip: true
                spacing: 8
                model: filmHost.tiles
                delegate: Rectangle { width: 72; height: 72 }
            }
            Rectangle {
                id: addTileItem
                visible: filmHost.addTile
                Layout.preferredWidth: 72
                Layout.preferredHeight: 72
            }
        }
    }

    function _settle() { wait(60) }   // layouts/positioners relay out on the next polish pass

    function init() {
        filmHost.width = 300
        filmHost.tiles = 5
        filmHost.addTile = true
        _settle()
    }

    function test_add_tile_always_fully_inside_the_container_width() {
        verify(addTileItem.x >= 0 && addTileItem.x + addTileItem.width <= filmHost.width + 0.5,
               "+ tile inside the visible width, not pushed off by scroll content")
    }

    function test_add_tile_position_independent_of_photo_count() {
        filmHost.tiles = 1
        _settle()
        var xFew = addTileItem.x
        filmHost.tiles = 9
        _settle()
        var xMany = addTileItem.x
        compare(xFew, xMany, "+ tile sits at a fixed offset from the right edge either way")
    }

    function test_listview_scrolls_instead_of_pushing_the_add_tile() {
        filmHost.tiles = 9   // 9*72 + 8*8 = 712px of content in a ~220px-wide list
        _settle()
        verify(filmList.contentWidth > filmList.width, "more content than fits -> scrollable")
        verify(addTileItem.x + addTileItem.width <= filmHost.width + 0.5,
               "+ tile still fully visible, unaffected by the overflow")
    }

    function test_no_add_tile_when_read_only() {
        filmHost.addTile = false
        _settle()
        verify(!addTileItem.visible)
    }

    function test_narrow_container_still_keeps_add_tile_inside() {
        filmHost.width = 160
        _settle()
        verify(addTileItem.x + addTileItem.width <= filmHost.width + 0.5)
        filmHost.width = 300
        _settle()
    }

    function test_monkey_random_counts_and_widths_add_tile_never_escapes() {
        // CI failure, 2026-09-29 (PR #84 round 4 push): iteration 31 (tiles=5, addTile visible,
        // width=207px) read a stale addTileItem.x. The geometry itself has comfortable margin at
        // every input this loop generates (RowLayout only ever needs ~80px minimum: 8px spacing +
        // 72px add tile; ListView's own implicitWidth is 0, so it has no floor stopping it
        // shrinking to fit) -- this was every other assertion in this file settling on wait(60)
        // via _settle() while this one alone used a bare wait(10), the only difference between the
        // one loop that failed and the ones that didn't.
        for (var i = 0; i < 100; ++i) {
            filmHost.tiles = (i * 5) % 10
            filmHost.addTile = (i % 5) !== 0
            filmHost.width = 180 + ((i * 37) % 160)   // 180..339 px
            _settle()
            if (addTileItem.visible)
                verify(addTileItem.x + addTileItem.width <= filmHost.width + 0.5, "iteration " + i)
        }
    }
}
