# Stuck-writes dialog + Retry now (part B, slice S1) — design

**Date:** 2026-09-29. **Branch:** `feat/2026-09-29-stuck-writes-dialog-retry-now`.
**Plan:** `2026-09-29-gateway-park-retry-discard-plan.md` (S1 row). P1-P4 stand; nothing here changes them.
**Scope:** tappable header caption -> one dialog listing stuck writes -> per-row Retry now. No persistence, no park, no Discard, no server change.
**Path:** bounded (existing flow, one plan row). Decisions below were made in a single pass per the standing rule; each is overrulable in the PR.

## What shipped

| Piece | File |
|---|---|
| Row label (pure) | `qml/helper/DescribeItem.js` (`describe(item)` -> `{title, detail}`) |
| Row list + stuck lookup (pure) | `qml/helper/StuckWrites.js` (`isStuck`, `rows`) |
| Make an item due now | `OutboxStore.retryNow(requestId)`, `isInFlight`, `inFlightCount` |
| Gateway API | `Gateway.stuckRows()`, `Gateway.retryStuck(requestId)` |
| UI | `qml/pages/StuckWritesSheet.qml` (BottomSheet), `Main.qml` `openStuckWrites()` + back-button list, `GlassHeader` caption tap |

## Decisions and trade-offs

**D1. Retry keeps the stuck flag (deviates from plan wording).** The plan's Retry line says "drop the requestId from `StuckWrites` state". That is right for a *parked* item (S2). In S1 nothing is parked, and dropping the flag has a bad failure mode: the user taps Retry, the header line and the row vanish, the server rejects it again, and the user sees nothing for ~3 minutes (5 more failures). The only signal that a write is broken would go dark right after the user asked about it. Chosen: `retryStuck` resets attempts and makes the item due, and leaves `stuck` / `terminal` alone. Only leaving the outbox clears it (`_pruneStuck`, unchanged). Cost: after a retry that fails, the row looks the same as before (no "retry failed" proof beyond the row returning from "Sending..." to "Not syncing"). Alternative kept: drop the flag, accept the silent window. Revisit when S2 lands its own Retry.

**D2. Reset `attempts` to 0 on retry.** Backoff restarts at ~2 s, so the user sees the outcome in seconds, not after a 10-minute step. Cost: a persistently failing write gets ~5 fast attempts after each tap (5 requests, ~3 min), not one. Bounded by the user tapping; no auto-loop.

**D3. In-flight write cannot be retried.** `retryNow` returns false, the button is disabled and the row says "Sending...". A second send would race the first; idempotency by requestId would make it safe on the server, but there is no reason to send twice.

**D4. Labels come from the item only.** Pure JS, no store lookups. A stock delta shows "Stock change" + the record id, not the product name (the item carries no name). Cost: an opaque id for delta rows. Alternative: pass a `nameOf(entity, id)` lookup from Gateway; deferred (extra coupling for one row kind). Batches show a count only.

**D5. Caption is the entry point: underline + wider hit area, wording unchanged.** No "Tap to review" text (the caption already elides on narrow phones). Cost: discoverability relies on the underline. Only tappable while online and stuck; offline keeps the offline message and is inert.

**D6. Rows are a function, re-read off three signals.** `stuckRows()` reads live state; the sheet re-evaluates on `Gateway.stuckCount`, `OutboxStore.revision`, `OutboxStore.inFlightCount` (new, public, so the sheet does not touch `_inFlightKeys`). Same watcher idiom as `NotificationsSheet`. A stuck id that already left the outbox is skipped, so no ghost row before the next prune.

**D7. No "Retry all", no auto-close on empty.** Plan lists per-row Retry only; with 20+ rows that is tedious but S2/S3 will reshape the list anyway. Empty state text: "Nothing is stuck right now."

**D8. Sheet is first in the `Main.qml` back-button list.** Nothing opens above it in S1 (the header is under a modal overlay while any dialog is open), but S3's confirm dialog will, and the AGENTS.md rule is to hoist and put new popups first.

## Known limits (deliberate)

- The sheet's rendering and the header tap have no automated coverage (Felgo `app` context): on-device only.
- `Gateway._send*` XHR paths are untouched and still untestable headless; `retryStuck` is tested up to `drainNow()` (safe with no idToken).
- Party / Category / OrderChannel are not in scope (never touch `Gateway`).
- Server untouched: no Node tests, no rules tests, no e2e for S1 (e2e "reject, park, discard" belongs to S3).

## Next

S2 (persist stuck for all writes per P5, park terminal only). Found on device during this PR's review: the stuck state is in-memory, so a relaunch drops it (S1 keeps that as a deliberate limit; P5 fixes it in S2). Its Retry will clear the parked flag and the `StuckWrites` state, which is the plan's original wording, because a parked item has no auto-retry to lose.
