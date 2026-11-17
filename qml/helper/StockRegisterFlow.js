.pragma library
.import "StockRegisterModel.js" as M

// P1 S4b-2: every decision the stock register PAGE makes, as pure functions, so StockRegisterPage.qml (Felgo,
// not loadable under qmltestrunner) only holds one state object and paints what `view` returns.
// The state is a plain object, never edited in place: each function returns a NEW state. The service is passed in
// (`svc`: load / cancel / clear / cached), so Node runs the real flow against a fake and CI runs it in the Qt engine.
// Design: docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md section 5 and the S4b-2 addendum.
//
// Invariant (a monkey test asserts it after every step): `body` is null, or it is the answer for exactly `win`.
// A chip or a custom day change replaces `body` with the cached answer for the new window, or with null.

var CHIPS = [
    { preset: "month", label: "This month" },
    { preset: "lastMonth", label: "Last month" },
    { preset: "quarter", label: "This quarter" },
    { preset: "lastQuarter", label: "Last quarter" },
    { preset: "fy", label: "This FY" },
    { preset: "lastFy", label: "Last FY" },
    { preset: "custom", label: "Custom" }
]

var PERIOD_NOTE = "Closing is the balance at the end of the period. For a period that has not ended it is today's balance."
var NO_DETAIL = "No stock moved in this period."
var CUSTOM_BLANK = "Enter the first and last day as YYYY-MM-DD."
var DAY_NOTE = "Both days are included."

function _isObj(x) { return x !== null && typeof x === "object" && !Array.isArray(x) }
function _has(o, k) { return Object.prototype.hasOwnProperty.call(o, k) }

function _with(s, patch) {
    var o = {}
    for (var k in s) if (_has(s, k)) o[k] = s[k]
    for (var p in patch) if (_has(patch, p)) o[p] = patch[p]
    return o
}

function initial() {
    return { preset: "month", customFrom: "", customTo: "", showAll: false, phase: "idle", error: null,
             body: null, win: null, expandedId: "" }
}

function chipLabels() {
    var out = []
    for (var i = 0; i < CHIPS.length; i++) out.push(CHIPS[i].label)
    return out
}

function chipIndex(preset) {
    for (var i = 0; i < CHIPS.length; i++) if (CHIPS[i].preset === preset) return i
    return 0
}

// ---- the selected window -----------------------------------------------------------------------------------

// { ok:true, win } | { ok:false, message, blank }. A custom range with an empty field is "blank" (a hint, not an
// error); a non-blank one that does not parse carries the model's words.
function windowFor(state, nowMs) {
    if (state.preset !== "custom") {
        var p = M.presetWindow(state.preset, nowMs)
        return p.ok ? { ok: true, win: p } : { ok: false, message: M.message("unknown"), blank: false }
    }
    var f = String(state.customFrom).trim(), t = String(state.customTo).trim()
    if (f === "" || t === "") return { ok: false, message: CUSTOM_BLANK, blank: true }
    var c = M.customWindow(f, t)
    return c.ok ? { ok: true, win: c } : { ok: false, message: M.customErrorText(c.error), blank: false }
}

// Attach the cached answer (if the service holds one for this exact window, workspace and role) to a state whose
// body is empty. A cache hit shows the figures at once, with no request.
function _attach(s, nowMs, svc) {
    var w = windowFor(s, nowMs)
    if (!w.ok || !svc || typeof svc.cached !== "function") return s
    var c = svc.cached(w.win)
    if (!c || !c.body || !c.window) return s
    return _with(s, { body: c.body, win: c.window, phase: "shown" })
}

function _cleared(state, patch) {
    return _with(state, _with({ phase: "idle", error: null, body: null, win: null, expandedId: "" }, patch || {}))
}

// ---- taps --------------------------------------------------------------------------------------------------

// Chips, custom days and Load are locked while a request flies (the answer is for the window that was sent).
function selectChip(state, index, nowMs, svc) {
    if (state.phase === "loading") return state
    if (typeof index !== "number" || index !== Math.floor(index) || index < 0 || index >= CHIPS.length) return state
    return _attach(_cleared(state, { preset: CHIPS[index].preset }), nowMs, svc)
}

function setCustom(state, from, to, nowMs, svc) {
    if (state.phase === "loading") return state
    var f = typeof from === "string" ? from : "", t = typeof to === "string" ? to : ""
    if (f === state.customFrom && t === state.customTo) return state
    // The days only matter while "Custom" is selected: a shown register for another chip stays.
    if (state.preset !== "custom") return _with(state, { customFrom: f, customTo: t })
    return _attach(_cleared(state, { customFrom: f, customTo: t }), nowMs, svc)
}

