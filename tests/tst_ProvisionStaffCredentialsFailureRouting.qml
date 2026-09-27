import QtQuick
import QtTest
import "../qml/model"

// Bug: "add a new staff member with a role (staff/manager/admin) and 'Create
// app login' ticked -> Team Members still only shows Owner, even after
// refresh." Root cause: AuthService.provisionStaffCredentials() is always
// invoked ASYNCHRONOUSLY from Main.qml's onStaffAdded handler, fired well
// after AddStaffDialog has already closed -- but every failure branch inside
// it called authFailed(...), a signal Main.qml only ever surfaces through
// inviteMemberDlg/forgotPasswordDlg (see the AuthService Connections block).
// Neither dialog is open during this flow, so every failure was completely
// silent: the staff roster entry (StaffStore.addStaff) still saved, but the
// person never actually got a tenants/{tenantId}/members doc -- the thing
// the Team Members dialog reads -- and nothing ever told the user why.
//
// Fix: every failure branch in provisionStaffCredentials now emits
// memberOperationFailed instead, which Main.qml's onMemberOperationFailed
// falls back to a Toast for when neither dialog is open (see
// tst_MemberOperationFailedFallback.qml for that half of the fix, modeled
// separately since Main.qml can't load under qmltestrunner).
//
// These ARE real singleton calls (not a hand-modeled simulation): every case
// below deliberately stays on the synchronous side of provisionStaffCredentials
// -- either an early guard, or (test_networkFailure_*) Gateway.provisionMember's
// own synchronous no-XHR guards (provisioningAvailable === false, and
// AuthStore.idToken empty) -- so nothing here ever opens a real network
// connection. See docs/superpowers/test-plans/2026-09-27-team-members-not-visible.md
// for why the actual XHR success/conflict branch is out of scope (same
// documented gap as tst_Gateway.qml's _send/_sendBatch).
//
// NOT RUN IN THIS SANDBOX -- no Qt/qmltestrunner toolchain available (project
// convention, see CHECKPOINT.md). Written to convention and manually
// reviewed; needs a local `qmltestrunner` pass / CI's qml-tests job before
// merge (same status as tst_Gateway.qml, tst_AuthStore.qml).
TestCase {
    name: "ProvisionStaffCredentialsFailureRouting"

    SignalSpy { id: failedSpy; target: AuthService; signalName: "memberOperationFailed" }
    SignalSpy { id: succeededSpy; target: AuthService; signalName: "memberOperationSucceeded" }
    SignalSpy { id: authFailedSpy; target: AuthService; signalName: "authFailed" }

    function init() {
        // Full reset (memory + persisted file) -- see tst_AuthStore.qml's
        // cleanupTestCase for why the on-disk copy matters: every store
        // shares one Settings file under qmltestrunner, and referencing
        // AuthService anywhere triggers its lazy init() -> loadSession(),
        // which would silently overwrite an in-memory-only reset.
        AuthStore.clear()
        AuthStore.saveSession()
        Gateway.provisioningAvailable = false
        failedSpy.clear()
        succeededSpy.clear()
        authFailedSpy.clear()
    }

    function cleanup() {
        AuthStore.clear()
        AuthStore.saveSession()
        Gateway.provisioningAvailable = false
    }

    // Fills in every guard EXCEPT the one under test, so each case proves
    // that specific guard -- not some other one -- caused the result.
    function _validOwnerState() {
        AuthStore.isAuthenticated = true
        AuthStore.uid = "owner-uid-1"
        AuthStore.role = "owner"       // canInviteMembers === true
        AuthStore.tenantId = "tenant-1"
    }

    // ── Early guards (all fire before Gateway is ever touched) ──

    function test_notAuthenticated_emits_memberOperationFailed_not_authFailed() {
        _validOwnerState()
        AuthStore.isAuthenticated = false
        AuthService.provisionStaffCredentials("Alex", "alex@example.com", "password1", "", "Sales", "staff", "STF-1")
        compare(failedSpy.count, 1, "memberOperationFailed should fire")
        compare(authFailedSpy.count, 0, "authFailed must NOT fire -- nothing surfaces it for this flow")
        compare(failedSpy.signalArguments[0][0], "Not authenticated")
    }

    function test_missingPermission_emits_memberOperationFailed_not_authFailed() {
        _validOwnerState()
        AuthStore.role = "staff"       // canInviteMembers === false
        AuthService.provisionStaffCredentials("Alex", "alex@example.com", "password1", "", "Sales", "staff", "STF-1")
        compare(failedSpy.count, 1)
        compare(authFailedSpy.count, 0)
        compare(failedSpy.signalArguments[0][0], "Only owner/admin can create staff login credentials")
    }

    function test_missingTenant_emits_memberOperationFailed_not_authFailed() {
        _validOwnerState()
        AuthStore.tenantId = ""
        AuthService.provisionStaffCredentials("Alex", "alex@example.com", "password1", "", "Sales", "staff", "STF-1")
        compare(failedSpy.count, 1)
        compare(authFailedSpy.count, 0)
        compare(failedSpy.signalArguments[0][0], "Tenant context missing")
    }

    function test_invalidEmail_emits_memberOperationFailed_not_authFailed() {
        _validOwnerState()
        AuthService.provisionStaffCredentials("Alex", "not-an-email", "password1", "", "Sales", "staff", "STF-1")
        compare(failedSpy.count, 1)
        compare(authFailedSpy.count, 0)
        compare(failedSpy.signalArguments[0][0], "Valid staff email is required")
    }

    function test_emptyEmail_emits_memberOperationFailed_not_authFailed() {
        _validOwnerState()
        AuthService.provisionStaffCredentials("Alex", "", "password1", "", "Sales", "staff", "STF-1")
        compare(failedSpy.count, 1)
        compare(authFailedSpy.count, 0)
    }

    function test_shortPassword_emits_memberOperationFailed_not_authFailed() {
        _validOwnerState()
        AuthService.provisionStaffCredentials("Alex", "alex@example.com", "abc12", "", "Sales", "staff", "STF-1")
        compare(failedSpy.count, 1)
        compare(authFailedSpy.count, 0)
        compare(failedSpy.signalArguments[0][0], "Staff password must be at least 6 characters")
    }

    // Role edge cases: manager and admin must pass the same guards as staff
    // (this function's OWN guards don't gate on role value -- Gateway.provisionMember's
    // canAssignRole does, server-side, out of scope here). Proves the fix
    // isn't accidentally staff-role-specific ("staff or any role" in the bug report).
    function test_managerRole_reachesGatewayGuard_not_authFailed() {
        _validOwnerState()
        Gateway.provisioningAvailable = true
        AuthStore.idToken = "" // keeps Gateway.provisionMember's own guard synchronous, no XHR
        AuthService.provisionStaffCredentials("Sam", "sam@example.com", "password1", "", "Ops", "manager", "STF-2")
        compare(failedSpy.count, 1)
        compare(authFailedSpy.count, 0)
    }

    function test_adminRole_reachesGatewayGuard_not_authFailed() {
        _validOwnerState()
        Gateway.provisioningAvailable = true
        AuthStore.idToken = ""
        AuthService.provisionStaffCredentials("Jo", "jo@example.com", "password1", "", "Ops", "admin", "STF-3")
        compare(failedSpy.count, 1)
        compare(authFailedSpy.count, 0)
    }

    // ── The actual bug's smoking-gun line: Gateway.provisionMember's own
    // network-failure branch, hit here via its synchronous not-signed-in
    // guard (no XHR -- see file header) ──

    function test_networkFailure_notSignedIn_emits_memberOperationFailed_not_authFailed() {
        _validOwnerState()
        Gateway.provisioningAvailable = true   // so provisionMember doesn't short-circuit as "unavailable"
        AuthStore.idToken = ""                 // Gateway.provisionMember's own guard: synchronous, no XHR
        AuthService.provisionStaffCredentials("Alex", "alex@example.com", "password1", "", "Sales", "staff", "STF-1")
        compare(failedSpy.count, 1, "memberOperationFailed should fire")
        compare(authFailedSpy.count, 0, "authFailed must NOT fire -- this is exactly the line that was silent")
        compare(failedSpy.signalArguments[0][0], "Failed to create staff credentials: you're not signed in.")
    }

    // ── Regression guard: the pre-Blaze "provisioning unavailable" branch
    // is a deliberate SOFT SUCCESS (staff record already saved; login access
    // just isn't deployed yet) and must stay that way -- this fix only
    // touches the genuine-failure branch below it. ──

    function test_provisioningUnavailable_staysASoftSuccess() {
        _validOwnerState()
        // Gateway.provisioningAvailable is false by default (see init()) --
        // this is the pre-Blaze / not-yet-deployed state.
        AuthService.provisionStaffCredentials("Alex", "alex@example.com", "password1", "", "Sales", "staff", "STF-1")
        compare(succeededSpy.count, 1, "provisioning-unavailable must still be a soft success, not a failure")
        compare(failedSpy.count, 0, "must NOT regress into a failure")
        compare(authFailedSpy.count, 0)
    }
}
