import QtQuick
import QtTest
import "../qml/model"

// Regression coverage for the retry-with-backoff added 2026-08-11 alongside
// the ledger-sync guard (see tst_DataModel_adjustOrderSyncGuard.qml and
// docs/superpowers/specs/2026-08-11-ledger-sync-race-CHECKPOINT.md).
//
// Without this retry, a single failed sync page left TransactionStore.
// hasMore stuck at true FOREVER (no code anywhere set it back to false on
// failure) — meaning DataModel._tryAdjustOrder's new guard would
// permanently refuse every completed-order return after one transient
// network blip, until the app was restarted. This test covers the backoff
// math itself, which is a pure function of _retryAttempt and needs no
// network. It does NOT cover _fetchFromFirebase's actual success/failure
// branches, which need a real (or mocked) FirebaseService response this
// test suite has no established pattern for — that needs on-device
// verification: kill the network mid-sync and confirm the console log
// keeps retrying with growing delays instead of giving up.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
TestCase {
    name: "TransactionStore_syncRetry"

    function init() {
        TransactionStore._retryAttempt = 0
        // A stale timer from an earlier test (if any) would carry over its
        // interval otherwise -- force _scheduleRetry to size it fresh.
        if (TransactionStore._retryTimer) TransactionStore._retryTimer.stop()
    }

    function test_first_retry_uses_the_base_delay() {
        TransactionStore._scheduleRetry()
        compare(TransactionStore._retryTimer.interval, 3000)
        compare(TransactionStore._retryAttempt, 1, "attempt counter must advance so the NEXT call backs off further")
    }

    function test_backs_off_exponentially_on_repeated_failures() {
        TransactionStore._scheduleRetry() // attempt 0 -> interval 3000,  attempt becomes 1
        compare(TransactionStore._retryTimer.interval, 3000)
        TransactionStore._scheduleRetry() // attempt 1 -> interval 6000,  attempt becomes 2
        compare(TransactionStore._retryTimer.interval, 6000)
        TransactionStore._scheduleRetry() // attempt 2 -> interval 12000, attempt becomes 3
        compare(TransactionStore._retryTimer.interval, 12000)
        TransactionStore._scheduleRetry() // attempt 3 -> interval 24000, attempt becomes 4
        compare(TransactionStore._retryTimer.interval, 24000)
    }

    function test_backoff_is_capped_so_an_offline_device_does_not_hammer_the_network() {
        for (var i = 0; i < 10; ++i) TransactionStore._scheduleRetry()
        verify(TransactionStore._retryTimer.interval <= 30000,
               "must never exceed the 30s cap no matter how many consecutive failures")
    }

    function test_retry_timer_is_single_shot_not_repeating() {
        TransactionStore._scheduleRetry()
        compare(TransactionStore._retryTimer.repeat, false,
                "each retry must be scheduled explicitly with its own backoff, not left on a fixed repeat interval")
    }
}
