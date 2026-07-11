import QtQuick
import QtTest
import "../qml/model"

// Regression tests for the P0 compliance gateway's persisted outbox queue.
// Covers the spec's "Outbox: enqueue→drain→dequeue; persistence across
// relaunch; backoff" requirement (docs/superpowers/specs/2026-06-06-P0-
// compliance-gateway-design.md §6) plus the new-this-session batch item
// shape (enqueueBatch, backs Gateway.recordMutations).
//
// NOT covered here: actually sending (Gateway._send/_sendBatch) — that's a
// real XHR call with no mock HTTP layer in this codebase, so it's out of
// scope for a fast, deterministic unit test. See tst_Gateway.qml for what
// IS safely testable around the send path (the auth-token guard means
// gateway-mode enqueue+drain is safe to exercise without hitting the
// network; direct-mode's FirebaseService calls are not, so those aren't
// exercised here either).
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
}
