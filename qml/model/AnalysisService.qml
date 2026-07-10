pragma Singleton
import QtQuick

// Client for the computeAnalysis Cloud Function (Phase 2 of the
// scale-reads-writes-analytics design, docs/superpowers/specs/
// 2026-07-06-scale-reads-writes-analytics-design.md). Moves Revenue/Profit/
// Sold/Purchased aggregation off the phone -- once wired in, SalesPage no
// longer needs the full transaction ledger resident in QML to compute these.
// Same XHR + Bearer-token pattern as Gateway.qml.
//
// NOT YET WIRED INTO SalesPage.qml -- that cutover is a deliberately separate,
// later step (SalesPage is large and can only be manually verified, per
// Skill 29's coverage-ceiling note; better as its own reviewed change than
// folded into this one). InventoryStore.realisedProfitByDimension/
// realisedTotals/realisedBucketWalk still do the local RealisedMath scan
// today.
QtObject {
    id: root

    // computeAnalysis HTTPS endpoint (Gen-2 onRequest, asia-south1) --
    // same project/region as Gateway's endpoints.
    property string functionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/computeAnalysis"

    property bool loading: false
    property string lastError: ""

    // period: 0=Day 1=Week 2=Month 3=Year (same index as SalesPage's period
    //   selector / BreakdownMath.periodWindow).
    // viewMode: "revenue" | "profit" | "sold" | "purchased".
    // dims: e.g. ["category", "supplier"] -- which by-dimension breakdowns to
    //   compute in this one call.
    // scope: { window: {from,to}|null, channel, staffId, category, supplierId }
    //   -- window.from/to may be Date objects or ISO strings; serialized to
    //   ISO strings before sending either way.
    // periodScoped: mirrors SalesPage._realisedScope(periodScoped) -- true
    //   intersects the selected period (on-screen hero/chart), false is the
    //   whole filter window (export sections).
    // callback(ok, data) -- data is { totals, byDimension, bucketWalk } on
    // success (totals is null for sold/purchased, which have no single-total
    // hero), or { error } on failure.
    function compute(period, viewMode, dims, scope, periodScoped, callback) {
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            if (callback) callback(false, { error: "not-signed-in" })
            return
        }
        if (typeof AuthService !== "undefined" && AuthService)
            AuthService.ensureFreshToken()

        var win = null
        if (scope && scope.window && scope.window.from && scope.window.to) {
            win = {
                from: (scope.window.from instanceof Date) ? scope.window.from.toISOString() : scope.window.from,
                to: (scope.window.to instanceof Date) ? scope.window.to.toISOString() : scope.window.to
            }
        }

        loading = true
        lastError = ""
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            loading = false
            var ok = xhr.status >= 200 && xhr.status < 300
            var data = null
            try { data = JSON.parse(xhr.responseText) } catch (e) { data = null }
            if (!ok) {
                lastError = (data && data.error) ? data.error : ("HTTP " + xhr.status)
                console.warn("[AnalysisService] compute failed", xhr.status, xhr.responseText)
            }
            if (callback) callback(ok, data)
        }
        xhr.open("POST", functionUrl)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        xhr.send(JSON.stringify({
            env: FirebaseService.environment,
            period: period,
            viewMode: viewMode,
            dims: dims || ["category", "supplier"],
            scope: {
                window: win,
                channel: (scope && scope.channel) || "",
                staffId: (scope && scope.staffId) || "",
                category: (scope && scope.category) || "",
                supplierId: (scope && scope.supplierId) || ""
            },
            periodScoped: !!periodScoped
        }))
    }
}
