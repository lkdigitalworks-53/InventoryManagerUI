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
