import QtQuick
import QtTest
import "../qml/helper/StockRegisterPage.js" as P
import "../qml/helper/StockRegisterModel.js" as M

// Headless tests for the stock register page's pure glue (P1 S4b-2). The full contract (about 250 checks, a seeded
// monkey, 52 hand mutants, three time zones) runs in Node in .github/scripts/__tests__/stockRegisterPage.test.js;
// this file proves the main cases in the real Qt JS engine (where a reserved word such as `id` as a role name, or a
// missing builtin, shows up first).
// Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md section 8
// Test plan: docs/superpowers/test-plans/2026-11-20-p1-s4b2-register-page-test-plan.md
TestCase {
    name: "StockRegisterPage"

    readonly property double off: 19800000
    function istAt(y, m0, d, h, mi) { return Date.UTC(y, m0, d, h || 0, mi || 0) - off }
    readonly property double now: istAt(2026, 10, 20, 15, 42)

    function product(over) {
        var p = { productId: "p-abcdef123", name: "Silk Saree", deleted: false, opening: 10,
                  kinds: { sale: { in: 0, out: 3 }, receipt: { in: 5, out: 0 } },
                  inTotal: 5, outTotal: 3, closing: 12, currentStock: 12, ledgerStock: 12,
                  reconciles: true, movementCount: 4 }
        for (var k in over) p[k] = over[k]
        return p
    }
    function answer(win, products) {
        return { ok: true, window: { fromMs: win.fromMs, toMs: win.toMs }, readAt: now, products: products,
                 counts: { rowsInWindow: 5, skipped: {} } }
    }

    function test_chips() {
        compare(P.chipLabels().length, 7)
        compare(P.chipLabels()[6], "Custom")
        compare(P.CUSTOM_INDEX, M.PRESETS.length)
    }

    function test_resolveWindow() {
        var r = P.resolveWindow(0, "", "", now)
        verify(r.ok)
        compare(r.win.fromMs, M.presetWindow("month", now).fromMs)
        verify(P.resolveWindow(6, " 2026-04-01 ", "2026-04-30", 0).ok)
        compare(P.resolveWindow(6, "x", "", 0).text, M.customErrorText("bad-from"))
        verify(!P.resolveWindow(7, "", "", now).ok)
        verify(!P.resolveWindow(-1, "", "", now).ok)
        verify(!P.resolveWindow(1.5, "", "", now).ok)
    }

    function test_tapDecision() {
        var good = P.resolveWindow(0, "", "", now)
        verify(P.tapDecision({ loading: false, online: true, role: "owner", resolved: good }).go)
        compare(P.tapDecision({ loading: true, online: true, role: "owner", resolved: good }).kind, "busy")
        compare(P.tapDecision({ loading: false, online: true, role: "staff", resolved: good }).kind, "role")
        compare(P.tapDecision({ loading: false, online: false, role: "owner", resolved: good }).kind, "offline")
        compare(P.tapDecision({ loading: false, online: true, role: "owner", resolved: { ok: false, text: "x" } }).kind, "window")
        compare(P.tapDecision(null).kind, "window")
    }

    function test_stateFromResult() {
        var win = M.presetWindow("month", now)
        var st = P.stateFromResult({ ok: true, body: answer(win, [product(), product({ productId: "q", opening: 0, inTotal: 0, outTotal: 0, closing: 0, currentStock: 0, ledgerStock: 0, movementCount: 0, kinds: {} })]) }, win, false)
        compare(st.status, "ok")
        compare(st.rows.length, 1)
        compare(st.summary.hiddenQuiet, 1)
        compare(Object.keys(st.rows[0]).join(","), P.ROW_KEYS.join(","))
        verify(P.stateFromResult({ ok: false, kind: "busy" }, win, false) === null)
        verify(P.stateFromResult({ ok: false, kind: "cancelled" }, win, false) === null)
        compare(P.stateFromResult({ ok: false, kind: "role", message: "No.", retryable: false }, win, false).retryable, false)
        compare(P.stateFromResult(null, win, false).status, "error")
        compare(P.stateFromCache(null, win, false).status, "idle")
    }

    function test_rowKeysAreNotReserved() {
        verify(P.ROW_KEYS.indexOf("id") < 0)
        compare(P.ROW_KEYS.length, 9)
    }

    function test_texts() {
        compare(P.asOfText(now), "as of 20 Nov 2026, 3:42 pm (IST)")
        compare(P.asOfText(0), "")
        compare(P.summaryText({ shown: 1, hiddenQuiet: 0 }), "1 product shown")
        compare(P.summaryText({ shown: 12, hiddenQuiet: 3 }), "12 products shown, 3 with no stock history hidden")
        compare(P.warningLines({ mismatches: 0, skippedLedgerRows: 0, droppedBad: 0 }).length, 0)
        compare(P.warningLines({ mismatches: 2, skippedLedgerRows: 1, droppedBad: 1 }).length, 3)
        compare(P.loadLabel("ok", true), "Reload register")
        compare(P.loadLabel("error", true), "Try again")
        compare(P.nextExpanded("a", "a"), "")
        compare(P.nextExpanded("", "a"), "a")
    }
}
