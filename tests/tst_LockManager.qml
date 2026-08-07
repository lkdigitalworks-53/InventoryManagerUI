import QtQuick
import QtTest
import "../qml/model"

// Tests for LockManager's pure classification logic (_classifyAcquireResponse)
// — the actual network round-trip (_post's XMLHttpRequest) has no mock HTTP
// layer in this codebase, same limitation as tst_Gateway.qml, so it isn't
// exercised here. What IS fully testable, and is where the real bug lived,
// is the decision logic that turns a raw (status, body) pair into
// {granted, holder, reason}.
//
// Regression coverage for the 2026-07-29 bug (systematic-debugging session):
// a lone tester saw "someone else is editing this order" with nobody else
// on the system. Root cause: acquireLock wasn't deployed yet, so every
// acquire attempt got an infrastructure-level 404 with no real body — and
// the original code treated ANY non-2xx response as a genuine denial,
// unable to tell "couldn't get a real answer" from "got a real no."
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local
// `qmltestrunner` pass before merge, same status as every other client-
// side file this session.
TestCase {
    name: "LockManager"

    function test_classifyAcquireResponse_treats_a_malformed_body_as_error_not_denied() {
        // What an undeployed acquireLock endpoint's 404 actually looks
        // like: no JSON body at all, so body is null by the time this runs.
        var result = LockManager._classifyAcquireResponse(404, null)
        compare(result.granted, false)
        compare(result.reason, "error", "must not be reported as a genuine denial")
        compare(result.holder, null)
    }

    function test_classifyAcquireResponse_treats_a_body_without_ok_as_error() {
        var result = LockManager._classifyAcquireResponse(404, { error: { code: 404 } })
        compare(result.granted, false)
        compare(result.reason, "error")
    }

    function test_classifyAcquireResponse_treats_a_genuine_grant_as_granted() {
        var result = LockManager._classifyAcquireResponse(200, { ok: true, expiresAt: 1234567 })
        compare(result.granted, true)
        compare(result.reason, null)
    }

    function test_classifyAcquireResponse_treats_a_genuine_rejection_as_denied_with_holder() {
        var result = LockManager._classifyAcquireResponse(409, {
            ok: false, holder: { name: "Priya", role: "staff", expiresAt: 999 }
        })
        compare(result.granted, false)
        compare(result.reason, "denied")
        compare(result.holder.name, "Priya")
    }

    function test_classifyAcquireResponse_denied_without_holder_info_still_reports_denied_not_error() {
        // Server said no but didn't (or couldn't) include holder details —
        // still a REAL decision, must stay "denied", not get downgraded to
        // "error" just because `holder` is missing.
        var result = LockManager._classifyAcquireResponse(409, { ok: false })
        compare(result.reason, "denied")
        compare(result.holder, null)
    }

    // Regression coverage for review finding C6 (2026-08-06): the function
    // used to classify EVERY well-formed ok:false body as "denied",
    // regardless of status — so a 400/401/403/500 (none of which mean
    // "someone else holds this lock") showed the user a fabricated
    // "someone else is editing this" message. Only 409 is a real denial;
    // everything else well-formed-but-not-ok must be "error", same bucket
    // as a malformed body. These four cases all returned "denied" before
    // the fix — this is the coverage that would have caught it, and the
    // gap tst_LockManager.qml had until now (every prior case here only
    // ever used status 404 or 409, never a well-formed body at any other
    // status).
    function test_classifyAcquireResponse_400_missing_fields_is_error_not_denied() {
        var result = LockManager._classifyAcquireResponse(400, { ok: false, error: "missing-fields" })
        compare(result.reason, "error")
        compare(result.granted, false)
    }

    function test_classifyAcquireResponse_401_invalid_token_is_error_not_denied() {
        var result = LockManager._classifyAcquireResponse(401, { ok: false, error: "invalid-token" })
        compare(result.reason, "error")
    }

    function test_classifyAcquireResponse_403_no_tenant_context_is_error_not_denied() {
        var result = LockManager._classifyAcquireResponse(403, { ok: false, error: "no-tenant-context" })
        compare(result.reason, "error")
    }

    function test_classifyAcquireResponse_500_lock_failed_is_error_not_denied() {
        // Same reasoning _classifyDeltaResponse already applies on the
        // delta path: a 5xx, even with a well-formed body, is an
        // infrastructure problem on OUR side (here, acquireLock's own
        // transaction catch block), not a definitive "someone else has
        // it" decision — worth being told apart, not treated as a denial.
        var result = LockManager._classifyAcquireResponse(500, { ok: false, error: "lock-failed" })
        compare(result.reason, "error")
    }

    function test_acquire_with_no_auth_token_reports_error_not_denied() {
        var originalToken = AuthStore.idToken
        AuthStore.idToken = ""
        var received = null
        LockManager.acquire("order", "o1", function(result) { received = result })
        AuthStore.idToken = originalToken

        verify(received !== null, "callback must fire synchronously when there's no token to even try with")
        compare(received.granted, false)
        compare(received.reason, "error", "not being signed in yet is not the same as someone else holding the lock")
    }
}