function toggleShowAll(state) {
    return _with(state, { showAll: !state.showAll, expandedId: "" })
}

function toggleExpand(state, id) {
    if (typeof id !== "string" || id === "") return state
    return _with(state, { expandedId: state.expandedId === id ? "" : id })
}

// Re-evaluate the selection when the page is shown: a month may have turned, or the service may hold an answer.
function onOpen(state, nowMs, svc) {
    if (state.phase === "loading") return state
    var w = windowFor(state, nowMs)
    if (!w.ok) return state
    if (state.body && state.win && M.windowKey(state.win) === M.windowKey(w.win)) return state
    return _attach(_cleared(state), nowMs, svc)
}

// ---- the request ---------------------------------------------------------------------------------------------

function _settledPhase(state) { return state.body ? "shown" : "idle" }

// The service answered. A callback that lands when the page is no longer loading (reset, sign-out) is ignored.
function applyResult(state, win, r) {
    if (state.phase !== "loading") return state
    if (!_isObj(r)) return _with(state, { phase: _settledPhase(state), error: null })
    if (r.ok === true) {
        if (!M.validateAnswer(r.body, win).ok) {
            return _with(state, { phase: "error", error: { kind: "badAnswer", message: M.message("badAnswer"), retryable: true } })
        }
        return _with(state, { phase: "shown", error: null, body: r.body, win: win, expandedId: "" })
    }
    // Not errors: the caller shows nothing for these (busy: another load owns the service; cancelled: we asked).
    if (r.kind === "busy" || r.kind === "cancelled") return _with(state, { phase: _settledPhase(state), error: null })
    return _with(state, {
        phase: "error",
        error: { kind: String(r.kind), message: typeof r.message === "string" && r.message !== "" ? r.message : M.message("unknown"),
                 retryable: r.retryable !== false }
    })
}

// ctx = { get(): state, set(state) }. The loading state is committed BEFORE the service is called: a refusal
// can answer synchronously, and its result must land on top of "loading", not under it.
function startLoad(ctx, nowMs, svc, role) {
    var s = ctx.get()
    if (s.phase === "loading") return false
    var w = windowFor(s, nowMs)
    if (!w.ok) {
        if (!w.blank) ctx.set(_with(s, { phase: "error", error: { kind: "window", message: w.message, retryable: false } }))
        return false
    }
    if (!M.canView(role)) {
        ctx.set(_with(s, { phase: "error", error: { kind: "role", message: M.message("role"), retryable: false } }))
        return false
    }
    ctx.set(_with(s, { phase: "loading", error: null }))
    return svc.load(w.win, function(result) { ctx.set(applyResult(ctx.get(), w.win, result)) })
}

// The page's tap handler caught an exception between "loading" and the service's answer (a missing singleton, a
// failed property read): nothing is pending, so "loading" would stay for good. Settle with words and a retry.
function crashed(state) {
    return _with(state, { phase: "error", error: { kind: "unknown", message: M.message("unknown"), retryable: true } })
}

// Stops waiting (the server keeps scanning). The service answers "cancelled", which settles the state.
function cancelLoad(ctx, svc) {
    if (ctx.get().phase === "loading") svc.cancel()
}

// Workspace change, lost role, sign-out. The cache holds a whole register: dropped on request (sign-out, workspace
// switch), kept for a role change.
function reset(ctx, svc, clearCache) {
    ctx.set(initial())
    svc.cancel()
    if (clearCache === true) svc.clear()
}

// ---- what the page paints ----------------------------------------------------------------------------------

function asOfText(ms) {
    if (typeof ms !== "number" || !isFinite(ms) || ms <= 0) return ""
    var d = new Date(ms + M.IST_OFFSET_MS)
    var h = d.getUTCHours(), mi = d.getUTCMinutes()
    var hh = h % 12 === 0 ? 12 : h % 12
    return d.getUTCDate() + " " + M.MONTHS[d.getUTCMonth()] + " " + d.getUTCFullYear() + ", " + hh + ":" +
           (mi < 10 ? "0" + mi : mi) + " " + (h < 12 ? "am" : "pm") + " IST"
}

function _plural(n, one, many) { return n + " " + (n === 1 ? one : many) }

