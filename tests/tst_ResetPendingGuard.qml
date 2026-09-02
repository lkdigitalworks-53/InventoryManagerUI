import QtQuick
import QtTest

// Regression coverage for the "residual trade-off" flagged in SKILLS.md
// Skill 39: `if (loadingMore) return` (the fix for the concurrent-reset race,
// tst_TenantContextRaceGuard.qml) also silently drops a *legitimate* reset
// that happens to arrive mid-fetch -- e.g. a user switching accounts while
// the previous account's own sync is still in flight. The in-flight fetch
// completes with the OLD account's data; the new account's reset request is
// just discarded.
//
// Fix (applied to all 6 paginated stores -- TransactionStore, InventoryStore,
// OrdersStore, StaffStore, StockBatchStore, SupplierStore): `_resetAndFetch()`
// sets `_resetPending = true` instead of silently returning when it's called
// while `loadingMore` is true. The in-flight fetch's callback checks that
// flag the moment it completes: if set, it abandons that now-stale response
// unprocessed and immediately re-runs `_resetAndFetch()` for real, instead of
// applying data for an account the app has already moved on from.
//
// Same technique as tst_TenantContextRaceGuard.qml: a minimal plain-JS object
// mirrors the real singletons' control flow (loadingMore / _resetAndFetch /
// _fetchFromFirebase), with `queue` standing in for in-flight Firestore
// responses so the test can control arrival order deterministically. The real
// singletons can't be exercised this way under qmltestrunner: FirebaseService's
// `function query(...)` is a read-only method on the QML object (confirmed by
// trying to reassign it: "Cannot assign to read-only property"), and any test
// that imports the real qml/model singletons to work around that hits this
// sandbox's separate, pre-existing `AuthStore unavailable` compile issue (see
// tst_TransactionStore_resetGuard.qml/tst_TransactionStore_syncRetry.qml,
// both already "NOT RUN IN THIS SANDBOX" for that same reason). This file
// avoids both: on-device/CI (real Qt 6.8, no compile issue) is still the
// place to confirm the real singletons behave the same way as this model.
TestCase {
    name: "ResetPendingGuard"

    // `variant`: "old" (pre-fix, just `if (loadingMore) return`) | "fixed"
    // (`_resetPending`). `tag` throughout stands in for "which account's
    // data this is" -- the real code has no such field, this is purely a
    // test hook to tell stale/fresh data apart in assertions.
    //
    // Note: `_pendingTag` below exists only here, not in the real stores.
    // That's intentional, not drift -- the real `_resetAndFetch()` doesn't
    // take an account/tenant parameter at all; it re-reads whatever the
    // current auth context is when it actually runs, so it has nothing to
    // remember between the pending reset being requested and being honored.
    // This model needs the tag anyway, purely so assertions can tell which
    // account's data a run ended up with.
    function makeStore(variant) {
        return {
            variant: variant,
            loadingMore: false,
            _resetPending: false,
            _pendingTag: null,
            activeTag: null,
            entries: null,
            requestsSent: 0,

            _fetchFromFirebase: function(queue) {
                if (this.loadingMore) return
                this.loadingMore = true
                this.requestsSent++
                var self = this
                var tagAtCallTime = self.activeTag
                queue.push(function() {
                    self.loadingMore = false
                    if (self.variant === "fixed" && self._resetPending) {
                        // This response is for a tenant the app has already
                        // moved on from -- discard unprocessed, don't let it
                        // touch `entries`, and run the real, current reset.
                        self._resetPending = false
                        var nextTag = self._pendingTag
                        self._pendingTag = null
                        self._resetAndFetch(queue, nextTag)
                        return
                    }
                    self.entries = [tagAtCallTime]
                })
            },

            _resetAndFetch: function(queue, tag) {
                if (this.loadingMore) {
                    if (this.variant === "fixed") {
                        this._resetPending = true
                        this._pendingTag = tag
                    }
                    // "old" variant: silently drop, exactly today's behavior.
                    return
                }
                this.entries = null
                this.activeTag = tag
                this._fetchFromFirebase(queue)
            }
        }
    }

    function test_old_applies_stale_data_when_a_reset_races_an_in_flight_fetch() {
        var queue = []
        var store = makeStore("old")

        store._resetAndFetch(queue, "accountA")     // fires, loadingMore -> true
        store._resetAndFetch(queue, "accountB")     // races it -> silently dropped
        queue.shift()()                              // accountA's response lands

        compare(store.requestsSent, 1, "the accountB reset was dropped, never even sent")
        compare(store.entries, ["accountA"],
                "BUG (pre-fix, documented for contrast): store ends up showing the " +
                "OLD account's data even though a switch to accountB was requested")
    }

    function test_fixed_defers_the_racing_reset_instead_of_dropping_it() {
        var queue = []
        var store = makeStore("fixed")

        store._resetAndFetch(queue, "accountA")
        store._resetAndFetch(queue, "accountB")     // races it -> deferred, not dropped

        compare(store._resetPending, true, "the racing reset must be remembered, not discarded")
        compare(store._pendingTag, "accountB")
        compare(store.entries, null, "must not touch entries until the pending reset actually runs")
        compare(store.requestsSent, 1, "no wasted request yet -- only the original accountA fetch is in flight")
    }

    function test_fixed_ends_up_with_the_new_accounts_data_not_the_stale_fetch() {
        var queue = []
        var store = makeStore("fixed")

        store._resetAndFetch(queue, "accountA")     // request #1, in flight
        store._resetAndFetch(queue, "accountB")     // deferred (see test above)
        queue.shift()()                              // accountA's stale response lands ->
                                                       // discarded, accountB's reset fires for real
        compare(store.requestsSent, 2, "exactly one real request for accountB, not zero, not a pile-up")
        compare(store.loadingMore, true, "accountB's own fetch is now the one in flight")
        queue.shift()()                              // accountB's response lands

        compare(store.entries, ["accountB"],
                "FIX: store ends up with the account the app actually switched to")
        compare(store._resetPending, false)
    }

    function test_fixed_coalesces_multiple_resets_arriving_while_one_fetch_is_in_flight() {
        // Rapid A (in flight) -> switch to B -> switch to C, all before A's
        // response lands. Only ONE extra request should ever fire (for C,
        // the last requested state) -- not one per switch.
        var queue = []
        var store = makeStore("fixed")

        store._resetAndFetch(queue, "accountA")
        store._resetAndFetch(queue, "accountB")
        store._resetAndFetch(queue, "accountC")
        compare(store._pendingTag, "accountC", "the LATEST pending reset wins, not the first")
        compare(store.requestsSent, 1, "still only the original in-flight request -- no pile-up from coalescing")

        queue.shift()()                              // accountA's stale response -> triggers accountC's fetch
        compare(store.requestsSent, 2)
        queue.shift()()                              // accountC's response lands

        compare(store.entries, ["accountC"], "ends up on the LAST requested account, B was correctly skipped entirely")
    }

    function test_fixed_proceeds_normally_when_nothing_is_in_flight() {
        // Baseline: the non-racing path is unchanged by this fix.
        var queue = []
        var store = makeStore("fixed")

        store._resetAndFetch(queue, "accountA")
        compare(store.loadingMore, true)
        compare(store._resetPending, false)
        queue.shift()()

        compare(store.entries, ["accountA"])
        compare(store.requestsSent, 1)
    }
}
