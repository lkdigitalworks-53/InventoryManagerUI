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
// flagging as a known gap rather than a silently-passing fake test.
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
        // Re-asserts the production default independent of init()'s reset,
        // since a wrong default here means P0 goes live for nobody asked for
        // it the moment someone forgets to set it explicitly.
        compare(Gateway.mode, "direct")
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
}
