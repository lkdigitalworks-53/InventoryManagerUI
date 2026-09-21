.pragma library

// Pure numbers and arithmetic behind Gateway's send timeouts and retry jitter.
// Design: docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
//
// Gateway owns the Timer and the XHR; nothing here touches QML, the outbox or the
// network, so it has a headless test (tests/tst_SendPolicy.qml).
//
// Both timeouts are starting values, NOT measured: tune them on a device after the
// first real runs (Cloud Function cold starts in asia-south1 are the thing to watch).

// Background outbox drain: nobody is waiting, so be generous.
var TIMEOUT_BACKGROUND_MS = 30000

// Foreground "server first" wait: a person is looking at a spinner, so be short.
var TIMEOUT_AWAIT_MS = 10000

// +-20% around the outbox backoff delay, so two devices that reconnect together do
// not retry in lockstep.
var JITTER_FRACTION = 0.2

// rand is Math.random() in production and a fixed value in tests, in [0, 1).
function jittered(delayMs, rand) {
    return Math.round(delayMs * (1 - JITTER_FRACTION + 2 * JITTER_FRACTION * rand))
}