function _warnings(sum) {
    var w = []
    if (sum.skippedLedgerRows > 0) {
        w.push(_plural(sum.skippedLedgerRows, "stock ledger row", "stock ledger rows") + " could not be read and " +
               (sum.skippedLedgerRows === 1 ? "is" : "are") + " not in these figures.")
    }
    if (sum.droppedBad > 0) {
        w.push(_plural(sum.droppedBad, "product", "products") + " in the answer could not be read and " +
               (sum.droppedBad === 1 ? "is" : "are") + " not listed.")
    }
    if (sum.mismatches > 0) {
        w.push(_plural(sum.mismatches, "product", "products") + " where the ledger and the stock figure disagree " +
               "(marked below).")
    }
    return w
}

// One flat object: strings, numbers, booleans, one array of flat rows, one array of strings.
function view(state, nowMs, role) {
    var w = windowFor(state, nowMs)
    var key = w.ok ? M.windowKey(w.win) : ""
    var data = !!(state.win && w.ok && M.windowKey(state.win) === key)
    var v = data ? M.buildView(state.body, state.win, { showAll: state.showAll }) : null
    if (v && !v.ok) { v = null; data = false }
    var loading = state.phase === "loading"
    var allowed = M.canView(role)
    var sum = v ? v.summary : null
    var rows = v ? v.rows : []
    var asOf = sum ? asOfText(sum.readAt) : ""
    var err = loading ? null : state.error
    var errorText = ""
    if (!allowed) errorText = M.message("role")
    else if (err) errorText = err.message
    var retry = !!(err && err.retryable === true && allowed)

    var loadLabel = "Load register"
    if (loading) loadLabel = "Loading\u2026"
    else if (retry) loadLabel = "Try again"
    else if (data) loadLabel = "Reload"

    var summaryText = ""
    var emptyText = ""
    if (sum) {
        summaryText = _plural(sum.shown, "product", "products") + " shown"
        if (sum.hiddenQuiet > 0) summaryText += ", " + sum.hiddenQuiet + " with no movement hidden"
        if (rows.length === 0) {
            emptyText = sum.hiddenQuiet > 0
                ? "No product moved in this period. " + _plural(sum.hiddenQuiet, "product with no movement is", "products with no movement are") + " hidden."
                : "There are no products to show."
        }
    }
    return {
        chips: chipLabels(),
        chipIndex: chipIndex(state.preset),
        custom: state.preset === "custom",
        caption: w.ok ? (state.preset === "custom" ? w.win.text : w.win.label + " \u00b7 " + w.win.text) : w.message,
        captionIsError: !w.ok && !w.blank,
        dayNote: DAY_NOTE,
        loading: loading,
        canLoad: !loading && w.ok && allowed,
        loadLabel: loadLabel,
        canCancel: loading,
        locked: loading,
        hasData: data,
        asOf: asOf === "" ? "" : "As of " + asOf,
        running: !!(sum && state.win && sum.readAt > 0 && state.win.toMs > sum.readAt),
        periodNote: PERIOD_NOTE,
        summaryText: summaryText,
        warnings: sum ? _warnings(sum) : [],
        hasWarning: !!(sum && sum.hasWarning),
        rows: rows,
        emptyText: emptyText,
        showToggle: !!(sum && (sum.hiddenQuiet > 0 || state.showAll)),
        showAll: state.showAll === true,
        toggleText: state.showAll ? "Hide products with no movement" : "Show products with no movement",
        errorText: errorText,
        canRetry: retry,
        staleNote: data && err ? "The figures below are from the earlier load" + (asOf !== "" ? ", as of " + asOf : "") + "." : ""
    }
}

// Rows are flat records; two lists are the same when every key of every row is strictly equal. A page assigns a
// new list to its ListView only when this is false (a new array resets the scroll position, Skill 161 rule 3).
function sameRows(a, b) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) {
        var x = a[i], y = b[i]
        if (!_isObj(x) || !_isObj(y)) return false
        var kx = 0, ky = 0
        for (var k in x) if (_has(x, k)) { kx++; if (x[k] !== y[k]) return false }
        for (var j in y) if (_has(y, j)) ky++
        if (kx !== ky) return false
    }
    return true
}

// The kinds a product moved in this period for the open row.
function detailFor(state, id) {
    return M.detailFor(state.body, id)
}

// One sentence a screen reader says for a row.
function rowSpeech(row) {
    if (!_isObj(row)) return ""
    return row.title + ". Opening " + row.openingText + ", in " + row.inText + ", out " + row.outText +
           ", closing " + row.closingText + "." + (row.note !== "" ? " " + row.note + "." : "")
}
