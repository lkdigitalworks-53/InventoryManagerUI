import QtQuick
import QtTest
import "../qml/helper/RealisedMath.js" as RM
import "../qml/helper/BreakdownMath.js" as BM

// REPRO: "Day period and custom date filter not applied — shows all calculations."
// Three sales on three different days. Assert that a Day-scoped and a
// custom-date-scoped aggregation return ONLY the in-window sale, not all three.
TestCase {
    name: "DateFilterRepro"
    function _round2(x) { return Math.round(x * 100) / 100 }

    function _events() {
        return [
            { kind: "sale", timestamp: "2026-06-23T10:00:00", productId: "P1", quantity: 1,
              unitPrice: 100, net: 100, tax: 0, discountShare: 0,
              consumption: [{ supplierId: "S1", qtyConsumed: 1, unitCost: 40 }] },
            { kind: "sale", timestamp: "2026-06-24T10:00:00", productId: "P1", quantity: 1,
              unitPrice: 100, net: 100, tax: 0, discountShare: 0,
              consumption: [{ supplierId: "S1", qtyConsumed: 1, unitCost: 40 }] },
            { kind: "sale", timestamp: "2026-06-25T10:00:00", productId: "P1", quantity: 1,
              unitPrice: 100, net: 100, tax: 0, discountShare: 0,
              consumption: [{ supplierId: "S1", qtyConsumed: 1, unitCost: 40 }] }
        ]
    }

    // Simulate SalesPage._realisedScope(true) for the Day period: periodWindow ∩ dateWindow.
    function test_day_period_scope_restricts_to_today() {
        var now = new Date(2026, 5, 25, 12, 0, 0)         // June 25
        var periodWin = BM.periodWindow(0, now)            // Day = today
        var scope = { window: periodWin, channel: "", staffId: "", category: "", supplierId: "" }
        var t = RM.totals(_events(), scope, {})
        compare(_round2(t.net), 100, "Day total must be ONLY June 25's sale (100), not all three (300)")
    }

    // Custom date filter: June 23 → June 23 only.
    function test_custom_date_scope_restricts() {
        // Mirror SalesPage._dateWindow() custom branch: [from, to+1day).
        var f = new Date("2026-06-23")
        var t0 = new Date("2026-06-23")
        var to = new Date(t0.getFullYear(), t0.getMonth(), t0.getDate() + 1)
        var scope = { window: { from: f, to: to }, channel: "", staffId: "", category: "", supplierId: "" }
        var tot = RM.totals(_events(), scope, {})
        compare(_round2(tot.net), 100, "Custom [Jun23,Jun23] must show ONLY that day's sale (100), not 300")
    }

    // Faithful mirror of SalesPage._dateWindow()'s custom branch, parameterised
    // by `withFix`: false = bare new Date(s) (UTC midnight) for `from`,
    // true = new Date(s + "T00:00:00") (local midnight, matching `to`/period
    // bounds). The TZ bug only the `from` edge had: a bare parse lands the start
    // 5.5h late in IST (UTC+5:30), so a sale stamped at the day's first hours
    // sorts BEFORE `from` and the custom report silently drops it.
    function _customWindow(customFrom, customTo, withFix) {
        var f = withFix ? new Date(customFrom + "T00:00:00") : new Date(customFrom)
        var t = withFix ? new Date(customTo + "T00:00:00")   : new Date(customTo)
        if (isNaN(f.getTime()) || isNaN(t.getTime())) return null
        return { from: f, to: new Date(t.getFullYear(), t.getMonth(), t.getDate() + 1),
                 channel: "", staffId: "", category: "", supplierId: "" }
    }

    // The custom `from` edge must be LOCAL midnight, identical to the period
    // bounds and the inclusive `to` (all local-constructed). This holds in every
    // machine TZ. The bare-parse bug built `from` from new Date("yyyy-MM-dd") =
    // UTC midnight, which only equals local midnight at UTC+0 — east of UTC (IST,
    // UTC+5:30) it lands 5.5h late and drops start-of-day sales.
    function test_custom_from_is_local_midnight() {
        var fixed = _customWindow("2026-06-23", "2026-06-23", true)
        compare(fixed.from.getTime(), new Date(2026, 5, 23).getTime(),
                "fixed `from` == locally-constructed Jun 23 midnight (TZ-portable)")
        // The fix only matters when the machine isn't UTC; where it is, both
        // parses coincide and there's nothing to prove — so guard the assertion.
        var buggy = _customWindow("2026-06-23", "2026-06-23", false)
        if (new Date("2026-06-23").getTime() !== new Date(2026, 5, 23).getTime())
            verify(buggy.from.getTime() !== fixed.from.getTime(),
                   "bare-parse `from` diverges from local midnight off UTC — the dropped-sales bug")
    }

    // A sale stamped at a local-morning instant on the custom day must land
    // inside [day, day] with the local-midnight parse, in every zone.
    function test_custom_window_includes_start_of_day() {
        var ev = [{ kind: "sale", timestamp: "2026-06-23T01:00:00", productId: "P1", quantity: 1,
                    unitPrice: 100, net: 100, tax: 0, discountShare: 0,
                    consumption: [{ supplierId: "S1", qtyConsumed: 1, unitCost: 40 }] }]
        var win = _customWindow("2026-06-23", "2026-06-23", true)
        var tot = RM.totals(ev, win, {})
        compare(_round2(tot.net), 100,
                "early-morning sale on the custom day is inside [Jun23,Jun23] with local-midnight parse")
    }

    // bucketWalk for Day must also restrict: only today's bin populated.
    function test_day_bucketwalk_restricts() {
        var now = new Date(2026, 5, 25, 12, 0, 0)
        var periodWin = BM.periodWindow(0, now)
        var scope = { window: periodWin }
        var bins = RM.bucketWalk("net", 0, _events(), scope, now, {})
        var sum = 0
        for (var i = 0; i < bins.length; ++i) sum += bins[i].value
        compare(_round2(sum), 100, "Day bucketWalk sums to today's sale only (100), not 300")
    }
}
