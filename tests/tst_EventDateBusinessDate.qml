import QtQuick
import QtTest
import "../qml/helper/OrderMath.js" as OM
import "../qml/helper/RealisedMath.js" as RM
import "../qml/helper/BreakdownMath.js" as BM

// REPRO of the production bug: "no orders today, but every report shows all-time
// numbers." Confirmed against live Firestore — completed sales store
//   date:      "2026-06-24"               (BUSINESS date — the order's day)
//   timestamp: "2026-06-25T04:14:…Z"      (WRITE instant — when recorded)
// and every analytics walker bucketed on `new Date(e.timestamp || e.date)`,
// i.e. the WRITE instant. So a sale dated yesterday but recorded today matched
// the "Day = today" filter and the reports never narrowed.
//
// The fix routes all bucketing through OrderMath.eventDate(e), which buckets on
// the business `date` (with same-day live events keeping their real hour). These
// tests lock that — using fixtures where date != timestamp DAY, the exact case
// the earlier same-day fixtures (tst_DateFilterRepro) failed to exercise.
TestCase {
    name: "EventDateBusinessDate"
    function _round2(x) { return Math.round(x * 100) / 100 }

    // ── eventDate() unit — the three branches ──────────────────────────────
    function test_eventDate_backdated_uses_business_day() {
        // date = Jun 24, written Jun 25 → buckets at Jun 24 LOCAL midnight.
        var d = OM.eventDate({ date: "2026-06-24", timestamp: "2026-06-25T04:14:04.530Z" })
        compare(d.getTime(), new Date(2026, 5, 24).getTime(),
                "back-dated event buckets at its business day (local midnight), not the write day")
    }

    function test_eventDate_live_keeps_real_hour() {
        // Same business day as the write instant → keep the real clock time so
        // the hourly Day view retains intra-day shape. Build a same-day local
        // instant and round-trip it through an ISO timestamp.
        var sameDay = new Date(2026, 5, 25, 9, 30, 0)
        var d = OM.eventDate({ date: "2026-06-25", timestamp: sameDay.toISOString() })
        compare(d.getTime(), sameDay.getTime(),
                "live same-day event keeps its real hour-of-day")
    }

    function test_eventDate_missing_date_falls_back_to_timestamp() {
        var ts = "2026-06-25T04:14:04.530Z"
        var d = OM.eventDate({ timestamp: ts })
        compare(d.getTime(), new Date(ts).getTime(),
                "no business date → fall back to the write instant")
    }

    // ── The actual production fixtures ─────────────────────────────────────
    // A sale dated yesterday, recorded today (exactly the Firestore shape).
    function _backdatedSale() {
        return [{ kind: "sale", date: "2026-06-24", timestamp: "2026-06-25T04:14:04.530Z",
                  productId: "P1", quantity: 1, unitPrice: 100, net: 100, tax: 0, discountShare: 0,
                  consumption: [{ supplierId: "S1", qtyConsumed: 1, unitCost: 40 }] }]
    }

    // RealisedMath (Revenue/Profit hero + chart + by-dimension): Day = today must
    // be EMPTY when the only sale is dated yesterday.
    function test_realised_day_excludes_backdated() {
        var now = new Date(2026, 5, 25, 12, 0, 0)
        var periodWin = BM.periodWindow(0, now)   // Day = Jun 25
        var scope = { window: periodWin }
        var t = RM.totals(_backdatedSale(), scope, {})
        compare(_round2(t.net), 0, "Day(today) total is 0 — the only sale is dated yesterday")
    }

    // …but Month (which contains both days) must still include it.
    function test_realised_month_includes_backdated() {
        var now = new Date(2026, 5, 25, 12, 0, 0)
        var periodWin = BM.periodWindow(2, now)   // Month = June
        var t = RM.totals(_backdatedSale(), { window: periodWin }, {})
        compare(_round2(t.net), 100, "Month includes the Jun 24 sale")
    }

    // bucketWalk (the on-screen chart) must put the sale in NO bin on the Day
    // view (today), since it belongs to yesterday.
    function test_realised_bucketwalk_day_excludes_backdated() {
        var now = new Date(2026, 5, 25, 12, 0, 0)
        var bins = RM.bucketWalk("net", 0, _backdatedSale(), { window: BM.periodWindow(0, now) }, now, {})
        var sum = 0
        for (var i = 0; i < bins.length; ++i) sum += bins[i].value
        compare(_round2(sum), 0, "Day chart bins are all empty for a yesterday-dated sale")
    }

    // BreakdownMath._sold (Sold view by category/supplier): a yesterday-dated
    // sale must not appear in the Day window.
    function test_sold_day_excludes_backdated() {
        var now = new Date(2026, 5, 25, 12, 0, 0)
        var out = BM.breakdown({
            metric: "sold", dim: "category",
            entries: _backdatedSale(), window: BM.periodWindow(0, now),
            productCategory: { "P1": "Cat" }, supplierName: {}
        })
        var total = 0
        for (var k in out) total += out[k]
        compare(total, 0, "Sold(Day) excludes the yesterday-dated sale")
    }
}
