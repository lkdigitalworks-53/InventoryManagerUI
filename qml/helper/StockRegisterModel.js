.pragma library

// P1 S4b-1: every decision the stock-register client makes, as pure functions (no QML, no singletons, no
// local-time getters). StockRegisterService.qml only sends and receives; a page (S4b-2) only paints what
// buildView returns. Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md
// Server contract: docs/superpowers/specs/2026-11-11-p1-s4a-stock-register-design.md section 3.

// ---- constants -------------------------------------------------------------------------------------------

// Periods are Indian statutory periods in IST (UTC+05:30, no DST), computed with UTC arithmetic only, so the
// answer never depends on the phone's time zone (design D2).
var IST_OFFSET_MS = 19800000
var MIN_YEAR = 2000
var MAX_YEAR = 2100

// Mirrors functions/lib/stockRegisterMath.js REGISTER_ROLES; a guard test parses both so they cannot drift.
var REGISTER_ROLES = ["owner", "admin", "manager"]

// Same order as functions/lib/movementLogic.js KIND_DIRECTION; a guard test pins it.
var KINDS = ["receipt", "sales_return", "sale", "loss", "theft", "destroyed", "write_off", "free_sample", "gift", "adjustment"]
var KIND_LABELS = {
    receipt: "Received", sales_return: "Sales return", sale: "Sold", loss: "Loss", theft: "Theft",
    destroyed: "Destroyed", write_off: "Written off", free_sample: "Free sample", gift: "Gift",
    adjustment: "Adjustment"
}

