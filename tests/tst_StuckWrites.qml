import QtQuick
import QtTest
import "../qml/helper/StuckWrites.js" as SW

// Headless tests for the bookkeeping behind Gateway.stuckCount. Pure JS, no
// singletons, so nothing here can be polluted by another test file.
// Design: docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-design.md
TestCase {
    name: "StuckWrites"

    // Fails `id` `n` times with `status`; returns how many of those calls
    // reported "this failure tipped the item into stuck".
    function _fail(state, id, status, n) {
        var tipped = 0
        for (var i = 0; i < n; ++i)
            if (SW.noteFailure(state, id, status)) tipped++
        return tipped
    }

    // Small deterministic PRNG (LCG) so a failing monkey run reproduces from its seed.
    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    // ── isStuckStatus ────────────────────────────────────────────────────────

    function test_isStuckStatus_counts_server_side_failures() {
        var counted = [400, 403, 404, 408, 422, 429, 500, 502, 503, 504, 599]
        for (var i = 0; i < counted.length; ++i)
            compare(SW.isStuckStatus(counted[i]), true, "status " + counted[i])
    }

    function test_isStuckStatus_ignores_offline_auth_conflict_and_success() {
        // 0 = offline / no response, 401 = token refresh, 409 = CAS conflict
        // (dropped elsewhere), 1xx-3xx = not a failure at all.
        var ignored = [0, 100, 200, 204, 299, 301, 399, 401, 409]
        for (var i = 0; i < ignored.length; ++i)
            compare(SW.isStuckStatus(ignored[i]), false, "status " + ignored[i])
    }

    function test_isStuckStatus_ignores_missing_or_non_numeric_status() {
        compare(SW.isStuckStatus(undefined), false)
        compare(SW.isStuckStatus(null), false)
        compare(SW.isStuckStatus(NaN), false)
    }

    function test_isStuckStatus_boundary_is_400() {
        compare(SW.isStuckStatus(399), false)
        compare(SW.isStuckStatus(400), true)
    }

    // ── noteFailure ──────────────────────────────────────────────────────────

    function test_threshold_is_five() {
        // Pinned on purpose: 5 server-side failures is about 3 minutes with
        // OutboxStore's backoff ([2s, 8s, 30s, 2m, 10m]). Changing it changes how
        // quickly the user is told, so it should be a deliberate edit.
        compare(SW.THRESHOLD, 5)
    }

    function test_failures_below_threshold_do_not_tip() {
        var state = SW.newState()
        compare(_fail(state, "a", 500, SW.THRESHOLD - 1), 0)
        compare(SW.stuckCount(state), 0)
    }

    function test_the_threshold_failure_tips_exactly_once() {
        var state = SW.newState()
        compare(_fail(state, "a", 500, SW.THRESHOLD), 1)
        compare(SW.stuckCount(state), 1)
        compare(_fail(state, "a", 500, 10), 0, "later failures of an already-stuck item must not tip again")
        compare(SW.stuckCount(state), 1)
    }

    function test_the_status_may_change_between_failures() {
        var state = SW.newState()
        var mix = [500, 503, 403, 404, 400]
        var tipped = 0
        for (var i = 0; i < mix.length; ++i)
            if (SW.noteFailure(state, "a", mix[i])) tipped++
        compare(tipped, 1)
        compare(SW.stuckCount(state), 1)
    }

    function test_offline_auth_and_conflict_failures_neither_count_nor_reset() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD - 1)
        compare(_fail(state, "a", 0, 50), 0)
        compare(_fail(state, "a", 401, 50), 0)
        compare(_fail(state, "a", 409, 50), 0)
        compare(SW.stuckCount(state), 0)
        compare(_fail(state, "a", 503, 1), 1, "the next server-side failure is still the 5th")
        compare(SW.stuckCount(state), 1)
    }

    function test_non_counting_statuses_leave_no_bookkeeping() {
        var state = SW.newState()
        _fail(state, "a", 0, 20)
        _fail(state, "a", 401, 20)
        _fail(state, "a", 409, 20)
        _fail(state, "a", 200, 20)
        compare(Object.keys(state.failures).length, 0)
        compare(Object.keys(state.stuck).length, 0)
    }

    function test_items_are_counted_independently() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        _fail(state, "b", 500, SW.THRESHOLD - 1)
        compare(SW.stuckCount(state), 1)
        compare(_fail(state, "b", 500, 1), 1)
        compare(SW.stuckCount(state), 2)
    }

    function test_states_are_independent_of_each_other() {
        var s1 = SW.newState()
        var s2 = SW.newState()
        _fail(s1, "a", 500, SW.THRESHOLD)
        compare(SW.stuckCount(s1), 1)
        compare(SW.stuckCount(s2), 0)
    }

    // ── prune ────────────────────────────────────────────────────────────────

    function test_prune_keeps_stuck_items_still_in_the_outbox() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        compare(SW.prune(state, { a: true }), 1)
        compare(state.stuck.a, true)
    }

    function test_prune_drops_items_that_left_the_outbox() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        _fail(state, "b", 500, SW.THRESHOLD)
        compare(SW.prune(state, { a: true }), 1)
        compare(state.stuck.b, undefined)
        compare(state.failures.b, undefined)
    }

    function test_prune_forgets_partial_failure_counts() {
        var state = SW.newState()
        _fail(state, "a", 500, 3)
        SW.prune(state, {})
        compare(Object.keys(state.failures).length, 0)
        // Same id re-enqueued later starts from zero, not from 3.
        compare(_fail(state, "a", 500, 2), 0)
        compare(SW.stuckCount(state), 0)
    }

    function test_prune_with_an_empty_outbox_resets_everything() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        _fail(state, "b", 500, 2)
        compare(SW.prune(state, {}), 0)
        compare(Object.keys(state.stuck).length, 0)
        compare(Object.keys(state.failures).length, 0)
    }

    function test_prune_is_idempotent() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        _fail(state, "b", 500, SW.THRESHOLD)
        compare(SW.prune(state, { a: true }), 1)
        compare(SW.prune(state, { a: true }), 1)
    }

    function test_prune_on_a_fresh_state_is_a_no_op() {
        compare(SW.prune(SW.newState(), { a: true }), 0)
    }

    function test_an_id_can_go_stuck_again_after_it_was_pruned() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        compare(SW.prune(state, {}), 0)
        compare(_fail(state, "a", 500, SW.THRESHOLD), 1)
        compare(SW.stuckCount(state), 1)
    }

    // ── monkey ───────────────────────────────────────────────────────────────

    // Random failures and prunes over a handful of ids, checked step by step
    // against an independently written reference model.
    function test_monkey_random_sequences_match_a_reference_model() {
        var statuses = [0, 200, 400, 401, 403, 404, 409, 500, 503]
        var ids = ["a", "b", "c", "d", "e", "f"]
        for (var seed = 1; seed <= 25; ++seed) {
            var rnd = _rng(seed)
            var state = SW.newState()
            var refCount = {}
            var refStuck = {}
            for (var step = 0; step < 400; ++step) {
                var where = "seed " + seed + " step " + step
                if (rnd() < 0.85) {
                    var id = ids[Math.floor(rnd() * ids.length)]
                    var st = statuses[Math.floor(rnd() * statuses.length)]
                    var expectTip = false
                    if (st >= 400 && st !== 401 && st !== 409) {
                        refCount[id] = (refCount[id] || 0) + 1
                        if (refCount[id] === 5) { refStuck[id] = true; expectTip = true }
                    }
                    compare(SW.noteFailure(state, id, st), expectTip, where + " noteFailure(" + id + "," + st + ")")
                } else {
                    var live = {}
                    for (var k = 0; k < ids.length; ++k)
                        if (rnd() < 0.5) live[ids[k]] = true
                    var pruned = SW.prune(state, live)
                    for (var rc in refCount) if (!live[rc]) delete refCount[rc]
                    for (var rs in refStuck) if (!live[rs]) delete refStuck[rs]
                    compare(pruned, Object.keys(refStuck).length, where + " prune")
                }
                compare(SW.stuckCount(state), Object.keys(refStuck).length, where + " stuckCount")
                for (var sid in state.stuck)
                    verify(state.failures[sid] >= SW.THRESHOLD, where + " stuck id " + sid + " has fewer failures than THRESHOLD")
            }
        }
    }

    // Whatever happened before, an empty outbox must always mean a clean slate.
    function test_monkey_pruning_everything_always_resets_to_zero() {
        var statuses = [0, 400, 401, 403, 409, 500, 503]
        for (var seed = 1; seed <= 25; ++seed) {
            var rnd = _rng(seed)
            var state = SW.newState()
            for (var step = 0; step < 200; ++step)
                SW.noteFailure(state, "id" + Math.floor(rnd() * 10), statuses[Math.floor(rnd() * statuses.length)])
            compare(SW.prune(state, {}), 0, "seed " + seed)
            compare(Object.keys(state.stuck).length, 0, "seed " + seed + " stuck")
            compare(Object.keys(state.failures).length, 0, "seed " + seed + " failures")
        }
    }
}
