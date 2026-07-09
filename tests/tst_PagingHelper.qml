import QtQuick
import QtTest
import "../qml/helper/PagingHelper.js" as Paging

TestCase {
    name: "PagingHelper"

    function test_mergePage_exact_page_no_overflow_means_no_more() {
        // Requested limit 3, over-fetch was limit+1=4, but only 3 came back
        // -> that really was everything.
        var r = Paging.mergePage([], [{id:1},{id:2},{id:3}], 3)
        compare(r.items.length, 3)
        compare(r.hasMore, false)
    }

    function test_mergePage_overflow_row_trimmed_and_hasMore_true() {
        // Requested limit 3, over-fetch limit+1=4, got all 4 back -> trim
        // the 4th and report hasMore.
        var r = Paging.mergePage([], [{id:1},{id:2},{id:3},{id:4}], 3)
        compare(r.items.length, 3)
        compare(r.hasMore, true)
        compare(r.items[2].id, 3) // overflow row (id:4) trimmed, not appended
    }

    function test_mergePage_appends_to_existing_items() {
        var existing = [{id:1},{id:2}]
        var r = Paging.mergePage(existing, [{id:3},{id:4}], 3)
        compare(r.items.length, 4)
        compare(r.items[0].id, 1)
        compare(r.items[3].id, 4)
        compare(r.hasMore, false)
        // existing array itself must not be mutated in place
        compare(existing.length, 2)
    }

    function test_mergePage_handles_empty_new_page() {
        var r = Paging.mergePage([{id:1}], [], 50)
        compare(r.items.length, 1)
        compare(r.hasMore, false)
    }

    function test_cursorFrom_empty_items_is_null() {
        compare(Paging.cursorFrom([], "createdAt"), null)
    }

    function test_cursorFrom_returns_last_items_field_value() {
        var items = [{createdAt: "2026-01-01"}, {createdAt: "2026-01-03"}]
        compare(Paging.cursorFrom(items, "createdAt"), "2026-01-03")
    }

    function test_nextState_bundles_merge_and_cursor() {
        // limit=2 means the store over-fetched limit+1=3 raw rows.
        var current = { items: [{createdAt:"2026-01-01"}], hasMore: true, loadingMore: true }
        var s = Paging.nextState(current,
            [{createdAt:"2026-01-02"},{createdAt:"2026-01-03"},{createdAt:"2026-01-04"}], 2, "createdAt")
        compare(s.items.length, 3)          // 1 existing + 2 kept (overflow row trimmed)
        compare(s.hasMore, true)
        compare(s.loadingMore, false)
        compare(s.cursor, "2026-01-03")      // last KEPT item, not the trimmed overflow row
    }

    function test_nextState_last_page_clears_hasMore() {
        var current = { items: [], hasMore: true, loadingMore: true }
        var s = Paging.nextState(current, [{createdAt:"2026-01-01"}], 50, "createdAt")
        compare(s.hasMore, false)
        compare(s.cursor, "2026-01-01")
    }
}
