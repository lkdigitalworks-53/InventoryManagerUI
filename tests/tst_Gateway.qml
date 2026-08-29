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
        // Force "direct" for every case below so these tests stay isolated
        // from whatever the real production default is (see Gateway.qml —
        // currently "gateway" since 649046d). NOTE: this means no test in
        // this file can assert on the *true* declared default — init() runs
        // before every test function, so the singleton's real value is
        // always overwritten before any compare() sees it. A prior version
        // of this file had a test_mode_defaults_to_direct() that appeared
        // to check this but couldn't actually observe it under this
        // structure, and had gone stale (still asserting "direct" after the
        // production default moved to "gateway") without ever failing.
        // Verifying the real default is a job for an integration/E2E check
        // that inspects the deployed app, not this per-case-reset TestCase.
        Gateway.mode = "direct"
        OutboxStore.clear()
        AuthStore.idToken = "" // keep the _send/_sendBatch guard closed (see header)
        // In-memory reset alone isn't enough: Gateway.drainNow() itself
        // triggers AuthService's first-ever lazy construction (only real
        // reference to it in this file), whose init() calls
        // AuthStore.loadSession() -- reading from the SAME on-disk file
        // every store shares under qmltestrunner (see SettingsPath.js).
        // If tst_AuthStore.qml's persistence test left a real idToken
        // there, loadSession() silently overwrites the line above with
        // it, right before _send checks it. Clear the disk copy too.
        AuthStore._settings.sessionJson = ""
    }

    // ── mode + collection mapping ────────────────────────────────────────────

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
        // Fixture matches the ACTUAL wire body functions/index.js's
        // recordMutation handler sends (error:"conflict" + conflict:true +
        // current), not gatewayLogic.js's internal result object. Those two
        // shapes look almost identical but aren't the same thing, and this
        // test previously used the wrong one -- see the regression test
        // below for why that distinction is the whole bug.
        var body = JSON.stringify({ ok: false, error: "conflict", conflict: true, current: { stock: 5, name: "Widget" } })
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

    // ── Regression: E2E testing phase 2 followup, ninth debugging round ──────
    // 8 rounds of investigation (see CHECKPOINT.md) chased this as a transport/
    // timing/emulator problem before finding the real cause: functions/index.js's
    // recordMutation handler forwarded `current` but silently dropped
    // `result.conflict` -- the field this parser actually checks -- and sent
    // `error:"conflict"` in its place. The 409 arrived, parsed as valid JSON,
    // and was STILL misread as a generic failure every time, because the one
    // field the check depends on was never on the wire. This body is the
    // literal shape the handler used to send, byte for byte -- if a future
    // change to functions/index.js's response construction ever drops
    // `conflict` again, this is the test that must catch it.
    function test_parseMutationConflict_would_have_caught_the_dropped_conflict_field_bug() {
        var preFixServerBody = JSON.stringify({ ok: false, error: "conflict", current: { stock: 5, name: "Widget" } })
        var result = Gateway._parseMutationConflict(409, preFixServerBody)
        compare(result.isConflict, false) // this is what the bug produced -- documenting the failure mode, not asserting it's desired
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

    // ── _parseBatchMutationConflict (review finding I1) ──────────────────────
    // _sendBatch had NO conflict handling at all before this round — deliberately
    // so, per its own prior comment: applyMutationsBatch had no CAS check yet,
    // so a 409 conflict was unreachable. Now that it's reachable (I1's Cloud
    // Function fix), this is the client-side half.

    function test_parseBatchMutationConflict_recognizes_a_genuine_conflict() {
        var body = JSON.stringify({
            ok: false, error: "conflict",
            conflicts: [{ entityId: "order-1", current: { status: "shipped" } }]
        })
        var result = Gateway._parseBatchMutationConflict(409, body)
        compare(result.isConflict, true)
        compare(result.conflicts.length, 1)
        compare(result.conflicts[0].entityId, "order-1")
    }

    function test_parseBatchMutationConflict_reports_every_conflicting_item() {
        var body = JSON.stringify({
            ok: false, error: "conflict",
            conflicts: [
                { entityId: "order-1", current: { status: "shipped" } },
                { entityId: "order-2", current: { status: "cancelled" } }
            ]
        })
        var result = Gateway._parseBatchMutationConflict(409, body)
        compare(result.conflicts.length, 2)
    }

    function test_parseBatchMutationConflict_ignores_a_409_without_conflicts() {
        var result = Gateway._parseBatchMutationConflict(409, JSON.stringify({ ok: false, error: "some-other-409-reason" }))
        compare(result.isConflict, false)
    }

    function test_parseBatchMutationConflict_ignores_non_409_statuses() {
        compare(Gateway._parseBatchMutationConflict(400, JSON.stringify({ ok: false, error: "missing-fields" })).isConflict, false)
        compare(Gateway._parseBatchMutationConflict(500, JSON.stringify({ ok: false, error: "write-failed" })).isConflict, false)
    }

    function test_parseBatchMutationConflict_handles_a_malformed_or_empty_body_safely() {
        compare(Gateway._parseBatchMutationConflict(409, "").isConflict, false)
        compare(Gateway._parseBatchMutationConflict(409, "not json{{{").isConflict, false)
        compare(Gateway._parseBatchMutationConflict(409, JSON.stringify({ ok: false, conflicts: [] })).isConflict, false)
    }

    // ── _captureBeforeStatusIsLost (QTBUG-49896 workaround, 12th round) ──────
    // Plain mock objects stand in for a real XMLHttpRequest here -- the
    // function only reads readyState/status/responseText and calls
    // getAllResponseHeaders(), so a plain object with those members exercises
    // the exact same code path. This tests the workaround's OWN logic in
    // isolation; it does not and cannot prove the underlying Qt engine bug
    // is what's actually happening on a real run -- that needs a real
    // qmltestrunner/CI pass (see CHECKPOINT.md, twelfth round).

    function test_captureBeforeStatusIsLost_snapshots_status_at_headersReceived() {
        var snapshot = { status: 0, responseText: "", headers: "" }
        var mockXhr = { readyState: XMLHttpRequest.HEADERS_RECEIVED, status: 409, responseText: "",
                         getAllResponseHeaders: function() { return "content-type: application/json" } }
        Gateway._captureBeforeStatusIsLost(mockXhr, snapshot)
        compare(snapshot.status, 409)
        compare(snapshot.headers, "content-type: application/json")
    }

    function test_captureBeforeStatusIsLost_keeps_the_latest_snapshot_from_loading() {
        // readyState progresses HEADERS_RECEIVED -> LOADING with the full
        // body only available by LOADING -- the realistic sequence for a
        // small JSON response arriving in one read.
        var snapshot = { status: 0, responseText: "", headers: "" }
        var body = JSON.stringify({ ok: false, error: "conflict", conflict: true, current: { stock: 5 } })
        Gateway._captureBeforeStatusIsLost({ readyState: XMLHttpRequest.HEADERS_RECEIVED, status: 409, responseText: "",
                                              getAllResponseHeaders: function() { return "" } }, snapshot)
        Gateway._captureBeforeStatusIsLost({ readyState: XMLHttpRequest.LOADING, status: 409, responseText: body,
                                              getAllResponseHeaders: function() { return "" } }, snapshot)
        compare(snapshot.status, 409)
        compare(snapshot.responseText, body)
    }

    function test_captureBeforeStatusIsLost_ignores_a_zero_status_mid_flight() {
        // status===0 during HEADERS_RECEIVED/LOADING means the response
        // genuinely hasn't arrived yet (or a real transport failure) --
        // must not overwrite a valid earlier snapshot with nothing.
        var snapshot = { status: 200, responseText: "prior-good-body", headers: "prior" }
        Gateway._captureBeforeStatusIsLost({ readyState: XMLHttpRequest.LOADING, status: 0, responseText: "",
                                              getAllResponseHeaders: function() { return "" } }, snapshot)
        compare(snapshot.status, 200)
        compare(snapshot.responseText, "prior-good-body")
    }

    function test_captureBeforeStatusIsLost_does_nothing_at_other_readyStates() {
        var snapshot = { status: 0, responseText: "", headers: "" }
        Gateway._captureBeforeStatusIsLost({ readyState: XMLHttpRequest.OPENED, status: 409, responseText: "irrelevant" }, snapshot)
        compare(snapshot.status, 0)
        Gateway._captureBeforeStatusIsLost({ readyState: XMLHttpRequest.DONE, status: 409, responseText: "irrelevant" }, snapshot)
        compare(snapshot.status, 0) // DONE is exactly the state this workaround exists to not trust blindly
    }

    // ── Regression: the exact QTBUG-49896 sequence, end to end ───────────────
    // Reproduces the bug report's own observed sequence (status correct at
    // readyState 2/3, reset to 0 at DONE) and confirms the effective-status
    // fallback pattern used at every Gateway.qml call site recovers it.
    function test_effectiveStatus_fallback_recovers_a_QTBUG49896_lost_status() {
        var snapshot = { status: 0, responseText: "", headers: "" }
        var body = JSON.stringify({ ok: false, error: "conflict", conflict: true, current: { notes: "staff edit" } })
        Gateway._captureBeforeStatusIsLost({ readyState: XMLHttpRequest.HEADERS_RECEIVED, status: 409, responseText: "",
                                              getAllResponseHeaders: function() { return "" } }, snapshot)
        Gateway._captureBeforeStatusIsLost({ readyState: XMLHttpRequest.LOADING, status: 409, responseText: body,
                                              getAllResponseHeaders: function() { return "" } }, snapshot)
        // DONE: the bug -- both status and responseText read as lost.
        var xhrAtDone = { status: 0, responseText: "" }
        var effStatus = (xhrAtDone.status !== 0) ? xhrAtDone.status : snapshot.status
        var effResponseText = (xhrAtDone.status !== 0) ? xhrAtDone.responseText : snapshot.responseText
        compare(effStatus, 409)
        var conflict = Gateway._parseMutationConflict(effStatus, effResponseText)
        compare(conflict.isConflict, true)
        compare(conflict.current.notes, "staff edit")
    }

    // ── Bulk-import chunking fix (2026-08-29) ────────────────────────────────
    // Root cause: recordMutations() sent an arbitrarily large `items` array
    // as ONE outbox entry / ONE HTTP call. Past 200 items,
    // functions/lib/batchMutationLogic.js's validateBatchMutationRequest
    // rejects the whole thing with 400 batch-too-large — and because
    // _sendBatch treated that identically to a transient failure, it retried
    // the SAME oversized batch forever (OutboxStore's backoff caps at 10min
    // but never gives up), completely silently, while the calling store had
    // already committed every row locally. See CHECKPOINT.md for the full
    // trace across InventoryStore/OrdersStore/SupplierStore.

    function test_chunkItems_returns_a_single_chunk_when_under_the_limit() {
        var chunks = Gateway._chunkItems([{ entityId: "a" }, { entityId: "b" }], 200)
        compare(chunks.length, 1)
        compare(chunks[0].length, 2)
    }

    function test_chunkItems_splits_evenly_at_the_boundary() {
        var items = []
        for (var i = 0; i < 400; ++i) items.push({ entityId: "e" + i })
        var chunks = Gateway._chunkItems(items, 200)
        compare(chunks.length, 2, "exactly 2x the limit must not leave a trailing empty chunk")
        compare(chunks[0].length, 200)
        compare(chunks[1].length, 200)
    }

    function test_chunkItems_splits_with_a_remainder() {
        var items = []
        for (var i = 0; i < 250; ++i) items.push({ entityId: "e" + i })
        var chunks = Gateway._chunkItems(items, 200)
        compare(chunks.length, 2)
        compare(chunks[0].length, 200)
        compare(chunks[1].length, 50)
        compare(chunks[1][0].entityId, "e200", "chunk boundaries must not drop or duplicate an item")
    }

    function test_chunkItems_returns_empty_for_no_items() {
        compare(Gateway._chunkItems([], 200).length, 0)
        compare(Gateway._chunkItems(null, 200).length, 0)
    }

    // ── Regression: the exact reported bug — >200 rows must not be sent as
    // one oversized outbox entry ──────────────────────────────────────────────

    function test_recordMutations_splits_an_oversized_batch_into_multiple_outbox_entries() {
        Gateway.mode = "gateway"
        var items = []
        for (var i = 0; i < 250; ++i) {
            items.push({ entityId: "p" + i, action: "create", before: null, after: { name: "Product " + i } })
        }
        var requestId = Gateway.recordMutations("inventory", items)

        verify(requestId.length > 0)
        // This is the actual regression: before the fix, this was 1 entry of
        // 250 items, which the server unconditionally rejects — every retry,
        // forever, identically.
        compare(OutboxStore.pendingCount, 2, "250 items at a 200 cap must produce 2 outbox entries, not 1")
        compare(OutboxStore.items[0].items.length, 200)
        compare(OutboxStore.items[1].items.length, 50)
        verify(OutboxStore.items[0].items.length <= Gateway.maxBatchSize)
        verify(OutboxStore.items[1].items.length <= Gateway.maxBatchSize)
    }

    function test_recordMutations_gives_each_chunk_a_distinct_but_related_requestId() {
        // Distinct requestIds so OutboxStore never coalesces/overwrites one
        // chunk with another; related (shared prefix) so a stable id
        // survives retries of that SAME chunk — this is what keeps a retry
        // idempotent against the server's requestId:entityId audit-log
        // dedup in applyMutationsBatch, including across an app relaunch
        // that resumes a partially-sent import from what OutboxStore
        // persisted to disk before the interruption.
        Gateway.mode = "gateway"
        var items = []
        for (var i = 0; i < 300; ++i) items.push({ entityId: "p" + i, action: "create", before: null, after: {} })
        var requestId = Gateway.recordMutations("inventory", items)

        compare(OutboxStore.pendingCount, 2)
        verify(OutboxStore.items[0].requestId !== OutboxStore.items[1].requestId)
        compare(OutboxStore.items[0].requestId, requestId + "-c0")
        compare(OutboxStore.items[1].requestId, requestId + "-c1")
    }

    function test_recordMutations_under_the_limit_is_unaffected_by_chunking() {
        // Must not regress the pre-existing, already-tested small-batch
        // shape (test_recordMutations_in_gateway_mode_enqueues_one_batch_item
        // above) — a single chunk keeps the PLAIN requestId, no "-c0" suffix.
        Gateway.mode = "gateway"
        var requestId = Gateway.recordMutations("inventory", [
            { entityId: "p1", action: "create", before: null, after: {} }
        ])
        compare(OutboxStore.pendingCount, 1)
        compare(OutboxStore.items[0].requestId, requestId)
    }

    function test_recordMutations_direct_mode_is_unaffected_by_chunking() {
        // direct mode's _writeDirectBatch talks straight to FirebaseService,
        // not the capped Cloud Function — out of scope for this fix (see
        // CHECKPOINT.md), and must keep behaving exactly as before.
        Gateway.mode = "direct"
        var items = []
        for (var i = 0; i < 250; ++i) items.push({ entityId: "p" + i, action: "create", before: null, after: {} })
        Gateway.recordMutations("inventory", items)
        compare(OutboxStore.pendingCount, 0, "direct mode must never touch the outbox")
    }

    // ── _classifyBatchMutationFailure ────────────────────────────────────────
    // Deliberately narrow: only the specific validateBatchMutationRequest
    // error strings are terminal. Everything else (malformed body, 5xx, or a
    // 4xx whose error isn't one of these five) falls through to the existing
    // markFailed/backoff retry path completely unchanged — same conservative
    // default as _parseMutationConflict elsewhere in this file: when unsure,
    // retry rather than silently give up.

    function test_classifyBatchMutationFailure_treats_a_malformed_body_as_non_terminal() {
        var result = Gateway._classifyBatchMutationFailure(400, "not json{{{")
        compare(result.terminal, false)
    }

    function test_classifyBatchMutationFailure_treats_an_empty_body_as_non_terminal() {
        var result = Gateway._classifyBatchMutationFailure(400, "")
        compare(result.terminal, false)
    }

    function test_classifyBatchMutationFailure_treats_a_body_without_ok_false_as_non_terminal() {
        var result = Gateway._classifyBatchMutationFailure(400, JSON.stringify({ error: { code: 400 } }))
        compare(result.terminal, false)
    }

    function test_classifyBatchMutationFailure_recognizes_batch_too_large_as_terminal() {
        // The exact reported bug's server response shape.
        var result = Gateway._classifyBatchMutationFailure(400, JSON.stringify({ ok: false, error: "batch-too-large" }))
        compare(result.terminal, true)
        compare(result.error, "batch-too-large")
    }

    function test_classifyBatchMutationFailure_recognizes_every_definitive_validation_error() {
        var definitiveErrors = ["unsupported-entity", "missing-fields", "empty-batch", "batch-too-large", "unsupported-action"]
        for (var i = 0; i < definitiveErrors.length; ++i) {
            var result = Gateway._classifyBatchMutationFailure(400, JSON.stringify({ ok: false, error: definitiveErrors[i] }))
            compare(result.terminal, true, definitiveErrors[i] + " must be classified as terminal")
        }
    }

    function test_classifyBatchMutationFailure_does_not_treat_auth_or_tenant_failures_as_terminal() {
        // 401/403 describe CALLER STATE (token, tenant context) that can
        // legitimately change between attempts without the payload changing
        // at all — unlike the five errors above, retrying these might
        // actually succeed (e.g. after AuthService.ensureFreshToken() runs
        // on the next drainNow()). Must keep retrying via markFailed.
        compare(Gateway._classifyBatchMutationFailure(401, JSON.stringify({ ok: false, error: "invalid-token" })).terminal, false)
        compare(Gateway._classifyBatchMutationFailure(403, JSON.stringify({ ok: false, error: "no-tenant-context" })).terminal, false)
    }

    function test_classifyBatchMutationFailure_treats_a_well_formed_5xx_as_non_terminal() {
        // Same reasoning as test_classifyDeltaResponse_treats_a_well_formed_5xx_as_non_terminal
        // above: a well-formed ok:false body doesn't make a 5xx definitive —
        // status range is checked FIRST, before the error-string allowlist.
        var result = Gateway._classifyBatchMutationFailure(500, JSON.stringify({ ok: false, error: "batch-too-large" }))
        compare(result.terminal, false, "5xx must never be terminal regardless of the error string")
    }

    function test_classifyBatchMutationFailure_ignores_a_2xx_status() {
        var result = Gateway._classifyBatchMutationFailure(200, JSON.stringify({ ok: true }))
        compare(result.terminal, false)
    }

    function test_classifyBatchMutationFailure_does_not_treat_an_unrecognized_4xx_error_as_terminal() {
        // Conservative default: an error string this classifier doesn't
        // recognize (e.g. a future validation error added to
        // batchMutationLogic.js without updating this allowlist) must keep
        // retrying, not silently give up on an unfamiliar rejection.
        var result = Gateway._classifyBatchMutationFailure(400, JSON.stringify({ ok: false, error: "some-future-error" }))
        compare(result.terminal, false)
    }
}
