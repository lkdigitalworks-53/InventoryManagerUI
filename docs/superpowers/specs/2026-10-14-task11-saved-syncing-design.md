# Task 11 — "Saved, syncing" hint for a queued order completion (design, 2026-10-14)

Plan source: `plans/2026-09-20-atomic-operation-outbox.md` Task 11. Re-checked against the code on PR #139's tip, not copied.

## Problem (verified in code)
`DataModel._onCompletionResult` shows an order as `completed` and calls `callback(true)` when the completion is **queued**
(offline) or the await window ran out (`SendPolicy.TIMEOUT_AWAIT_MS` = 10 s). Nothing on screen says the server has not
confirmed it yet. If the server later rejects it, PR #139 now tells the operator why (toast); until then the order looks final.

## State that already exists
`DataModel._openCompletions[key] = { orderId, attempt, clampStock, plan, undo, callback }`. An entry with `undo !== null` is
exactly "shown as completed, server not confirmed". It is a plain `var` map, so QML bindings cannot observe it.

## Design (BOUNDED)
1. `DataModel.syncingOrderIds` (`var`, `{ orderId: true }`) and `DataModel.completionsSyncing` (`int`, its size).
   A plain object mutated in place does not notify, so `_refreshSyncing()` builds a NEW object each time and assigns it.
2. Every place that shows (`open.undo = ...`) or closes (`delete _openCompletions[k]`) an entry goes through two helpers:
   `_closeOpen(key)` (delete + refresh) and `_refreshSyncing()` (called after `undo` is set). No call site recomputes by hand.
3. `OrderDetailDialog`: one quiet caption under the Status combo, `visible: dataModel.syncingOrderIds[dlg.orderId] === true`,
   text `Saved. Syncing…`, with an accessible name. Dialog behaviour is unchanged (no blocking UI, no new status).
4. Not in this slice: orders-list chip, approve-all banner wording, NewOrderDialog (see D-1).

## Decisions (defaults taken, override cost stated)
- **D-1 Where the hint shows.** A = dialog caption only (taken). B = A + a chip on the order row. C = header line.
  A: smallest, matches the plan. Weak: an operator who never reopens the order sees nothing; the header "not syncing" line
  (stuck writes) still covers a long hang. B: more visible, touches the shared `OrderRow` component, +1 test surface,
  ~+40 lines. C: rejected, the header line means "stuck" (StuckWrites), a quiet in-flight state would blur it.
- **D-2 Source of truth.** Session `_openCompletions` (taken) vs the durable `OutboxStore`. After a relaunch the stores reload
  from Firestore and the order is `pending` again until the op lands (known open gap: overlay of a queued write after relaunch),
  so a "syncing" caption on a `pending` order would mislead. Session-scoped is consistent with what the screen shows.
  Cost of choosing the Outbox later: a second source of truth plus an orderId parse from the key.
- **D-3 Per-order map, not only a count.** The plan's count alone cannot say whether THIS dialog's order is syncing
  (Approve-all can leave 5 open). Map + count, one refresh function.
- **D-4 No animation / spinner.** No reduced-motion setting exists in the project; static text is enough for a caption.

- **D-5 Parked writes (decided 2026-10-15, option B, PR #144 review).** A write the server rejected and the Gateway parked
  (`StuckWrites.isParked`: stuck AND terminal) waits for Retry/Discard; it is not syncing, and the header line already says so.
  `_refreshSyncing` skips keys for which `Gateway.isParkedKey(k)` is true, and a `stuckTerminalCount` listener refreshes when a write
  parks or is un-parked. Rejected: A keep the caption (two screens, two stories), C neutral wording (hides a real state behind vague text).
  Known limit: stuck-but-retrying (outage) keeps the caption on purpose; the count is the only signal, so a park and an un-park in one
  instant that cancel out cannot happen (every path changes it by one and refreshes).

## Honest value statement
The window is only "queued, or >10 s without an answer". With a healthy connection the hint never shows. Value is real but
modest; the higher-risk open item is restock as one atomic operation (KNOWN-ISSUES, decided 2026-09-30, unbuilt).

## Tests
`tests/tst_DataModel_completionsSyncing.qml` drives the real DataModel + Gateway + OutboxStore like
`tst_DataModel_completeOrderAtomic.qml`. Page wiring (Felgo import blocks instantiation under qmltestrunner) is guarded by a
source test in `.github/scripts/__tests__/`. Plan: `test-plans/2026-10-14-task11-saved-syncing-test-plan.md`.
