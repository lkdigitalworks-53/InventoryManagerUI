.pragma library

// Deterministic ids for the atomic order-completion operation. Design:
// docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
//
// The same order at the same completion epoch always yields the same key, so a
// re-run after a hang, a restart or a sign-out/in resends the SAME requestId and
// the server replays the first result instead of applying it twice. The epoch is
// stored on the order and bumped by the operation itself, so re-completing a
// reopened order gets a fresh key.

// Number of the completion this attempt would be. Orders written before this
// field existed count as epoch 0, so their first completion is epoch 1.
function nextEpoch(order) {
    var n = order ? order.completionEpoch : 0
    return (isFinite(n) && n >= 0 && Math.floor(n) === n) ? n + 1 : 1
}

function completeOrderKey(orderId, epoch) {
    return "completeOrder:" + orderId + ":" + epoch
}

// One sale transaction doc per order line. Keeps the "tx-s-" prefix the ids always had.
function saleTxId(orderId, epoch, lineIndex) {
    return "tx-s-" + orderId + "-" + epoch + "-" + lineIndex
}

// Drift-repair batch synthesised for a line whose batches cannot cover its quantity.
function repairBatchId(orderId, epoch, lineIndex) {
    return "BAT-RPR-" + orderId + "-" + epoch + "-" + lineIndex
}

// ---- restock (atomic-ops R3, design 2026-10-16 section 4, slice design 2026-11-01-r3-restock-plan-design.md) ----
//
// A restock key is made ONCE, at the tap, and kept with the queued operation. The same key resent
// after a hang or a relaunch makes the server replay the first result, so a restock is never applied
// twice. Unlike completeOrderKey it is not derived from a record (a product can be restocked many
// times), so a sign-out that clears the outbox loses the operation (gap G4; the sign-out guard warns).

// Cap for the part after "restock:". The server allows 200 characters for the whole id; keep room.
var MAX_NONCE = 100
var _NONCE = /^[A-Za-z0-9._-]+$/

// Time plus two independent random draws (each below 36^6, about 31 bits, so about 62 bits together): two taps in the same millisecond must not
// share a key, because the server would answer the second with the first one's result and the second
// restock would silently not exist. `random` returns a number in [0, 1) (Math.random in the app).
function restockNonce(nowMs, random) {
    var a = Math.floor(random() * 2176782336).toString(36).padStart(6, "0")    // 36^6
    var b = Math.floor(random() * 2176782336).toString(36).padStart(6, "0")
    return String(Math.floor(nowMs)) + "-" + a + b
}

// "" when the nonce is not a short plain token (the server also refuses "/", "~" and long ids).
function restockKey(nonce) {
    if (typeof nonce !== "string" || nonce.length === 0 || nonce.length > MAX_NONCE || !_NONCE.test(nonce)) return ""
    return "restock:" + nonce
}

function isRestockKey(key) {
    return typeof key === "string" && key.indexOf("restock:") === 0 && restockKey(key.substring(8)) === key
}

// The purchase record of a restock. Its id is derived from the minted batch id: unique because the
// batch id is, and a replay can never produce a second one. Same "tx-p-" prefix purchases always had.
function purchaseTxId(batchId) {
    return "tx-p-" + batchId
}
