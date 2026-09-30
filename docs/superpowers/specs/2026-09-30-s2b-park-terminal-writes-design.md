# Gateway stuck writes, part B, slice S2b: park rejected writes — design

**Date:** 2026-09-30. **Branch:** `feat/2026-09-30-s2b-park-terminal-writes` (off `main` @ `0d77f9a`).
**Plan:** `2026-09-29-gateway-park-retry-discard-plan.md` (P1, P3, P5; slice S2b). **Decided by Taher 2026-09-30:** Q-S2b-1 = A (state rule), Q-S2b-2 = A (parked blocks same-key writes).
**Out of scope:** Discard + resync (S3), photos (roadmap item 4), any server change.

## Goal
A write the server has **rejected** (`write-rejected`) and that is already stuck stops auto-retrying until the user taps Retry. Transient / unknown answers keep retrying and are never parked (P1).

## Decisions

| # | Decision | Why | Cost |
|---|---|---|---|
| D1 | **Parked is derived: `stuck && terminal`.** No `parked` / `parkedAt` field. `StuckWrites.isParkedItem(item)` is the one rule, used by `OutboxStore`. | Both inputs are already persisted (S2a). A stored flag could drift from them; there is nothing to migrate or repair. Ponytail: zero new fields. | `parkedAt` is not recorded (nothing reads it today). |
| D2 | **Park rule = state rule (Q-S2b-1 A).** Parked whenever stuck AND the latest answer was rejected, so a write that first failed transiently and is rejected later also parks. | One rule, survives relaunch with no extra state. | The plan text said "on the failure that tips"; this is broader (accepted). |
| D3 | **Retry releases by clearing `terminal`** (`OutboxStore.retryNow` deletes it on the item, `Gateway.retryStuck` clears it in state). `stuck` and `failures` stay. | A rejected retry sets `terminal` again and re-parks after **one** attempt; a transient answer leaves it stuck and retrying. No new state. | Between the tap and the answer the row reads "Not syncing" (not "Rejected"); "Sending..." while in flight. |
| D4 | **Parked holds its keys (Q-S2b-2 A).** `dueItems` marks a parked item's keys claimed; `nextDueInMs` ignores the parked item and anything queued behind it on a shared key. | A later write for the same record must not overtake the parked one (Retry would then fail the CAS check and be dropped). Without the `nextDueInMs` part a blocked sibling would spin the drain timer at 0. | A record with a parked write accepts no other write until Retry (Discard in S3). Edits to a plain item still merge into the parked one (P3, unchanged). |
| D5 | **`wakeStuck` skips parked.** The launch re-check (S2a) must not send a parked write. | Parked waits for the user, not the launch. | None. |
| D6 | **Reuse `stuckTerminalCount` as the parked count.** `terminalCount` = stuck && terminal = parked. No new property. | Already published, already drives the caption. | Name says "terminal", means "parked" (commented). |
| D7 | **Copy.** Toast at the tip says "paused" when the tipping answer is a rejection; caption "N change(s) rejected by the server. Tap to retry."; row "Rejected by the server. Paused until you tap Retry."; button "Retry" on rejected rows, "Retry now" otherwise. | The old text said "keeps retrying", which is now false for these writes. | Strings only. |

## Files
`qml/helper/StuckWrites.js` (`isParkedItem`, `isParked`, `clearTerminal`), `qml/model/OutboxStore.qml` (`dueItems`, `nextDueInMs`, `wakeStuck`, `retryNow`), `qml/model/Gateway.qml` (`_noteFailure` toast, `retryStuck`), `qml/components/GlassHeader.qml`, `qml/pages/StuckWritesSheet.qml` (copy only).

## Behaviour change vs S1/S2a (by design)
A rejected stuck write used to retry on the backoff forever; it now waits for Retry. Existing tests that assumed rejected writes stay due were updated (`tst_OutboxStore`: coalesce/retryNow and wakeStuck-among-several; `tst_Gateway`: retryStuck-with-a-rejected-write).

## Risks
- A parked write with no Discard (S3 not shipped) is a dead end for a genuinely bad write: Retry is rejected again. Ship S2b and S3 to `main` together.
- Everything else on that record queues behind it (D4). The header/dialog are the only signal.
- `tst_OutboxStore` / `tst_Gateway` were not run (no Qt in the sandbox); CI is the first run.

## Next
S3: Discard + resync (`Gateway.discardParked`, `parkedWriteDiscarded`, one `DataModel` handler, confirm dialog, operation items).
