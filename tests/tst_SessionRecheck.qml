import QtQuick
import QtTest
import "../qml/helper/SessionRecheck.js" as SR

// Headless tests for the silent session re-check helper: when an automatic check may start and what its answer
// changes. Pure JS, no singletons. AuthService and the Main.qml resume hook cannot run here (Felgo, no App
// context): they are pinned by .github/scripts/__tests__/sessionRecheck{Behavior,Wiring}.test.js and covered by
// the on-device plan. The same cases run in Node in sessionRecheck.test.js, with hand mutants; this file proves
// them in the real Qt JS engine.
// Design: docs/superpowers/specs/2026-10-31-l3-session-lifecycle-design.md (L3-D1c, L3-D2a)
// Test plan: docs/superpowers/test-plans/2026-10-31-l3-session-lifecycle-test-plan.md
TestCase {
    name: "SessionRecheck"

    readonly property var roles: ["owner", "admin", "manager", "staff"]
    readonly property double t0: 1700000000000

    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    function _enter(role, verified) { return { action: "enter", role: role, verified: verified !== false } }
    function _block(reason) { return { action: "block", reason: reason } }

    // changeKind for an ordinary open session whose stores have synced; pass the 6th argument to change that
    function _ck(a, b, c, d, e) {
        return SR.changeKind(a, b, c, d, e, arguments.length > 5 ? arguments[5] : true)
    }

    // ---- constants -------------------------------------------------------------------------

    function test_spacing_is_60_seconds_and_a_lost_check_is_120() {
        compare(SR.AUTO_SPACING_MS, 60000)
        compare(SR.STALE_MS, 120000)
    }

    // ---- canStart: nothing in flight ---------------------------------------------------------

    function test_never_started_runs() {
        verify(SR.canStart(false, 0, t0))
        verify(SR.canStart(false, null, t0))
        verify(SR.canStart(false, undefined, t0))
    }

    function test_window_boundaries() {
        verify(!SR.canStart(false, t0, t0), "same instant")
        verify(!SR.canStart(false, t0, t0 + 1), "1 ms")
        verify(!SR.canStart(false, t0, t0 + 59999), "59 999 ms")
        verify(SR.canStart(false, t0, t0 + 60000), "exactly 60 000 ms")
        verify(SR.canStart(false, t0, t0 + 60001), "60 001 ms")
        verify(SR.canStart(false, t0, t0 + 6 * 3600 * 1000), "hours later")
    }

    function test_a_clock_that_went_backwards_runs_and_never_wedges() {
        verify(SR.canStart(false, t0, t0 - 1))
        verify(SR.canStart(false, t0, t0 - 3600000))
    }

    function test_junk_clock_or_start_fails_to_run_when_nothing_is_out() {
        var junk = [undefined, null, NaN, Infinity, -Infinity, "", "x", "1700000000000", true, false, {}, []]
        for (var i = 0; i < junk.length; i++) {
            verify(SR.canStart(false, t0, junk[i]), "junk now " + i)
            verify(SR.canStart(false, junk[i], t0), "junk start " + i)
        }
    }

    // ---- canStart: a check is in flight ------------------------------------------------------

    function test_in_flight_is_dropped_until_it_is_lost() {
        verify(!SR.canStart(true, t0, t0), "0 ms")
        verify(!SR.canStart(true, t0, t0 + 1), "1 ms")
        verify(!SR.canStart(true, t0, t0 + 60000), "past the 60 s window is still in flight")
        verify(!SR.canStart(true, t0, t0 + 119999), "119 999 ms")
        verify(SR.canStart(true, t0, t0 + 120000), "a check lost for 120 000 ms may be replaced")
        verify(SR.canStart(true, t0, t0 + 6 * 3600000), "hours")
    }

    function test_in_flight_with_an_unknown_or_backwards_clock_keeps_waiting() {
        var junk = [undefined, null, NaN, Infinity, "x", true, {}, []]
        for (var i = 0; i < junk.length; i++) {
            verify(!SR.canStart(true, t0, junk[i]), "junk now " + i)
            verify(!SR.canStart(true, junk[i], t0), "junk start " + i)
        }
        verify(!SR.canStart(true, t0, t0 - 1))
        verify(!SR.canStart(true, t0, t0 - 3600000))
    }

    function test_truthy_junk_in_flight_counts_as_in_flight() {
        verify(!SR.canStart("yes", t0, t0 + 1000))
        verify(!SR.canStart(1, t0, t0 + 61000))
        verify(!SR.canStart({}, t0, t0 + 119999))
    }

    function test_throttle_matches_an_independent_reference_over_seeded_cases() {
        var rnd = _rng(12345)
        for (var i = 0; i < 4000; i++) {
            var last = Math.floor(rnd() * 5e12)
            var now = rnd() < 0.7 ? last + Math.floor(rnd() * 260000) - 5000 : Math.floor(rnd() * 5e12)
            var inFlight = rnd() < 0.3
            var elapsed = now - last
            var expected = inFlight ? elapsed >= 120000 : (elapsed < 0 || elapsed >= 60000)
            compare(SR.canStart(inFlight, last, now), expected, JSON.stringify([inFlight, last, now]))
        }
    }

    function test_a_storm_inside_one_window_starts_exactly_one_check() {
        var last = 0, starts = 0
        for (var i = 0; i < 500; i++) {
            var now = t0 + i * 100
            if (SR.canStart(false, last, now)) { last = now; starts++ }
        }
        compare(starts, 1)
        for (var j = 0; j < 500; j++) {
            var now2 = t0 + 50000 + j * 100
            if (SR.canStart(false, last, now2)) { last = now2; starts++ }
        }
        compare(starts, 2)
    }

    // ---- changeKind --------------------------------------------------------------------------

    function test_unchanged_answer_is_none_for_every_role() {
        for (var i = 0; i < roles.length; i++) {
            compare(_ck("t1", roles[i], false, "t1", _enter(roles[i])), "none", roles[i])
            compare(_ck("t1", roles[i], false, "t1", _enter(roles[i], false)), "none", "unverified keeps the held role: " + roles[i])
        }
    }

    function test_all_12_role_changes_are_role() {
        var n = 0
        for (var i = 0; i < roles.length; i++)
            for (var j = 0; j < roles.length; j++) {
                if (i === j) continue
                compare(_ck("t1", roles[i], false, "t1", _enter(roles[j])), "role", roles[i] + " -> " + roles[j])
                n++
            }
        compare(n, 12)
    }

    function test_another_workspace_wins_over_a_role_change() {
        for (var i = 0; i < roles.length; i++) {
            compare(_ck("t1", roles[i], false, "t2", _enter(roles[i])), "tenant")
            compare(_ck("t1", roles[i], false, "t2", _enter(roles[(i + 1) % 4])), "tenant")
        }
    }

    function test_let_in_after_a_block_is_unblock_whatever_else_changed() {
        for (var i = 0; i < roles.length; i++) {
            compare(_ck("t1", roles[i], true, "t1", _enter(roles[i])), "unblock")
            compare(_ck("t1", roles[i], true, "t2", _enter("staff")), "unblock")
        }
    }

    function test_not_synced_is_first_even_when_nothing_differs() {
        for (var i = 0; i < roles.length; i++) {
            compare(_ck("t1", roles[i], false, "t1", _enter(roles[i]), false), "first", roles[i])
            compare(_ck("t1", roles[i], false, "t1", _enter(roles[i], false), false), "first", "unverified, held role: " + roles[i])
            compare(_ck("t1", roles[i], false, "t1", _enter(roles[i]), true), "none", "synced: " + roles[i])
        }
    }

    function test_only_exactly_true_counts_as_synced() {
        var odd = [undefined, null, false, 0, 1, "true", "yes", {}, [], NaN]
        for (var i = 0; i < odd.length; i++)
            compare(SR.changeKind("t1", "owner", false, "t1", _enter("owner"), odd[i]), "first", "odd " + i)
    }

    function test_first_beats_a_tenant_or_role_change_so_there_is_no_toast_at_first_resolve() {
        compare(_ck("t1", "owner", false, "t2", _enter("staff"), false), "first")
        compare(_ck("t1", "admin", false, "t1", _enter("staff"), false), "first")
    }

    function test_unblock_beats_first_and_a_refusal_is_block_whether_or_not_synced() {
        compare(_ck("t1", "owner", true, "t1", _enter("owner"), false), "unblock")
        compare(SR.changeKind("t1", "owner", true, "t1", _enter("owner"), undefined), "unblock")
        var reasons = ["removed", "suspended", "role", "unverified"]
        for (var i = 0; i < reasons.length; i++) {
            // Q1 (PR #180): an unreadable answer with no block showing is ignored by a silent check
            compare(_ck("t1", "owner", false, "t1", _block(reasons[i]), false), reasons[i] === "unverified" ? "none" : "block")
            compare(SR.changeKind("t1", "owner", true, "t1", _block(reasons[i]), undefined), "block")
        }
    }

    function test_a_malformed_answer_is_none_even_when_not_synced() {
        var junk = [undefined, null, NaN, "", "x", "enter", 5, true, []]
        for (var i = 0; i < junk.length; i++)
            compare(_ck("t1", "owner", false, "t1", junk[i], false), "none", "junk " + i)
        compare(_ck("t1", "owner", false, "t1", { action: "enter", role: "" }, false), "none")
    }

    function test_wasBlocked_must_be_exactly_true() {
        var odd = ["yes", 1, {}, [], "true"]
        for (var i = 0; i < odd.length; i++)
            compare(_ck("t1", "owner", odd[i], "t1", _enter("owner")), "none", "odd " + i)
    }

    function test_every_refusal_is_block() {
        var reasons = ["removed", "suspended", "role", "unverified"]
        for (var i = 0; i < roles.length; i++)
            for (var r = 0; r < reasons.length; r++) {
                compare(_ck("t1", roles[i], false, "t1", _block(reasons[r])), reasons[r] === "unverified" ? "none" : "block")
                compare(_ck("t1", roles[i], true, "t1", _block(reasons[r])), "block")
            }
    }

    function test_q1_unreadable_answer_for_another_workspace_is_ignored_unless_a_block_shows() {
        var syncs = [true, false, undefined]
        for (var i = 0; i < syncs.length; i++) {
            compare(SR.changeKind("t1", "owner", false, "t2", _block("unverified"), syncs[i]), "none")
            compare(SR.changeKind("t1", "owner", true, "t2", _block("unverified"), syncs[i]), "block")
        }
        var refusals = ["removed", "suspended", "role"]
        for (var r = 0; r < refusals.length; r++)
            compare(SR.changeKind("t1", "owner", false, "t2", _block(refusals[r]), true), "block")
        compare(SR.changeKind("t1", "owner", true, "t1", _block("moved"), true), "block")
    }

    function test_a_malformed_answer_is_none_and_never_blocks() {
        var junk = [undefined, null, NaN, "", "x", "enter", "block", 5, true, false, [], function() { return 1 }]
        for (var i = 0; i < junk.length; i++)
            compare(_ck("t1", "owner", false, "t1", junk[i]), "none", "junk " + i)
        compare(_ck("t1", "owner", false, "t1", { action: "noop", role: "staff" }), "none")
    }

    function test_enter_without_a_valid_role_string_is_none() {
        var badRoles = ["", undefined, null, 5, {}, []]
        for (var i = 0; i < badRoles.length; i++) {
            compare(_ck("t1", "owner", false, "t1", { action: "enter", role: badRoles[i] }), "none", "role " + i)
            compare(_ck("t1", "owner", true, "t1", { action: "enter", role: badRoles[i] }), "none", "blocked, role " + i)
        }
        compare(_ck("t1", "owner", true, "t1", { action: "enter" }), "none")
    }

    function test_junk_previous_values_never_throw_and_never_claim_a_block() {
        var junk = [undefined, null, NaN, "", "x", 5, true, {}, []]
        for (var i = 0; i < junk.length; i++) {
            var k = _ck(junk[i], junk[i], junk[i], junk[i], _enter("staff"))
            verify(["none", "tenant", "role", "unblock"].indexOf(k) >= 0, "junk " + i + " -> " + k)
        }
    }

    // ---- the pair: a trigger storm against the decision, end to end in the pure layer ----------

    function test_seeded_sequence_of_checks_follows_the_design() {
        var rnd = _rng(7)
        var tenant = "t1", role = "owner", blocked = false, synced = false, last = 0, now = t0
        var starts = 0, changes = 0
        for (var i = 0; i < 3000; i++) {
            now += Math.floor(rnd() * 90000)
            if (!SR.canStart(false, last, now)) continue
            last = now
            starts++
            var r = rnd()
            var out = r < 0.15 ? _block("suspended") : _enter(roles[Math.floor(rnd() * 4)], rnd() < 0.9)
            var t = rnd() < 0.1 ? "t2" : tenant
            var kind = _ck(tenant, role, blocked, t, out, synced)
            if (out.action === "block") { compare(kind, "block"); blocked = true; continue }
            if (blocked) compare(kind, "unblock")
            else if (!synced) compare(kind, "first")
            else if (t !== tenant) compare(kind, "tenant")
            else if (out.role !== role) compare(kind, "role")
            else compare(kind, "none")
            if (kind !== "none") changes++
            blocked = false; synced = true; tenant = t; role = out.role
        }
        verify(starts > 100, "the sequence started checks: " + starts)
        verify(changes > 20, "and changed state: " + changes)
    }
}
