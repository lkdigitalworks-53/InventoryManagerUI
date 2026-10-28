.pragma library

// P1 (CGST Rule 56(2)) client side of the stock-movement ledger. The SERVER builds and stamps every
// ledger row (functions/lib/movementLogic.js); the client only DESCRIBES the event: { kind, qty,
// reason }. Pure: no QML/singleton deps, so it is unit-testable and the parity test can run it in Node.
//
// MIRRORS functions/lib/movementLogic.js (KIND_DIRECTION, MAX_MOVEMENTS, MAX_REASON) and the delta
// checks in functions/lib/gatewayLogic.js validateDeltaRequest. Change both together; the Node test
// functions/test/stockMovementsParity.test.js fails when they drift.
//
// Why a client-side validator at all: the server rejects a bad `movements` with a TERMINAL 4xx. A
// terminal rejection of a queued write is parked or dropped, so a client bug here would lose a stock
// change, not just a label. Refusing before the call is queued leaves nothing half-done.

var KIND_DIRECTION = {
    receipt: 1,
    sales_return: 1,
    sale: -1,
    loss: -1,
    theft: -1,
    destroyed: -1,
    write_off: -1,
    free_sample: -1,
    gift: -1,
    adjustment: 0
}
var MAX_MOVEMENTS = 50
var MAX_REASON = 500
var EPSILON = 1e-9

function _hasKeys(obj) {
    if (!obj || typeof obj !== "object") return false
    for (var k in obj) if (Object.prototype.hasOwnProperty.call(obj, k)) return true
    return false
}

// True for a non-empty movements array (the only shape that means "explicit movements").
function hasMovements(movements) {
    return Array.isArray(movements) && movements.length > 0
}

// One movement description. `reason` is trimmed and cut to the server's limit so a long free-text
// reason can never turn a valid restock into a rejected one. valueAtCost is deliberately not sent:
// it is only meaningful for the intent kinds (loss, theft, ...) that arrive with S2e.
function make(kind, qty, reason) {
    var text = (typeof reason === "string") ? reason.trim() : ""
    if (text.length > MAX_REASON) text = text.substring(0, MAX_REASON).trim()
    return { kind: kind, qty: qty, reason: text }
}

// "" when the delta call is acceptable, else the error code. Same codes as the server where one
// exists; `movements-with-clamps` is client-only (the server's own check is the applied-delta
// mismatch, which the client cannot predict, so any clamp next to explicit movements is refused).
// `movements` undefined/null means "no explicit movements": the server derives the row. That is
// always valid here.
function validate(entity, deltas, clamps, movements) {
    if (movements === undefined || movements === null) return ""
    if (!Array.isArray(movements) || movements.length === 0) return "invalid-movements"
    if (movements.length > MAX_MOVEMENTS) return "too-many-movements"
    if (entity !== "inventory") return "movements-require-inventory"
    if (!deltas || typeof deltas.stock !== "number" || !isFinite(deltas.stock))
        return "movements-require-stock-delta"
    if (_hasKeys(clamps)) return "movements-with-clamps"

    var sum = 0
    for (var i = 0; i < movements.length; ++i) {
        var m = movements[i]
        if (!m || typeof m !== "object") return "invalid-movements"
        if (!Object.prototype.hasOwnProperty.call(KIND_DIRECTION, m.kind)) return "invalid-movement-kind"
        if (typeof m.qty !== "number" || !isFinite(m.qty) || m.qty === 0) return "invalid-movement-qty"
        var direction = KIND_DIRECTION[m.kind]
        if (direction !== 0 && (m.qty > 0 ? 1 : -1) !== direction) return "invalid-movement-qty"
        if (m.reason !== undefined && m.reason !== null
                && (typeof m.reason !== "string" || m.reason.length > MAX_REASON))
            return "invalid-movement-reason"
        sum += m.qty
    }
    if (Math.abs(sum - deltas.stock) > EPSILON) return "movement-qty-mismatch"
    return ""
}

// May two held delta calls for the same record become ONE outbox item? The server needs
// sum(movements.qty) == the delta it applies, so:
//   - neither side explicit: the old rule (sum the deltas), unchanged for stock_batch and the
//     clamped imported-order deduction;
//   - one side explicit, the other derived: NO (merging would leave part of the delta unexplained);
//   - both explicit: yes, movements concatenate, unless a clamp is present or the total would pass
//     the server's per-request cap (then a second item is queued instead).
// `a` and `b` are outbox items / calls: { movements?, clamps? }.
function canCoalesce(a, b) {
    var aExplicit = hasMovements(a && a.movements)
    var bExplicit = hasMovements(b && b.movements)
    if (!aExplicit && !bExplicit) return true
    if (aExplicit !== bExplicit) return false
    if (_hasKeys(a.clamps) || _hasKeys(b.clamps)) return false
    return a.movements.length + b.movements.length <= MAX_MOVEMENTS
}

// Movements of two coalesced calls, in call order. Only meaningful when canCoalesce() was true.
function mergeMovements(a, b) {
    var out = hasMovements(a) ? a.slice() : []
    return hasMovements(b) ? out.concat(b) : out
}