var PRESETS = ["month", "lastMonth", "quarter", "lastQuarter", "fy", "lastFy"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var MSG = {
    role: "Only the owner, an admin or a manager can open the stock register.",
    notSignedIn: "Sign in again to open the stock register.",
    auth: "Your sign-in has expired. Tap to try again.",
    tenant: "This workspace is not ready yet. Try again in a moment.",
    window: "That date range is not valid.",
    tooLarge: "The stock ledger is too large for this report. It needs a support fix.",
    timeout: "The server took too long to build the register. Try a quieter moment.",
    server: "The server could not build the register. Try again.",
    offline: "No answer from the server. Check your connection and try again.",
    badAnswer: "The server's answer did not match the request, so it was not shown. Try again.",
    unknown: "Something went wrong. Try again.",
    // Not errors: the caller shows nothing for these.
    busy: "",
    cancelled: ""
}

// ---- small helpers ---------------------------------------------------------------------------------------

function _isNum(x) { return typeof x === "number" && isFinite(x) }
function _isObj(x) { return x !== null && typeof x === "object" && !Array.isArray(x) }
function _has(o, k) { return Object.prototype.hasOwnProperty.call(o, k) }

function canView(role) {
    return REGISTER_ROLES.indexOf(role) >= 0   // strict equality: a non-string never matches
}

// Epoch ms of IST midnight for a 0-based month; month and day may overflow (Date.UTC normalises).
function istMidnight(year, month0, day) {
    return Date.UTC(year, month0, day) - IST_OFFSET_MS
}

// IST calendar parts of an instant.
function istParts(ms) {
    var d = new Date(ms + IST_OFFSET_MS)
    return { y: d.getUTCFullYear(), m: d.getUTCMonth(), d: d.getUTCDate() }
}

function _daysInMonth(year, month1) {
    var d = new Date(0)
    d.setUTCFullYear(year, month1, 0)
    return d.getUTCDate()
}

function _pad2(n) { return n < 10 ? "0" + n : String(n) }

function _dayText(ms) {
    var p = istParts(ms)
    return p.d + " " + MONTHS[p.m] + " " + p.y
}

// "1 Apr 2026 - 30 Apr 2026 (IST)" for a half-open window: the last day is the day of `to - 1 ms`.
function rangeText(fromMs, toMs) {
    if (!_isNum(fromMs) || !_isNum(toMs) || toMs <= fromMs) return ""
    return _dayText(fromMs) + " \u2013 " + _dayText(toMs - 1) + " (IST)"
}

function _fyLabel(fyYear) {
    return "FY " + fyYear + "-" + _pad2((fyYear + 1) % 100)
}

// ---- periods ---------------------------------------------------------------------------------------------

function _win(preset, label, fromMs, toMs) {
    return { ok: true, preset: preset, label: label, fromMs: fromMs, toMs: toMs, text: rangeText(fromMs, toMs) }
}

// A window for a preset, relative to `nowMs`. Returns { ok:true, preset, label, fromMs, toMs, text }
// or { ok:false, error:"bad-preset" | "bad-now" }.
function presetWindow(preset, nowMs) {
    if (typeof preset !== "string" || PRESETS.indexOf(preset) < 0) return { ok: false, error: "bad-preset" }
    if (!_isNum(nowMs) || nowMs < istMidnight(MIN_YEAR, 0, 1) || nowMs >= istMidnight(MAX_YEAR + 1, 0, 1)) {
        return { ok: false, error: "bad-now" }
    }
    var p = istParts(nowMs)
    var fyYear = p.m >= 3 ? p.y : p.y - 1                 // FY starts on 1 April
    var q = Math.floor(((p.m - 3 + 12) % 12) / 3)         // 0..3 = Apr-Jun .. Jan-Mar
    var qStartMonth = 3 + 3 * q                           // months from January of fyYear (may exceed 11)

    if (preset === "month" || preset === "lastMonth") {
        var mo = preset === "month" ? p.m : p.m - 1
        var from = istMidnight(p.y, mo, 1)
        var fp = istParts(from)
        return _win(preset, MONTHS[fp.m] + " " + fp.y, from, istMidnight(p.y, mo + 1, 1))
    }
    if (preset === "quarter" || preset === "lastQuarter") {
        var sm = preset === "quarter" ? qStartMonth : qStartMonth - 3
        var qf = istMidnight(fyYear, sm, 1)
        var qt = istMidnight(fyYear, sm + 3, 1)
        var qi = ((sm - 3) % 12 + 12) % 12 / 3
        // FY of the start month: months 3..14 belong to fyYear, months before 3 belong to fyYear - 1.
        var fyOfQ = sm < 3 ? fyYear - 1 : fyYear
        var a = istParts(qf), b = istParts(qt - 1)
        return _win(preset, "Q" + (qi + 1) + " " + _fyLabel(fyOfQ) + " (" + MONTHS[a.m] + "\u2013" + MONTHS[b.m] + ")", qf, qt)
    }
    var y = preset === "fy" ? fyYear : fyYear - 1
    return _win(preset, _fyLabel(y), istMidnight(y, 3, 1), istMidnight(y + 1, 3, 1))
}

function _parseYmd(s) {
    if (typeof s !== "string") return null
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s)
    if (!m) return null
    var y = Number(m[1]), mo = Number(m[2]), d = Number(m[3])
    if (y < MIN_YEAR || y > MAX_YEAR) return { range: true }
    if (mo < 1 || mo > 12) return null
    if (d < 1 || d > _daysInMonth(y, mo)) return null     // 2026-02-30 is refused, never rolled into March
    return { y: y, m: mo, d: d }
}

// Custom range from two "YYYY-MM-DD" days, BOTH inclusive; the window is [from-day 00:00, day-after-to 00:00).
// Errors: "bad-from", "bad-to", "out-of-range" (year outside 2000-2100), "reversed".
function customWindow(fromYmd, toYmd) {
    var f = _parseYmd(fromYmd), t = _parseYmd(toYmd)
    if (f === null) return { ok: false, error: "bad-from" }
    if (t === null) return { ok: false, error: "bad-to" }
    if (f.range || t.range) return { ok: false, error: "out-of-range" }
    var fromMs = istMidnight(f.y, f.m - 1, f.d)
    var toMs = istMidnight(t.y, t.m - 1, t.d + 1)
    if (toMs <= fromMs) return { ok: false, error: "reversed" }
    return _win("custom", rangeText(fromMs, toMs).replace(" (IST)", ""), fromMs, toMs)
}

