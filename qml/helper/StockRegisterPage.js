.pragma library
.import "StockRegisterModel.js" as Model

// P1 S4b-2: every decision the stock register PAGE makes, as pure functions, so StockRegisterPage.qml only holds
// state and paints (Skill 161 rule 1: qmltestrunner cannot load a Felgo page, so a decision inside it would be
// untested until a device). No QML, no singletons, no local-time getters (periods and the "as of" time are IST
// by UTC arithmetic, design D2). Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md section 8.

var CHIPS = ["This month", "Last month", "This quarter", "Last quarter", "This FY", "Last FY", "Custom"]
// The chip after the six presets. A guard test pins CHIPS.length === Model.PRESETS.length + 1.
var CUSTOM_INDEX = 6

// Keys of every ListModel row, in order. A wiring test requires StockRegisterPage.qml's row delegate to declare
// `required property` names equal to these (Skill 161 rule 2). `id` is NOT a key: it is a reserved QML word.
var ROW_KEYS = ["productId", "title", "note", "reconciles", "openingText", "inText", "outText", "closingText", "rowName"]

function _isInt(x) { return typeof x === "number" && isFinite(x) && Math.floor(x) === x }
function _trim(s) { return typeof s === "string" ? s.trim() : "" }
function _plural(n, one, many) { return n + " " + (n === 1 ? one : many) }

function chipLabels() { return CHIPS.slice() }

// The window for the chosen chip. A preset chip needs `nowMs` (an instant, never a local calendar part); the
// custom chip needs two typed "YYYY-MM-DD" days. Returns { ok:true, win } or { ok:false, text }.
// (A negative index needs no guard of its own: PRESETS[-1] is undefined and presetWindow refuses it; a mutant proved it.)
function resolveWindow(chipIndex, fromText, toText, nowMs) {
    if (!_isInt(chipIndex) || chipIndex > CUSTOM_INDEX) return { ok: false, text: Model.message("window") }
    if (chipIndex < CUSTOM_INDEX) {
        var p = Model.presetWindow(Model.PRESETS[chipIndex], nowMs)
        return p.ok ? { ok: true, win: p } : { ok: false, text: Model.message("window") }
    }
    var c = Model.customWindow(_trim(fromText), _trim(toText))
    return c.ok ? { ok: true, win: c } : { ok: false, text: Model.customErrorText(c.error) }
}

// May a tap on the load button send a request? ctx: { loading, online, role, resolved } where `resolved` is the
// result of resolveWindow. Order matters: a second tap while loading is silent (the first request is the answer),
// a bad window is worded before role or network. Returns { go:true } or { go:false, kind, text }.
function tapDecision(ctx) {
    var c = ctx && typeof ctx === "object" ? ctx : {}
    if (c.loading === true) return { go: false, kind: "busy", text: "" }
    if (!c.resolved || c.resolved.ok !== true) {
        return { go: false, kind: "window", text: c.resolved && typeof c.resolved.text === "string" ? c.resolved.text : Model.message("window") }
    }
    if (!Model.canView(c.role)) return { go: false, kind: "role", text: Model.message("role") }
    if (c.online !== true) return { go: false, kind: "offline", text: Model.message("offline") }
    return { go: true, kind: "", text: "" }
}

// A page state: status idle | ok | error (loading is the service's own flag, the single latch, Skill 155 rule 1);
// rows are ListModel rows; `win` is the window the shown answer is for (null unless status is ok).
function initialState() {
    return { status: "idle", rows: [], summary: null, body: null, win: null, text: "", retryable: true }
}

function _error(text, retryable) {
    return { status: "error", rows: [], summary: null, body: null, win: null, text: text, retryable: retryable }
}

function _ok(body, win, showAll) {
    var v = Model.buildView(body, win, { showAll: showAll === true })
    if (!v.ok) return _error(Model.message("badAnswer"), true)
    var rows = []
    for (var i = 0; i < v.rows.length; i++) rows.push(toListRow(v.rows[i]))
    return { status: "ok", rows: rows, summary: v.summary, body: body, win: win, text: "", retryable: true }
}

// The page state for a service answer (StockRegisterService.load callback). Returns the NEW state, or null when
// the answer must leave the page as it is ("busy": another request is the real answer; "cancelled": the person
// or a workspace change stopped it, the caller resets the state itself).
function stateFromResult(result, win, showAll) {
    if (!result || typeof result !== "object") return _error(Model.message("unknown"), true)
    if (result.ok === true) return _ok(result.body, win, showAll)
    if (result.kind === "busy" || result.kind === "cancelled") return null
    var text = typeof result.message === "string" && result.message !== "" ? result.message : Model.message(result.kind)
    return _error(text, result.retryable !== false)
}

// The page state for a tap the page refused itself (tapDecision gave go:false). null for "busy" (silent).
// Only the offline refusal is worth retrying: a bad window or a refused role will not change by tapping again.
function stateFromRefusal(d) {
    if (!d || typeof d !== "object" || d.go === true || d.kind === "busy") return null
    return _error(typeof d.text === "string" ? d.text : Model.message("unknown"), d.kind === "offline")
}

