import QtQuick
import QtTest

// Models the OTHER half of the "Team Members not visible" fix: Main.qml's
// AuthService Connections block, function onMemberOperationFailed(reason).
//
// Old behavior: only set memberErrorMessage (silently, bound to
// memberMgmtDlg.errorMessage) and, if inviteMemberDlg happened to be visible,
// also set its errorMessage. If NEITHER dialog was open -- exactly the case
// when AuthService.provisionStaffCredentials fails, since it always runs
// asynchronously after AddStaffDialog has already closed -- the failure had
// nowhere to go. No toast, no popup, nothing.
//
// Fix: when neither dialog is open, fall back to the same successMessage ->
// Toast bridge Main.qml already uses for other background notices (e.g.
// "Export failed"), so the failure is never silent.
//
// This is a pure-logic model, not the real qml/Main.qml: Main.qml is a
// top-level ApplicationWindow that needs the full Felgo App context to
// instantiate (same reason tst_AddStaffSyncClose.qml models AddStaffDialog's
// submit-ordering fix in pure JS instead of loading the real page). The
// model below mirrors the real handler's exact branching (see qml/Main.qml's
// onMemberOperationFailed) line for line -- if that handler's branching
// changes, this model must change with it.
//
// NOT RUN IN THIS SANDBOX -- no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local
// `qmltestrunner` pass / CI's qml-tests job before merge.
TestCase {
    name: "MemberOperationFailedFallback"

    // Mirrors just enough of Main.qml's relevant state to exercise the
    // branching: two dialogs' visible+errorMessage, plus the
    // successMessage/toastCount bridge (Toast.show() is called once per
    // successMessage change in the real app; toastCount stands in for that).
    function makeApp(inviteVisible, memberMgmtVisible) {
        return {
            inviteMemberDlg: { visible: inviteVisible, errorMessage: "" },
            memberMgmtDlg: { visible: memberMgmtVisible },
            memberErrorMessage: "",
            successMessage: "",
            toastCount: 0,

            // Exact mirror of qml/Main.qml's onMemberOperationFailed.
            onMemberOperationFailed: function(reason) {
                var msg = reason || "Operation failed"
                this.memberErrorMessage = msg
                if (this.inviteMemberDlg.visible) {
                    this.inviteMemberDlg.errorMessage = msg
                } else if (!this.memberMgmtDlg.visible) {
                    this.successMessage = msg
                    this.toastCount++
                }
            }
        }
    }

    // ── Bug reproduction: neither dialog open -- the exact AddStaffDialog
    // credential-provisioning scenario -- used to leave the user with
    // nothing on screen at all. ──
    function test_neitherDialogOpen_fallsBackToToast() {
        var app = makeApp(false, false)
        app.onMemberOperationFailed("Failed to create staff credentials: you're not signed in.")
        compare(app.toastCount, 1, "FIX: the failure must reach the user via Toast")
        compare(app.successMessage, "Failed to create staff credentials: you're not signed in.")
        compare(app.memberErrorMessage, "Failed to create staff credentials: you're not signed in.")
    }

    // ── Existing, still-correct behavior: InviteMemberDialog open ──
    function test_inviteDialogOpen_showsInline_noToast() {
        var app = makeApp(true, false)
        app.onMemberOperationFailed("Target user UID is required")
        compare(app.inviteMemberDlg.errorMessage, "Target user UID is required")
        compare(app.toastCount, 0, "dialog already shows it inline -- no duplicate toast")
    }

    // ── Existing, still-correct behavior: Team Members dialog open (e.g. a
    // role-update or remove-member failure while the user is looking at the
    // list) -- memberErrorMessage alone already feeds its bound errorMessage
    // property in the real app, so no toast fallback should fire either. ──
    function test_memberMgmtDialogOpen_showsInline_noToast() {
        var app = makeApp(false, true)
        app.onMemberOperationFailed("Only owner/admin can update roles")
        compare(app.memberErrorMessage, "Only owner/admin can update roles")
        compare(app.toastCount, 0, "memberMgmtDlg already shows it inline -- no duplicate toast")
    }

    // ── Edge case: both happen to be visible (shouldn't normally occur --
    // they're mutually exclusive sheets -- but the invite dialog's own inline
    // error must still win, and there must still be no duplicate toast). ──
    function test_bothDialogsVisible_inviteDialogWinsInline_noToast() {
        var app = makeApp(true, true)
        app.onMemberOperationFailed("Some failure")
        compare(app.inviteMemberDlg.errorMessage, "Some failure")
        compare(app.toastCount, 0)
    }

    // ── Edge case: empty/undefined reason still produces a visible fallback
    // message rather than a blank toast. ──
    function test_emptyReason_fallsBackToGenericMessage() {
        var app = makeApp(false, false)
        app.onMemberOperationFailed("")
        compare(app.successMessage, "Operation failed")
        compare(app.toastCount, 1)
    }

    // ── Multiple failures in a row (e.g. two background provisioning calls
    // resolving in sequence) each toast independently -- no swallowing. ──
    function test_multipleFailuresInSequence_eachToasts() {
        var app = makeApp(false, false)
        app.onMemberOperationFailed("First failure")
        app.onMemberOperationFailed("Second failure")
        compare(app.toastCount, 2)
        compare(app.successMessage, "Second failure")
    }
}