var CUSTOM_ERROR_TEXT = {
    "bad-from": "Enter the start date as a real day.",
    "bad-to": "Enter the end date as a real day.",
    "out-of-range": "Pick days between 2000 and 2100.",
    "reversed": "The end date is before the start date."
}
function customErrorText(code) {
    return (typeof code === "string" && _has(CUSTOM_ERROR_TEXT, code)) ? CUSTOM_ERROR_TEXT[code] : MSG.window
}

function windowKey(win) {
    return _isObj(win) && _isNum(win.fromMs) && _isNum(win.toMs) ? win.fromMs + ":" + win.toMs : ""
}

// The body fields the server reads, besides `env` (added by the service). Epoch ms, never a date string.
function requestBody(win) {
    return { from: win.fromMs, to: win.toMs }
}

// ---- errors ----------------------------------------------------------------------------------------------

// Words and a retry flag for a failed call. status 0 = no answer (timeout, offline). `body` may be null.
function classify(status, body) {
    var code = (_isObj(body) && typeof body.error === "string") ? body.error : ""
    if (!_isNum(status) || status === 0) return { kind: "offline", message: MSG.offline, retryable: true }
    if (status === 401) return { kind: "auth", message: MSG.auth, retryable: true }
    if (status === 403) {
        if (code === "role-not-allowed") return { kind: "role", message: MSG.role, retryable: false }
        return { kind: "tenant", message: MSG.tenant, retryable: true }
    }
    if (status === 400 && code === "invalid-window") return { kind: "window", message: MSG.window, retryable: false }
    if (status === 413) return { kind: "tooLarge", message: MSG.tooLarge, retryable: false }
    if (status === 504) return { kind: "timeout", message: MSG.timeout, retryable: true }
    if (status >= 500) return { kind: "server", message: MSG.server, retryable: true }
    return { kind: "unknown", message: MSG.unknown, retryable: true }
}

function message(key) { return _has(MSG, key) ? MSG[key] : MSG.unknown }

// ---- the answer ------------------------------------------------------------------------------------------

// Is a 200 body safe to show? The echoed window must equal the requested one: a silently moved boundary is a
// wrong statutory report with no error (Skill 163 rule 10). Returns { ok:true } or { ok:false, reason }.
function validateAnswer(body, win) {
    if (!_isObj(win)) return { ok: false, reason: "bad-window" }
    if (!_isObj(body) || body.ok !== true) return { ok: false, reason: "not-ok" }
    if (!_isObj(body.window) || body.window.fromMs !== win.fromMs || body.window.toMs !== win.toMs) {
        return { ok: false, reason: "window-mismatch" }
    }
    if (!Array.isArray(body.products)) return { ok: false, reason: "no-products" }
    return { ok: true }
}

// Quantity text: up to 3 decimals, trailing zeros dropped, Indian digit grouping (12,34,567), no "-0".
function fmtQty(n) {
    if (!_isNum(n)) return "\u2014"
    var r = Math.round(Math.abs(n) * 1000) / 1000
    if (r === 0) return "0"
    var s = r.toFixed(3).replace(/\.?0+$/, "")
    var parts = s.split(".")
    var ip = parts[0]
    if (ip.length > 3) {
        var head = ip.substring(0, ip.length - 3), tail = ip.substring(ip.length - 3)
        ip = head.replace(/\B(?=(\d{2})+(?!\d))/g, ",") + "," + tail
    }
    return (n < 0 ? "-" : "") + ip + (parts.length > 1 ? "." + parts[1] : "")
}

function _shortId(id) { return String(id).substring(0, 6) }

function _title(p) {
    var nm = typeof p.name === "string" ? p.name.trim() : ""
    return nm !== "" ? nm : "Product " + _shortId(p.productId)
}

function _note(p) {
    if (p.deleted === true) {
        return p.reconciles === true ? "Deleted product" : "Deleted product, ledger shows " + fmtQty(p.ledgerStock) + " left"
    }
    if (p.reconciles !== true) return "Ledger " + fmtQty(p.ledgerStock) + " vs stock " + fmtQty(p.currentStock)
    return ""
}

