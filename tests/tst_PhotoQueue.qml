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
// for real, by tests/tst_PhotoQueueLogic.qml and functions/test/photoQueueLogic.parity.test.js.
// _failUpload() (the failure tail of _upload: discard rule, retry/failed bookkeeping, breaker, signal) is NOT
// behind NativeFile/XHR, so it is covered here (section "_failUpload"). Only the XHR plumbing stays device-only.
//
// NOT RUN IN THIS SANDBOX -- no qmltestrunner toolchain available (standing instruction). Written
// to this project's exact conventions (tst_OutboxStore.qml's import/init() pattern, tst_Gateway.qml's
// singleton-import style); CI is the proof.
TestCase {
    name: "PhotoQueue"

    SignalSpy { id: failSpy; target: PhotoQueue; signalName: "photoUploadFailed" }

    function init() {
        failSpy.clear()
        PhotoQueue.clear()
        AuthStore.idToken = ""
        AuthStore.isAuthenticated = false   // ensureFreshToken() must stay a no-op (no refresh XHR)
        AuthStore.uid = "u1"
        AuthStore.tenantId = "t1"
        OutboxStore.clear()
        // _breaker is singleton state shared by every test file in this qmltestrunner process; a
        // drain that hits the "file unreadable" branch counts a failure and 5 trip it open for 60 s.
        PhotoQueue._breaker = ({ status: "closed", consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000, tripCount: 0 })
    }

    // Never leak a live token into the next test's event-loop turn (PhotoQueue drains on token arrival).
    function cleanup() {
        AuthStore.idToken = ""
        // _failUpload tests drive InventoryStore.hasProduct(): put the shared singleton back to its defaults.
        InventoryStore.products = []
        InventoryStore.hasMore = true
        InventoryStore.loadingMore = false
        InventoryStore._resetPending = false
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

    // Regression (PR #84 device test, 2026-09-28): the one-shot drain timer fired while the item was
    // still gated and never re-armed, so the photo sat "enqueued" (spinner) forever.
    function test_outbox_mutation_landing_rearms_the_drain_timer() {
        var mutation = OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "prod-1", action: "create" })
        PhotoQueue.enqueue(_call({ productId: "prod-1" }))
        PhotoQueue._drainTimer.stop()
        verify(!PhotoQueue._drainTimer.running, "precondition: timer idle, as after the gated one-shot fired")
        OutboxStore.markSent(mutation.requestId)
        verify(PhotoQueue._drainTimer.running, "outbox change must re-arm the drain")
    }

    function test_outbox_change_with_an_empty_queue_does_not_arm_the_timer() {
        PhotoQueue.enqueue(_call())
        PhotoQueue.discard("photo-1")
        if (PhotoQueue._drainTimer) PhotoQueue._drainTimer.stop()
        OutboxStore.enqueue({ requestId: "r9", entity: "inventory", entityId: "prod-9", action: "create" })
        verify(!PhotoQueue._drainTimer || !PhotoQueue._drainTimer.running)
    }

    function test_outbox_change_does_not_rearm_for_a_terminally_failed_item() {
        PhotoQueue.enqueue(_call())
        PhotoQueue.items = [Object.assign({}, PhotoQueue.items[0], { state: "failed" })]
        PhotoQueue._drainTimer.stop()
        OutboxStore.enqueue({ requestId: "r9", entity: "inventory", entityId: "prod-9", action: "create" })
        verify(!PhotoQueue._drainTimer.running, "failed items wait for the user's Retry, not the outbox")
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

    // ── F1 (PR #84 final sweep): an item persisted as "uploading" must not stay stuck ────────
    // _upload() persists state "uploading" before the XHR. Kill/suspend in that window and, on the
    // next launch, drainCandidates/_reschedule (which only take enqueued|retrying) never picked it
    // up: spinner forever, no Retry/Discard, still counted toward the 10-photo cap.

    function _persistedThenRelaunched(items) {
        PhotoQueue.items = items
        PhotoQueue._save()
        PhotoQueue.items = []
        PhotoQueue._load()
    }

    function test_relaunch_recovers_an_item_persisted_mid_upload() {
        var it = PhotoQueue.enqueue(_call())
        _persistedThenRelaunched([Object.assign({}, it, { state: "uploading", attempts: 2 })])
        compare(PhotoQueue.items[0].state, "enqueued")
        compare(PhotoQueue.items[0].attempts, 2, "a crash is not a failed attempt: attempts kept")
        compare(PhotoQueue.drainCandidates(Date.now()).length, 1, "and it must be drainable again")
    }

    function test_relaunch_leaves_failed_and_retrying_items_untouched() {
        var base = PhotoQueue.enqueue(_call())
        var failed = Object.assign({}, base, { photoId: "f", state: "failed", attempts: 8, lastError: 400 })
        var retrying = Object.assign({}, base, { photoId: "r", state: "retrying", attempts: 3, nextAttemptAt: 4102444800000 })
        _persistedThenRelaunched([failed, retrying])
        compare(PhotoQueue.items[0].state, "failed", "failed waits for the user's Retry")
        compare(PhotoQueue.items[0].lastError, 400)
        compare(PhotoQueue.items[1].state, "retrying")
        compare(PhotoQueue.items[1].nextAttemptAt, 4102444800000, "backoff kept")
    }

    function test_relaunch_recovers_only_the_uploading_items_of_a_mixed_queue() {
        var b = PhotoQueue.enqueue(_call())
        var states = ["enqueued", "uploading", "retrying", "failed", "uploading"]
        var items = []
        for (var i = 0; i < states.length; ++i)
            items.push(Object.assign({}, b, { photoId: "p" + i, state: states[i] }))
        _persistedThenRelaunched(items)
        compare(PhotoQueue.items.length, 5, "nothing dropped or duplicated")
        var want = ["enqueued", "enqueued", "retrying", "failed", "enqueued"]
        for (var j = 0; j < want.length; ++j)
            compare(PhotoQueue.items[j].state, want[j], "item " + j)
    }

    function test_relaunch_with_empty_or_corrupt_storage_is_still_a_harmless_noop() {
        PhotoQueue.clear()
        PhotoQueue._load()
        compare(PhotoQueue.pendingCount, 0)
        PhotoQueue._settings.itemsJson = "{not json"
        PhotoQueue._load()
        compare(PhotoQueue.pendingCount, 0, "corrupt JSON must not throw or invent items")
    }

    function test_an_in_session_uploading_item_is_still_excluded_from_drain() {
        // Recovery is a LOAD-time rule only: it must not turn a genuinely in-flight upload back
        // into a drain candidate (double send).
        var it = PhotoQueue.enqueue(_call())
        PhotoQueue.items = [Object.assign({}, it, { state: "uploading" })]
        compare(PhotoQueue.drainCandidates(Date.now()).length, 0)
    }

    // ── F4: a token that arrives late must trigger a drain ───────────────────────────────────
    // _upload() returns quietly when idToken is empty and nothing re-armed the drain, so the item
    // waited for an unrelated trigger. The watcher is event-driven (no polling). Under
    // qmltestrunner NativeFile is undefined, so a drain pass that does reach _upload() ends in the
    // "file unreadable" branch: the item leaves "enqueued". That is the observable here.

    function test_token_arrival_triggers_a_drain_pass() {
        PhotoQueue.enqueue(_call())
        compare(PhotoQueue.items[0].state, "enqueued", "precondition: no token, nothing sent")
        AuthStore.idToken = "tok-1"
        verify(PhotoQueue.items[0].state !== "enqueued", "token arrival must drain the queue")
    }

    function test_token_cleared_does_not_drain() {
        AuthStore.idToken = "tok-1"          // queue empty: nothing to do, must not throw
        PhotoQueue.enqueue(_call())
        AuthStore.idToken = ""               // sign-out style clear
        compare(PhotoQueue.items[0].state, "enqueued", "an empty token is not a trigger")
    }

    function test_token_arrival_respects_the_outbox_gate() {
        OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "prod-1", action: "create" })
        PhotoQueue.enqueue(_call({ productId: "prod-1" }))
        AuthStore.idToken = "tok-1"
        compare(PhotoQueue.items[0].state, "enqueued", "gated on its product's create: still waiting")
    }

    function test_token_arrival_with_an_empty_queue_is_a_noop() {
        AuthStore.idToken = "tok-1"
        compare(PhotoQueue.pendingCount, 0)
    }

    function test_token_arrival_skips_an_item_from_a_different_identity() {
        PhotoQueue.enqueue(_call({ uid: "someone-else" }))
        AuthStore.idToken = "tok-1"
        compare(PhotoQueue.items[0].state, "enqueued", "identity gate holds when the token arrives")
    }

    // ── PR #99 sweep 2: token-watcher edges the first pass did not pin down ────────────────────

    function test_token_arrival_respects_an_open_circuit_breaker() {
        PhotoQueue._breaker = ({ status: "open", consecutiveFailures: 5, cooldownUntil: Date.now() + 600000,
                                 cooldownMs: 60000, tripCount: 1 })
        PhotoQueue.enqueue(_call())
        AuthStore.idToken = "tok-1"
        compare(PhotoQueue.items[0].state, "enqueued", "breaker open: a token arrival must not send")
    }

    function test_hourly_token_refresh_leaves_a_failed_item_untouched() {
        var it = PhotoQueue.enqueue(_call())
        PhotoQueue.items = [Object.assign({}, it, { state: "failed", attempts: 8, lastError: 404 })]
        AuthStore.idToken = "tok-1"
        AuthStore.idToken = "tok-2"
        compare(PhotoQueue.items[0].state, "failed", "failed waits for the user's Retry, whatever the token does")
        compare(PhotoQueue.items[0].attempts, 8)
        compare(PhotoQueue.items[0].lastError, 404)
    }

    function test_token_arrival_respects_a_retrying_items_backoff() {
        var it = PhotoQueue.enqueue(_call())
        PhotoQueue.items = [Object.assign({}, it, { state: "retrying", attempts: 2, nextAttemptAt: Date.now() + 600000 })]
        AuthStore.idToken = "tok-1"
        compare(PhotoQueue.items[0].state, "retrying", "backoff not elapsed: no early retry")
        compare(PhotoQueue.items[0].attempts, 2)
    }

    function test_token_churn_monkey_never_loses_or_revives_items() {
        // Deterministic LCG (a*m < 2^53, exact in a double). 60 random token set/clear/refresh events
        // over a mixed queue: nothing lost or duplicated, failed/in-flight/backed-off/other-identity
        // items never move, and the one eligible item is drained.
        var seed = 987
        function rnd(n) { seed = (seed * 1664525 + 1013904223) % 4294967296; return Math.floor(seed / 65536) % n }
        var base = PhotoQueue.enqueue(_call())
        PhotoQueue.items = [
            Object.assign({}, base, { photoId: "live" }),
            Object.assign({}, base, { photoId: "dead", state: "failed", attempts: 8, lastError: 400 }),
            Object.assign({}, base, { photoId: "wait", state: "retrying", attempts: 1, nextAttemptAt: Date.now() + 600000 }),
            Object.assign({}, base, { photoId: "fly", state: "uploading" }),
            Object.assign({}, base, { photoId: "other", uid: "someone-else" })
        ]
        var sawToken = false
        for (var i = 0; i < 60; ++i) {
            var t = (rnd(3) === 0) ? "" : "tok-" + rnd(1000)
            if (t !== "") sawToken = true
            AuthStore.idToken = t
        }
        verify(sawToken, "the generator must produce at least one non-empty token")
        compare(PhotoQueue.items.length, 5, "nothing lost or duplicated")
        var byId = {}
        for (var k = 0; k < PhotoQueue.items.length; ++k) byId[PhotoQueue.items[k].photoId] = PhotoQueue.items[k]
        compare(byId.dead.state, "failed")
        compare(byId.dead.attempts, 8)
        compare(byId.wait.state, "retrying")
        compare(byId.fly.state, "uploading")
        compare(byId.other.state, "enqueued")
        verify(byId.live.state !== "enqueued", "the eligible item must have been drained")
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

    // ── _failUpload: the failure tail of _upload (PH4 R1 discard rule + retry/failed bookkeeping) ──────────
    // Driven directly: no NativeFile, no XHR. The discard needs ALL of: status 404, body error "product-not-found",
    // and the product row absent from the COMPLETE local list. Anything else keeps the photo and counts a failure.

    readonly property string pnfBody: '{"ok":false,"error":"product-not-found"}'

    function _uploadingItem(state) {
        var it = Object.assign({}, _call(), { requestId: "photo-1", state: state || "uploading",
                                              attempts: 0, nextAttemptAt: 0, lastError: null })
        PhotoQueue.items = [it]
        return it
    }
    function _listComplete(rows) {
        InventoryStore.products = rows
        InventoryStore.hasMore = false
        InventoryStore.loadingMore = false
        InventoryStore._resetPending = false
    }

    function test_failUpload_404_with_the_server_code_and_the_row_gone_discards_the_photo() {
        var it = _uploadingItem()
        _listComplete([])
        PhotoQueue._failUpload(it, it, 404, pnfBody)
        compare(PhotoQueue.items.length, 0, "item removed")
        compare(PhotoQueue.pendingCount, 0)
        compare(failSpy.count, 0, "a discard is not a failure report")
        compare(PhotoQueue._breaker.consecutiveFailures, 0, "a discard is not an endpoint failure")
    }

    function test_failUpload_an_html_404_keeps_the_photo_as_failed_even_when_the_row_is_gone() {
        var it = _uploadingItem()
        _listComplete([])
        PhotoQueue._failUpload(it, it, 404, "<html><h1>404 Not Found</h1></html>")
        compare(PhotoQueue.items.length, 1, "kept")
        compare(PhotoQueue.items[0].state, "failed")
        compare(PhotoQueue.items[0].attempts, 1)
        compare(PhotoQueue.items[0].lastError, 404)
        compare(failSpy.count, 1)
        compare(failSpy.signalArguments[0][0], "prod-1")
        compare(failSpy.signalArguments[0][1], "photo-1")
        compare(failSpy.signalArguments[0][2], 404)
        compare(PhotoQueue._breaker.consecutiveFailures, 1)
    }

    function test_failUpload_a_404_without_a_body_or_with_another_code_never_discards() {
        var bodies = ["", undefined, null, "{}", '{"error":"photo-limit"}', '{"error":"PRODUCT-NOT-FOUND"}', "{", "[]"]
        for (var i = 0; i < bodies.length; ++i) {
            var it = _uploadingItem()
            _listComplete([])
            PhotoQueue._failUpload(it, it, 404, bodies[i])
            compare(PhotoQueue.items.length, 1, "body " + bodies[i])
            compare(PhotoQueue.items[0].state, "failed", "body " + bodies[i])
        }
    }

    function test_failUpload_404_with_the_code_keeps_the_photo_while_the_row_still_exists_locally() {
        var it = _uploadingItem()
        _listComplete([{ productId: "prod-1" }])
        PhotoQueue._failUpload(it, it, 404, pnfBody)
        compare(PhotoQueue.items.length, 1)
        compare(PhotoQueue.items[0].state, "failed")
    }

    function test_failUpload_404_with_the_code_keeps_the_photo_while_the_product_list_is_partial() {
        var it = _uploadingItem()
        InventoryStore.products = []
        InventoryStore.hasMore = true   // page 2+ not loaded: the answer is "unknown", never "gone"
        PhotoQueue._failUpload(it, it, 404, pnfBody)
        compare(PhotoQueue.items.length, 1)
        compare(PhotoQueue.items[0].state, "failed")
    }

    function test_failUpload_the_code_alone_is_not_enough_other_statuses_never_discard() {
        var statuses = [0, 400, 401, 403, 409, 413, 429, 500, 503]
        for (var i = 0; i < statuses.length; ++i) {
            var it = _uploadingItem()
            _listComplete([])
            PhotoQueue._failUpload(it, it, statuses[i], pnfBody)
            compare(PhotoQueue.items.length, 1, "status " + statuses[i])
        }
    }

    function test_failUpload_a_transient_status_schedules_a_retry_and_stays_quiet() {
        var it = _uploadingItem()
        _listComplete([{ productId: "prod-1" }])
        PhotoQueue._failUpload(it, it, 503, "")
        compare(PhotoQueue.items[0].state, "retrying")
        compare(PhotoQueue.items[0].attempts, 1)
        verify(PhotoQueue.items[0].nextAttemptAt > Date.now(), "backoff in the future")
        compare(failSpy.count, 0, "only a terminal failure is reported to the UI")
        compare(PhotoQueue._breaker.consecutiveFailures, 1)
    }

    function test_failUpload_a_timeout_is_status_zero_and_retries() {
        var it = _uploadingItem()
        PhotoQueue._failUpload(it, it, 0, "")
        compare(PhotoQueue.items[0].state, "retrying")
        compare(failSpy.count, 0)
    }

    function test_failUpload_the_unreadable_file_status_400_fails_the_item_and_reports_it() {
        var it = _uploadingItem()
        PhotoQueue._failUpload(it, it, 400, "")
        compare(PhotoQueue.items[0].state, "failed")
        compare(failSpy.count, 1)
        compare(failSpy.signalArguments[0][2], 400)
    }

    function test_failUpload_a_stale_report_for_an_item_that_is_not_uploading_changes_nothing() {
        var it = _uploadingItem("enqueued")
        PhotoQueue._failUpload(it, it, 409, "")
        compare(PhotoQueue.items[0].state, "enqueued", "reduceQueueItem ignores a report for an item that is not in flight")
        compare(PhotoQueue.items[0].attempts, 0)
        compare(failSpy.count, 0)
    }

    function test_failUpload_a_late_report_for_an_item_that_is_already_gone_is_a_harmless_noop() {
        var it = _uploadingItem()
        PhotoQueue.items = []
        _listComplete([])
        PhotoQueue._failUpload(it, it, 404, pnfBody)   // discard of an unknown id
        PhotoQueue._failUpload(it, it, 404, "")        // replace of an unknown id
        compare(PhotoQueue.items.length, 0)
    }

    // MONKEY: 5 seeds x 200 random (status, body, row state); a one-line reference model decides the discard.
    // High bits of the LCG: its low bits cycle with a tiny period and never reached 404 + code + row gone.
    function test_failUpload_monkey_only_404_plus_code_plus_row_gone_discards() {
        var statuses = [0, 200, 400, 401, 403, 404, 404, 409, 413, 429, 500, 503]
        var bodies = [pnfBody, "", "<html>404</html>", '{"error":"photo-limit"}', "{", undefined]
        var rows = ["gone", "present", "unknown"]
        var discards = 0, keeps404 = 0
        for (var seed = 1; seed <= 5; ++seed) {
            var st = seed * 15485863
            var rnd = function(n) { st = (st * 1103515245 + 12345) & 0x7fffffff; return Math.floor(st / 65536) % n }
            for (var i = 0; i < 200; ++i) {
                var status = statuses[rnd(statuses.length)]
                var body = bodies[rnd(bodies.length)]
                var row = rows[rnd(rows.length)]
                var it = _uploadingItem()
                if (row === "gone") _listComplete([])
                else if (row === "present") _listComplete([{ productId: "prod-1" }])
                else { InventoryStore.products = []; InventoryStore.hasMore = true }
                PhotoQueue._failUpload(it, it, status, body)
                var want = status === 404 && body === pnfBody && row === "gone"
                compare(PhotoQueue.items.length === 0, want, "status " + status + " body " + body + " row " + row)
                if (want) discards++
                else if (status === 404) keeps404++
            }
        }
        verify(discards > 0, "the generator must reach the discard case")
        verify(keeps404 > 0, "the generator must reach the kept 404 cases")
    }
}
