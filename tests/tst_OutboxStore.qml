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
}
