import QtQuick
import QtTest
import "../qml/helper/FailureCause.js" as FC

// Headless tests for the plain-language cause text (pure JS, no singletons).
// Design: docs/superpowers/specs/2026-10-13-completion-error-cause-design.md
// Test plan: docs/superpowers/test-plans/2026-10-13-completion-error-cause-test-plan.md (section 1)
TestCase {
    name: "FailureCause"

    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    // ── forRejection ─────────────────────────────────────────────────────

    function test_U01_insufficient_quantity_keeps_the_established_wording_and_names_the_product() {
        var r = FC.forRejection({ error: "insufficient-quantity" }, "Widget")
        compare(r.text, "Widget: stock ran out before this order could complete")
        compare(r.kind, "stock")
    }

    function test_U01b_insufficient_quantity_without_a_name_has_no_leading_colon() {
        compare(FC.forRejection({ error: "insufficient-quantity" }, "").text, "stock ran out before this order could complete")
        compare(FC.forRejection({ error: "insufficient-quantity" }).text, "stock ran out before this order could complete")
        compare(FC.forRejection({ error: "insufficient-quantity" }, "   ").text, "stock ran out before this order could complete")
    }

    function test_U02_conflict() {
        var r = FC.forRejection({ error: "conflict", conflict: true }, "")
        compare(r.kind, "conflict")
        verify(r.text.indexOf("Another device") === 0)
    }

    function test_U03_not_found() {
        var r = FC.forRejection({ error: "not-found" }, "")
        compare(r.kind, "missing")
        verify(r.text.indexOf("deleted on another device") > 0)
    }

    function test_U04_server_cannot_accept_codes_are_flagged_as_app_problems_and_echo_the_code() {
        var codes = ["missing-fields", "unsupported-op-type", "invalid-request-id", "empty-operation",
                     "unsupported-kind", "invalid-entity-id", "cascade-delete-not-allowed"]
        for (var i = 0; i < codes.length; ++i) {
            var r = FC.forRejection({ error: codes[i] }, "")
            compare(r.kind, "bug", codes[i])
            verify(r.text.indexOf("(" + codes[i] + ")") > 0, codes[i])
        }
    }

    function test_U04b_too_large_and_duplicate_request_id() {
        compare(FC.forRejection({ error: "operation-too-large" }, "").kind, "limit")
        verify(FC.forRejection({ error: "operation-too-large" }, "").text.indexOf("second order") >= 0)
        compare(FC.forRejection({ error: "request-id-in-use" }, "").kind, "duplicate")
    }

    function test_U05_unknown_code_is_generic_and_echoes_only_a_safe_token() {
        var r = FC.forRejection({ error: "brand-new-code" }, "")
        compare(r.kind, "unknown")
        compare(r.text, "The server rejected this change (brand-new-code)")
    }

    function test_U06_unsafe_codes_are_never_echoed() {
        var bad = ["<script>alert(1)</script>", "has space", "x".repeat(41), "a/b", "\u00e9\u00e9", ""]
        for (var i = 0; i < bad.length; ++i) {
            var r = FC.forRejection({ error: bad[i] }, "")
            compare(r.text, "The server rejected this change", "input " + i)
            compare(r.kind, "unknown")
        }
    }

    function test_U07_negative_inputs_never_throw_and_always_give_text() {
        var inputs = [null, undefined, "x", 7, [], {}, { error: 5 }, { error: null }, true]
        for (var i = 0; i < inputs.length; ++i) {
            var r = FC.forRejection(inputs[i], null)
            verify(r.text.length > 0, "input " + i)
            compare(r.kind, "unknown")
        }
    }

    function test_U08_a_hostile_name_is_trimmed_and_passed_through_as_text_only() {
        var r = FC.forRejection({ error: "insufficient-quantity" }, "  <b>Wid\u00e9get</b>\n  ")
        compare(r.text, "<b>Wid\u00e9get</b>: stock ran out before this order could complete")
        var huge = "N".repeat(5000)
        compare(FC.forRejection({ error: "insufficient-quantity" }, huge).text.length, 5000 + ": stock ran out before this order could complete".length)
    }

    // ── forWriteError ────────────────────────────────────────────────────

    function test_U09_write_rejected_says_usually_never_asserts_one_cause() {
        var r = FC.forWriteError("write-rejected", 500)
        compare(r.kind, "rejected")
        verify(r.text.indexOf("Usually") > 0)
    }

    function test_U10_write_unavailable_and_write_failed() {
        compare(FC.forWriteError("write-unavailable", 500).kind, "transient")
        compare(FC.forWriteError("write-unavailable", 500).text, "The server is temporarily unavailable")
        compare(FC.forWriteError("write-failed", 500).kind, "unknown")
        compare(FC.forWriteError("write-failed", 500).text, "The server hit an unexpected error")
    }

    function test_U11_timeout_and_plain_http_status_and_nothing() {
        compare(FC.forWriteError("", "timeout").kind, "timeout")
        compare(FC.forWriteError("", 503).text, "The server returned an error (HTTP 503)")
        compare(FC.forWriteError("", 503.9).text, "The server returned an error (HTTP 503)")
        compare(FC.forWriteError("", 0).text, "The server returned an error")
        compare(FC.forWriteError("", 200).text, "The server returned an error")
        compare(FC.forWriteError("", NaN).text, "The server returned an error")
        compare(FC.forWriteError("", Infinity).text, "The server returned an error")
    }

    function test_U12_code_wins_over_status_and_is_trimmed() {
        compare(FC.forWriteError(" write-rejected ", "timeout").kind, "rejected")
    }

    function test_U13_negative_inputs_never_throw() {
        var inputs = [null, undefined, 5, {}, [], true]
        for (var i = 0; i < inputs.length; ++i) {
            verify(FC.forWriteError(inputs[i], inputs[i]).text.length > 0, "input " + i)
        }
    }

    function test_U14_no_tenant_context_says_removed_or_suspended_most_likely_and_never_asserts_one_cause() {
        var r = FC.forWriteError("no-tenant-context", 403)
        compare(r.kind, "access")
        compare(r.text, "The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it")
        verify(r.text.indexOf("most likely") >= 0, "must hedge: the code cannot know which cause")
        verify(r.text.indexOf("removed") >= 0 && r.text.indexOf("suspended") >= 0, "names the two usual causes")
        verify(r.text.indexOf("owner or an admin") >= 0, "names who can fix it (an admin can restore members)")
        verify(r.text.indexOf("deactivated") < 0, "S2f-3 wording replaced 'changed or deactivated'")
        verify(r.text.indexOf("403") < 0, "the status is not echoed when the code is known")
    }

    function test_U15_no_tenant_context_wins_over_status_is_trimmed_and_neighbours_are_unchanged() {
        compare(FC.forWriteError(" no-tenant-context ", 500).kind, "access")
        compare(FC.forWriteError("no-tenant-context", "timeout").kind, "access")
        compare(FC.forWriteError("no-tenant-context", undefined).kind, "access")
        // other 403 bodies (and a 403 with no body) keep the plain status text
        compare(FC.forWriteError("not-authorized", 403).text, "The server returned an error (HTTP 403)")
        compare(FC.forWriteError("", 403).text, "The server returned an error (HTTP 403)")
        // a near-miss code is not the access text
        compare(FC.forWriteError("no-tenant-context-x", 403).kind, "unknown")
    }

    function test_U16_monkey_never_throws_and_text_is_never_empty() {
        var rnd = _rng(1337)
        var codes = ["write-rejected", "write-unavailable", "write-failed", "conflict", "not-found",
                     "insufficient-quantity", "weird", "", null, undefined, 4, {}, "<x>"]
        var statuses = [0, 200, 400, 404, 409, 500, 503, "timeout", null, undefined, NaN, "x", {}]
        function pick(a) { return a[Math.floor(rnd() * a.length)] }
        for (var i = 0; i < 500; ++i) {
            var a = FC.forRejection({ error: pick(codes), opIndex: Math.floor(rnd() * 5) }, pick(["", "Widget", null, 3]))
            var b = FC.forWriteError(pick(codes), pick(statuses))
            verify(typeof a.text === "string" && a.text.length > 0, "rejection run " + i)
            verify(typeof b.text === "string" && b.text.length > 0, "write run " + i)
            verify(typeof a.kind === "string" && typeof b.kind === "string")
        }
    }

    // ---- S2f-3 sweep (PR #171 device test): lock acquire results ----
    function test_U17_forAccess_is_the_one_wording_shared_with_the_403_stuck_write() {
        var a = FC.forAccess()
        compare(a.kind, "access")
        compare(a.text, FC.forWriteError("no-tenant-context", 403).text)
        verify(a.text.indexOf("try again") < 0, "retrying cannot help a removed or suspended member")
        verify(a.text.indexOf("elsewhere") < 0, "never reads as a lock denial")
        verify(a.text.indexOf("connection") < 0, "never reads as a network problem")
        verify(a.text.indexOf("owner or an admin") >= 0)
    }

    function test_U18_lockState_maps_each_acquire_result_to_one_state() {
        compare(FC.lockState({ granted: true, holder: null, reason: null }), "granted")
        compare(FC.lockState({ granted: false, holder: { name: "A" }, reason: "denied" }), "denied")
        compare(FC.lockState({ granted: false, holder: null, reason: "denied" }), "denied")
        compare(FC.lockState({ granted: false, holder: null, reason: "error", noAccess: true }), "no-access")
        compare(FC.lockState({ granted: false, holder: null, reason: "error" }), "error")
    }

    function test_U19_lockState_never_reads_junk_as_granted_denied_or_no_access() {
        var junk = [null, undefined, 0, 1, "", "granted", "denied", true, false, [], {},
                    { granted: "true" }, { granted: 1 }, { granted: false, reason: "Denied" },
                    { granted: false, reason: "weird" }, { granted: false, noAccess: "true" },
                    { granted: false, noAccess: 1 }, { reason: "denied", granted: undefined, noAccess: false }]
        var expect = ["error", "error", "error", "error", "error", "error", "error", "error", "error", "error", "error",
                      "error", "error", "error", "error", "error", "error", "denied"]
        for (var i = 0; i < junk.length; ++i)
            compare(FC.lockState(junk[i]), expect[i], "case " + i)
    }

    function test_U20_lockState_granted_beats_a_stray_noAccess_flag_and_noAccess_beats_denied() {
        compare(FC.lockState({ granted: true, noAccess: true }), "granted")
        compare(FC.lockState({ granted: false, noAccess: true, reason: "denied" }), "no-access")
    }
}
