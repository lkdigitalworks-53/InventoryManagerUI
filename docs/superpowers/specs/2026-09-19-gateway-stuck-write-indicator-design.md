# Gateway stuck-write indicator — design

**Date:** 2026-09-19
**Branch / PR:** `fix/2026-09-19-gateway-send-terminal-failure`, PR #75
**Status:** approved by Taher on 2026-09-19 (decisions Q1-Q5 below).
**Source item:** `docs/superpowers/DELETE-FEATURE-ROADMAP.md` item 1 (HIGH): `Gateway._send` retries a
failed mutation forever, silently.

## Problem

A queued write that fails for a reason other than a CAS conflict is retried with backoff
(`[2s, 8s, 30s, 2m, 10m]`, last delay repeating) with no attempt cap and no signal to any caller.
Stores have already applied the change to local state optimistically, so a write that can never
succeed leaves the device showing something the server never accepted, and nobody is told.
`_sendBatch` and `_sendDelta` classify a few definitive failures as terminal, but every other 403 / 5xx
behaves the same way in all three senders. For `_sendDelta` the caller's completion callback also stays
pending forever.

## What the code trace established

- The server (`functions/index.js`, `recordMutation`) turns every `applyMutation` exception into
  `500 write-failed`. A poison write and a transient blip look identical to the client, so client-side
  classification of 5xx is not possible; only an attempt count is.
- Offline-first: status 0 (no response) must keep retrying indefinitely. 401 must keep retrying too
  (token refresh). 409 with `conflict: true` is already dropped and reported.
- Retrying is safe (the server dedupes on `requestId`). The defect is that the retry is unbounded and
  silent, not that it retries.
- The 400 validation errors are reachable only through client bugs, so classifying just those would not
  close the real gap (403 / 5xx after an optimistic delete).
- The app has no sync-status UI. `Toast` is ephemeral. `ActivityLog.record` is a poor channel: own-actor
  entries are suppressed from the bell and Notifications sheet (dashboard card only), a non-own actor would
  broadcast to every staff member's device through the tenant-wide `activity_log`, and it is a direct
  Firestore write that can fail during the outage it reports.
- `GlassHeader` already has a caption line that shows a danger-coloured "App is offline" message.

## Decisions (Taher, 2026-09-19)

| # | Question | Chosen | Rejected, and why |
|---|---|---|---|
| Q1 | Policy for a non-network, non-401, non-409 failure | **D: surface only, keep retrying** | A narrow classify + drop + rollback (catches client bugs only); B bound + park + Retry/Discard (much larger, threshold is a heuristic); C server-side classification first (largest blast radius; a mis-mapped transient error becomes silent data loss) |
| Q2 | Surface | **Toast once + local per-device indicator** | Toast only (ephemeral); own-actor ActivityLog entry (dashboard only, direct write); non-own-actor bell (leaks to other devices) |
| Q3 | Indicator implementation | **Reuse the `GlassHeader` caption line** | New dedicated strip (more visible, but new component, layout and safe-area work) |
| Q4 | Which senders | **All three: `_send`, `_sendBatch`, `_sendDelta`** | `_send` only (leaves two partial fixes, which KNOWN-ISSUES warns against) |
| Q5 | Pace | **Autonomous through spec, plan and implementation**; Taher reviews in the PR | |

## Design

### Detection (`Gateway`, helper `qml/helper/StuckWrites.js`)

- New `Gateway.stuckCount` (int). Bookkeeping lives in a pure `.pragma library` helper so it has a
  headless test: `newState()`, `isStuckStatus(status)`, `noteFailure(state, requestId, status)`,
  `stuckCount(state)`, `prune(state, liveIds)`, and `THRESHOLD = 5`.
- `isStuckStatus`: `status >= 400`, except 401 and 409. Status 0 and successes never count.
- `Gateway._noteFailure(item, status)` runs directly after each `OutboxStore.markFailed` in `_send`,
  `_sendBatch` and `_sendDelta`. The 5th server-side failure of one `requestId` (about 3 minutes with the
  current backoff) marks it stuck and raises `stuckCount`. When the count goes from 0 to 1 it shows one
  toast: "Some changes aren't syncing. The app keeps retrying."
- `Gateway._pruneStuck()` runs at the top of `_reschedule()`, which every send handler and `drainNow` end
  with. It rebuilds the set of live `requestId`s from `OutboxStore.items` and drops stuck / failure state for
  anything no longer queued. One place therefore covers success, conflict, permanent drop, coalescing and
  sign-out, instead of a clear call at each of the six `markSent` sites. `Gateway.clear()` (the
  sign-out reset) also resets the state.
- Retry, backoff, dropping and rollback behaviour are untouched.

### Surface

- `Main.qml` exposes `readonly property int syncStuckCount: Gateway.stuckCount`. `GlassHeader` reads it as
  `app.syncStuckCount`, the same way it already reads `app.isOnline` (no component under `qml/components`
  imports `../model` today).
- The caption line shows, in priority order: the offline message; else, when `syncStuckCount > 0`,
  "N change(s) not syncing. Still retrying." in `Constants.danger`; else the page subtitle.

### Behaviour by response

| Response | Counts toward stuck? | Why |
|---|---|---|
| Network error / no response (status 0) | No | Offline-first; resolves on reconnect |
| 401 | No | Token refresh path |
| 409 conflict | No | Already dropped and reported by the sender |
| 2xx | No | Success |
| 400, 403, 404, 408, 429, 5xx | Yes | Server answered and refused, or failed |

## Testing approach and its limits

- `tests/tst_StuckWrites.qml`: unit cases for every helper function and boundary, plus two seeded monkey
  tests (random failure / prune sequences against an independent reference model; "empty outbox always
  resets").
- `tests/tst_Gateway.qml`: `_noteFailure` / `_pruneStuck` / `clear()` driven with real `OutboxStore` items
  (threshold, single toast, second item, recovery, sign-out, non-counting statuses) plus one Gateway-level
  monkey test.
- Functions and Firestore rules: no server or rules change, so no new tests there.
- **Limits, stated plainly.** The `onreadystatechange` handlers cannot run under `qmltestrunner` (no mock
  HTTP layer; see the scope note in `tests/tst_Gateway.qml`), so the three one-line `_noteFailure` call
  sites are covered only by the on-device plan. `GlassHeader` needs Felgo `dp()` / `sp()` and the `app`
  root, so its caption expression is on-device only as well. 100% line coverage of the wiring is not
  reachable in CI with the current harness.

## Not fixed (follow-ups)

- Local state stays diverged from the server while a write is stuck, and there is no in-app Retry /
  Discard (option B).
- The server still returns `500 write-failed` for every write exception (option C).
- The counter is in memory, so it restarts with the app: a still-failing write raises the indicator again
  about 3 minutes after relaunch.
- If the QTBUG-49896 workaround in the senders fails to recover a status, `effStatus` reads 0 and detection
  never fires. The sender logs already print both raw and effective status.
- A stuck write does not block later writes to the same record while it waits in backoff (existing
  behaviour): the later write can hit a CAS 409 and be dropped with the "updated elsewhere" toast.
