import QtQuick
import QtTest

// Covers the Orders-page date filter (OrdersPage.qml _dateWindow + the row
// predicate in _filteredOrders). Two regressions are locked here:
//
//   1. CUSTOM range — added so "Custom" + from/to actually narrows the list.
//      Inclusive `to` (a [Jun 10, Jun 10] window must catch all of Jun 10),
//      and an unparseable end means "no filter" rather than an empty list.
//
//   2. TZ PARSE BUG — orders store `date` as "yyyy-MM-dd". `new Date(s)` parses
//      that as UTC midnight, but the window bounds are built with
//      new Date(y,m,d) = LOCAL midnight. In a negative-offset zone today's
//      order then sorts BEFORE win.from and "Today" shows nothing. The fix
//      parses `s + "T00:00:00"` = local midnight, matching the bounds.
//
// OrdersPage can't load under qmltestrunner (it pulls in OrdersStore/StaffScope
// singletons), so this faithfully mirrors the pure logic with a `withFix` flag
// and an injected `now`, exactly like tst_RecentSalesPriceAdjustRow.
TestCase {
    name: "OrdersDateFilter"

    // Faithful mirror of OrdersPage._dateWindow, with `now` injected for
    // determinism. Identical branch structure to the real function.
    function _dateWindow(dateRange, customFrom, customTo, now) {
        if (dateRange === "all" || !dateRange) return null
        var to = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)
        var from
        if (dateRange === "today")
            from = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        else if (dateRange === "7days")
            from = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 6)
        else if (dateRange === "30days")
            from = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 29)
        else if (dateRange === "custom") {
            var f = new Date(customFrom + "T00:00:00")
            var t = new Date(customTo + "T00:00:00")
            if (isNaN(f.getTime()) || isNaN(t.getTime())) return null
            from = f
            to = new Date(t.getFullYear(), t.getMonth(), t.getDate() + 1)
        } else
            return null
        return { from: from, to: to }
    }

    // Mirror of the per-row date test inside _filteredOrders, parameterised by
    // `withFix`: false = buggy bare parse (UTC), true = local-midnight parse.
    function _inWindow(dateStr, win, withFix) {
        if (!win) return true
        var od = withFix ? new Date(dateStr + "T00:00:00") : new Date(dateStr)
        if (isNaN(od.getTime())) return false
        return !(od < win.from || od >= win.to)
    }

    // ── Custom range ────────────────────────────────────────────────────
    function test_custom_inclusive_single_day() {
        var now = new Date(2026, 5, 25)
        var win = _dateWindow("custom", "2026-06-10", "2026-06-10", now)
        verify(win !== null, "both ends parse → window active")
        verify(_inWindow("2026-06-10", win, true), "Jun 10 order is inside [Jun 10, Jun 10]")
    }

    function test_custom_excludes_outside() {
        var now = new Date(2026, 5, 25)
        var win = _dateWindow("custom", "2026-06-10", "2026-06-10", now)
        verify(!_inWindow("2026-06-11", win, true), "Jun 11 is past the inclusive end")
        verify(!_inWindow("2026-06-09", win, true), "Jun 9 is before the start")
    }

    function test_custom_unparseable_is_inactive() {
        var now = new Date(2026, 5, 25)
        compare(_dateWindow("custom", "", "", now), null, "blank ends → no filter")
        compare(_dateWindow("custom", "2026-06-10", "not-a-date", now), null, "bad end → no filter")
    }

    // ── TZ parse fix ────────────────────────────────────────────────────
    // The invariant the fix restores, true on every machine TZ: a stored
    // "yyyy-MM-dd" parsed local-midnight equals the locally-built bound for the
    // same day. The buggy bare parse only matches at UTC+0.
    function test_local_parse_matches_window_bound() {
        var fixed = new Date("2026-06-25T00:00:00").getTime()
        var bound = new Date(2026, 5, 25).getTime()
        compare(fixed, bound, "local-midnight parse == locally-constructed bound")
    }

    // "Today" must include an order stamped with today's local date. With the
    // fix this holds in every zone; the buggy parse drops it west of UTC.
    function test_today_includes_todays_order() {
        var now = new Date(2026, 5, 25)
        var win = _dateWindow("today", "", "", now)
        // Build today's stamp the way OrdersStore does (local Y-M-D).
        var s = "2026-06-25"
        verify(_inWindow(s, win, true), "today's order is inside the Today window")
    }
}
