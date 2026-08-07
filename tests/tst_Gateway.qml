import QtQuick
import QtTest
import "../qml/model"

// Regression tests for the P0 compliance gateway's client bridge.
//
// SCOPE NOTE (read before extending this file): Gateway._send/_sendBatch
// perform real XHR calls against a live Cloud Functions URL, and
// direct-mode's _writeDirect/_writeDirectBatch call FirebaseService.put/
// remove/putMany, which talk to real Firestore. Neither has a mock/fake
// layer anywhere in this codebase. So:
//   - Direct-mode dispatch (recordMutation/recordMutations when
//     mode==="direct") is NOT exercised end-to-end here — only the pieces
//     that don't touch the network (_collectionFor, mode's default).
//   - Gateway-mode's enqueue step IS safely testable: _send/_sendBatch both
//     start with `if (!AuthStore.idToken || ...) return`, and a test run
//     has no real signed-in session, so drainNow()'s immediate send attempt
//     no-ops on that guard before any XHR happens. This is the one path in
//     this file that indirectly touches _send, and it's safe specifically
//     because of that guard — don't set AuthStore.idToken in these tests,
//     or that safety property no longer holds.
// A real mock-HTTP layer to test _send/_sendBatch's actual request/response
// handling would need new test infrastructure this session didn't build —
// flagging as a known gap rather than a silently-passing fake test. Same
// applies to _sendDelta (Component 4) and its callback firing on a REAL
// terminal response — only the enqueue-and-callback-stays-pending path is
// testable here, not the actual success/conflict branch inside the XHR
// handler. That branch is exercised indirectly by gatewayLogic.test.js
// (node --test, fully executable in this sandbox) against the SERVER-side
// logic it calls into — this file only covers the client dispatch shape.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local
// `qmltestrunner` pass before merge (same status as tst_EnvConfig.qml per
// the 2026-07-10 checkpoint).
TestCase {
    name: "Gateway"

    function init() {
        Gateway.mode = "direct" // the real default — reset every case
        OutboxStore.clear()
        AuthStore.idToken = "" // keep the _send/_sendBatch guard closed (see header)
    }

    // ── mode + collection mapping ────────────────────────────────────────────

    function test_mode_defaults_to_direct() {
        // NOTE (2026-08-06, found as a byproduct of the C3 review fix, not
        // itself one of the review's findings): this assertion was stale.
        // Gateway.mode's actual production default was flipped from
        // "direct" to "gateway" in 649046d — this test was never updated to
        // match and would have failed the moment qmltestrunner actually ran
        // it. Fixed to assert the real, intentional current default;
        // init()'s explicit reset to "direct" below is what actually keeps
        // every OTHER test in this file gateway-mode-off unless it opts in.
        compare(Gateway.mode, "gateway")
    }

    function test_collectionFor_covers_every_registered_entity() {
        // One entry per store this session (+ the two pre-existing ledger-
        // only entities). A typo/missing entry here is exactly the class of
        // bug the CF-side gatewayLogic.test.js tests caught twice already.
        compare(Gateway._collectionFor("inventory"), "inventory")
        compare(Gateway._collectionFor("stock_batch"), "stock_batches")
        compare(Gateway._collectionFor("stock_movement"), "stock_movements")
        compare(Gateway._collectionFor("transaction"), "transactions")
        compare(Gateway._collectionFor("order"), "orders")
        compare(Gateway._collectionFor("staff"), "staff")
        compare(Gateway._collectionFor("supplier"), "suppliers")
    }

    function test_collectionFor_returns_empty_string_for_unknown_entity() {
        compare(Gateway._collectionFor("widget"), "")
    }

    // ── gateway-mode enqueue (safe: no network — see header) ────────────────

    function test_recordMutation_in_gateway_mode_enqueues_not_writes_directly() {
        Gateway.mode = "gateway"
        var requestId = Gateway.recordMutation("order", "o1", "update", { status: "pending" }, { status: "approved" })

        verify(requestId.length > 0)
        compare(OutboxStore.pendingCount, 1)
        var item = OutboxStore.items[0]
        compare(item.requestId, requestId)
        compare(item.entity, "order")
        compare(item.entityId, "o1")
        compare(item.action, "update")
        compare(item.after.status, "approved")
    }

    function test_recordMutation_returns_empty_string_for_an_unknown_entity() {
        Gateway.mode = "gateway"
        var requestId = Gateway.recordMutation("widget", "w1", "update", null, {})
        compare(requestId, "")
        compare(OutboxStore.pendingCount, 0, "an unknown entity must not be enqueued at all")
    }

    function test_recordMutations_in_gateway_mode_enqueues_one_batch_item() {
        Gateway.mode = "gateway"
        var requestId = Gateway.recordMutations("order", [
            { entityId: "o1", action: "update", before: { status: "pending" }, after: { status: "approved" } },
            { entityId: "o2", action: "update", before: { status: "pending" }, after: { status: "approved" } }
        ])

        verify(requestId.length > 0)
        compare(OutboxStore.pendingCount, 1, "N items must produce ONE outbox entry, not N")
        var item = OutboxStore.items[0]
        compare(item.requestId, requestId)
        compare(item.items.length, 2)
        compare(item.items[0].entityId, "o1")
        compare(item.items[1].entityId, "o2")
    }

    function test_recordMutations_returns_empty_string_for_an_empty_items_array() {
        Gateway.mode = "gateway"
        var requestId = Gateway.recordMutations("order", [])
        compare(requestId, "")
        compare(OutboxStore.pendingCount, 0)
    }

    // ── Component 1: in-flight tracking doesn't leak when nothing sends ─────
    // (the _send/_sendDelta no-auth guard must still clear in-flight, or
    // every item enqueued during a test run — or in a real not-yet-signed-in
    // app launch — would be permanently stuck "blocked" and never drain
    // once a real session does arrive)

    function test_drainNow_does_not_leave_an_item_stuck_in_flight_when_unauthenticated() {
        Gateway.mode = "gateway"
        Gateway.recordMutation("order", "o1", "update", null, { status: "approved" })
        // drainNow() already ran once inside recordMutation(); call again to
        // prove the item is actually drainable, not silently stuck blocked.
        Gateway.drainNow()

        compare(OutboxStore.dueItems().length, 1,
                "the no-auth guard must clear in-flight, or this item can never be picked up again")
    }

    // ── Component 4: recordDelta ─────────────────────────────────────────────

    function test_recordDelta_in_gateway_mode_enqueues_a_delta_item() {
        Gateway.mode = "gateway"
        var requestId = Gateway.recordDelta("stock_batch", "b1", { qtyRemaining: -3 }, { qtyRemaining: 0 }, {}, null)

        verify(requestId.length > 0)
        compare(OutboxStore.pendingCount, 1)
        var item = OutboxStore.items[0]
        compare(item.requestId, requestId)
        compare(item.deltas.qtyRemaining, -3)
        compare(item.floors.qtyRemaining, 0)
    }

    function test_recordDelta_requires_gateway_mode() {
        Gateway.mode = "direct" // delta has no direct-mode equivalent — needs server-side read-then-write
        var calledWith = null
        Gateway.recordDelta("stock_batch", "b1", { qtyRemaining: -3 }, {}, {}, function(result) { calledWith = result })

        compare(OutboxStore.pendingCount, 0, "must not enqueue anything in direct mode")
        verify(calledWith !== null, "callback must fire synchronously with an explanatory error, not hang")
        compare(calledWith.ok, false)
        compare(calledWith.error, "delta-requires-gateway-mode")
    }

    function test_recordDelta_returns_empty_string_for_an_unknown_entity() {
        Gateway.mode = "gateway"
        var requestId = Gateway.recordDelta("widget", "w1", { qty: -1 }, {}, {}, null)
        compare(requestId, "")
        compare(OutboxStore.pendingCount, 0)
    }

    function test_recordDelta_callback_is_not_invoked_before_any_response() {
        // With AuthStore.idToken empty (see init()), _sendDelta's guard
        // returns before any XHR fires — the callback must stay pending,
        // not fire with a fabricated success/failure.
        Gateway.mode = "gateway"
        var callCount = 0
        Gateway.recordDelta("stock_batch", "b1", { qtyRemaining: -3 }, {}, {}, function(result) { callCount++ })

        compare(callCount, 0, "no server response has happened yet — the callback must not fire")
    }

    // ── _classifyDeltaResponse — regression tests for the 2026-07-29 bug ────
    // (systematic-debugging session: an undeployed recordDelta endpoint's
    // 404 was being treated as "transient, retry forever" — which is
    // actually correct in isolation, but meant order completion's callback
    // NEVER fired, silently stranding the order at "pending" forever. The
    // classification itself wasn't wrong so much as it was fragile: it
    // happened to work by accident for a body-less 404, but the underlying
    // logic didn't express the real distinction it needed to.)

    function test_classifyDeltaResponse_treats_a_malformed_body_as_non_terminal() {
        // What an undeployed Cloud Function's 404 actually looks like:
        // JSON.parse already failed upstream, so body is null here.
        var result = Gateway._classifyDeltaResponse(404, null)
        compare(result.terminal, false,
                "no real decision was made — must retry, not report a false rejection")
    }

    function test_classifyDeltaResponse_treats_a_body_without_ok_as_non_terminal() {
        // Some infra-level error responses ARE valid JSON, just not OUR
        // envelope shape (e.g. a generic platform error object).
        var result = Gateway._classifyDeltaResponse(404, { error: { code: 404, message: "not found" } })
        compare(result.terminal, false)
    }

    function test_classifyDeltaResponse_treats_a_genuine_success_as_terminal() {
        var result = Gateway._classifyDeltaResponse(200, { ok: true, after: { stock: 7 } })
        compare(result.terminal, true)
        compare(result.result.after.stock, 7)
    }

    function test_classifyDeltaResponse_treats_a_genuine_4xx_rejection_as_terminal() {
        var result = Gateway._classifyDeltaResponse(409, { ok: false, error: "insufficient-quantity", field: "stock" })
        compare(result.terminal, true)
        compare(result.result.error, "insufficient-quantity")
    }

    function test_classifyDeltaResponse_treats_a_well_formed_5xx_as_non_terminal() {
        // Our OWN code produced this body (see index.js's catch block: even
        // an unhandled exception sends {ok:false, error:"write-failed"}) —
        // but a 5xx could be a transient issue on our side, worth retrying,
        // unlike a 4xx which is a definitive decision. Must not give up
        // immediately just because the body happens to be well-formed.
        var result = Gateway._classifyDeltaResponse(500, { ok: false, error: "write-failed" })
        compare(result.terminal, false)
    }

    // ── _parseMutationConflict (review finding C3, 2026-08-06) ──────────────
    // Before this fix, _send had NO status-branching logic at all — this is
    // exactly the coverage gap the review flagged: this file tested
    // _classifyDeltaResponse (the recordDelta path) thoroughly, but never
    // _send's own behavior for the plain recordMutation path, which is why
    // a genuine 409 conflict retrying forever went unnoticed.

    function test_parseMutationConflict_recognizes_a_genuine_conflict() {
        var body = JSON.stringify({ ok: false, status: 409, conflict: true, current: { stock: 5, name: "Widget" } })
        var result = Gateway._parseMutationConflict(409, body)
        compare(result.isConflict, true)
        compare(result.current.stock, 5)
    }

    function test_parseMutationConflict_ignores_a_409_without_the_conflict_flag() {
        // Belt-and-braces: applyMutation always sets conflict:true on its
        // 409, but a future endpoint using 409 for something else entirely
        // must not be misread as a CAS conflict just because of the status.
        var result = Gateway._parseMutationConflict(409, JSON.stringify({ ok: false, error: "some-other-409-reason" }))
        compare(result.isConflict, false)
    }

    function test_parseMutationConflict_ignores_non_409_statuses() {
        // These must fall through to the existing markFailed/retry path
        // completely unchanged — a 400/401/403/5xx MIGHT resolve on retry
        // (token refresh, transient infra), unlike a real conflict, which
        // never will. Only 409+conflict:true short-circuits the retry.
        compare(Gateway._parseMutationConflict(400, JSON.stringify({ ok: false, error: "missing-fields" })).isConflict, false)
        compare(Gateway._parseMutationConflict(401, JSON.stringify({ ok: false, error: "invalid-token" })).isConflict, false)
        compare(Gateway._parseMutationConflict(500, JSON.stringify({ ok: false, error: "write-failed" })).isConflict, false)
    }

    function test_parseMutationConflict_handles_a_malformed_or_empty_body_safely() {
        compare(Gateway._parseMutationConflict(409, "").isConflict, false)
        compare(Gateway._parseMutationConflict(409, "not json{{{").isConflict, false)
        compare(Gateway._parseMutationConflict(404, "").isConflict, false)
    }
}
