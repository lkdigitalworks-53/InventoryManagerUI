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

    // ── metaOf / hydrate (P5: stuck state survives a relaunch) ───────────────

    function test_metaOf_an_unknown_write_is_all_zero() {
        var m = SW.metaOf(SW.newState(), "nope")
        compare(m.failures, 0)
        compare(m.stuck, false)
        compare(m.terminal, false)
    }

    function test_metaOf_reports_a_counting_write_before_it_is_stuck() {
        var s = SW.newState()
        _fail(s, "a", 500, 3)
        var m = SW.metaOf(s, "a")
        compare(m.failures, 3)
        compare(m.stuck, false)
    }

    function test_metaOf_reports_a_stuck_terminal_write() {
        var s = SW.newState()
        for (var i = 0; i < 5; ++i) SW.noteFailure(s, "a", 500, true, "write-rejected")
        var m = SW.metaOf(s, "a")
        compare(m.failures, 5)
        compare(m.stuck, true)
        compare(m.terminal, true)
    }

    function test_hydrate_of_non_arrays_and_empty_input_is_an_empty_state() {
        var inputs = [undefined, null, 0, "x", {}, []]
        for (var i = 0; i < inputs.length; ++i) {
            var s = SW.hydrate(inputs[i])
            compare(SW.stuckCount(s), 0, "input " + i)
            compare(Object.keys(s.failures).length, 0, "input " + i)
        }
    }

    function test_hydrate_restores_a_stuck_write_and_its_failure_count() {
        var s = SW.hydrate([{ requestId: "a", failures: 7, stuck: true }])
        compare(SW.isStuck(s, "a"), true)
        compare(s.failures["a"], 7)
        compare(SW.stuckCount(s), 1)
    }

    function test_hydrate_restores_a_counting_write_that_is_not_yet_stuck() {
        var s = SW.hydrate([{ requestId: "a", failures: 2 }])
        compare(SW.isStuck(s, "a"), false)
        compare(s.failures["a"], 2)
        // and it tips on exactly the failure that would have tipped it before the relaunch
        compare(SW.noteFailure(s, "a", 500), false)
        compare(SW.noteFailure(s, "a", 500), false)
        compare(SW.noteFailure(s, "a", 500), true)
    }

    function test_hydrate_restores_the_terminal_label() {
        var s = SW.hydrate([{ requestId: "a", failures: 5, stuck: true, terminal: true },
                            { requestId: "b", failures: 5, stuck: true }])
        compare(SW.terminalCount(s), 1)
        compare(SW.rows(s, [{ requestId: "a" }, { requestId: "b" }])[0].terminal, true)
        compare(SW.rows(s, [{ requestId: "a" }, { requestId: "b" }])[1].terminal, false)
    }

    function test_hydrate_derives_stuck_when_failures_reached_the_threshold() {
        var s = SW.hydrate([{ requestId: "a", failures: SW.THRESHOLD }])
        compare(SW.isStuck(s, "a"), true)
    }

    function test_hydrate_repairs_stuck_with_a_too_low_count_so_it_cannot_toast_twice() {
        var s = SW.hydrate([{ requestId: "a", failures: 1, stuck: true }])
        compare(s.failures["a"], SW.THRESHOLD)
        compare(SW.noteFailure(s, "a", 500), false, "already stuck: a later failure must not tip again")
        compare(SW.noteFailure(s, "a", 500), false)
    }

    function test_hydrate_repairs_stuck_without_any_count() {
        var s = SW.hydrate([{ requestId: "a", stuck: true }])
        compare(s.failures["a"], SW.THRESHOLD)
        compare(SW.stuckCount(s), 1)
    }

    function test_hydrate_after_more_failures_than_the_threshold_does_not_retip() {
        var s = SW.hydrate([{ requestId: "a", failures: 9, stuck: true }])
        compare(SW.noteFailure(s, "a", 500), false)
        compare(s.failures["a"], 10)
    }

    function test_hydrate_ignores_malformed_items_and_fields() {
        var s = SW.hydrate([null, undefined, 5, "x", {}, { requestId: "" }, { failures: 9, stuck: true },
                            { requestId: "a", failures: "5", stuck: "yes", terminal: 1 },
                            { requestId: "b", failures: -3 },
                            { requestId: "c", failures: NaN },
                            { requestId: "d", failures: 2.9 }])
        compare(SW.stuckCount(s), 0)
        compare(Object.keys(s.terminal).length, 0)
        compare(s.failures["d"], 2, "a fractional count is floored")
        compare(s.failures["b"], undefined)
        compare(s.failures["c"], undefined)
    }

    function test_hydrate_returns_a_state_the_rest_of_the_module_accepts() {
        var s = SW.hydrate([{ requestId: "a", failures: 5, stuck: true, terminal: true }])
        compare(SW.prune(s, { "a": true }), 1)
        compare(SW.prune(s, {}), 0)
        compare(Object.keys(s.failures).length, 0)
        compare(Object.keys(s.terminal).length, 0)
    }

    function test_hydrate_does_not_mutate_its_input() {
        var items = [{ requestId: "a", failures: 1, stuck: true }]
        var snapshot = JSON.stringify(items)
        SW.hydrate(items)
        compare(JSON.stringify(items), snapshot)
    }

    function test_metaOf_then_hydrate_round_trips_every_write() {
        var s = SW.newState()
        _fail(s, "counting", 500, 2)
        for (var i = 0; i < 6; ++i) SW.noteFailure(s, "stuck", 503, true, "write-unavailable")
        for (var j = 0; j < 5; ++j) SW.noteFailure(s, "poison", 500, true, "write-rejected")
        var items = ["counting", "stuck", "poison"].map(function(id) {
            var m = SW.metaOf(s, id)
            return { requestId: id, failures: m.failures, stuck: m.stuck, terminal: m.terminal }
        })
        var back = SW.hydrate(JSON.parse(JSON.stringify(items)))
        compare(JSON.stringify(back.failures), JSON.stringify(s.failures))
        compare(JSON.stringify(back.stuck), JSON.stringify(s.stuck))
        compare(JSON.stringify(back.terminal), JSON.stringify(s.terminal))
    }

    // Monkey: random failures on random writes, "relaunch" (persist -> hydrate) at
    // random points. The relaunched state must behave exactly like the one that
    // never relaunched: same stuck set, same terminal set, same tip decisions.
    function test_monkey_a_relaunch_never_changes_what_the_state_would_have_done() {
        var rnd = _rng(20260929)
        var statuses = [500, 503, 404, 401, 409, 0, SW.TIMEOUT]
        var codes = ["", "write-rejected", "write-unavailable"]
        var ids = ["a", "b", "c", "d"]
        var live = SW.newState()
        var relaunched = SW.newState()
        for (var step = 0; step < 400; ++step) {
            var id = ids[Math.floor(rnd() * ids.length)]
            var st = statuses[Math.floor(rnd() * statuses.length)]
            var online = rnd() < 0.7
            var code = codes[Math.floor(rnd() * codes.length)]
            var t1 = SW.noteFailure(live, id, st, online, code)
            var t2 = SW.noteFailure(relaunched, id, st, online, code)
            compare(t1, t2, "step " + step)
            if (rnd() < 0.15) {
                var items = ids.map(function(x) {
                    var m = SW.metaOf(relaunched, x)
                    return { requestId: x, failures: m.failures, stuck: m.stuck, terminal: m.terminal }
                })
                relaunched = SW.hydrate(JSON.parse(JSON.stringify(items)))
            }
            compare(SW.stuckCount(relaunched), SW.stuckCount(live), "step " + step)
            compare(SW.terminalCount(relaunched), SW.terminalCount(live), "step " + step)
        }
    }

    // ── S2b: parked = stuck AND the latest answer was "rejected" ─────────────

    function _rejected(state, id, n) {
        for (var i = 0; i < n; ++i) SW.noteFailure(state, id, 500, true, "write-rejected")
    }
    function _outage(state, id, n) {
        for (var i = 0; i < n; ++i) SW.noteFailure(state, id, 500, true, "write-unavailable")
    }

    function test_isParkedItem_needs_stuck_and_terminal() {
        compare(SW.isParkedItem({ stuck: true, terminal: true }), true)
        compare(SW.isParkedItem({ stuck: true }), false)
        compare(SW.isParkedItem({ terminal: true }), false)
        compare(SW.isParkedItem({ stuck: true, terminal: false }), false)
        compare(SW.isParkedItem({}), false)
    }

    function test_isParkedItem_repairs_a_missing_stuck_flag_like_hydrate() {
        compare(SW.isParkedItem({ failures: 5, terminal: true }), true)
        compare(SW.isParkedItem({ failures: 4, terminal: true }), false)
        compare(SW.isParkedItem({ failures: 99, terminal: true }), true)
    }

    function test_isParkedItem_tolerates_garbage() {
        var bad = [null, undefined, 0, "", "x", 7, [], { stuck: "true", terminal: "true" },
                   { failures: "9", terminal: true }, { failures: NaN, terminal: true },
                   { stuck: 1, terminal: 1 }]
        for (var i = 0; i < bad.length; ++i)
            compare(SW.isParkedItem(bad[i]), false, "case " + i)
    }

    function test_a_rejected_write_parks_on_the_failure_that_tips_it() {
        var st = SW.newState()
        _rejected(st, "a", 4)
        compare(SW.isParked(st, "a"), false)
        _rejected(st, "a", 1)
        compare(SW.isParked(st, "a"), true)
    }

    function test_an_outage_write_is_stuck_but_never_parked() {
        var st = SW.newState()
        _outage(st, "a", 12)
        compare(SW.isStuck(st, "a"), true)
        compare(SW.isParked(st, "a"), false)
    }

    function test_park_rule_A_a_write_rejected_only_after_the_tip_still_parks() {
        var st = SW.newState()
        _outage(st, "a", 5)
        compare(SW.isParked(st, "a"), false)
        _rejected(st, "a", 1)
        compare(SW.isParked(st, "a"), true, "Q-S2b-1 A: state rule, not edge rule")
    }

    function test_a_rejection_before_the_threshold_does_not_park() {
        var st = SW.newState()
        _rejected(st, "a", 3)
        compare(SW.isParked(st, "a"), false)
        compare(SW.terminalCount(st), 0)
    }

    function test_an_unknown_id_is_not_parked() {
        compare(SW.isParked(SW.newState(), "nope"), false)
    }

    function test_clearTerminal_unparks_but_keeps_the_write_stuck() {
        var st = SW.newState()
        _rejected(st, "a", 5)
        SW.clearTerminal(st, "a")
        compare(SW.isParked(st, "a"), false)
        compare(SW.isStuck(st, "a"), true)
        compare(SW.stuckCount(st), 1)
        compare(SW.terminalCount(st), 0)
        compare(SW.metaOf(st, "a").failures, 5)
    }

    function test_a_released_write_rejected_again_re_parks_after_one_attempt() {
        var st = SW.newState()
        _rejected(st, "a", 5)
        SW.clearTerminal(st, "a")
        _rejected(st, "a", 1)
        compare(SW.isParked(st, "a"), true)
        compare(SW.stuckCount(st), 1, "never counted twice")
    }

    function test_a_released_write_that_gets_an_outage_answer_keeps_retrying() {
        var st = SW.newState()
        _rejected(st, "a", 5)
        SW.clearTerminal(st, "a")
        _outage(st, "a", 1)
        compare(SW.isParked(st, "a"), false)
        compare(SW.isStuck(st, "a"), true)
    }

    function test_clearTerminal_is_harmless_on_anything() {
        var st = SW.newState()
        SW.clearTerminal(st, "nope")
        SW.clearTerminal(st, undefined)
        SW.clearTerminal(st, "")
        compare(JSON.stringify(st), JSON.stringify(SW.newState()))
        _outage(st, "a", 5)
        SW.clearTerminal(st, "a")
        compare(SW.isStuck(st, "a"), true)
    }

    function test_parked_matches_terminalCount() {
        var st = SW.newState()
        _rejected(st, "a", 5)
        _rejected(st, "b", 5)
        _outage(st, "c", 5)
        _rejected(st, "d", 2)
        var parked = ["a", "b", "c", "d"].filter(function(i) { return SW.isParked(st, i) }).length
        compare(parked, SW.terminalCount(st))
        compare(parked, 2)
    }

    function test_parked_survives_metaOf_then_hydrate() {
        var st = SW.newState()
        _rejected(st, "a", 5)
        var back = SW.hydrate([Object.assign({ requestId: "a" }, SW.metaOf(st, "a"))])
        compare(SW.isParked(back, "a"), true)
    }

    function test_prune_forgets_parked_writes_that_left_the_outbox() {
        var st = SW.newState()
        _rejected(st, "a", 5)
        SW.prune(st, {})
        compare(SW.isParked(st, "a"), false)
    }

    // Monkey: the persisted-item rule and the in-memory rule must never disagree.
    function test_monkey_isParkedItem_agrees_with_hydrate() {
        var rnd = _rng(2024)
        var fails = [undefined, 0, 1, 4, 4.9, 5, 6, 40, -3, NaN, "5", null]
        var flags = [undefined, true, false, "true", 1, null]
        for (var i = 0; i < 600; ++i) {
            var it = { requestId: "r" + i }
            var f = fails[Math.floor(rnd() * fails.length)]
            var s = flags[Math.floor(rnd() * flags.length)]
            var t = flags[Math.floor(rnd() * flags.length)]
            if (f !== undefined) it.failures = f
            if (s !== undefined) it.stuck = s
            if (t !== undefined) it.terminal = t
            compare(SW.isParked(SW.hydrate([it]), it.requestId), SW.isParkedItem(it), JSON.stringify(it))
        }
    }

    // Monkey: random answers and releases never leave a parked write that is not stuck
    // and never let the parked set exceed the stuck set.
    function test_monkey_parked_is_always_a_subset_of_stuck() {
        var rnd = _rng(77)
        var st = SW.newState()
        var ids = ["a", "b", "c"]
        var codes = ["write-rejected", "write-unavailable", "write-failed", ""]
        for (var i = 0; i < 500; ++i) {
            var id = ids[Math.floor(rnd() * ids.length)]
            if (rnd() < 0.2) SW.clearTerminal(st, id)
            else SW.noteFailure(st, id, 500, true, codes[Math.floor(rnd() * codes.length)])
            var parked = 0
            for (var k = 0; k < ids.length; ++k) {
                if (SW.isParked(st, ids[k])) { parked++; verify(SW.isStuck(st, ids[k]), "step " + i) }
            }
            compare(parked, SW.terminalCount(st), "step " + i)
            verify(parked <= SW.stuckCount(st), "step " + i)
        }
    }
}
