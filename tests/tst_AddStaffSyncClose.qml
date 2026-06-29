import QtQuick
import QtTest

// Reproduces: after pressing Save in AddStaffDialog with "Create app login"
// ticked, the sheet stays open + busy even though the save succeeded.
//
// Root cause (AddStaffDialog.trySubmit + the result Connections):
//   The result listener is gated `enabled: _provisioning`. The OLD code emitted
//   staffCreated(payload) FIRST, then set _provisioning = true. But provisioning
//   resolves SYNCHRONOUSLY in the current pre-Blaze build (Gateway
//   provisioningAvailable === false → callback fires inline → AuthService emits
//   memberOperationSucceeded DURING the staffCreated() emit). At that instant
//   _provisioning was still false, so the listener was disabled and the close()
//   never ran. The fix arms _provisioning = true BEFORE emitting.
//
// This models that exact ordering with a tiny signal bus whose delivery is
// gated by an `armed` flag, plus a synchronous provider that "emits success"
// the moment staffCreated runs. Pure logic — the page QML needs the full Felgo
// App context and can't load under qmltestrunner.
TestCase {
    name: "AddStaffSyncClose"

    // ── A minimal model of the dialog + its gated result listener. ──
    function makeDialog(emitOrder) {
        return {
            armed: false,        // mirrors `_provisioning` (Connections.enabled)
            busy: false,
            closed: false,
            error: "",

            // The result listener — only acts while armed (enabled: _provisioning).
            onSuccess: function() {
                if (!this.armed) return    // disabled → signal dropped
                this.armed = false
                this.busy = false
                this.closed = true
            },
            onFailure: function(reason) {
                if (!this.armed) return
                this.armed = false
                this.busy = false
                this.error = reason
            },

            // Stand-in for the synchronous provision chain: emits success
            // immediately (pre-Blaze: provisioning-unavailable → success notice).
            _emitSyncSuccess: function() { this.onSuccess() },

            trySubmit: function() {
                if (emitOrder === "fixed") {
                    // FIX: arm BEFORE emitting.
                    this.armed = true
                    this.busy = true
                    this._emitSyncSuccess()   // staffCreated() → sync success
                } else {
                    // OLD (buggy): emit first, arm after.
                    this._emitSyncSuccess()   // staffCreated() → sync success (dropped)
                    this.armed = true
                    this.busy = true
                }
            }
        }
    }

    // ── Bug: the OLD ordering leaves the sheet stuck open + busy ──
    function test_old_ordering_misses_sync_success() {
        var dlg = makeDialog("buggy")
        dlg.trySubmit()
        verify(!dlg.closed, "BUG: sheet never closes — sync success was dropped while disabled")
        verify(dlg.busy,    "BUG: sheet stuck in busy state")
    }

    // ── Fix: arming before the emit catches the synchronous success ──
    function test_fixed_ordering_closes_on_sync_success() {
        var dlg = makeDialog("fixed")
        dlg.trySubmit()
        verify(dlg.closed,  "FIX: sheet closes when provisioning resolves synchronously")
        verify(!dlg.busy,   "FIX: busy cleared")
        compare(dlg.error, "", "no error on success")
    }

    // ── A genuinely async result still works with the fixed ordering ──
    // (provider does NOT emit during submit; result arrives later)
    function test_fixed_ordering_async_result() {
        var dlg = makeDialog("fixed")
        dlg._emitSyncSuccess = function() { /* async: nothing fires during submit */ }
        dlg.trySubmit()
        verify(!dlg.closed, "still open, awaiting async result")
        verify(dlg.busy,    "busy while in flight")
        // Result arrives later:
        dlg.onSuccess()
        verify(dlg.closed,  "closes when the async success finally arrives")
        verify(!dlg.busy,   "busy cleared on async success")
    }

    // ── A synchronous FAILURE is shown (not closed) with the fixed ordering ──
    function test_fixed_ordering_sync_failure_shows_error() {
        var dlg = makeDialog("fixed")
        dlg._emitSyncSuccess = function() { this.onFailure("Email already exists") }
        dlg.trySubmit()
        verify(!dlg.closed, "failure keeps the sheet open")
        verify(!dlg.busy,   "busy cleared on failure")
        compare(dlg.error, "Email already exists", "error surfaced to the user")
    }
}
