import QtQuick
import QtTest

// Regression test for ASYNC-REENTRANCY-BUGS.md C-2: NewOrderDialog.trySubmit()
// had no `busy` guard of any kind and called dlg.close() on the line right
// after emitting the fire-and-forget `orderCreated` signal — identical shape
// to the original order-completion double-submit bug (SKILLS Skill 61),
// reached via order CREATION instead of order approval. A plain double-tap
// on "Place order" (no slow connection or special reopen steps needed) mints
// two separate orders via OrdersStore.nextOrderId's real, server-coordinated
// round trip, and — if autoApproveEnabled is on — double-deducts stock too,
// since both duplicate orders get auto-completed.
//
// Fix: `if (busy) return` as literally the first line of trySubmit(), `busy =
// true` set synchronously before the orderCreated emit, and a `Connections {
// target: logic }` block that waits for a real `logic.orderAdded` (success)
// or the new dedicated `logic.orderCreationFailed` (failure) signal before
// clearing busy and closing — mirroring OrderDetailDialog's existing
// Connections-on-logic pattern from PR #70.
//
// NewOrderDialog.qml itself can't be instantiated here: it imports "../model"
// -> Constants.qml -> `import Felgo`, and no CI job points qmltestrunner at
// Felgo-dependent files (see test/felgo-dependent/README.md — confirmed by an
// actual CI failure, not a guess). This test models trySubmit()'s guarded
// control flow with a plain JS-object stand-in instead, same technique as
// tests/tst_AddStaffSyncClose.qml (the existing precedent for this exact
// constraint). Real on-device coverage of the actual dialog is in the
// accompanying test plan.
TestCase {
    name: "NewOrderDialogSubmitGuard"

    // ── A minimal model of the dialog's new guarded trySubmit(). ──
    // `mintCalls` counts how many times the stand-in for
    // logic.addOrder(...) -> OrdersStore.nextOrderId's real network mint
    // would have actually fired — the number that matters for the bug
    // (does a double-tap mint one order or two), not just the dialog's own
    // busy flag.
    function makeDialog() {
        return {
            busy: false,
            closed: false,
            errorText: "",
            mintCalls: 0,

            // Stand-in for the fire-and-forget `orderCreated(...)` emit ->
            // Main.qml -> logic.addOrder(...) -> DataModel.onAddOrder ->
            // OrdersStore.addOrder -> nextOrderId's real round trip. Doesn't
            // resolve on its own — the test drives resolution explicitly via
            // onOrderAdded/onOrderCreationFailed, same as production where
            // resolution arrives asynchronously off a real network response.
            _emitOrderCreated: function() { this.mintCalls++ },

            trySubmit: function() {
                // The actual fix: must be the very first line.
                if (this.busy) return
                // (Field validation lives here in the real dialog; omitted —
                // it runs and returns before this point in every case this
                // test cares about, exactly like the real trySubmit().)
                this.busy = true
                this._emitOrderCreated()
            },

            // Mirrors the Connections block's two handlers.
            onOrderAdded: function() {
                if (!this.busy) return
                this.busy = false
                this.closed = true
            },
            onOrderCreationFailed: function(message) {
                if (!this.busy) return
                this.busy = false
                this.errorText = message || "Could not create order — try again"
            },

            // Mirrors onOpened()'s defensive reset.
            reopen: function() {
                this.busy = false
                this.closed = false
                this.errorText = ""
            }
        }
    }

    // ── The actual reported defect, reproduced ──────────────────────────
    function test_double_tap_while_in_flight_mints_only_once() {
        var dlg = makeDialog()
        dlg.trySubmit()
        compare(dlg.mintCalls, 1, "first tap starts exactly one mint attempt")
        verify(dlg.busy, "busy while the mint is still in flight")

        // The second tap, before any result has arrived — the real-world
        // double-tap / slow-connection-retry scenario from the doc.
        dlg.trySubmit()
        compare(dlg.mintCalls, 1,
                "BUG regression: a second tap while busy must NOT start a second mint — " +
                "this is the exact call that used to create a duplicate order")
    }

    function test_third_and_further_taps_also_rejected_while_busy() {
        var dlg = makeDialog()
        dlg.trySubmit()
        dlg.trySubmit()
        dlg.trySubmit()
        dlg.trySubmit()
        compare(dlg.mintCalls, 1, "repeated taps while busy never exceed the first mint")
    }

    // ── Success path ─────────────────────────────────────────────────────
    function test_success_signal_clears_busy_and_closes() {
        var dlg = makeDialog()
        dlg.trySubmit()
        dlg.onOrderAdded("ORD-001")
        verify(!dlg.busy, "busy cleared on success")
        verify(dlg.closed, "sheet closes on success")
        compare(dlg.errorText, "", "no error text on success")
    }

    // ── Failure path — the point of the new dedicated signal ────────────
    function test_failure_signal_clears_busy_shows_error_does_not_close() {
        var dlg = makeDialog()
        dlg.trySubmit()
        dlg.onOrderCreationFailed("Could not add order — try again")
        verify(!dlg.busy, "busy cleared on failure so the user can retry")
        verify(!dlg.closed, "sheet stays open on failure, unlike the success path")
        compare(dlg.errorText, "Could not add order — try again", "failure message surfaced")
    }

    function test_failure_with_no_message_falls_back_to_default_text() {
        var dlg = makeDialog()
        dlg.trySubmit()
        dlg.onOrderCreationFailed("")
        compare(dlg.errorText, "Could not create order — try again",
                "empty/missing message still shows a usable fallback")
    }

    // ── After a real result arrives, a legitimate new submit must work ───
    function test_can_submit_again_after_success() {
        var dlg = makeDialog()
        dlg.trySubmit()
        dlg.onOrderAdded("ORD-001")
        dlg.reopen()
        dlg.trySubmit()
        compare(dlg.mintCalls, 2, "a genuinely new submit after a prior success is not blocked")
    }

    function test_can_retry_after_failure_without_reopening() {
        // Failure doesn't close the sheet, so the user retries in place —
        // must not still be wedged busy=true from the failed attempt.
        var dlg = makeDialog()
        dlg.trySubmit()
        dlg.onOrderCreationFailed("network blip")
        dlg.trySubmit()
        compare(dlg.mintCalls, 2, "retry after a failure starts a genuine second mint")
    }

    // ── Stale/late signal safety ──────────────────────────────────────────
    function test_late_signal_after_already_resolved_is_a_no_op() {
        // Guards against a hypothetical duplicate/late-delivered signal
        // firing again after busy has already been cleared once — must not
        // double-close or throw re-entering an already-settled state.
        var dlg = makeDialog()
        dlg.trySubmit()
        dlg.onOrderAdded("ORD-001")
        verify(dlg.closed, "closed after the first, legitimate signal")

        dlg.closed = false // simulate "reopened since" so a false-positive would be visible
        dlg.onOrderAdded("ORD-001")
        verify(!dlg.closed, "a stale signal arriving while not busy must be ignored")
    }

    // ── Reopen resets stale state (onOpened's defensive busy = false) ────
    function test_reopen_clears_any_stuck_busy_state() {
        var dlg = makeDialog()
        dlg.trySubmit() // never resolved — simulates an abandoned/never-completing attempt
        verify(dlg.busy, "stuck busy from the never-resolved attempt")
        dlg.reopen()
        verify(!dlg.busy, "reopening clears stale busy so the sheet isn't permanently stuck")
    }
}
