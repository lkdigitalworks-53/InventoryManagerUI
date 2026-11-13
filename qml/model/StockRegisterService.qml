pragma Singleton
import QtQuick
import "../helper/StockRegisterModel.js" as StockRegisterModel

// Client for the computeStockRegister Cloud Function (P1 S4a server). Sends one request and hands back a
// validated answer; every decision (period, wording, row building) lives in StockRegisterModel.js.
// DORMANT: nothing calls this until the register page (S4b-2); a caller grep in
// functions/test/stockRegisterClient.guard.test.js pins that.
// Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md
//
// Rules this file keeps:
//  * ON DEMAND ONLY. One request reads the whole ledger (billed per document), so there is no timer, no resume
//    hook and no auto-refresh here. A person taps; one request flies (single flight).
//  * Every load() callback fires EXACTLY ONCE: answer, error, cancel, or "busy".
//  * An answer is shown only if the server echoes the window that was asked for (a silently moved period
//    boundary is a wrong statutory report). A workspace or sign-in change during flight drops the answer.
//  * No timer objects (QtObject has no declarative children): the XHR's own timeout is the only clock.
QtObject {
    id: root

    // Same project and region as Gateway and AnalysisService.
    property string functionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/computeStockRegister"
    // The server's function timeout is 120 s and its scan stops starting pages at 100 s and answers a coded 504.
    // A shorter client timeout would abort a scan that is still valid and still billed.
    readonly property int requestTimeoutMs: 125000

    property bool loading: false
    // Last good answer: the validated server body, the window it answered, and who it belongs to.
    property var lastBody: null
    property var lastWindow: null
    property string lastTenantId: ""
    property string lastRole: ""

    property var _xhr: null
    property var _pendingCallback: null
    property int _generation: 0

    // The last good answer for exactly this window, and only for the workspace and role that fetched it.
    // Null otherwise. Reading it costs nothing; only load() reads the ledger.
    function cached(win) {
        if (!lastBody || !lastWindow) return null
        if (StockRegisterModel.windowKey(win) !== StockRegisterModel.windowKey(lastWindow)) return null
        if (lastTenantId !== AuthStore.tenantId || lastRole !== AuthStore.role) return null
        return { body: lastBody, window: lastWindow }
    }

    function clear() {
        lastBody = null
        lastWindow = null
        lastTenantId = ""
        lastRole = ""
    }

    function _answer(callback, result) {
        if (callback) callback(result)
    }

    function _fail(callback, kind) {
        _answer(callback, { ok: false, kind: kind, message: StockRegisterModel.message(kind), retryable: kind !== "role" })
    }

    // QTBUG-49896 (Skill 45/76): the XHR can reset `status` to 0 at the 3->4 transition for some non-2xx answers.
    // Keep the last non-zero status and body seen at HEADERS_RECEIVED / LOADING, as Gateway and LockManager do.
    function _captureBeforeStatusIsLost(xhr, snap) {
        if (xhr.readyState === XMLHttpRequest.HEADERS_RECEIVED || xhr.readyState === XMLHttpRequest.LOADING) {
            if (xhr.status !== 0) {
                snap.status = xhr.status
                snap.responseText = xhr.responseText
            }
        }
    }

    // win: a window from StockRegisterModel.presetWindow / customWindow ({ ok:true, fromMs, toMs, ... }).
    // callback(result): { ok:true, body, window } | { ok:false, kind, message, retryable }.
    // kind: busy | window | notSignedIn | role | offline | auth | tenant | tooLarge | timeout | server |
    //       badAnswer | unknown | cancelled. Returns true when a request was sent.
    function load(win, callback) {
        if (loading) {
            _answer(callback, { ok: false, kind: "busy", message: "", retryable: true })
            return false
        }
        if (!win || win.ok !== true || StockRegisterModel.windowKey(win) === "") {
            _fail(callback, "window")
            return false
        }
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            _fail(callback, "notSignedIn")
            return false
        }
        // The server is the authority; this only saves a billed round trip that is certain to be refused.
        if (!StockRegisterModel.canView(AuthStore.role)) {
            _fail(callback, "role")
            return false
        }
        if (typeof AuthService !== "undefined" && AuthService)
            AuthService.ensureFreshToken()

        var gen = _generation   // only cancel() bumps it: a request that was cancelled never matches again
        var tenantAtSend = AuthStore.tenantId
        var roleAtSend = AuthStore.role
        var xhr = new XMLHttpRequest()
        var settled = false
        var snap = { status: 0, responseText: "" }
        _xhr = xhr
        _pendingCallback = callback
        loading = true

        function settle(status, text) {
            if (settled) return
            settled = true
            // Cancelled (or superseded): cancel() already answered the caller.
            if (gen !== _generation) return
            _xhr = null
            _pendingCallback = null
            loading = false

            // The person left this workspace or changed role while the ledger was being read: drop the answer.
            if (tenantAtSend !== AuthStore.tenantId || roleAtSend !== AuthStore.role) {
                _fail(callback, "cancelled")
                return
            }
            var body = null
            try { body = JSON.parse(text) } catch (e) { body = null }

            if (status >= 200 && status < 300) {
                var check = StockRegisterModel.validateAnswer(body, win)
                if (!check.ok) {
                    console.warn("[StockRegisterService] answer refused:", check.reason)
                    _fail(callback, "badAnswer")
                    return
                }
                lastBody = body
                lastWindow = win
                lastTenantId = tenantAtSend
                lastRole = roleAtSend
                _answer(callback, { ok: true, body: body, window: win })
                return
            }
            var c = StockRegisterModel.classify(status, body)
            console.warn("[StockRegisterService] failed", status, c.kind)
            // A 401 usually means the token expired: ask the one silent door (sessionRecheckWiring pins that no
            // other file calls refreshIdToken(true)) so the person's next tap works. No retry here: single flight.
            if (c.kind === "auth" && typeof AuthService !== "undefined" && AuthService)
                AuthService.ensureFreshToken()
            _answer(callback, { ok: false, kind: c.kind, message: c.message, retryable: c.retryable })
        }

        xhr.onreadystatechange = function() {
            _captureBeforeStatusIsLost(xhr, snap)
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var lost = xhr.status === 0
            settle(lost ? snap.status : xhr.status, lost ? snap.responseText : xhr.responseText)
        }
        xhr.ontimeout = function() { settle(0, "") }
        xhr.open("POST", functionUrl)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        xhr.timeout = requestTimeoutMs
        var envelope = StockRegisterModel.requestBody(win)
        envelope.env = FirebaseService.environment
        xhr.send(JSON.stringify(envelope))
        return true
    }

    // Stops waiting. The server keeps reading (and billing) until it finishes; this only frees the screen.
    function cancel() {
        if (!loading) return
        var cb = _pendingCallback
        var xhr = _xhr
        _generation++
        _xhr = null
        _pendingCallback = null
        loading = false
        try { if (xhr) xhr.abort() } catch (e) { }
        _fail(cb, "cancelled")
    }
}
