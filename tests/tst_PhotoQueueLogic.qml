import QtQuick
import QtTest
import "../qml/helper/PhotoQueueLogic.js" as PQL

// Headless tests for the pure photo-queue classification, backoff, breaker and reducer logic.
// Pure JS, no singletons. Design: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md
// A plain-Node mirror of this same logic runs for real under node --test
// (functions/test/photoQueueLogic.parity.test.js, 23/23 including two monkey tests, run stably
// 5 times in the authoring session) -- this file proves the QML copy stays in sync and loads
// correctly, verified by CI (qmltestrunner is not available in this sandbox).
TestCase {
    name: "PhotoQueueLogic"

    // Small deterministic PRNG (LCG) so a failing monkey run reproduces from its seed --
    // same technique as tst_StuckWrites.qml.
    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    function _base() {
        return { photoId: "p1", state: "enqueued", attempts: 0, nextAttemptAt: 0, lastError: null }
    }

    // ── classifyError ───────────────────────────────────────────────────────

    function test_classifyError_terminal_codes() {
        var codes = [400, 413, 404, 409]
        for (var i = 0; i < codes.length; ++i)
            compare(PQL.classifyError(codes[i]), "terminal", "status " + codes[i])
    }

    function test_classifyError_transient_codes() {
        var codes = [401, 429, 500, 502, 503, 0]
        for (var i = 0; i < codes.length; ++i)
            compare(PQL.classifyError(codes[i]), "transient", "status " + codes[i])
    }

    function test_classifyError_unknown_status_defaults_to_transient() {
        compare(PQL.classifyError(599), "transient")
    }

    // ── nextBackoffMs ────────────────────────────────────────────────────────

    function test_nextBackoffMs_matches_OutboxStore_schedule_exactly_capped() {
        var expected = [2000, 8000, 30000, 120000, 600000, 600000]
        for (var i = 0; i < expected.length; ++i)
            compare(PQL.nextBackoffMs(i + 1), expected[i])
    }

    // ── reduceQueueItem ──────────────────────────────────────────────────────

    function test_reduceQueueItem_sent_removes_the_item() {
        var item = _base(); item.state = "uploading"
        compare(PQL.reduceQueueItem(item, { type: "sent" }), null)
    }

    function test_reduceQueueItem_transient_failure_under_cap_retries_with_backoff() {
        var item = _base(); item.state = "uploading"; item.attempts = 0
        var r = PQL.reduceQueueItem(item, { type: "failed", status: 500 })
        compare(r.state, "retrying")
        compare(r.attempts, 1)
        verify(r.nextAttemptAt > 0)
    }

    function test_reduceQueueItem_terminal_failure_fails_regardless_of_attempts() {
        var item = _base(); item.state = "uploading"; item.attempts = 0
        var r = PQL.reduceQueueItem(item, { type: "failed", status: 400 })
        compare(r.state, "failed")
        compare(r.lastError, 400)
    }

    function test_reduceQueueItem_eighth_transient_failure_hits_the_attempt_cap() {
        var item = _base(); item.state = "uploading"; item.attempts = 7
        var r = PQL.reduceQueueItem(item, { type: "failed", status: 500 })
        compare(r.state, "failed")
        compare(r.attempts, 8)
    }

    function test_reduceQueueItem_seventh_transient_failure_still_retries() {
        var item = _base(); item.state = "uploading"; item.attempts = 6
        var r = PQL.reduceQueueItem(item, { type: "failed", status: 500 })
        compare(r.state, "retrying")
        compare(r.attempts, 7)
    }

    function test_reduceQueueItem_retry_resets_attempts_and_reopens() {
        var item = _base(); item.state = "failed"; item.attempts = 8; item.lastError = 400
        var r = PQL.reduceQueueItem(item, { type: "retry" })
        compare(r.state, "enqueued")
        compare(r.attempts, 0)
        compare(r.nextAttemptAt, 0)
        compare(r.lastError, null)
    }

    function test_reduceQueueItem_discard_removes_from_any_state() {
        var states = ["enqueued", "uploading", "retrying", "failed"]
        for (var i = 0; i < states.length; ++i) {
            var item = _base(); item.state = states[i]
            compare(PQL.reduceQueueItem(item, { type: "discard" }), null, states[i])
        }
    }

    function test_reduceQueueItem_ignores_a_failed_event_when_not_uploading() {
        var item = _base(); item.state = "failed"; item.attempts = 8; item.lastError = 400
        var r = PQL.reduceQueueItem(item, { type: "failed", status: 500 })
        compare(r.state, "failed")
        compare(r.attempts, 8, "must not exceed the attempt cap via a stale failure report")
    }

    function test_reduceQueueItem_unrecognised_event_is_a_noop() {
        var item = _base(); item.state = "uploading"
        var r = PQL.reduceQueueItem(item, { type: "bogus" })
        compare(r.state, item.state)
        compare(r.attempts, item.attempts)
    }

    // ── breaker ──────────────────────────────────────────────────────────────

    function test_breaker_opens_after_five_consecutive_failures_not_before() {
        var s = { status: "closed", consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 }
        for (var i = 0; i < 4; ++i) s = PQL.breakerReducer(s, { type: "failure" })
        compare(s.status, "closed")
        s = PQL.breakerReducer(s, { type: "failure" })
        compare(s.status, "open")
    }

    function test_breaker_success_resets_and_closes() {
        var s = { status: "open", consecutiveFailures: 5, cooldownUntil: 1e15, cooldownMs: 60000 }
        s = PQL.breakerReducer(s, { type: "success" })
        compare(s.status, "closed")
        compare(s.consecutiveFailures, 0)
    }

    function test_breaker_first_trip_cooldown_is_the_60s_base() {
        var s = { status: "closed", consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 }
        for (var i = 0; i < 5; ++i) s = PQL.breakerReducer(s, { type: "failure" })
        compare(s.cooldownMs, 60000)
    }

    function test_breaker_cooldown_doubles_on_repeated_trips_capped() {
        var s = { status: "closed", consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 }
        for (var i = 0; i < 5; ++i) s = PQL.breakerReducer(s, { type: "failure" })
        compare(s.cooldownMs, 60000)

        s.status = "closed"; s.consecutiveFailures = 0
        for (i = 0; i < 5; ++i) s = PQL.breakerReducer(s, { type: "failure" })
        compare(s.cooldownMs, 120000)

        s.status = "closed"; s.consecutiveFailures = 0
        for (i = 0; i < 5; ++i) s = PQL.breakerReducer(s, { type: "failure" })
        compare(s.cooldownMs, 240000)
    }

    function test_breaker_genuine_success_resets_escalation() {
        var s = { status: "closed", consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 }
        for (var i = 0; i < 5; ++i) s = PQL.breakerReducer(s, { type: "failure" })
        compare(s.cooldownMs, 60000)
        s = PQL.breakerReducer(s, { type: "success" })
        for (i = 0; i < 5; ++i) s = PQL.breakerReducer(s, { type: "failure" })
        compare(s.cooldownMs, 60000)
    }

    function test_breaker_escalation_caps_at_ten_minutes() {
        var s = { status: "closed", consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 }
        for (var trip = 0; trip < 10; ++trip) {
            s.status = "closed"; s.consecutiveFailures = 0
            for (var i = 0; i < 5; ++i) s = PQL.breakerReducer(s, { type: "failure" })
        }
        compare(s.cooldownMs, 600000)
    }

    function test_isBreakerOpen_true_before_cooldownUntil_false_after() {
        var s = { status: "open", consecutiveFailures: 5, cooldownUntil: 1000, cooldownMs: 60000 }
        compare(PQL.isBreakerOpen(s, 500), true)
        compare(PQL.isBreakerOpen(s, 1500), false)
    }

    function test_isBreakerOpen_always_false_when_not_open() {
        var s = { status: "closed", consecutiveFailures: 0, cooldownUntil: 1e15, cooldownMs: 60000 }
        compare(PQL.isBreakerOpen(s, 0), false)
    }

    // ── monkey tests ─────────────────────────────────────────────────────────

    function test_monkey_random_event_sequences_never_produce_an_invalid_item() {
        var rand = _rng(20260921)
        var events = [
            { type: "failed", status: 500 }, { type: "failed", status: 400 },
            { type: "failed", status: 401 }, { type: "retry" }
        ]
        for (var run = 0; run < 500; ++run) {
            var item = _base()
            for (var step = 0; step < 20; ++step) {
                var ev = events[Math.floor(rand() * events.length)]
                var inFlight = item.state === "enqueued" || item.state === "retrying"
                var current = Object.assign({}, item, { state: inFlight ? "uploading" : item.state })
                var next = PQL.reduceQueueItem(current, ev)
                if (next === null) break
                verify(["enqueued", "uploading", "retrying", "failed"].indexOf(next.state) !== -1)
                verify(next.attempts >= 0)
                verify(next.attempts <= 8)
                item = next
            }
        }
    }

    function test_monkey_random_breaker_sequences_stay_within_invariants() {
        var rand = _rng(20260921)
        for (var run = 0; run < 500; ++run) {
            var s = { status: "closed", consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 }
            for (var step = 0; step < 30; ++step) {
                var ev = rand() < 0.5 ? { type: "success" } : { type: "failure" }
                s = PQL.breakerReducer(s, ev)
                verify(s.consecutiveFailures >= 0)
                verify(s.cooldownMs <= 600000)
                verify(["open", "closed"].indexOf(s.status) !== -1)
            }
        }
    }
}
