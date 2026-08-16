import QtQuick
import QtTest
import "../qml/model"

// Regression coverage for the concurrent-reset race Taher found and fixed
// 2026-08-12 (commits e512c3f, 2c23e16): TransactionStore.Component.
// onCompleted and Main.qml's onTenantContextReady BOTH call _resetAndFetch()
// on a cold start (Component.onCompleted's AuthStore.tenantId.length > 0
// guard turned out NOT to reliably prevent this on-device -- tenantId CAN
// already be populated by the time this singleton is created, so both
// triggers fire). Since both calls are async, whichever's page-1 request
// lands first sets loadingMore = true and starts accumulating pages; the
// SECOND _resetAndFetch() call used to run anyway, wiping `entries` back to
// [] and resetting `_cursor` out from under the first, in-flight fetch --
// whose eventual page-1 response then concatenated onto the wiped array,
// and whose _cursor got clobbered, corrupting the rest of that pagination
// chain. Symptom: TransactionStore.hasMore could end up false with `entries`
// still incomplete, silently defeating the DataModel._tryAdjustOrder guard
// from Skill 38 (no "still syncing" message, but the ledger total was still
// wrong) -- and, independent of that guard, Orders/Inventory screens simply
// showed stale or partial data until entries eventually finished settling.
//
// Fix: _resetAndFetch() now starts with `if (loadingMore) return` -- a
// second reset call arriving while a fetch is already in flight is a no-op
// instead of wiping state out from under it. Same guard applied to every
// other paginated store (InventoryStore, OrdersStore, StaffStore,
// StockBatchStore, SupplierStore) -- see SKILLS Skill 39 for the full sweep,
// including which stores DON'T need this and why.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
TestCase {
    name: "TransactionStore_resetGuard"

    function init() {
        TransactionStore.loadingMore = false
        TransactionStore.hasMore = true
        TransactionStore.entries = []
        TransactionStore._cursor = null
        // test_resetAndFetch_proceeds_normally_when_nothing_is_in_flight
        // deliberately lets _resetAndFetch() run all the way through to
        // _fetchFromFirebase() -- empty idToken is the same no-real-network
        // safety pattern tst_Gateway.qml/tst_OrdersStore_applyAdjustment.qml
        // already rely on elsewhere in this suite.
        AuthStore.idToken = ""
    }

    function cleanup() {
        // The second test below lets a real (fast-failing, no idToken)
        // fetch attempt run, which can schedule a retry -- don't let it
        // survive into another test file's run.
        if (TransactionStore._retryTimer) TransactionStore._retryTimer.stop()
    }

    function test_resetAndFetch_is_a_no_op_while_a_fetch_is_already_in_flight() {
        // Simulates the exact race: an earlier _resetAndFetch() call has
        // already started a fetch (loadingMore true) and has SOME state
        // accumulated from an in-progress page.
        TransactionStore.entries = [{ txId: "tx-1", orderId: "ORD-1" }]
        TransactionStore._cursor = "some-in-flight-cursor"
        TransactionStore.loadingMore = true

        TransactionStore._resetAndFetch()

        compare(TransactionStore.entries.length, 1,
                "a second, overlapping reset must not wipe entries the first fetch is still building on")
        compare(TransactionStore._cursor, "some-in-flight-cursor",
                "must not reset the cursor out from under a fetch that's still using it")
    }

    function test_resetAndFetch_proceeds_normally_when_nothing_is_in_flight() {
        TransactionStore.entries = [{ txId: "tx-stale", orderId: "ORD-OLD" }]
        TransactionStore.hasMore = false
        TransactionStore.loadingMore = false

        TransactionStore._resetAndFetch()

        // _resetAndFetch clears synchronously before handing off to
        // _fetchFromFirebase (which then sets loadingMore = true) -- confirm
        // the synchronous part of a legitimate reset still runs exactly as
        // before this fix.
        compare(TransactionStore.entries.length, 0,
                "a genuinely fresh reset (nothing in flight) must still clear stale data")
        compare(TransactionStore.hasMore, true, "must reset hasMore so callers correctly wait again")
    }
}
