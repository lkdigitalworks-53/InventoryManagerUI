import QtQuick
import QtTest
import "../qml/helper/StockRegisterModel.js" as M

// Headless tests for the stock register's pure helper (P1 S4b-1). The full contract (about 400 assertions, 3000
// random instants, 80 hand mutants) runs in Node in .github/scripts/__tests__/stockRegisterModel.test.js; this
// file proves the main cases in the real Qt JS engine (the one place a reserved word or a missing builtin shows).
// Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md
// Test plan: docs/superpowers/test-plans/2026-11-12-p1-s4b1-register-client-engine-test-plan.md
TestCase {
    name: "StockRegisterModel"

    readonly property double off: 19800000

    function istAt(y, m0, d, h, mi) { return Date.UTC(y, m0, d, h || 0, mi || 0) - off }

    function product(over) {
        var p = { productId: "p-abcdef123", name: "Silk Saree", deleted: false, opening: 10,
                  kinds: { sale: { in: 0, out: 3 }, receipt: { in: 5, out: 0 } },
                  inTotal: 5, outTotal: 3, closing: 12, currentStock: 12, ledgerStock: 12,
                  reconciles: true, movementCount: 4 }
        for (var k in over) p[k] = over[k]
        return p
    }
    function answer(win, products) {
        return { ok: true, window: { fromMs: win.fromMs, toMs: win.toMs }, readAt: 5, products: products,
                 counts: { rowsInWindow: 5, skipped: { noProduct: 1, badKind: 0 } } }
    }

    function test_presets_use_india_calendar() {
        var now = istAt(2026, 10, 12, 10)
        var w = M.presetWindow("month", now)
        verify(w.ok)
        compare(w.fromMs, istAt(2026, 10, 1))
        compare(w.toMs, istAt(2026, 11, 1))
        compare(w.text, "1 Nov 2026 \u2013 30 Nov 2026 (IST)")
        compare(M.presetWindow("quarter", now).label, "Q3 FY 2026-27 (Oct\u2013Dec)")
        compare(M.presetWindow("lastQuarter", now).label, "Q2 FY 2026-27 (Jul\u2013Sep)")
        compare(M.presetWindow("fy", now).label, "FY 2026-27")
        compare(M.presetWindow("lastFy", now).text, "1 Apr 2025 \u2013 31 Mar 2026 (IST)")
    }

    function test_the_ist_midnight_is_the_boundary_not_the_utc_one() {
        compare(M.presetWindow("month", Date.UTC(2026, 2, 31, 18, 29, 59, 999)).label, "Mar 2026")
        compare(M.presetWindow("month", Date.UTC(2026, 2, 31, 18, 30, 0, 0)).label, "Apr 2026")
        compare(M.presetWindow("fy", Date.UTC(2026, 2, 31, 18, 30, 0, 0)).label, "FY 2026-27")
    }

    function test_neighbouring_periods_chain() {
        var now = istAt(2026, 0, 1)
        compare(M.presetWindow("lastMonth", now).toMs, M.presetWindow("month", now).fromMs)
        compare(M.presetWindow("lastQuarter", now).toMs, M.presetWindow("quarter", now).fromMs)
        compare(M.presetWindow("lastFy", now).toMs, M.presetWindow("fy", now).fromMs)
        compare(M.presetWindow("lastMonth", now).label, "Dec 2025")
    }

    function test_bad_preset_and_bad_now() {
        compare(M.presetWindow("constructor", 1).error, "bad-preset")
        compare(M.presetWindow("__proto__", 1).error, "bad-preset")
        compare(M.presetWindow("month", NaN).error, "bad-now")
        compare(M.presetWindow("month", istAt(1999, 11, 31)).error, "bad-now")
    }

    function test_custom_range_is_inclusive_and_never_rolls_a_date() {
        var w = M.customWindow("2026-04-01", "2026-04-30")
        verify(w.ok)
        compare(w.fromMs, istAt(2026, 3, 1))
        compare(w.toMs, istAt(2026, 4, 1))
        compare(M.customWindow("2026-04-01", "2026-04-01").toMs - M.customWindow("2026-04-01", "2026-04-01").fromMs, 86400000)
        compare(M.customWindow("2028-02-29", "2028-02-29").ok, true)
        compare(M.customWindow("2026-02-29", "2026-03-01").error, "bad-from")
        compare(M.customWindow("2026-04-01", "2026-04-31").error, "bad-to")
        compare(M.customWindow("2026-04-30", "2026-04-01").error, "reversed")
        compare(M.customWindow("2026-04-02", "2026-04-01").error, "reversed")
        compare(M.customWindow("1999-12-31", "2026-01-01").error, "out-of-range")
        compare(M.customWindow("2026-4-1", "2026-04-30").error, "bad-from")
    }

    function test_request_body_is_epoch_ms() {
        var w = M.presetWindow("month", istAt(2026, 10, 12))
        compare(M.requestBody(w).from, w.fromMs)
        compare(M.requestBody(w).to, w.toMs)
        compare(typeof M.requestBody(w).from, "number")
        compare(M.windowKey(w), w.fromMs + ":" + w.toMs)
        compare(M.windowKey({}), "")
    }

    function test_errors_are_worded_by_cause() {
        compare(M.classify(0, null).kind, "offline")
        compare(M.classify(401, null).kind, "auth")
        compare(M.classify(403, { error: "role-not-allowed" }).kind, "role")
        compare(M.classify(403, { error: "role-not-allowed" }).retryable, false)
        compare(M.classify(403, null).kind, "tenant")
        compare(M.classify(400, { error: "invalid-window" }).kind, "window")
        compare(M.classify(413, null).kind, "tooLarge")
        compare(M.classify(504, null).kind, "timeout")
        compare(M.classify(500, null).kind, "server")
        compare(M.classify(418, null).kind, "unknown")
        compare(M.message("constructor"), M.message("nope"))
    }

    function test_roles() {
        verify(M.canView("owner"))
        verify(M.canView("admin"))
        verify(M.canView("manager"))
        verify(!M.canView("staff"))
        verify(!M.canView("constructor"))
        verify(!M.canView(undefined))
    }

    function test_quantities_use_indian_grouping() {
        compare(M.fmtQty(0), "0")
        compare(M.fmtQty(-0.0004), "0")
        compare(M.fmtQty(999), "999")
        compare(M.fmtQty(1000), "1,000")
        compare(M.fmtQty(100000), "1,00,000")
        compare(M.fmtQty(1234567.1), "12,34,567.1")
        compare(M.fmtQty(-1234567.5), "-12,34,567.5")
        compare(M.fmtQty(1.2345), "1.235")
        compare(M.fmtQty(NaN), "\u2014")
    }

    function test_a_moved_window_is_refused() {
        var w = M.presetWindow("month", istAt(2026, 10, 12))
        var good = answer(w, [product({})])
        verify(M.validateAnswer(good, w).ok)
        var moved = answer(w, [product({})])
        moved.window.fromMs = w.fromMs + 1
        compare(M.validateAnswer(moved, w).reason, "window-mismatch")
        compare(M.buildView(moved, w).ok, false)
        compare(M.buildView(moved, w).rows.length, 0)
    }

    function test_rows_are_flat_and_complete() {
        var w = M.presetWindow("month", istAt(2026, 10, 12))
        var v = M.buildView(answer(w, [product({}), product({ productId: "q2", name: null, deleted: true, reconciles: false, ledgerStock: 4 })]), w, {})
        verify(v.ok)
        compare(v.rows.length, 2)
        var keys = Object.keys(v.rows[0]).sort().join(",")
        compare(Object.keys(v.rows[1]).sort().join(","), keys)
        compare(keys, "closingText,currentText,deleted,id,inText,moved,movementCount,note,openingText,outText,reconciles,title")
        compare(v.rows[0].openingText, "10")
        compare(v.rows[1].title, "Product q2")
        compare(v.rows[1].note, "Deleted product, ledger shows 4 left")
        compare(v.summary.skippedLedgerRows, 1)
        verify(v.summary.hasWarning)
    }

    function test_quiet_rows_hide_unless_asked_and_a_mismatch_never_hides() {
        var w = M.presetWindow("month", istAt(2026, 10, 12))
        var q = product({ productId: "z", opening: 0, inTotal: 0, outTotal: 0, closing: 0, currentStock: 0, ledgerStock: 0, movementCount: 0 })
        compare(M.buildView(answer(w, [q]), w, {}).rows.length, 0)
        compare(M.buildView(answer(w, [q]), w, {}).summary.hiddenQuiet, 1)
        compare(M.buildView(answer(w, [q]), w, { showAll: true }).rows.length, 1)
        var m = product({ productId: "z", opening: 0, inTotal: 0, outTotal: 0, closing: 0, currentStock: 3, ledgerStock: 0, movementCount: 0, reconciles: false })
        compare(M.buildView(answer(w, [m]), w, {}).rows.length, 1)
        compare(M.buildView(answer(w, [m]), w, {}).rows[0].note, "Ledger 0 vs stock 3")
    }

    function test_detail_lines_follow_the_kind_order() {
        var lines = M.detailLines(product({}))
        compare(lines.length, 2)
        compare(lines[0].kind, "receipt")
        compare(lines[0].label, "Received")
        compare(lines[1].kind, "sale")
        compare(lines[1].outText, "3")
        compare(M.detailLines(null).length, 0)
    }
}
