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
        var codes = [400, 413, 404, 409, 403] // 403 = PH4 item 1 (C01/C02)
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

    // ── PH4 (client): 403 terminal, L1 breaker wait, photo ids ──────────────

    function test_C04_failed_403_goes_straight_to_failed_with_no_backoff() {
        var r = PQL.reduceQueueItem({ photoId: "p1", state: "uploading", attempts: 0, nextAttemptAt: 0, lastError: null },
                                    { type: "failed", status: 403 })
        compare(r.state, "failed")
        compare(r.lastError, 403)
        compare(r.attempts, 1)
        compare(r.nextAttemptAt, 0)
    }

    function test_C03_other_transient_codes_stay_transient_next_to_403() {
        var codes = [401, 429, 500, 502, 503, 0]
        for (var i = 0; i < codes.length; ++i)
            compare(PQL.classifyError(codes[i]), "transient", "status " + codes[i])
    }

    function test_L1_breakerWaitMs_is_the_time_left_on_an_open_breaker() {
        var open = { status: "open", consecutiveFailures: 5, cooldownUntil: 61000, cooldownMs: 60000 }
        compare(PQL.breakerWaitMs(open, 1000), 60000)
        compare(PQL.breakerWaitMs(open, 60999), 1)
    }

    function test_L1_breakerWaitMs_is_zero_when_closed_expired_or_at_the_boundary() {
        compare(PQL.breakerWaitMs({ status: "closed", cooldownUntil: 99999 }, 1000), 0)
        compare(PQL.breakerWaitMs({ status: "open", cooldownUntil: 5000 }, 5000), 0)
        compare(PQL.breakerWaitMs({ status: "open", cooldownUntil: 5000 }, 9000), 0)
        compare(PQL.breakerWaitMs({}, 1000), 0)
    }

    function test_C07_C09_photoIdFromUuid_is_photo_prefix_plus_36_chars_without_braces() {
        var id = PQL.photoIdFromUuid("{123e4567-e89b-12d3-a456-426614174000}")
        compare(id, "photo-123e4567-e89b-12d3-a456-426614174000")
        verify(/^photo-[A-Za-z0-9_-]{36}$/.test(id))
        compare(id.length, 42)
    }

    function test_C08_photoIdFromUuid_strips_braces_and_leaves_plain_uuids_alone() {
        compare(PQL.photoIdFromUuid("{abc}"), "photo-abc")
        compare(PQL.photoIdFromUuid("abc"), "photo-abc")
    }

    // The UNVERIFIED point from the design (PH4 item 2): does Qt.uuid() work under headless qmltestrunner?
    // If this fails on CI, stub Qt.uuid in StorageService tests instead and record it in Skill 107.
    function test_C07_real_Qt_uuid_gives_a_server_whitelist_safe_id_and_1000_are_unique() {
        var seen = {}
        for (var i = 0; i < 1000; ++i) {
            var id = PQL.photoIdFromUuid(Qt.uuid())
            verify(/^photo-[A-Za-z0-9_-]{36}$/.test(id), "bad id: " + id)
            verify(!seen[id], "duplicate id " + id)
            seen[id] = true
        }
    }
}
