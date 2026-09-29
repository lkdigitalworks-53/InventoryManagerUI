import QtQuick
import QtTest
import "../qml/model"

// Regression tests for the P0 compliance gateway's persisted outbox queue.
// Covers the spec's "Outbox: enqueue→drain→dequeue; persistence across
// relaunch; backoff" requirement (docs/superpowers/specs/2026-06-06-P0-
// compliance-gateway-design.md §6), the batch item shape (enqueueBatch,
// backs Gateway.recordMutations), and — new this session — single-flight-
// per-record coalescing and in-flight tracking (Component 1 of
// docs/superpowers/specs/2026-07-29-async-write-sequencing-design.md §3).
//
// NOT covered here: actually sending (Gateway._send/_sendBatch) — that's a
// real XHR call with no mock HTTP layer in this codebase, so it's out of
// scope for a fast, deterministic unit test. See tst_Gateway.qml for what
// IS safely testable around the send path (the auth-token guard means
// gateway-mode enqueue+drain is safe to exercise without hitting the
// network; direct-mode's FirebaseService calls are not, so those aren't
// exercised here either). Everything in this file is pure data-structure
// logic (enqueue, dueItems, markInFlight/clearInFlight, coalescing) with no
// network dependency at all, so it's fully reviewable even unexecuted.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local
// `qmltestrunner` pass before merge (same status as tst_EnvConfig.qml per
// the 2026-07-10 checkpoint).
TestCase {
    name: "OutboxStore"

    function init() {
        // Settings-backed queue — start every case from a clean, empty,
        // persisted state (mirrors ActivityLog.clear() in tst_ActivityLog.qml).
        OutboxStore.clear()
        // markFailed() jitters its delay by ±20% (SendPolicy.jittered). Pin the
        // random source at its midpoint so every existing exact-delay assertion in
        // this file keeps meaning "the base backoff value" with no jitter; the one
        // test that exercises jitter itself overrides this and restores it after.
        OutboxStore._rand = function() { return 0.5 }
    }

    // ── enqueue / enqueueBatch ───────────────────────────────────────────────

    function test_enqueue_stores_a_due_item_with_zero_attempts() {
        var before = Date.now()
        var item = OutboxStore.enqueue({
            requestId: "req-1", entity: "inventory", entityId: "sku-1",
            action: "update", before: { qty: 1 }, after: { qty: 2 }
        })

        compare(item.requestId, "req-1")
        compare(item.attempts, 0)
        verify(item.nextAttemptAt <= Date.now(), "a freshly-enqueued item must be immediately due")
        verify(item.enqueuedAt >= before)
        compare(OutboxStore.pendingCount, 1)
        compare(OutboxStore.dueItems().length, 1)
    }

    function test_enqueue_defaults_missing_before_after_to_null() {
        var item = OutboxStore.enqueue({ requestId: "req-1", entity: "inventory", entityId: "sku-1", action: "create" })
        compare(item.before, null)
        compare(item.after, null)
    }

    function test_enqueueBatch_stores_the_items_array_not_singular_fields() {
        var item = OutboxStore.enqueueBatch({
            requestId: "batch-1", entity: "order",
            items: [{ entityId: "o1", action: "update", before: null, after: { status: "done" } }]
        })

        compare(item.requestId, "batch-1")
        verify(Array.isArray(item.items), "batch items must carry an items[] array")
        compare(item.items.length, 1)
        compare(item.items[0].entityId, "o1")
        compare(item.attempts, 0)
        compare(OutboxStore.pendingCount, 1, "a batch is ONE outbox item, not N")
    }

    function test_enqueue_and_enqueueBatch_coexist_in_the_same_queue() {
        OutboxStore.enqueue({ requestId: "req-1", entity: "inventory", entityId: "sku-1", action: "update" })
        OutboxStore.enqueueBatch({ requestId: "batch-1", entity: "order", items: [{ entityId: "o1", action: "update" }] })
        compare(OutboxStore.pendingCount, 2)
        compare(OutboxStore.dueItems().length, 2)
    }

    // ── dueItems ─────────────────────────────────────────────────────────────

    function test_dueItems_excludes_items_backed_off_into_the_future() {
        OutboxStore.enqueue({ requestId: "req-due", entity: "inventory", entityId: "sku-1", action: "update" })
        OutboxStore.enqueue({ requestId: "req-notdue", entity: "inventory", entityId: "sku-2", action: "update" })
        OutboxStore.markFailed("req-notdue") // pushes its nextAttemptAt into the future

        var due = OutboxStore.dueItems()
        compare(due.length, 1)
        compare(due[0].requestId, "req-due")
    }

    // ── markSent ─────────────────────────────────────────────────────────────

    function test_markSent_removes_only_the_matching_item() {
        OutboxStore.enqueue({ requestId: "req-1", entity: "inventory", entityId: "sku-1", action: "update" })
        OutboxStore.enqueue({ requestId: "req-2", entity: "inventory", entityId: "sku-2", action: "update" })
        OutboxStore.markSent("req-1")

        compare(OutboxStore.pendingCount, 1)
        compare(OutboxStore.dueItems()[0].requestId, "req-2")
    }

    // ── markFailed / backoff ─────────────────────────────────────────────────

    function test_markFailed_follows_the_documented_backoff_schedule() {
        // 2s, 8s, 30s, 2m, 10m, then capped at 10m — see OutboxStore._backoffMs.
        var schedule = [2000, 8000, 30000, 120000, 600000]
        OutboxStore.enqueue({ requestId: "req-1", entity: "inventory", entityId: "sku-1", action: "update" })

        for (var i = 0; i < schedule.length; ++i) {
            var beforeFail = Date.now()
            OutboxStore.markFailed("req-1")
            var item = OutboxStore.items[0]
            compare(item.attempts, i + 1)
            var delay = item.nextAttemptAt - beforeFail
            verify(Math.abs(delay - schedule[i]) < 500, "attempt " + (i + 1) + " delay ~" + schedule[i] + "ms, got " + delay)
        }
    }

    function test_markFailed_caps_backoff_after_the_schedule_is_exhausted() {
        OutboxStore.enqueue({ requestId: "req-1", entity: "inventory", entityId: "sku-1", action: "update" })
        for (var i = 0; i < 8; ++i) OutboxStore.markFailed("req-1") // well past the 5-entry schedule

        var item = OutboxStore.items[0]
        compare(item.attempts, 8)
        var delay = item.nextAttemptAt - Date.now()
        verify(Math.abs(delay - 600000) < 500, "must cap at the last schedule entry (10m), not keep growing")
    }

    function test_markFailed_does_not_touch_other_items() {
        OutboxStore.enqueue({ requestId: "req-1", entity: "inventory", entityId: "sku-1", action: "update" })
        OutboxStore.enqueue({ requestId: "req-2", entity: "inventory", entityId: "sku-2", action: "update" })
        OutboxStore.markFailed("req-1")

        var untouched = OutboxStore.items.find(function(it) { return it.requestId === "req-2" })
        compare(untouched.attempts, 0)
    }

    // ── nextDueInMs ──────────────────────────────────────────────────────────

    function test_nextDueInMs_is_negative_one_when_empty() {
        compare(OutboxStore.nextDueInMs(), -1)
    }

    function test_nextDueInMs_reports_the_soonest_pending_item() {
        OutboxStore.enqueue({ requestId: "req-soon", entity: "inventory", entityId: "sku-1", action: "update" })
        OutboxStore.enqueue({ requestId: "req-later", entity: "inventory", entityId: "sku-2", action: "update" })
        OutboxStore.markFailed("req-later") // ~2s out
        OutboxStore.markFailed("req-later") // ~8s out — now clearly the later of the two

        var soonest = OutboxStore.nextDueInMs()
        verify(soonest >= 0 && soonest < 8000, "the untouched req-soon item is still due now")
    }

    // ── persistence across relaunch ──────────────────────────────────────────
    // No real process relaunch available in a TestCase. Instead: enqueue,
    // then re-invoke the same load path the app calls on startup
    // (Component.onCompleted → _load()) and confirm the queue survives —
    // this exercises the actual save/load contract via the real QSettings-
    // backed store, not a re-implementation of it.

    function test_persists_across_a_simulated_relaunch() {
        OutboxStore.enqueue({ requestId: "req-1", entity: "inventory", entityId: "sku-1", action: "update", after: { qty: 5 } })
        OutboxStore._load() // re-read from Settings, as if the app had just started

        compare(OutboxStore.pendingCount, 1)
        compare(OutboxStore.items[0].requestId, "req-1")
        compare(OutboxStore.items[0].after.qty, 5)
    }

    // ── clear ────────────────────────────────────────────────────────────────

    function test_clear_empties_the_queue_and_the_persisted_state() {
        OutboxStore.enqueue({ requestId: "req-1", entity: "inventory", entityId: "sku-1", action: "update" })
        OutboxStore.clear()
        compare(OutboxStore.pendingCount, 0)

        OutboxStore._load() // confirm the persisted copy was wiped too, not just in-memory
        compare(OutboxStore.pendingCount, 0)
    }

    // ── hasPending ───────────────────────────────────────────────────────────

    function test_hasPending_tracks_queue_occupancy() {
        compare(OutboxStore.hasPending(), false)
        OutboxStore.enqueue({ requestId: "req-1", entity: "inventory", entityId: "sku-1", action: "update" })
        compare(OutboxStore.hasPending(), true)
        OutboxStore.markSent("req-1")
        compare(OutboxStore.hasPending(), false)
    }

    // ── Component 1: single-flight-per-record coalescing ────────────────────

    function test_enqueue_coalesces_second_call_for_same_key_when_not_in_flight() {
        OutboxStore.enqueue({ requestId: "r1", entity: "order", entityId: "o1", action: "update",
                               before: { status: "pending" }, after: { status: "pending" } })
        OutboxStore.enqueue({ requestId: "r2", entity: "order", entityId: "o1", action: "update",
                               before: { status: "pending" }, after: { status: "completed" } })

        compare(OutboxStore.items.length, 1, "two calls for the same order should merge into one item")
        compare(OutboxStore.items[0].requestId, "r1", "keeps the FIRST item's requestId/before/action")
        compare(OutboxStore.items[0].before.status, "pending")
        compare(OutboxStore.items[0].after.status, "completed", "takes the LATEST after")
    }

    function test_enqueue_does_not_coalesce_calls_for_different_keys() {
        OutboxStore.enqueue({ requestId: "r1", entity: "order", entityId: "o1", action: "update",
                               before: {}, after: { status: "completed" } })
        OutboxStore.enqueue({ requestId: "r2", entity: "order", entityId: "o2", action: "update",
                               before: {}, after: { status: "completed" } })

        compare(OutboxStore.items.length, 2, "different entityIds must never merge")
    }

    function test_enqueue_does_not_coalesce_calls_for_different_entities_same_id_string() {
        // Defends the key format itself (entity + "/" + entityId) — two
        // different entities that happen to share an id string must not
        // collide onto the same key.
        OutboxStore.enqueue({ requestId: "r1", entity: "order", entityId: "1", action: "update",
                               before: {}, after: { a: 1 } })
        OutboxStore.enqueue({ requestId: "r2", entity: "staff", entityId: "1", action: "update",
                               before: {}, after: { b: 2 } })

        compare(OutboxStore.items.length, 2)
    }

    function test_markInFlight_then_dueItems_excludes_that_item() {
        var item = OutboxStore.enqueue({ requestId: "r1", entity: "order", entityId: "o1",
                                          action: "update", before: {}, after: { status: "completed" } })
        OutboxStore.markInFlight(item)

        compare(OutboxStore.dueItems().length, 0, "an in-flight item must not be picked up again")
    }

    function test_clearInFlight_makes_the_item_due_again() {
        var item = OutboxStore.enqueue({ requestId: "r1", entity: "order", entityId: "o1",
                                          action: "update", before: {}, after: { status: "completed" } })
        OutboxStore.markInFlight(item)
        OutboxStore.clearInFlight(item)

        compare(OutboxStore.dueItems().length, 1)
    }

    function test_enqueue_does_not_mutate_an_in_flight_items_payload() {
        // The critical bug this design fixes: a second call arriving while
        // the first is already dispatched must NOT rewrite the in-flight
        // item's `after` — that payload is already on the wire. It must be
        // appended as a separate, held item instead.
        var item = OutboxStore.enqueue({ requestId: "r1", entity: "order", entityId: "o1",
                                          action: "update", before: { status: "pending" },
                                          after: { status: "pending" } })
        OutboxStore.markInFlight(item)

        OutboxStore.enqueue({ requestId: "r2", entity: "order", entityId: "o1", action: "update",
                               before: { status: "pending" }, after: { status: "completed" } })

        compare(OutboxStore.items.length, 2, "in-flight item + one held item, not merged")
        var inFlightItem = OutboxStore.items[0]
        compare(inFlightItem.requestId, "r1")
        compare(inFlightItem.after.status, "pending",
                "the in-flight item's payload must be untouched by the later arrival")
    }

    function test_multiple_arrivals_during_a_hold_collapse_into_one_held_item() {
        var item = OutboxStore.enqueue({ requestId: "r1", entity: "order", entityId: "o1",
                                          action: "update", before: {}, after: { n: 1 } })
        OutboxStore.markInFlight(item)

        OutboxStore.enqueue({ requestId: "r2", entity: "order", entityId: "o1", action: "update",
                               before: {}, after: { n: 2 } })
        OutboxStore.enqueue({ requestId: "r3", entity: "order", entityId: "o1", action: "update",
                               before: {}, after: { n: 3 } })
        OutboxStore.enqueue({ requestId: "r4", entity: "order", entityId: "o1", action: "update",
                               before: {}, after: { n: 4 } })

        compare(OutboxStore.items.length, 2,
                "three arrivals during one hold must collapse into a single held item, not pile up")
        var held = OutboxStore.items[1]
        compare(held.after.n, 4, "the held item reflects only the LATEST arrival")
    }

    function test_held_item_becomes_sendable_the_instant_the_predecessor_clears() {
        var item = OutboxStore.enqueue({ requestId: "r1", entity: "order", entityId: "o1",
                                          action: "update", before: {}, after: { n: 1 } })
        OutboxStore.markInFlight(item)
        OutboxStore.enqueue({ requestId: "r2", entity: "order", entityId: "o1", action: "update",
                               before: {}, after: { n: 2 } })
        compare(OutboxStore.dueItems().length, 0, "held item must not be sendable while r1 is in flight")

        OutboxStore.markSent("r1") // r1 succeeded and was removed from the queue
        OutboxStore.clearInFlight(item)

        var due = OutboxStore.dueItems()
        compare(due.length, 1)
        compare(due[0].after.n, 2)
    }

    function test_batch_in_flight_blocks_a_single_item_enqueue_for_a_member_entityId() {
        var batch = OutboxStore.enqueueBatch({
            requestId: "b1", entity: "order",
            items: [{ entityId: "o1", action: "update", before: {}, after: { status: "completed" } },
                    { entityId: "o2", action: "update", before: {}, after: { status: "completed" } }]
        })
        OutboxStore.markInFlight(batch)

        OutboxStore.enqueue({ requestId: "r-solo", entity: "order", entityId: "o2",
                               action: "update", before: {}, after: { status: "cancelled" } })

        compare(OutboxStore.dueItems().length, 0,
                "a single-item mutation for a member of an in-flight batch must wait for the whole batch")
    }

    // ── Component 1: delta calls (enqueueDelta) — sums on coalesce, not latest-wins ──
    // (design doc §3/§6 note: the one place the merge rule differs by kind —
    // two stock deductions queued together should both apply, not one clobber the other)

    function test_enqueueDelta_stores_deltas_and_floors() {
        var item = OutboxStore.enqueueDelta({ requestId: "d1", entity: "stock_batch", entityId: "b1",
                                               deltas: { qtyRemaining: -3 }, floors: { qtyRemaining: 0 } })
        compare(item.deltas.qtyRemaining, -3)
        compare(item.floors.qtyRemaining, 0)
    }

    function test_enqueueDelta_sums_when_coalesced_instead_of_taking_latest() {
        OutboxStore.enqueueDelta({ requestId: "d1", entity: "stock_batch", entityId: "b1",
                                    deltas: { qtyRemaining: -3 }, floors: { qtyRemaining: 0 } })
        OutboxStore.enqueueDelta({ requestId: "d2", entity: "stock_batch", entityId: "b1",
                                    deltas: { qtyRemaining: -2 }, floors: { qtyRemaining: 0 } })

        compare(OutboxStore.items.length, 1)
        compare(OutboxStore.items[0].deltas.qtyRemaining, -5, "deltas for the same key sum, they don't replace")
    }

    function test_enqueueDelta_does_not_mutate_an_in_flight_deltas_payload() {
        var item = OutboxStore.enqueueDelta({ requestId: "d1", entity: "stock_batch", entityId: "b1",
                                               deltas: { qtyRemaining: -3 }, floors: { qtyRemaining: 0 } })
        OutboxStore.markInFlight(item)
        OutboxStore.enqueueDelta({ requestId: "d2", entity: "stock_batch", entityId: "b1",
                                    deltas: { qtyRemaining: -2 }, floors: { qtyRemaining: 0 } })

        compare(OutboxStore.items.length, 2)
        compare(OutboxStore.items[0].deltas.qtyRemaining, -3, "in-flight delta payload must be untouched")
        compare(OutboxStore.items[1].deltas.qtyRemaining, -2, "held as a separate item, not merged in")
    }

    // ── Persistence across a simulated relaunch (SKILLS Skill 41) ───────────
    // The actual regression test for the QSettings org-identifier fix: without
    // it, _settings.itemsJson silently no-ops under qmltestrunner (Settings
    // never resolves a real file, so this test would fail -- pendingCount
    // would come back 0, not 1 -- proving the durability contract was never
    // exercised before now). Simulates "relaunch" by wiping only the
    // in-memory `items`, leaving the persisted `_settings.itemsJson`
    // untouched, then re-running the same `_load()` path Component.onCompleted
    // calls on construction -- can't literally destroy/reconstruct the
    // singleton within one qmltestrunner process, so this is the equivalent
    // real exercise of "does data survive independent of in-memory state".

    function test_persists_and_reloads_via_settings_across_a_simulated_relaunch() {
        OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "sku-1", action: "update",
                               before: { qty: 1 }, after: { qty: 2 } })
        compare(OutboxStore.pendingCount, 1)

        OutboxStore.items = [] // simulate pre-_load() in-memory state after a relaunch
        OutboxStore._load()    // simulate Component.onCompleted on the next launch

        compare(OutboxStore.pendingCount, 1,
                "must reload the persisted item after a simulated relaunch -- if this is 0, " +
                "Settings never actually wrote to a real file")
        compare(OutboxStore.items[0].requestId, "r1")
        compare(OutboxStore.items[0].after.qty, 2)
    }

    function test_clear_removes_the_persisted_file_contents_too_not_just_memory() {
        OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "sku-1", action: "update" })
        OutboxStore.clear()

        OutboxStore.items = []
        OutboxStore._load()

        compare(OutboxStore.pendingCount, 0,
                "clear() must wipe the persisted file too, or a cleared queue would come back after relaunch")
    }

    // -- operation items (atomic order completion, C-3) -----------------------
    // docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md

    function _op(id, entities) {
        var ops = []
        for (var i = 0; i < entities.length; ++i)
            ops.push({ kind: "delta", entity: entities[i][0], entityId: entities[i][1], deltas: { n: -1 }, floors: {}, clamps: {} })
        return { requestId: id, opType: "completeOrder", ops: ops }
    }

    function test_enqueueOperation_appends_a_durable_item() {
        var item = OutboxStore.enqueueOperation(_op("completeOrder:o1:1", [["inventory", "p1"], ["order", "o1"]]))
        compare(item.requestId, "completeOrder:o1:1")
        compare(item.opType, "completeOrder")
        compare(item.ops.length, 2)
        compare(item.attempts, 0)
        compare(OutboxStore.items.length, 1)
    }

    function test_enqueueOperation_with_a_queued_key_returns_the_existing_item_and_adds_nothing() {
        var a = OutboxStore.enqueueOperation(_op("k1", [["inventory", "p1"]]))
        var b = OutboxStore.enqueueOperation(_op("k1", [["inventory", "p1"], ["inventory", "p2"]]))
        compare(OutboxStore.items.length, 1)
        compare(b.requestId, a.requestId)
        compare(b.ops.length, 1, "the first payload wins; the same key never queues twice")
    }

    function test_keysForItem_lists_every_distinct_entity_the_operation_touches() {
        var item = _op("k1", [["inventory", "p1"], ["inventory", "p1"], ["order", "o1"]])
        var keys = OutboxStore._keysForItem(item)
        compare(keys.length, 2)
        verify(keys.indexOf("inventory/p1") >= 0)
        verify(keys.indexOf("order/o1") >= 0)
    }

    function test_operation_is_never_a_coalescing_target_for_plain_calls_or_deltas() {
        OutboxStore.enqueueOperation(_op("k1", [["inventory", "p1"]]))
        OutboxStore.enqueueDelta({ requestId: "d1", entity: "inventory", entityId: "p1", deltas: { stock: -1 } })
        OutboxStore.enqueue({ requestId: "m1", entity: "inventory", entityId: "p1", action: "update", before: null, after: {} })
        compare(OutboxStore.items.length, 3)
        compare(OutboxStore.items[0].ops.length, 1, "the operation item itself must be untouched by either coalescer")
    }

    function test_an_in_flight_operation_blocks_every_item_touching_its_keys() {
        var op = OutboxStore.enqueueOperation(_op("k1", [["inventory", "p1"], ["order", "o1"]]))
        OutboxStore.enqueue({ requestId: "m1", entity: "order", entityId: "o1", action: "update", before: null, after: {} })
        OutboxStore.enqueue({ requestId: "m2", entity: "order", entityId: "o2", action: "update", before: null, after: {} })
        OutboxStore.markInFlight(op)
        var due = OutboxStore.dueItems()
        compare(due.length, 1)
        compare(due[0].requestId, "m2", "only the item on an unrelated key may go")
    }

    function test_dueItems_never_returns_two_items_that_share_a_key_in_one_pass() {
        OutboxStore.enqueueOperation(_op("k1", [["order", "o1"]]))
        OutboxStore.enqueue({ requestId: "m1", entity: "order", entityId: "o1", action: "update", before: null, after: {} })
        OutboxStore.enqueue({ requestId: "m2", entity: "order", entityId: "o9", action: "update", before: null, after: {} })
        var due = OutboxStore.dueItems()
        compare(due.length, 2)
        compare(due[0].requestId, "k1", "oldest first")
        compare(due[1].requestId, "m2", "the later item on the same key waits for the next drain")
    }

    function test_markFailed_jitters_the_backoff_within_the_band() {
        OutboxStore.enqueueOperation(_op("k1", [["order", "o1"]]))
        var saved = OutboxStore._rand
        OutboxStore._rand = function() { return 0 }
        var before = Date.now()
        OutboxStore.markFailed("k1")
        var low = OutboxStore.items[0].nextAttemptAt - before
        OutboxStore._rand = function() { return 0.999999 }
        OutboxStore.markFailed("k1")   // second attempt: 8000ms base
        var high = OutboxStore.items[0].nextAttemptAt - Date.now()
        OutboxStore._rand = saved
        verify(low >= 1600 - 50 && low <= 1600 + 50, "attempt 1 at rand 0 is ~2000*0.8, got " + low)
        verify(high >= 9600 - 50 && high <= 9600, "attempt 2 at rand ~1 is ~8000*1.2, got " + high)
    }

    // ── hasPendingForEntity (2026-09-21 photos feature, Trap 1) ─────────────
    // A photo for a product created offline must wait until that product's
    // own "create" mutation has landed, or the server's uploadProductPhoto
    // would 404 (design spec, "Two traps found in the existing code").

    function test_hasPendingForEntity_true_right_after_enqueue() {
        OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "prod-1", action: "create" })
        compare(OutboxStore.hasPendingForEntity("inventory", "prod-1"), true)
    }

    function test_hasPendingForEntity_false_once_the_item_is_sent() {
        OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "prod-1", action: "create" })
        OutboxStore.markSent("r1")
        compare(OutboxStore.hasPendingForEntity("inventory", "prod-1"), false)
    }

    function test_hasPendingForEntity_false_for_an_unrelated_entityId() {
        OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "prod-1", action: "create" })
        compare(OutboxStore.hasPendingForEntity("inventory", "prod-2"), false)
    }

    function test_hasPendingForEntity_false_for_the_same_entityId_under_a_different_entity() {
        // "inventory"/prod-1 pending must not block a photo gate keyed on a
        // different entity string that happens to share the same id value.
        OutboxStore.enqueue({ requestId: "r1", entity: "stock_batch", entityId: "prod-1", action: "delete" })
        compare(OutboxStore.hasPendingForEntity("inventory", "prod-1"), false)
    }

    function test_hasPendingForEntity_true_while_the_item_is_in_flight_not_just_when_merely_queued() {
        var item = OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "prod-1", action: "update" })
        OutboxStore.markInFlight(item)
        compare(OutboxStore.hasPendingForEntity("inventory", "prod-1"), true)
    }

    function test_hasPendingForEntity_true_for_an_entityId_inside_a_pending_batch_item() {
        OutboxStore.enqueueBatch({
            requestId: "batch-1", entity: "inventory",
            items: [{ entityId: "prod-1", action: "update" }, { entityId: "prod-2", action: "update" }]
        })
        compare(OutboxStore.hasPendingForEntity("inventory", "prod-1"), true)
        compare(OutboxStore.hasPendingForEntity("inventory", "prod-2"), true)
        compare(OutboxStore.hasPendingForEntity("inventory", "prod-3"), false)
    }

    function test_hasPendingForEntity_true_for_a_pending_delta_item() {
        OutboxStore.enqueueDelta({ requestId: "d1", entity: "inventory", entityId: "prod-1", deltas: { qty: -1 } })
        compare(OutboxStore.hasPendingForEntity("inventory", "prod-1"), true)
    }

    function test_hasPendingForEntity_false_on_an_empty_queue() {
        compare(OutboxStore.hasPendingForEntity("inventory", "prod-1"), false)
    }


    // ── retryNow / isInFlight / inFlightCount (stuck-writes dialog, S1) ─────

    function _failedItem(id, entityId, n) {
        OutboxStore.enqueue({ requestId: id, entity: "order", entityId: entityId, action: "update", after: { v: 1 } })
        for (var i = 0; i < n; ++i) OutboxStore.markFailed(id)
    }

    function _find(id) {
        return OutboxStore.items.filter(function(i) { return i.requestId === id })[0]
    }

    function test_retryNow_makes_a_backed_off_item_due_with_fresh_attempts() {
        _failedItem("r1", "o1", 5)
        verify(_find("r1").nextAttemptAt > Date.now(), "precondition: backed off")
        compare(_find("r1").attempts, 5)
        var before = Date.now()
        compare(OutboxStore.retryNow("r1"), true)
        compare(_find("r1").attempts, 0)
        verify(_find("r1").nextAttemptAt >= before && _find("r1").nextAttemptAt <= Date.now())
        compare(OutboxStore.dueItems().length, 1)
        compare(OutboxStore.nextDueInMs(), 0)
    }

    function test_after_retryNow_the_next_failure_restarts_the_backoff_at_the_first_step() {
        _failedItem("r1", "o1", 5)
        OutboxStore.retryNow("r1")
        var t0 = Date.now()
        OutboxStore.markFailed("r1")
        compare(_find("r1").attempts, 1)
        var delay = _find("r1").nextAttemptAt - t0
        verify(delay >= 1900 && delay <= 2100, "expected ~2s, got " + delay)
    }

    function test_retryNow_unknown_id_returns_false_and_changes_nothing() {
        _failedItem("r1", "o1", 3)
        var snapshot = JSON.stringify(OutboxStore.items)
        compare(OutboxStore.retryNow("nope"), false)
        compare(OutboxStore.retryNow(""), false)
        compare(OutboxStore.retryNow(undefined), false)
        compare(JSON.stringify(OutboxStore.items), snapshot)
    }

    function test_retryNow_on_an_in_flight_item_is_a_no_op() {
        _failedItem("r1", "o1", 3)
        var item = _find("r1")
        OutboxStore.markInFlight(item)
        var snapshot = JSON.stringify(OutboxStore.items)
        compare(OutboxStore.retryNow("r1"), false)
        compare(JSON.stringify(OutboxStore.items), snapshot)
    }

    function test_retryNow_works_again_once_the_item_is_no_longer_in_flight() {
        _failedItem("r1", "o1", 3)
        var item = _find("r1")
        OutboxStore.markInFlight(item)
        OutboxStore.clearInFlight(item)
        compare(OutboxStore.retryNow("r1"), true)
    }

    function test_retryNow_touches_only_the_named_item() {
        _failedItem("r1", "o1", 4)
        _failedItem("r2", "o2", 4)
        var other = JSON.stringify(_find("r2"))
        OutboxStore.retryNow("r1")
        compare(JSON.stringify(_find("r2")), other)
    }

    function test_retryNow_keeps_the_payload_and_identity() {
        _failedItem("r1", "o1", 2)
        var enq = _find("r1").enqueuedAt
        OutboxStore.retryNow("r1")
        var it = _find("r1")
        compare(it.requestId, "r1")
        compare(it.entityId, "o1")
        compare(it.after.v, 1)
        compare(it.enqueuedAt, enq)
        compare(OutboxStore.pendingCount, 1)
    }

    function test_retryNow_works_for_batch_delta_and_operation_items() {
        OutboxStore.enqueueBatch({ requestId: "b1", entity: "inventory", items: [{ entityId: "p1", action: "update" }] })
        OutboxStore.enqueueDelta({ requestId: "d1", entity: "inventory", entityId: "p2", deltas: { stock: -1 } })
        OutboxStore.enqueueOperation({ requestId: "op1", opType: "completeOrder", ops: [{ entity: "order", entityId: "o9" }] })
        var ids = ["b1", "d1", "op1"]
        for (var i = 0; i < ids.length; ++i) {
            OutboxStore.markFailed(ids[i]); OutboxStore.markFailed(ids[i])
            compare(OutboxStore.retryNow(ids[i]), true, ids[i])
            compare(_find(ids[i]).attempts, 0, ids[i])
        }
        compare(OutboxStore.dueItems().length, 3)
    }

    function test_retryNow_survives_a_simulated_relaunch() {
        _failedItem("r1", "o1", 5)
        OutboxStore.retryNow("r1")
        OutboxStore._load()
        compare(_find("r1").attempts, 0)
        compare(OutboxStore.dueItems().length, 1)
    }

    function test_retryNow_bumps_revision_only_when_it_changes_something() {
        _failedItem("r1", "o1", 2)
        var rev = OutboxStore.revision
        OutboxStore.retryNow("nope")
        compare(OutboxStore.revision, rev)
        OutboxStore.retryNow("r1")
        verify(OutboxStore.revision > rev)
    }

    function test_isInFlight_and_inFlightCount_track_markInFlight_and_clearInFlight() {
        _failedItem("r1", "o1", 1)
        var item = _find("r1")
        compare(OutboxStore.isInFlight("r1"), false)
        compare(OutboxStore.inFlightCount, 0)
        OutboxStore.markInFlight(item)
        compare(OutboxStore.isInFlight("r1"), true)
        compare(OutboxStore.inFlightCount, 1)
        OutboxStore.clearInFlight(item)
        compare(OutboxStore.isInFlight("r1"), false)
        compare(OutboxStore.inFlightCount, 0)
    }

    function test_isInFlight_true_for_a_batch_via_any_of_its_keys() {
        OutboxStore.enqueueBatch({ requestId: "b1", entity: "inventory", items: [{ entityId: "p1" }, { entityId: "p2" }] })
        OutboxStore.markInFlight(_find("b1"))
        compare(OutboxStore.isInFlight("b1"), true)
        compare(OutboxStore.isInFlight("other"), false)
    }

    function test_clear_resets_in_flight_state() {
        _failedItem("r1", "o1", 1)
        OutboxStore.markInFlight(_find("r1"))
        OutboxStore.clear()
        compare(OutboxStore.isInFlight("r1"), false)
        compare(OutboxStore.inFlightCount, 0)
    }

    function test_monkey_retryNow_never_breaks_queue_invariants() {
        var s = 7
        var rnd = function() { s = (s * 1664525 + 1013904223) % 4294967296; return s / 4294967296 }
        var entities = ["m1", "m2", "m3"]
        for (var step = 0; step < 300; ++step) {
            var r = rnd()
            var n = OutboxStore.items.length
            var it = n > 0 ? OutboxStore.items[Math.floor(rnd() * n)] : null
            if (r < 0.3 || !it) {
                // Unique requestId per call, as Gateway mints them.
                var e = entities[Math.floor(rnd() * entities.length)]
                OutboxStore.enqueue({ requestId: "req-" + step, entity: "order", entityId: e, action: "update", after: { s: step } })
            }
            else if (r < 0.5) OutboxStore.markFailed(it.requestId)
            else if (r < 0.65) OutboxStore.markInFlight(it)
            else if (r < 0.75) OutboxStore.clearInFlight(it)
            else if (r < 0.9) {
                var wasInFlight = OutboxStore.isInFlight(it.requestId)
                compare(OutboxStore.retryNow(it.requestId), !wasInFlight, "step " + step)
            }
            else { OutboxStore.clearInFlight(it); OutboxStore.markSent(it.requestId) }
            var seen = {}
            for (var i = 0; i < OutboxStore.items.length; ++i) {
                var q = OutboxStore.items[i]
                verify(!seen[q.requestId], "duplicate id at step " + step)
                seen[q.requestId] = true
                verify(q.attempts >= 0, "attempts at step " + step)
            }
            compare(OutboxStore.pendingCount, OutboxStore.items.length, "step " + step)
        }
    }
}
