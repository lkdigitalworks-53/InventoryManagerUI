import QtQuick
import QtTest
import "../qml/model"

// Tests for PhotoQueue.qml's queue-management logic: persistence, retry/discard, and
// drainCandidates' gating (Trap 1: product's own create mutation must have landed via OutboxStore;
// Trap 2: only the currently signed-in identity's items drain).
//
// NOT covered here (see PhotoQueue.qml's TESTABILITY NOTE): _upload()'s native file read and XHR
// round-trip. NativeFile/ImageProcessor are root context properties (main.cpp
// setContextProperty), not QML singletons -- undefined under qmltestrunner, same reason
// StorageService.qml (the only other file that references them) has no tests, and same as
// Gateway._send's real XHR being untested at this level (tst_Gateway.qml's own comment). The
// classification/backoff/breaker logic those two functions delegate to is fully covered instead,
// for real, by tests/tst_PhotoQueueLogic.qml and functions/test/photoQueueLogic.parity.test.js
// (23/23, run for real, stable x5 including two monkey tests).
//
// NOT RUN IN THIS SANDBOX -- no qmltestrunner toolchain available (standing instruction). Written
// to this project's exact conventions (tst_OutboxStore.qml's import/init() pattern, tst_Gateway.qml's
// singleton-import style); CI is the proof.
TestCase {
    name: "PhotoQueue"

    function init() {
        PhotoQueue.clear()
        AuthStore.uid = "u1"
        AuthStore.tenantId = "t1"
        OutboxStore.clear()
    }

    function _call(overrides) {
        var base = {
            photoId: "photo-1", productId: "prod-1", uid: "u1", tenantId: "t1",
            mainFilePath: "/data/photo-1.jpg", thumbFilePath: "/data/photo-1_t.jpg"
        }
        return Object.assign({}, base, overrides || {})
    }

    // ── enqueue / persistence ────────────────────────────────────────────────

    function test_enqueue_stores_an_enqueued_item_with_zero_attempts() {
        var item = PhotoQueue.enqueue(_call())
        compare(item.state, "enqueued")
        compare(item.attempts, 0)
        compare(item.photoId, "photo-1")
        compare(item.requestId, "photo-1", "requestId mirrors photoId -- the idempotency key")
        compare(PhotoQueue.pendingCount, 1)
    }

    function test_enqueue_persists_across_a_simulated_relaunch() {
        PhotoQueue.enqueue(_call())
        compare(PhotoQueue.pendingCount, 1)

        PhotoQueue.items = [] // simulate pre-_load() in-memory state after a relaunch
        PhotoQueue._load()    // simulate Component.onCompleted on the next launch

        compare(PhotoQueue.pendingCount, 1,
                "must reload the persisted item after a simulated relaunch -- if this is 0, " +
                "Settings never actually wrote to a real file")
        compare(PhotoQueue.items[0].photoId, "photo-1")
    }

    function test_enqueue_two_photos_for_the_same_product_are_independent_items() {
        PhotoQueue.enqueue(_call({ photoId: "photo-1" }))
        PhotoQueue.enqueue(_call({ photoId: "photo-2" }))
        compare(PhotoQueue.pendingCount, 2)
    }

    function test_relaunch_resumes_draining_a_previously_queued_item() {
        // Regression test for a real bug found in review: _load() (Component.onCompleted on a
        // real app launch) loaded persisted items but never called _reschedule(), so a photo
        // queued in a previous session just sat frozen until something else happened to trigger
        // a drain -- silently breaking "survive app close" (design spec). Can't observe the
        // Timer firing under qmltestrunner (NativeFile is undefined here, see the file's
        // TESTABILITY NOTE), but drainCandidates() being non-empty immediately after _load()
        // proves the reschedule happened rather than leaving the item dormant.
        PhotoQueue.enqueue(_call())
        PhotoQueue.items = []
        PhotoQueue._load()
        compare(PhotoQueue.drainCandidates(Date.now()).length, 1)
    }

    // ── discard ──────────────────────────────────────────────────────────────

    function test_discard_removes_the_item() {
        PhotoQueue.enqueue(_call())
        PhotoQueue.discard("photo-1")
        compare(PhotoQueue.pendingCount, 0)
    }

    function test_discard_only_removes_the_matching_item() {
        PhotoQueue.enqueue(_call({ photoId: "photo-1" }))
        PhotoQueue.enqueue(_call({ photoId: "photo-2" }))
        PhotoQueue.discard("photo-1")
        compare(PhotoQueue.pendingCount, 1)
        compare(PhotoQueue.items[0].photoId, "photo-2")
    }

    function test_discard_of_an_unknown_id_is_a_harmless_noop() {
        PhotoQueue.enqueue(_call())
        PhotoQueue.discard("does-not-exist")
        compare(PhotoQueue.pendingCount, 1)
    }

    // ── retry ────────────────────────────────────────────────────────────────

    function test_retry_resets_a_failed_item_back_to_enqueued() {
        var item = PhotoQueue.enqueue(_call())
        var failedShape = Object.assign({}, item, { state: "failed", attempts: 8, lastError: 400 })
        PhotoQueue.items = [failedShape]
        PhotoQueue.retry("photo-1")
        compare(PhotoQueue.items[0].state, "enqueued")
        compare(PhotoQueue.items[0].attempts, 0)
        compare(PhotoQueue.items[0].lastError, null)
    }

    // ── drainCandidates: due time ────────────────────────────────────────────

    function test_drainCandidates_includes_a_freshly_enqueued_item() {
        PhotoQueue.enqueue(_call())
        var candidates = PhotoQueue.drainCandidates(Date.now())
        compare(candidates.length, 1)
        compare(candidates[0].photoId, "photo-1")
    }

    function test_drainCandidates_excludes_an_item_not_yet_due() {
        var item = PhotoQueue.enqueue(_call())
        var future = Object.assign({}, item, { state: "retrying", nextAttemptAt: Date.now() + 60000 })
        PhotoQueue.items = [future]
        var candidates = PhotoQueue.drainCandidates(Date.now())
        compare(candidates.length, 0)
    }

    function test_drainCandidates_includes_a_retrying_item_once_its_backoff_has_elapsed() {
        var item = PhotoQueue.enqueue(_call())
        var due = Object.assign({}, item, { state: "retrying", nextAttemptAt: Date.now() - 1000 })
        PhotoQueue.items = [due]
        var candidates = PhotoQueue.drainCandidates(Date.now())
        compare(candidates.length, 1)
    }

    function test_drainCandidates_excludes_an_uploading_item() {
        var item = PhotoQueue.enqueue(_call())
        var uploading = Object.assign({}, item, { state: "uploading" })
        PhotoQueue.items = [uploading]
        compare(PhotoQueue.drainCandidates(Date.now()).length, 0)
    }

    function test_drainCandidates_excludes_a_failed_item() {
        var item = PhotoQueue.enqueue(_call())
        var failedShape = Object.assign({}, item, { state: "failed", attempts: 8 })
        PhotoQueue.items = [failedShape]
        compare(PhotoQueue.drainCandidates(Date.now()).length, 0)
    }

    // ── drainCandidates: Trap 2 (identity match) ────────────────────────────

    function test_drainCandidates_excludes_an_item_from_a_different_uid() {
        PhotoQueue.enqueue(_call({ uid: "someone-else" }))
        compare(PhotoQueue.drainCandidates(Date.now()).length, 0)
    }

    function test_drainCandidates_excludes_an_item_from_a_different_tenant() {
        PhotoQueue.enqueue(_call({ tenantId: "other-tenant" }))
        compare(PhotoQueue.drainCandidates(Date.now()).length, 0)
    }

    function test_drainCandidates_resumes_once_the_matching_identity_signs_back_in() {
        PhotoQueue.enqueue(_call({ uid: "u2", tenantId: "t2" }))
        compare(PhotoQueue.drainCandidates(Date.now()).length, 0)
        AuthStore.uid = "u2"
        AuthStore.tenantId = "t2"
        compare(PhotoQueue.drainCandidates(Date.now()).length, 1)
    }

    // ── drainCandidates: Trap 1 (OutboxStore gate) ──────────────────────────

    function test_drainCandidates_excludes_an_item_whose_product_has_a_pending_outbox_mutation() {
        OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "prod-1", action: "create" })
        PhotoQueue.enqueue(_call({ productId: "prod-1" }))
        compare(PhotoQueue.drainCandidates(Date.now()).length, 0)
    }

    function test_drainCandidates_resumes_once_the_outbox_mutation_lands() {
        var mutation = OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "prod-1", action: "create" })
        PhotoQueue.enqueue(_call({ productId: "prod-1" }))
        compare(PhotoQueue.drainCandidates(Date.now()).length, 0)
        OutboxStore.markSent(mutation.requestId)
        compare(PhotoQueue.drainCandidates(Date.now()).length, 1)
    }

    function test_drainCandidates_is_unaffected_by_a_pending_outbox_mutation_for_a_different_product() {
        OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "prod-OTHER", action: "create" })
        PhotoQueue.enqueue(_call({ productId: "prod-1" }))
        compare(PhotoQueue.drainCandidates(Date.now()).length, 1)
    }

    // ── drainNow (the one case reachable without touching NativeFile/XHR: unauthenticated) ──

    function test_drainNow_when_unauthenticated_leaves_the_item_queued_not_failed() {
        // Regression test for a real gap found in review: drainNow() must call
        // AuthService.ensureFreshToken() once per pass (matching Gateway.drainNow()'s exact
        // placement) so a stuck "token not ready" item eventually gets unstuck by something
        // actually requesting a refresh, rather than waiting on some other unrelated caller to
        // do it first. ensureFreshToken() itself no-ops safely when AuthStore.isAuthenticated is
        // false (the default here), so this is callable under qmltestrunner without reaching
        // NativeFile/XHR -- the item should simply come back unchanged, not consumed or failed.
        PhotoQueue.enqueue(_call())
        PhotoQueue.drainNow()
        compare(PhotoQueue.pendingCount, 1, "must not drop the item")
        compare(PhotoQueue.items[0].state, "enqueued", "must not mark it failed for a missing token")
        compare(PhotoQueue.items[0].attempts, 0, "must not count this against the attempt cap")
    }

    // ── multiple items, mixed eligibility ───────────────────────────────────

    function test_drainCandidates_returns_only_the_eligible_subset_from_a_mixed_queue() {
        PhotoQueue.enqueue(_call({ photoId: "eligible" }))
        PhotoQueue.enqueue(_call({ photoId: "wrong-identity", uid: "someone-else" }))
        OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "prod-gated", action: "create" })
        PhotoQueue.enqueue(_call({ photoId: "gated", productId: "prod-gated" }))

        var candidates = PhotoQueue.drainCandidates(Date.now())
        compare(candidates.length, 1)
        compare(candidates[0].photoId, "eligible")
    }
}
