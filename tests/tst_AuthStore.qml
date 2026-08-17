import QtQuick
import QtTest
import "../qml/model"

// First test coverage for AuthStore -- deliberately scoped to session
// persistence only (loadSession/saveSession/applyAuth round-tripping
// through Settings), which is what the QSettings org-identifier fix
// (SKILLS Skill 41) makes actually testable for the first time. AuthStore's
// large surface of role/permission readonly properties (canManageInventory,
// canViewFinancials, etc.) has NO coverage here -- that's a separate,
// unscoped gap, not silently done or silently skipped, just out of scope
// for this file.
//
// NOT RUN IN THIS SANDBOX -- no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local `qmltestrunner`
// pass before merge (same status as tst_EnvConfig.qml).
TestCase {
    name: "AuthStore"

    function init() {
        // Mirrors AuthService.signOut()'s exact clear()+saveSession()
        // sequence -- start every case from a clean, blanked, PERSISTED
        // state (not just clean in-memory state; clear() alone doesn't
        // touch _settings.sessionJson, only saveSession() after it does).
        AuthStore.clear()
        AuthStore.saveSession()
    }

    function test_applyAuth_persists_session_and_loadSession_restores_it_after_a_simulated_relaunch() {
        AuthStore.applyAuth({
            uid: "u1", email: "a@example.com", displayName: "Ann",
            idToken: "tok-1", refreshToken: "refresh-1", expiresAtEpochSec: 9999999999
        })
        AuthStore.applyTenantContext({ tenantId: "t1", tenantName: "Ann's Shop", role: "owner" })
        compare(AuthStore.isAuthenticated, true)

        // Simulate relaunch: loadSession() is exactly what
        // AuthService.Component.onCompleted calls on a real launch -- it
        // clears in-memory state itself, then reloads from Settings.
        AuthStore.loadSession()

        compare(AuthStore.isAuthenticated, true,
                "must reload as authenticated after a simulated relaunch -- if this is false, " +
                "Settings never actually wrote to a real file")
        compare(AuthStore.uid, "u1")
        compare(AuthStore.idToken, "tok-1")
        compare(AuthStore.tenantId, "t1")
        compare(AuthStore.role, "owner")
    }

    function test_updateProfile_fields_survive_a_simulated_relaunch_too() {
        AuthStore.applyAuth({ uid: "u1", email: "a@example.com", idToken: "tok-1" })
        AuthStore.updateProfile({ phone: "555-1234", city: "Bengaluru", country: "IN" })

        AuthStore.loadSession()

        compare(AuthStore.phone, "555-1234")
        compare(AuthStore.city, "Bengaluru")
        compare(AuthStore.country, "IN")
    }

    function test_signOut_pattern_persists_a_blanked_session_not_the_stale_one() {
        // The exact sequence AuthService.signOut() runs: clear() then
        // saveSession() -- confirms sign-out actually erases the PERSISTED
        // session, not just the in-memory one (a stale persisted token would
        // silently "un-sign-out" the user on the next launch otherwise).
        AuthStore.applyAuth({ uid: "u1", email: "a@example.com", idToken: "tok-1" })
        compare(AuthStore.isAuthenticated, true)

        AuthStore.clear()
        AuthStore.saveSession()

        AuthStore.loadSession()
        compare(AuthStore.isAuthenticated, false,
                "a signed-out session must not silently come back authenticated after relaunch")
        compare(AuthStore.idToken, "")
    }

    function test_loadSession_with_no_persisted_data_starts_unauthenticated() {
        AuthStore.loadSession()

        compare(AuthStore.isAuthenticated, false)
        compare(AuthStore.isInitialized, true)
    }
}
