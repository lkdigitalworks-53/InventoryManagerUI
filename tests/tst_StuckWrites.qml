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

    // ── terminal flag (server said "write-rejected") ─────────────────────────

    function _stuckWith(state, id, code) {
        // Puts `id` into stuck, its latest answer being `code`.
        for (var i = 0; i < SW.THRESHOLD; ++i) SW.noteFailure(state, id, 500, true, code)
    }

    function test_errorCodeOf_reads_the_error_string_from_text_or_object() {
        compare(SW.errorCodeOf('{"ok":false,"error":"write-rejected"}'), "write-rejected")
        compare(SW.errorCodeOf({ ok: false, error: "write-unavailable" }), "write-unavailable")
        compare(SW.errorCodeOf('{"error":"write-failed"}'), "write-failed")
    }

    function test_errorCodeOf_never_throws_on_junk() {
        var junk = [undefined, null, "", "not json", "<html>502</html>", "[]", "null", "42", '{"error":7}',
                    '{"error":null}', '{"ok":false}', {}, [], 0, 7, true, { error: 5 }]
        for (var i = 0; i < junk.length; ++i)
            compare(SW.errorCodeOf(junk[i]), "", "junk #" + i)
    }

    function test_REJECTED_is_the_server_wire_string() {
        compare(SW.REJECTED, "write-rejected")
    }

    function test_a_rejected_stuck_write_is_counted_terminal() {
        var state = SW.newState()
        _stuckWith(state, "a", SW.REJECTED)
        compare(SW.stuckCount(state), 1)
        compare(SW.terminalCount(state), 1)
    }

    function test_rejected_below_threshold_is_not_terminal_yet() {
        var state = SW.newState()
        for (var i = 0; i < SW.THRESHOLD - 1; ++i) SW.noteFailure(state, "a", 500, true, SW.REJECTED)
        compare(SW.terminalCount(state), 0, "terminalCount only counts writes that are stuck")
        SW.noteFailure(state, "a", 500, true, SW.REJECTED)
        compare(SW.terminalCount(state), 1)
    }

    function test_unavailable_unknown_and_missing_codes_are_not_terminal() {
        var codes = ["write-unavailable", "write-failed", "", undefined, "anything-else"]
        for (var i = 0; i < codes.length; ++i) {
            var state = SW.newState()
            _stuckWith(state, "a", codes[i])
            compare(SW.stuckCount(state), 1)
            compare(SW.terminalCount(state), 0, "code " + codes[i])
        }
    }

    function test_the_latest_answer_wins_in_both_directions() {
        var state = SW.newState()
        _stuckWith(state, "a", SW.REJECTED)
        compare(SW.terminalCount(state), 1)
        SW.noteFailure(state, "a", 503, true, "write-unavailable")
        compare(SW.terminalCount(state), 0, "outage after a rejection: no longer labelled rejected")
        SW.noteFailure(state, "a", 500, true, SW.REJECTED)
        compare(SW.terminalCount(state), 1)
    }

    function test_ignored_statuses_never_touch_the_flag() {
        var state = SW.newState()
        _stuckWith(state, "a", SW.REJECTED)
        SW.noteFailure(state, "a", 401, true, "write-unavailable")
        SW.noteFailure(state, "a", 409, true, "write-unavailable")
        SW.noteFailure(state, "a", 0, true, "write-unavailable")
        SW.noteFailure(state, "a", SW.TIMEOUT, false, "write-unavailable")
        compare(SW.terminalCount(state), 1, "auth, conflict, offline and offline-timeout are not server answers about the write")
    }

    function test_a_timeout_online_clears_the_flag() {
        var state = SW.newState()
        _stuckWith(state, "a", SW.REJECTED)
        SW.noteFailure(state, "a", SW.TIMEOUT, true)
        compare(SW.terminalCount(state), 0, "a hang is not a rejection; the last real answer is stale")
    }

    function test_terminal_is_tracked_per_write() {
        var state = SW.newState()
        _stuckWith(state, "a", SW.REJECTED)
        _stuckWith(state, "b", "write-unavailable")
        _stuckWith(state, "c", SW.REJECTED)
        compare(SW.stuckCount(state), 3)
        compare(SW.terminalCount(state), 2)
    }

    function test_prune_forgets_terminal_flags_of_writes_that_left() {
        var state = SW.newState()
        _stuckWith(state, "a", SW.REJECTED)
        _stuckWith(state, "b", SW.REJECTED)
        SW.prune(state, { b: true })
        compare(SW.terminalCount(state), 1)
        compare(Object.keys(state.terminal).length, 1, "no leaked flag for the pruned id")
        SW.prune(state, {})
        compare(SW.terminalCount(state), 0)
        compare(Object.keys(state.terminal).length, 0)
    }

    function test_a_reused_id_after_prune_starts_clean() {
        var state = SW.newState()
        _stuckWith(state, "a", SW.REJECTED)
        SW.prune(state, {})
        _stuckWith(state, "a", "write-unavailable")
        compare(SW.terminalCount(state), 0)
    }

    function test_the_code_does_not_change_when_a_write_tips_into_stuck() {
        var a = SW.newState(), b = SW.newState()
        var tippedA = 0, tippedB = 0
        for (var i = 0; i < 10; ++i) {
            if (SW.noteFailure(a, "x", 500, true, SW.REJECTED)) tippedA++
            if (SW.noteFailure(b, "x", 500, true)) tippedB++
        }
        compare(tippedA, 1)
        compare(tippedB, 1)
        compare(SW.stuckCount(a), SW.stuckCount(b), "the code is a label; it must not move the threshold")
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

    // -- timeouts (D5, 2026-09-20): a hang while online is a stuck write --------

    function test_isStuckStatus_timeout_counts_only_while_online() {
        compare(SW.isStuckStatus(SW.TIMEOUT, true), true)
        compare(SW.isStuckStatus(SW.TIMEOUT, false), false)
        compare(SW.isStuckStatus(SW.TIMEOUT), false, "unknown connectivity is not evidence of a hang")
        compare(SW.isStuckStatus(SW.TIMEOUT, "yes"), false, "only a real boolean true counts")
    }

    function test_isStuckStatus_numeric_statuses_ignore_the_online_flag() {
        compare(SW.isStuckStatus(500, true), true)
        compare(SW.isStuckStatus(500, false), true, "the server answered, so connectivity is irrelevant")
        compare(SW.isStuckStatus(0, true), false)
        compare(SW.isStuckStatus(409, true), false)
    }

    function test_noteFailure_timeouts_online_tip_at_the_threshold() {
        var s = SW.newState()
        var tipped = 0
        for (var i = 0; i < SW.THRESHOLD; ++i)
            if (SW.noteFailure(s, "r1", SW.TIMEOUT, true)) tipped++
        compare(tipped, 1)
        compare(SW.stuckCount(s), 1)
    }

    function test_noteFailure_timeouts_offline_never_tip() {
        var s = SW.newState()
        for (var i = 0; i < SW.THRESHOLD * 3; ++i)
            compare(SW.noteFailure(s, "r1", SW.TIMEOUT, false), false)
        compare(SW.stuckCount(s), 0)
    }

    function test_noteFailure_timeouts_and_server_errors_share_one_counter() {
        var s = SW.newState()
        compare(SW.noteFailure(s, "r1", SW.TIMEOUT, true), false)
        compare(SW.noteFailure(s, "r1", 503, true), false)
        compare(SW.noteFailure(s, "r1", SW.TIMEOUT, true), false)
        compare(SW.noteFailure(s, "r1", 500, true), false)
        compare(SW.noteFailure(s, "r1", SW.TIMEOUT, true), true, "the 5th failure of any counted kind tips it")
    }

    function test_noteFailure_a_timeout_while_offline_does_not_reset_earlier_online_failures() {
        var s = SW.newState()
        for (var i = 0; i < 4; ++i) SW.noteFailure(s, "r1", SW.TIMEOUT, true)
        compare(SW.noteFailure(s, "r1", SW.TIMEOUT, false), false)
        compare(SW.noteFailure(s, "r1", SW.TIMEOUT, true), true)
    }
    // Terminal-flag monkey: random codes/statuses/prunes vs a reference model.
    function test_monkey_terminal_flag_matches_a_reference_model() {
        var statuses = [0, 200, 401, 409, 500, 503, SW.TIMEOUT]
        var codes = [SW.REJECTED, "write-unavailable", "write-failed", "", undefined]
        var ids = ["a", "b", "c", "d"]
        for (var seed = 1; seed <= 25; ++seed) {
            var rnd = _rng(seed * 7)
            var state = SW.newState()
            var refCount = {}, refStuck = {}, refTerm = {}
            for (var step = 0; step < 300; ++step) {
                var where = "seed " + seed + " step " + step
                if (rnd() < 0.85) {
                    var id = ids[Math.floor(rnd() * ids.length)]
                    var st = statuses[Math.floor(rnd() * statuses.length)]
                    var code = codes[Math.floor(rnd() * codes.length)]
                    var counts = (st === SW.TIMEOUT) ? true : (st >= 400 && st !== 401 && st !== 409)
                    if (counts) {
                        if (code === SW.REJECTED) refTerm[id] = true
                        else delete refTerm[id]
                        refCount[id] = (refCount[id] || 0) + 1
                        if (refCount[id] === 5) refStuck[id] = true
                    }
                    SW.noteFailure(state, id, st, true, code)
                } else {
                    var live = {}
                    for (var k = 0; k < ids.length; ++k) if (rnd() < 0.5) live[ids[k]] = true
                    SW.prune(state, live)
                    for (var rc in refCount) if (!live[rc]) delete refCount[rc]
                    for (var rs in refStuck) if (!live[rs]) delete refStuck[rs]
                    for (var rt in refTerm) if (!live[rt]) delete refTerm[rt]
                }
                var want = 0
                for (var sid in refStuck) if (refTerm[sid]) want++
                compare(SW.terminalCount(state), want, where)
                verify(SW.terminalCount(state) <= SW.stuckCount(state), where + " terminal <= stuck")
            }
        }
    }


    // ── isStuck / rows (stuck-writes dialog, S1 2026-09-29) ─────────────────

    function _stuckWrite(state, id, body) {
        for (var i = 0; i < 5; ++i) SW.noteFailure(state, id, 500, true, body)
    }

    function test_isStuck_false_for_unknown_and_below_threshold() {
        var s = SW.newState()
        compare(SW.isStuck(s, "nope"), false)
        SW.noteFailure(s, "a", 500, true)
        compare(SW.isStuck(s, "a"), false)
    }

    function test_isStuck_true_only_from_the_threshold_failure() {
        var s = SW.newState()
        _stuckWrite(s, "a")
        compare(SW.isStuck(s, "a"), true)
        compare(SW.isStuck(s, "b"), false)
    }

    function test_isStuck_false_again_after_prune_removes_it() {
        var s = SW.newState()
        _stuckWrite(s, "a")
        SW.prune(s, {})
        compare(SW.isStuck(s, "a"), false)
    }

    function test_rows_empty_for_no_items_or_bad_items_argument() {
        var s = SW.newState()
        _stuckWrite(s, "a")
        compare(SW.rows(s, []).length, 0)
        compare(SW.rows(s, undefined).length, 0)
        compare(SW.rows(s, null).length, 0)
        compare(SW.rows(s, "x").length, 0)
    }

    function test_rows_lists_only_stuck_items_in_queue_order() {
        var s = SW.newState()
        _stuckWrite(s, "b")
        _stuckWrite(s, "d")
        SW.noteFailure(s, "c", 500, true) // failing but not stuck yet
        var items = [{ requestId: "a" }, { requestId: "b" }, { requestId: "c" }, { requestId: "d" }]
        var rows = SW.rows(s, items)
        compare(rows.length, 2)
        compare(rows[0].requestId, "b")
        compare(rows[1].requestId, "d")
        compare(rows[0].item, items[1])
    }

    function test_rows_skips_a_stuck_id_that_left_the_outbox() {
        var s = SW.newState()
        _stuckWrite(s, "gone")
        _stuckWrite(s, "here")
        var rows = SW.rows(s, [{ requestId: "here" }])
        compare(rows.length, 1)
        compare(rows[0].requestId, "here")
    }

    function test_rows_terminal_flag_follows_the_latest_server_answer() {
        var s = SW.newState()
        _stuckWrite(s, "r", SW.REJECTED)
        _stuckWrite(s, "u", "write-unavailable")
        var rows = SW.rows(s, [{ requestId: "r" }, { requestId: "u" }])
        compare(rows[0].terminal, true)
        compare(rows[1].terminal, false)
        SW.noteFailure(s, "r", 500, true, "write-unavailable") // latest answer changes
        compare(SW.rows(s, [{ requestId: "r" }])[0].terminal, false)
    }

    function test_rows_ignores_null_entries_in_items() {
        var s = SW.newState()
        _stuckWrite(s, "a")
        compare(SW.rows(s, [null, undefined, { requestId: "a" }]).length, 1)
    }

    function test_rows_does_not_mutate_state() {
        var s = SW.newState()
        _stuckWrite(s, "a")
        var before = JSON.stringify(s)
        SW.rows(s, [{ requestId: "a" }])
        compare(JSON.stringify(s), before)
    }

    function test_monkey_rows_length_always_matches_stuck_ids_still_queued() {
        var ids = ["a", "b", "c", "d"]
        for (var seed = 1; seed <= 5; ++seed) {
            var rnd = _rng(seed)
            var state = SW.newState()
            var queued = {}
            for (var step = 0; step < 200; ++step) {
                var id = ids[Math.floor(rnd() * ids.length)]
                var r = rnd()
                if (r < 0.6) { queued[id] = true; SW.noteFailure(state, id, 500, true) }
                else if (r < 0.8) { delete queued[id]; SW.prune(state, queued) }
                var items = []
                for (var k = 0; k < ids.length; ++k) if (queued[ids[k]]) items.push({ requestId: ids[k] })
                var want = 0
                for (var w = 0; w < items.length; ++w) if (SW.isStuck(state, items[w].requestId)) want++
                compare(SW.rows(state, items).length, want, "seed " + seed + " step " + step)
            }
        }
    }
}