// The state for a window that already has a good answer in the service's memory (no request, no cost; design D9).
// `cached` is StockRegisterService.cached(win): { body, window } or null.
function stateFromCache(cached, win, showAll) {
    if (!cached || typeof cached !== "object" || !cached.body) return initialState()
    return _ok(cached.body, win, showAll)
}

// The "show all products" switch re-reads the same answer; nothing is requested.
function stateFromBody(body, win, showAll) {
    return body ? _ok(body, win, showAll) : initialState()
}

// A ListModel row: flat, every key present, no reserved word (rename `id`), plus one accessible sentence.
function toListRow(r) {
    var name = r.title + ". Opening " + r.openingText + ", in " + r.inText + ", out " + r.outText + ", closing " + r.closingText + "."
    return {
        productId: r.id,
        title: r.title,
        note: r.note,
        reconciles: r.reconciles === true,
        openingText: r.openingText,
        inText: r.inText,
        outText: r.outText,
        closingText: r.closingText,
        rowName: r.note !== "" ? name + " " + r.note + "." : name
    }
}

function loadLabel(status, retryable) {
    if (status === "ok") return "Reload register"
    if (status === "error" && retryable === true) return "Try again"
    return "Load register"
}

// Under the custom chip the person is still typing: nothing to complain about until a field has text.
function inlineError(chipIndex, fromText, toText, resolved) {
    if (resolved && resolved.ok === true) return ""
    if (chipIndex === CUSTOM_INDEX && _trim(fromText) === "" && _trim(toText) === "") return ""
    return resolved && typeof resolved.text === "string" ? resolved.text : Model.message("window")
}

// The period line: the window the shown answer is for when there is one, else the window the chips point at.
function captionText(shownWin, resolved) {
    if (shownWin && typeof shownWin.text === "string" && shownWin.text !== "") return shownWin.text
    return resolved && resolved.ok === true && resolved.win ? resolved.win.text : ""
}

// The per-kind lines of one row, only while that row is the open one.
function detailRows(body, expandedId, productId) {
    return expandedId === productId ? Model.detailFor(body, productId) : []
}

var IDLE_TEXT = "Pick a period, then tap Load register. It reads the whole stock ledger, so it loads only when you ask."
var LOADING_TEXT = "Reading the stock ledger. A big shop can take up to two minutes. Cancel only stops waiting here."
var DETAIL_EMPTY = "No stock movement in this period."

// Tap a row: open its per-kind lines, or close it when it is already open. One row open at a time.
function nextExpanded(current, productId) {
    return current === productId ? "" : productId
}

function summaryText(summary) {
    if (!summary || typeof summary !== "object") return ""
    var t = _plural(summary.shown, "product", "products") + " shown"
    if (summary.hiddenQuiet > 0) t += ", " + summary.hiddenQuiet + " with no stock history hidden"
    return t
}

// One line per thing the person must know before trusting the numbers (Skill 163 rule 5). [] = nothing to warn.
function warningLines(summary) {
    if (!summary || typeof summary !== "object") return []
    var out = []
    if (summary.mismatches > 0) out.push(_plural(summary.mismatches, "product", "products") + " where the ledger and the stock count disagree.")
    if (summary.skippedLedgerRows > 0) out.push(_plural(summary.skippedLedgerRows, "ledger row", "ledger rows") + " could not be read and are not in these numbers.")
    if (summary.droppedBad > 0) out.push(_plural(summary.droppedBad, "product row", "product rows") + " from the server were unreadable and are not shown.")
    return out
}

// When the shown list is empty: say why, never blank.
function emptyText(summary) {
    if (!summary || typeof summary !== "object") return ""
    if (summary.hiddenQuiet > 0) return "Nothing to show for this period. " + _plural(summary.hiddenQuiet, "product has", "products have") + " no stock history; use \"Show all products\" to list them."
    return "No products in this workspace yet."
}

// "as of 20 Nov 2026, 3:42 pm (IST)" from the server's read time; "" when it is missing. UTC arithmetic only.
function asOfText(readAtMs) {
    if (typeof readAtMs !== "number" || !isFinite(readAtMs) || readAtMs <= 0) return ""
    var d = new Date(readAtMs + Model.IST_OFFSET_MS)
    if (isNaN(d.getTime())) return ""   // a finite number past the Date range (about 8.64e15 ms) gives an Invalid Date
    var h = d.getUTCHours(), m = d.getUTCMinutes()
    var h12 = h % 12 === 0 ? 12 : h % 12
    return "as of " + d.getUTCDate() + " " + Model.MONTHS[d.getUTCMonth()] + " " + d.getUTCFullYear() + ", " +
           h12 + ":" + (m < 10 ? "0" + m : m) + " " + (h < 12 ? "am" : "pm") + " (IST)"
}

// The same line from the summary of a shown answer; "" when there is none.
function summaryAsOf(summary) {
    return summary && typeof summary === "object" ? asOfText(summary.readAt) : ""
}
