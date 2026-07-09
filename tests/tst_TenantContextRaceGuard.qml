import QtQuick
import QtTest

// Reproduces: on cold app open (persisted session), OrdersStore/InventoryStore/
// StaffStore/TransactionStore/SupplierStore/StockBatchStore randomly come back
// empty/403, fixed only by logout+login. Not present on main; introduced by
// Phase 1 pagination (feature/paginated-reads-phase1).
//
// Root cause (see docs/superpowers/specs/2026-07-06-scale-reads-writes-analytics-
// CHECKPOINT.md, 2026-07-09 session): every store's Component.onCompleted fires an
// unconditional first fetch. DashboardPage's eager bindings (OrdersStore.revision /
// InventoryStore.revision / ActivityLog.revision / StaffStore KPI) create these
// singletons — and thus their first fetch — before AuthService's
// Component.onCompleted (AuthStore.loadSession()) is guaranteed to have run, so
// AuthStore.tenantId is still "" and FirebaseService._resolvePath() builds an
// UNSCOPED path -> Firestore rules 403. Main.qml's onTenantContextReady already
// re-syncs every store once tenant context resolves — that's the existing safety
// net — but Phase 1's `loadingMore` single-flight guard (needed for the recursive
// page loop) can silently DROP that resync if it lands while the first, doomed
// request is still in flight. Outcome depends on network timing -> "random".
//
// This models the exact timing with a minimal object (same technique as
// tst_AddStaffSyncClose.qml) — the real singletons need the full Felgo App
// context and can't load under qmltestrunner. `queue` stands in for in-flight
// network responses so the test can control arrival order deterministically.
TestCase {
    name: "TenantContextRaceGuard"

    function makeStore(mode, tenantIdRef) {
        return {
            mode: mode, // "old" (current) | "fixed" (root-cause fix)
            loadingMore: false,
            data: null,
            requestsSent: 0,

            // Stand-in for FirebaseService.query(): path-scoping is resolved AT
            // CALL TIME (mirrors _resolvePath reading AuthStore.tenantId
            // synchronously), response delivery is deferred into `queue`.
            _fetchFromFirebase: function(queue) {
                if (this.loadingMore) return
                this.loadingMore = true
                this.requestsSent++
                var scopedAtCallTime = tenantIdRef.value.length > 0
                var self = this
                queue.push(function() {
                    self.loadingMore = false
                    if (!scopedAtCallTime) { self.data = null; return } // 403
                    self.data = "synced:" + tenantIdRef.value
                })
            },

            _resetAndFetch: function(queue) {
                this.data = null
                this._fetchFromFirebase(queue)
            },

            onCompleted: function(queue) {
                if (this.mode === "fixed" && tenantIdRef.value.length === 0)
                    return // root-cause fix: defer to onTenantContextReady's resync
                this._resetAndFetch(queue)
            },

            // Fired by Main.qml's onTenantContextReady handler.
            syncFromFirebase: function(queue) {
                this._resetAndFetch(queue)
            }
        }
    }

    function test_old_drops_retry_when_it_races_the_first_request() {
        var tenantId = { value: "" }
        var queue = []
        var store = makeStore("old", tenantId)

        store.onCompleted(queue)          // fires unscoped request #1
        tenantId.value = "tenant-1"       // tenant context resolves...
        store.syncFromFirebase(queue)     // ...while #1 still in flight -> guard drops this
        queue.shift()()                   // #1's response arrives (403)

        compare(store.requestsSent, 1, "only the doomed first request was ever sent")
        verify(store.data === null, "BUG reproduced: store left permanently empty")
    }

    function test_old_self_heals_when_it_does_not_race() {
        // Same buggy code, different timing -> proves the reported randomness is
        // timing-dependent, not two different code paths.
        var tenantId = { value: "" }
        var queue = []
        var store = makeStore("old", tenantId)

        store.onCompleted(queue)
        queue.shift()()                   // #1 completes (403) BEFORE tenant context ready
        tenantId.value = "tenant-1"
        store.syncFromFirebase(queue)     // loadingMore already false -> fires cleanly
        queue.shift()()

        compare(store.requestsSent, 2)
        compare(store.data, "synced:tenant-1")
    }

    function test_fixed_never_drops_data_regardless_of_race_timing() {
        var tenantId = { value: "" }
        var queue = []
        var store = makeStore("fixed", tenantId)

        store.onCompleted(queue)          // tenantId empty -> does not fetch at all
        tenantId.value = "tenant-1"
        store.syncFromFirebase(queue)     // first-ever fetch, correctly scoped
        compare(queue.length, 1, "exactly one request in flight, nothing wasted")
        queue.shift()()

        compare(store.requestsSent, 1, "no doomed first request")
        compare(store.data, "synced:tenant-1", "FIX: deterministically populated")
    }

    function test_fixed_still_fetches_immediately_when_already_authenticated() {
        // Warm/lazy creation (tenant context already resolved) must be unchanged.
        var tenantId = { value: "tenant-1" }
        var queue = []
        var store = makeStore("fixed", tenantId)

        store.onCompleted(queue)
        compare(queue.length, 1, "fetch fires immediately, same as today")
        queue.shift()()

        compare(store.data, "synced:tenant-1", "no regression for the warm-creation case")
    }
}
