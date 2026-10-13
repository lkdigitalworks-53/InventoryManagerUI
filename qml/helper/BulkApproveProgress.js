.pragma library

// Pure state for the Orders banner's "Approve all pending" button: pressed/busy look,
// progress bar and the short "All approved" hold at the end. Design:
// docs/superpowers/test-plans/2026-10-13-approve-all-progress-test-plan.md.
//
// OrdersPage owns one state object and replaces it with the result of each call (never
// mutates), so QML bindings re-evaluate. Nothing here touches QML, stores or timers, so it
// has a headless test (tests/tst_BulkApproveProgress.qml).
//
// phase: "idle" (nothing running) -> "running" (start, total > 0) -> "done" (every order
// reported) -> back to "idle" when OrdersPage's hold Timer calls newState().
// Outcomes: "ok" | "failed" | "locked". Any other value counts as "failed" (a wrong
// answer must never show as approved).
//
// shortcut: no watchdog. If a completion callback never fires the state stays "running" and
// the button stays disabled until the page is rebuilt; upgrade when LockManager or
// DataModel.tryCompleteOrder can be shown to hang.

function newState() { return { phase: "idle", total: 0, done: 0, failed: 0, lockedOut: 0 } }

// Only an idle state may start a run. This is the re-entrancy guard: a second tap while
// running (or during the end hold) is refused, so no second loop reports false "failed" orders.
function canStart(state) { return !!state && state.phase === "idle" }

// A run of 0 orders (or a non-finite count) stays idle: nothing to show, and a total that
// can never be reached would leave the button disabled forever.
function start(total) {
    var n = Math.floor(Number(total))
    if (!(n > 0) || !isFinite(n)) return newState()
    return { phase: "running", total: n, done: 0, failed: 0, lockedOut: 0 }
}

// Late or duplicate callbacks (not running, or already counted all orders) change nothing.
function step(state, outcome) {
    if (!state || state.phase !== "running" || state.done >= state.total) return state
    var done = state.done + 1
    return {
        phase: done >= state.total ? "done" : "running",
        total: state.total,
        done: done,
        failed: state.failed + (outcome !== "ok" && outcome !== "locked" ? 1 : 0),
        lockedOut: state.lockedOut + (outcome === "locked" ? 1 : 0)
    }
}

// 0..1 for the bar. Idle shows nothing; done is full.
function fraction(state) {
    if (!state || state.phase === "idle" || !(state.total > 0)) return 0
    return Math.min(1, state.done / state.total)
}

function approved(state) { return state ? state.done - state.failed - state.lockedOut : 0 }

// True only when every order of a finished run was approved.
function allOk(state) { return !!state && state.phase === "done" && approved(state) === state.total }
