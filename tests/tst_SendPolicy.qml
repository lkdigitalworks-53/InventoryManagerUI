import QtQuick
import QtTest
import "../qml/helper/SendPolicy.js" as SP

// Headless tests for Gateway's send-timeout and retry-jitter arithmetic. Pure JS,
// no singletons. Design: docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
TestCase {
    name: "SendPolicy"

    // Small deterministic PRNG (LCG) so a failing monkey run reproduces from its seed.
    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    function test_timeoutMs_uses_the_short_value_while_a_person_is_waiting() {
        compare(SP.timeoutMs(true), SP.TIMEOUT_AWAIT_MS)
        compare(SP.timeoutMs(false), SP.TIMEOUT_BACKGROUND_MS)
    }

    function test_timeout_values_are_pinned_and_ordered() {
        compare(SP.TIMEOUT_AWAIT_MS, 10000)
        compare(SP.TIMEOUT_BACKGROUND_MS, 30000)
        verify(SP.TIMEOUT_AWAIT_MS < SP.TIMEOUT_BACKGROUND_MS, "the foreground wait must be the shorter one")
    }

    function test_jittered_bounds_and_midpoint() {
        compare(SP.jittered(1000, 0), 800)
        compare(SP.jittered(1000, 0.5), 1000)
        compare(SP.jittered(1000, 0.999999), 1200)
    }

    function test_jittered_is_monotonic_in_rand() {
        var prev = -1
        for (var i = 0; i < 100; ++i) {
            var v = SP.jittered(30000, i / 100)
            verify(v >= prev, "not monotonic at " + i)
            prev = v
        }
    }

    function test_jittered_invalid_rand_falls_back_to_no_jitter() {
        var bad = [undefined, null, NaN, -0.1, 1, 2, "0.3"]
        for (var i = 0; i < bad.length; ++i)
            compare(SP.jittered(2000, bad[i]), 2000, "rand " + bad[i])
    }

    function test_jittered_zero_delay_stays_zero() {
        compare(SP.jittered(0, 0.9), 0)
    }

    // Monkey: every delay of the real outbox schedule stays within +-20% and integral.
    function test_monkey_jitter_stays_inside_its_band_for_the_whole_backoff_schedule() {
        var schedule = [2000, 8000, 30000, 120000, 600000]
        var rand = _rng(20260920)
        for (var n = 0; n < 500; ++n) {
            var d = schedule[n % schedule.length]
            var j = SP.jittered(d, rand())
            verify(j >= Math.round(d * 0.8) && j <= Math.round(d * 1.2), "out of band: " + d + " -> " + j)
            compare(j, Math.round(j))
        }
    }
}