// A row with nothing to say: no movement ever, nothing before, in or after the period, and it agrees with the
// stock document. Hidden by default (design D7); a row that does NOT reconcile is never hidden.
function _isQuiet(p) {
    return p.movementCount === 0 && p.opening === 0 && p.inTotal === 0 && p.outTotal === 0 && p.closing === 0 &&
           p.reconciles === true
}

function _validProduct(p) {
    return _isObj(p) && typeof p.productId === "string" && p.productId !== "" &&
           _isNum(p.opening) && _isNum(p.inTotal) && _isNum(p.outTotal) && _isNum(p.closing) &&
           _isNum(p.currentStock) && _isNum(p.ledgerStock) && _isNum(p.movementCount) &&
           typeof p.reconciles === "boolean" && typeof p.deleted === "boolean"
}

// Server order is kept (named first, case-insensitive, deleted after): one source of truth for the order.
// Every key of every row is always present, strings/numbers/booleans only (a ListModel fixes its roles from the
// first row, Skill 161 rule 2). opts.showAll = true keeps quiet rows.
function buildView(body, win, opts) {
    var showAll = _isObj(opts) && opts.showAll === true
    var check = validateAnswer(body, win)
    if (!check.ok) return { ok: false, reason: check.reason, rows: [], summary: null }

    var rows = [], dropped = 0, quiet = 0
    for (var i = 0; i < body.products.length; i++) {
        var p = body.products[i]
        if (!_validProduct(p)) { dropped++; continue }
        if (!showAll && _isQuiet(p)) { quiet++; continue }
        rows.push({
            id: p.productId,
            title: _title(p),
            note: _note(p),
            deleted: p.deleted,
            reconciles: p.reconciles,
            moved: p.movementCount > 0,
            movementCount: p.movementCount,
            openingText: fmtQty(p.opening),
            inText: fmtQty(p.inTotal),
            outText: fmtQty(p.outTotal),
            closingText: fmtQty(p.closing),
            currentText: fmtQty(p.currentStock)
        })
    }

    var c = _isObj(body.counts) ? body.counts : {}
    var sk = _isObj(c.skipped) ? c.skipped : {}
    var skipped = 0
    for (var k in sk) if (_has(sk, k) && _isNum(sk[k])) skipped += sk[k]
    var mismatches = 0
    for (var j = 0; j < rows.length; j++) if (!rows[j].reconciles) mismatches++
    return {
        ok: true,
        reason: "",
        rows: rows,
        summary: {
            shown: rows.length,
            hiddenQuiet: quiet,
            droppedBad: dropped,
            mismatches: mismatches,
            skippedLedgerRows: skipped,
            rowsInWindow: _isNum(c.rowsInWindow) ? c.rowsInWindow : 0,
            windowText: win.text,
            label: win.label,
            // The ledger holds rows the report could not read: the person must be told (Skill 163 rule 5).
            hasWarning: skipped > 0 || dropped > 0 || mismatches > 0,
            readAt: _isNum(body.readAt) ? body.readAt : 0
        }
    }
}

// The kinds a product moved in the period, in KINDS order, then any kind this client does not know yet.
// [{ kind, label, inText, outText }]; kinds with in = out = 0 are left out.
function detailLines(product) {
    if (!_isObj(product) || !_isObj(product.kinds)) return []
    var out = []
    function add(k) {
        var e = product.kinds[k]
        if (!_isObj(e)) return
        var i = _isNum(e.in) ? e.in : 0, o = _isNum(e.out) ? e.out : 0
        if (i === 0 && o === 0) return
        out.push({ kind: k, label: _has(KIND_LABELS, k) ? KIND_LABELS[k] : k, inText: fmtQty(i), outText: fmtQty(o) })
    }
    for (var a = 0; a < KINDS.length; a++) if (_has(product.kinds, KINDS[a])) add(KINDS[a])
    for (var k in product.kinds) if (_has(product.kinds, k) && KINDS.indexOf(k) < 0) add(k)
    return out
}

function detailFor(body, productId) {
    if (!_isObj(body) || !Array.isArray(body.products)) return []
    for (var i = 0; i < body.products.length; i++) {
        var p = body.products[i]
        if (_isObj(p) && p.productId === productId) return detailLines(p)
    }
    return []
}
