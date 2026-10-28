import QtQuick
import QtTest
import "../qml/helper/AccessState.js" as AS

// Headless tests for what the app does with the signed-in user's own member doc at login
// (enter / block) and the access-blocked screen's copy. Pure JS, no singletons. AuthService, the
// page and the Main.qml wiring cannot run here (Felgo, no App context): they are pinned by
// .github/scripts/__tests__/accessBlockWiring.test.js and covered by the on-device plan.
// Design: docs/superpowers/specs/2026-10-28-s2f3-access-wording-design.md
// Test plan: docs/superpowers/test-plans/2026-10-28-s2f3-access-blocked-test-plan.md
TestCase {
    name: "AccessState"

    readonly property var roles: ["owner", "admin", "manager", "staff"]
    readonly property string kept: "Changes that were not sent yet stay on this phone until you sign out."

    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    function _member(status, role) { return { uid: "u1", status: status, role: role } }

    // ---- constants -------------------------------------------------------------------------

    function test_valid_roles_are_the_four_the_server_and_rules_accept() {
        compare(AS.VALID_ROLES.length, 4)
        compare(AS.VALID_ROLES.join(","), "owner,admin,manager,staff")
    }

    function test_isValidRole_accepts_exactly_the_four() {
        for (var i = 0; i < roles.length; i++) verify(AS.isValidRole(roles[i]), roles[i])
        var bad = ["", "viewer", "Owner", "OWNER", " owner", "owner ", "admin\n", "root", null, undefined, 0, 1, true, {}, [], ["owner"]]
        for (var j = 0; j < bad.length; j++) verify(!AS.isValidRole(bad[j]), "junk role " + j)
    }

    function test_isBlockedState_is_the_four_blocked_states_only() {
        var blocked = ["removed", "suspended", "role", "unverified"]
        for (var i = 0; i < blocked.length; i++) verify(AS.isBlockedState(blocked[i]), blocked[i])
        var other = ["ok", "", "Removed", "unknown", null, undefined, 1, {}]
        for (var j = 0; j < other.length; j++) verify(!AS.isBlockedState(other[j]), "other " + j)
    }

    // ---- classify: happy -------------------------------------------------------------------

    function test_classify_active_member_with_each_role_is_ok_with_that_role() {
        for (var i = 0; i < roles.length; i++) {
            var r = AS.classify(true, 200, _member("active", roles[i]))
            compare(r.state, "ok")
            compare(r.role, roles[i])
        }
    }

    function test_classify_ignores_extra_fields_on_the_doc() {
        var doc = _member("active", "manager")
        doc.tenantName = "Aurora"; doc.displayName = "Asha"; doc.joinedAt = "2026-01-01"; doc.extra = { a: 1 }
        var r = AS.classify(true, 200, doc)
        compare(r.state, "ok")
        compare(r.role, "manager")
    }

    // ---- classify: removed ------------------------------------------------------------------

    function test_classify_404_is_removed() {
        compare(AS.classify(false, 404, null).state, "removed")
    }

    function test_classify_404_is_removed_even_if_a_doc_or_ok_flag_is_passed() {
        compare(AS.classify(false, 404, _member("active", "owner")).state, "removed")
        compare(AS.classify(true, 404, _member("active", "owner")).state, "removed")
        compare(AS.classify(undefined, 404, undefined).state, "removed")
    }

    function test_classify_removed_carries_no_role() {
        verify(AS.classify(false, 404, null).role === undefined)
    }

    // ---- classify: suspended (anything that is not exactly "active") -----------------------

    function test_classify_suspended_status_is_suspended() {
        for (var i = 0; i < roles.length; i++)
            compare(AS.classify(true, 200, _member("suspended", roles[i])).state, "suspended")
    }

    function test_classify_any_status_but_exactly_active_is_suspended_fail_closed() {
        var odd = [undefined, null, "", " ", "Active", "ACTIVE", " active", "active ", "active\n", "inactive", "deleted",
                   "enabled", 0, 1, true, false, {}, [], ["active"], { v: "active" }]
        for (var i = 0; i < odd.length; i++) {
            var r = AS.classify(true, 200, _member(odd[i], "owner"))
            compare(r.state, "suspended", "status variant " + i)
            verify(r.role === undefined)
        }
    }

    function test_classify_a_doc_with_no_fields_is_suspended() {
        compare(AS.classify(true, 200, {}).state, "suspended")
    }

    function test_classify_status_is_judged_before_role() {
        compare(AS.classify(true, 200, _member("suspended", "viewer")).state, "suspended")
        compare(AS.classify(true, 200, _member(undefined, undefined)).state, "suspended")
    }

    // ---- classify: role ---------------------------------------------------------------------

    function test_classify_active_with_an_invalid_role_is_role_never_a_default() {
        var bad = [undefined, null, "", " ", "viewer", "Owner", "OWNER", " owner", "owner ", "root", "Staff", 0, 1, true, {}, [], ["owner"]]
        for (var i = 0; i < bad.length; i++) {
            var r = AS.classify(true, 200, _member("active", bad[i]))
            compare(r.state, "role", "role variant " + i)
            verify(r.role === undefined)
        }
    }

    // ---- classify: unverified ---------------------------------------------------------------

    function test_classify_failed_reads_are_unverified() {
        var statuses = [0, 400, 401, 403, 408, 429, 500, 502, 503, 504, undefined, null, NaN, "timeout", "404", {}, -1]
        for (var i = 0; i < statuses.length; i++)
            compare(AS.classify(false, statuses[i], null).state, "unverified", "status variant " + i)
    }

    function test_classify_403_is_unverified_not_removed_or_suspended() {
        compare(AS.classify(false, 403, null).state, "unverified")
        compare(AS.classify(false, 403, _member("suspended", "staff")).state, "unverified")
    }

    function test_classify_ok_without_a_usable_doc_is_unverified() {
        var docs = [null, undefined, [], [1], "active", "", 0, 1, true, false]
        for (var i = 0; i < docs.length; i++)
            compare(AS.classify(true, 200, docs[i]).state, "unverified", "doc variant " + i)
    }

    function test_classify_only_the_boolean_true_counts_as_ok() {
        var flags = [undefined, null, 0, 1, "true", "ok", {}, [], NaN]
        for (var i = 0; i < flags.length; i++)
            compare(AS.classify(flags[i], 200, _member("active", "owner")).state, "unverified", "flag variant " + i)
    }

    function test_classify_missing_arguments_do_not_throw() {
        compare(AS.classify().state, "unverified")
        compare(AS.classify(true).state, "unverified")
        compare(AS.classify(true, 200).state, "unverified")
    }

    function test_classify_a_doc_whose_getter_throws_is_unverified() {
        var evil = {}
        Object.defineProperty(evil, "status", { get: function() { throw new Error("boom") } })
        compare(AS.classify(true, 200, evil).state, "unverified")
        var evilRole = { status: "active" }
        Object.defineProperty(evilRole, "role", { get: function() { throw new Error("boom") } })
        compare(AS.classify(true, 200, evilRole).state, "unverified")
    }

    // ---- outcome ---------------------------------------------------------------------------

    function test_outcome_ok_enters_with_the_member_role_verified() {
        for (var i = 0; i < roles.length; i++) {
            var o = AS.outcome({ state: "ok", role: roles[i] }, "")
            compare(o.action, "enter")
            compare(o.role, roles[i])
            compare(o.verified, true)
        }
    }

    function test_outcome_the_member_role_beats_the_held_role() {
        var o = AS.outcome({ state: "ok", role: "staff" }, "owner")
        compare(o.role, "staff")
        compare(o.verified, true)
    }

    function test_outcome_removed_suspended_role_block_even_with_a_held_role() {
        var states = ["removed", "suspended", "role"]
        for (var i = 0; i < states.length; i++) {
            var o = AS.outcome({ state: states[i] }, "owner")
            compare(o.action, "block", states[i])
            compare(o.reason, states[i])
            verify(o.role === undefined)
        }
    }

    function test_outcome_unverified_with_a_held_role_enters_unverified() {
        for (var i = 0; i < roles.length; i++) {
            var o = AS.outcome({ state: "unverified" }, roles[i])
            compare(o.action, "enter")
            compare(o.role, roles[i])
            compare(o.verified, false)
        }
    }

    function test_outcome_unverified_without_a_valid_held_role_blocks() {
        var held = ["", undefined, null, "viewer", "Owner", " owner", 0, 1, true, {}, []]
        for (var i = 0; i < held.length; i++) {
            var o = AS.outcome({ state: "unverified" }, held[i])
            compare(o.action, "block", "held variant " + i)
            compare(o.reason, "unverified")
        }
    }

    function test_outcome_junk_classification_is_treated_as_unverified() {
        var junk = [null, undefined, {}, [], "ok", 1, { state: "zzz" }, { state: "" }, { state: "ok" }, { state: "ok", role: "root" }, { state: "OK", role: "owner" }]
        for (var i = 0; i < junk.length; i++) {
            compare(AS.outcome(junk[i], "").action, "block", "junk " + i)
            compare(AS.outcome(junk[i], "").reason, "unverified")
            var held = AS.outcome(junk[i], "manager")
            compare(held.action, "enter", "junk with held " + i)
            compare(held.verified, false)
            compare(held.role, "manager")
        }
    }

    function test_outcome_ok_with_an_invalid_role_never_enters() {
        var o = AS.outcome({ state: "ok", role: "root" }, "")
        compare(o.action, "block")
        compare(o.reason, "unverified")
    }

    function test_outcome_missing_arguments_do_not_throw() {
        compare(AS.outcome().action, "block")
        compare(AS.outcome({ state: "removed" }).action, "block")
    }

    // ---- outcome with prevBlock (a "Try again" from the blocked screen) ----------------------

    function test_outcome_a_failed_check_keeps_the_block_that_is_showing_even_with_a_held_role() {
        var shown = ["removed", "suspended", "role", "unverified"]
        for (var i = 0; i < shown.length; i++) {
            for (var h = 0; h < 2; h++) {
                var o = AS.outcome({ state: "unverified" }, h === 0 ? "owner" : "", shown[i])
                compare(o.action, "block", shown[i] + " held " + h)
                compare(o.reason, shown[i])
                verify(o.role === undefined)
            }
        }
    }

    function test_outcome_a_conclusive_answer_beats_the_block_that_is_showing() {
        var shown = ["removed", "suspended", "role", "unverified"]
        for (var i = 0; i < shown.length; i++) {
            var ok = AS.outcome({ state: "ok", role: "staff" }, "owner", shown[i])
            compare(ok.action, "enter")
            compare(ok.role, "staff")
            compare(ok.verified, true)
            compare(AS.outcome({ state: "removed" }, "owner", shown[i]).reason, "removed")
            compare(AS.outcome({ state: "suspended" }, "owner", shown[i]).reason, "suspended")
            compare(AS.outcome({ state: "role" }, "owner", shown[i]).reason, "role")
        }
    }

    function test_outcome_a_prevBlock_that_is_not_a_block_state_is_ignored() {
        var junk = ["", undefined, null, "zzz", "ok", "Suspended", " removed", 0, 1, true, {}, []]
        for (var i = 0; i < junk.length; i++) {
            var held = AS.outcome({ state: "unverified" }, "manager", junk[i])
            compare(held.action, "enter", "junk " + i)
            compare(held.verified, false)
            compare(held.role, "manager")
            var none = AS.outcome({ state: "unverified" }, "", junk[i])
            compare(none.action, "block", "junk none " + i)
            compare(none.reason, "unverified")
        }
    }

    // ---- copy ------------------------------------------------------------------------------

    function test_copy_removed() {
        var c = AS.copy("removed", "Aurora Coffee")
        compare(c.title, "Your access was removed")
        compare(c.body, "You are no longer a member of Aurora Coffee. " + kept + " Ask the shop owner to add you again.")
    }

    function test_copy_suspended() {
        var c = AS.copy("suspended", "Aurora Coffee")
        compare(c.title, "Your access is suspended")
        compare(c.body, "Your access to Aurora Coffee is suspended or inactive. You cannot see or change shop data until the shop owner or an admin restores it. " + kept)
    }

    function test_copy_role() {
        var c = AS.copy("role", "Aurora Coffee")
        compare(c.title, "Your role is not valid")
        compare(c.body, "Your account in Aurora Coffee has a role this app does not recognise, so access is blocked. Ask the shop owner or an admin to fix your role.")
    }

    function test_copy_unverified() {
        var c = AS.copy("unverified", "Aurora Coffee")
        compare(c.title, "Could not check your access")
        compare(c.body, "The app could not confirm your access to Aurora Coffee. Check your internet connection and try again.")
    }

    function test_copy_other_states_are_empty_never_undefined() {
        var other = ["ok", "", "Removed", null, undefined, 1, {}]
        for (var i = 0; i < other.length; i++) {
            var c = AS.copy(other[i], "Aurora")
            compare(c.title, "")
            compare(c.body, "")
        }
    }

    function test_copy_shop_name_fallback_when_missing_or_blank() {
        var names = [undefined, null, "", " ", "\n\t", 0, 5, {}, [], true]
        for (var i = 0; i < names.length; i++)
            compare(AS.copy("unverified", names[i]).body,
                    "The app could not confirm your access to this shop. Check your internet connection and try again.", "name variant " + i)
        compare(AS.copy("removed").body.indexOf("You are no longer a member of this shop. "), 0)
    }

    function test_copy_shop_name_is_single_line_and_trimmed() {
        verify(AS.copy("unverified", "  Aurora \n Coffee\t").body.indexOf("access to Aurora Coffee. ") > 0)
        verify(AS.copy("unverified", "A\u0000B\u001fC\u007fD").body.indexOf("access to A B C D. ") > 0)
    }

    function test_copy_shop_name_cap_boundary_60_61_and_long() {
        var s60 = new Array(61).join("a")
        var s61 = s60 + "a"
        verify(AS.copy("unverified", s60).body.indexOf("access to " + s60 + ". ") >= 0, "60 chars kept whole")
        var capped = AS.copy("unverified", s61).body
        verify(capped.indexOf("access to " + s60.slice(0, 59) + "\u2026. ") >= 0, "61 chars capped to 59 + ellipsis")
        var huge = AS.copy("unverified", new Array(5001).join("b")).body
        verify(huge.length < 200, "a 5000 char name cannot blow up the screen: " + huge.length)
    }

    function test_copy_markup_in_the_name_is_text_not_stripped_the_page_shows_plain_text() {
        verify(AS.copy("unverified", "<b>Acme</b>").body.indexOf("<b>Acme</b>") >= 0)
    }

    function test_copy_never_returns_empty_text_for_a_blocked_state() {
        var blocked = ["removed", "suspended", "role", "unverified"]
        for (var i = 0; i < blocked.length; i++) {
            var c = AS.copy(blocked[i], "x")
            verify(c.title.length > 0 && c.body.length > 0, blocked[i])
        }
    }

    // ---- scenario ---------------------------------------------------------------------------

    function test_scenario_login_matrix_status_x_role_x_held() {
        var statuses = ["active", "suspended", undefined, "Active"]
        var memberRoles = ["owner", "admin", "manager", "staff", "viewer", undefined]
        for (var s = 0; s < statuses.length; s++) {
            for (var r = 0; r < memberRoles.length; r++) {
                var cls = AS.classify(true, 200, _member(statuses[s], memberRoles[r]))
                var o = AS.outcome(cls, "staff")
                var shouldEnter = statuses[s] === "active" && roles.indexOf(memberRoles[r]) >= 0
                compare(o.action, shouldEnter ? "enter" : "block", statuses[s] + "/" + memberRoles[r])
                if (shouldEnter) compare(o.role, memberRoles[r])
            }
        }
    }

    function test_scenario_removed_then_restored_then_suspended() {
        compare(AS.outcome(AS.classify(false, 404, null), "owner").action, "block")
        compare(AS.outcome(AS.classify(true, 200, _member("active", "staff")), "").action, "enter")
        compare(AS.outcome(AS.classify(true, 200, _member("suspended", "staff")), "staff").action, "block")
    }

    function test_scenario_suspended_member_retries_on_a_flaky_network_then_is_restored() {
        var shown = AS.outcome(AS.classify(true, 200, _member("suspended", "staff")), "staff", "").reason
        compare(shown, "suspended")
        var codes = [0, 500, 503, 401, 403]
        for (var i = 0; i < codes.length; i++) {
            var o = AS.outcome(AS.classify(false, codes[i], null), "staff", shown)
            compare(o.action, "block", "retry failed " + codes[i])
            compare(o.reason, "suspended")
        }
        compare(AS.outcome(AS.classify(true, 200, _member("active", "staff")), "staff", shown).action, "enter")
    }

    function test_scenario_flaky_network_never_blocks_a_verified_member_but_always_blocks_an_unknown_one() {
        var codes = [0, 500, 503, 401, 403]
        for (var i = 0; i < codes.length; i++) {
            compare(AS.outcome(AS.classify(false, codes[i], null), "owner").action, "enter")
            compare(AS.outcome(AS.classify(false, codes[i], null), "").action, "block")
        }
    }

    // ---- monkey (seeded, independent oracle) -----------------------------------------------

    function _junk(rnd) {
        var pool = [undefined, null, "", " ", "active", "Active", "suspended", "owner", "admin", "manager", "staff", "viewer", "x",
                    0, 1, -1, true, false, NaN, {}, [], ["active"], 404, 200, 403, 500]
        return pool[Math.floor(rnd() * pool.length)]
    }

    function test_monkey_classify_matches_an_independent_oracle() {
        var rnd = _rng(20261028)
        for (var n = 0; n < 4000; n++) {
            var ok = rnd() < 0.7 ? true : _junk(rnd)
            var status = rnd() < 0.2 ? 404 : (rnd() < 0.5 ? 200 : _junk(rnd))
            var doc = rnd() < 0.15 ? _junk(rnd) : { status: _junk(rnd), role: _junk(rnd) }
            var r = AS.classify(ok, status, doc)
            var expected
            if (status === 404) expected = "removed"
            else if (ok !== true) expected = "unverified"
            else if (doc === null || typeof doc !== "object" || Array.isArray(doc)) expected = "unverified"
            else if (doc.status !== "active") expected = "suspended"
            else if (roles.indexOf(doc.role) < 0) expected = "role"
            else expected = "ok"
            compare(r.state, expected, "iteration " + n)
            if (r.state === "ok") compare(r.role, doc.role)
            else verify(r.role === undefined)
        }
    }

    function test_monkey_outcome_enters_only_for_an_ok_member_or_a_valid_held_role() {
        var rnd = _rng(20261029)
        var states = ["ok", "removed", "suspended", "role", "unverified", "", "zzz", undefined, null]
        for (var n = 0; n < 4000; n++) {
            var cls = rnd() < 0.1 ? _junk(rnd) : { state: states[Math.floor(rnd() * states.length)], role: _junk(rnd) }
            var held = rnd() < 0.5 ? roles[Math.floor(rnd() * 4)] : _junk(rnd)
            var o = AS.outcome(cls, held)
            var st = (cls && typeof cls === "object") ? cls.state : ""
            verify(o.action === "enter" || o.action === "block")
            if (o.action === "enter") {
                verify(roles.indexOf(o.role) >= 0, "entered with an invalid role, iteration " + n)
                if (o.verified) verify(st === "ok" && o.role === cls.role, "verified without an ok state")
                else verify(o.role === held && st !== "removed" && st !== "suspended" && st !== "role",
                            "held role used although the member was refused, iteration " + n)
            } else {
                verify(AS.isBlockedState(o.reason), "block without a reason, iteration " + n)
                verify(o.role === undefined)
            }
        }
    }

    function test_monkey_outcome_with_prevBlock_never_enters_on_an_inconclusive_check_while_blocked() {
        var rnd = _rng(20261031)
        var states = ["ok", "removed", "suspended", "role", "unverified", "", "zzz", undefined, null]
        var blocks = ["removed", "suspended", "role", "unverified"]
        for (var n = 0; n < 4000; n++) {
            var cls = rnd() < 0.1 ? _junk(rnd) : { state: states[Math.floor(rnd() * states.length)], role: _junk(rnd) }
            var held = rnd() < 0.5 ? roles[Math.floor(rnd() * 4)] : _junk(rnd)
            var prev = rnd() < 0.5 ? blocks[Math.floor(rnd() * 4)] : _junk(rnd)
            var o = AS.outcome(cls, held, prev)
            var st = (cls && typeof cls === "object") ? cls.state : ""
            var conclusive = (st === "ok" && roles.indexOf(cls.role) >= 0) || st === "removed" || st === "suspended" || st === "role"
            if (!conclusive && blocks.indexOf(prev) >= 0) {
                compare(o.action, "block", "entered while blocked on an inconclusive check, iteration " + n)
                compare(o.reason, prev)
            } else {
                var base = AS.outcome(cls, held)
                compare(o.action, base.action, "prevBlock changed a case it must not, iteration " + n)
                compare(o.reason, base.reason)
                compare(o.role, base.role)
            }
        }
    }

    function test_monkey_copy_always_returns_two_strings() {
        var rnd = _rng(20261030)
        var states = ["removed", "suspended", "role", "unverified", "ok", "", undefined, null, 5]
        for (var n = 0; n < 2000; n++) {
            var c = AS.copy(states[Math.floor(rnd() * states.length)], _junk(rnd))
            verify(typeof c.title === "string" && typeof c.body === "string", "iteration " + n)
        }
    }

    function test_no_state_between_calls() {
        var a = AS.classify(true, 200, _member("active", "owner"))
        AS.classify(false, 404, null)
        var b = AS.classify(true, 200, _member("active", "owner"))
        compare(JSON.stringify(a), JSON.stringify(b))
    }
}
