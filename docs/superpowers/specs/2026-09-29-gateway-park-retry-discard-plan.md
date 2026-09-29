# Gateway stuck writes, part B: park + Retry / Discard — scope plan

**Date:** 2026-09-29
**Status:** S1 IMPLEMENTED 2026-09-29 (`feat/2026-09-29-stuck-writes-dialog-retry-now`, see its design doc; one deliberate deviation: Retry keeps the stuck flag in S1). S2-S4 not started. Was: PLAN ONLY. No code. P1-P3 DECIDED 2026-09-29 (see Decisions). P4 not asked, default stands. Slices are sequential; one PR each.
**Builds on:** `2026-09-28-gateway-stuck-write-retry-discard-options.md` (Q2-Q4 decided there), PR #75 (indicator), PR #93 (server classification).
**Out of scope:** photo cleanup on delete (roadmap item 4), handled in a separate photos session. Interplay noted at the end.

## Code facts (traced 2026-09-29, nothing run) — two correct the 09-28 doc

1. **Party / Category / OrderChannel never touch `Gateway`.** No `recordMutation` in their stores. They cannot have a stuck write, so they need no park, no rollback, no refresh path. The 09-28 doc listed them as "need new code": stale. **Dropped from B.**
2. Entities that DO go through `Gateway`: `inventory`, `stock_batch`, `order`, `staff`, `removed_staff`, `supplier`, `transaction`. Four sender kinds: single (`_send`), batch (`_sendBatch`), delta (`_sendDelta`), operation (`_sendOperation`, multi-entity, `ops[]`).
3. **A re-pull mechanism already exists:** `syncFromFirebase()` on Inventory, StockBatch, Orders, Staff, Supplier, Transaction (called from `DataModel.qml` ~105-111). It is a full reset + refetch (`products = []`, cursor reset, paginated), not a record fetch. No single-record GET exists client-side.
4. Full resync makes **all three actions uniform**: update -> reverts to server value, delete -> record returns, create that never reached the server -> simply absent after the fetch. The 09-28 worry ("create needs its own handling") disappears.
5. `OutboxStore`: items are `{requestId, entity, entityId, action, before, after, attempts, nextAttemptAt, ...}`; no `parked` field. `dueItems()` and `nextDueInMs()` do not know about it, so a parked item would keep the drain timer spinning unless both are changed. `hasPendingForEntity()` stays true for a parked item (photo gating).
6. `enqueue()` coalesces a new edit into any not-in-flight item for the same key (keeps earliest `before`, takes latest `after`). A parked item is never in flight, so a later edit to that record merges into it.
7. `StuckWrites` state is in-memory and rebuilt from failures after relaunch. A persisted parked flag is the first stuck-related state that survives a restart, so the header count must come from the outbox for parked items.
8. Server signal from PR #93 is available: `StuckWrites.terminal[requestId]` = latest answer was `write-rejected`.

## Design (P1-P3 decided; rest PROPOSED)

- **Park rule (P1):** park only when the write tips over THRESHOLD **and** the server's latest answer was `write-rejected`. Transient / unknown 500s keep retrying and never get a Discard button. That is the whole reason C shipped first.
- **Retry:** clear `parked`, set `nextAttemptAt = now`, reset `attempts`, drop the requestId from `StuckWrites` state. If it is rejected again it re-parks after 5 more attempts.
- **Discard:** disabled while offline. Remove the item from the outbox, then emit `parkedWriteDiscarded(entity, entityId, action)`. **One** handler in `DataModel.qml` maps entity -> that store's `syncFromFirebase()` (P2). For an operation item, resync every entity in `ops[]` and finish any awaiting caller as failed via `_finishOperation`.
- **Edit while parked (P3):** unchanged coalesce path, item stays parked. Nothing new to write; the user hits Retry to send the merged version.
- **UI:** `GlassHeader` caption becomes tappable when stuck or parked count > 0 -> one dialog. Rows show a plain label (`describeItem`, pure JS), state, Retry, Discard (confirm dialog). Scrollable list for many items.
- **Persistence:** `parked: true`, `parkedAt`, `lastError` on the outbox item. Old items load without them (falsy = not parked). Sign-out already clears the whole outbox.

## Sequenced slices (each mergeable alone, none regresses behaviour)

Order chosen so no slice leaves a write with no way out. Parking before the UI exists would silently stop retrying a persisted item forever, so **parking comes after the dialog**.

| # | Slice | Ships | Tests | Risk |
|---|---|---|---|---|
| **S1** | Dialog shell + **Retry-now** on stuck (not yet parked) items | Tappable caption, `describeItem.js`, dialog listing stuck items, Retry-now (`OutboxStore.retryNow(requestId)` + `Gateway` unstick). No persistence, no Discard. | `tst_DescribeItem` (every entity x action, missing fields), `tst_OutboxStore` retryNow, `tst_Gateway` retry clears stuck state, `tst_StuckWrites` | Low. Useful today, non-destructive. Dialog render is on-device only. |
| **S2** | **Park + persist** (terminal only) | `parked/parkedAt/lastError` on outbox item, park at the tip, `dueItems`/`nextDueInMs` skip parked, `parkedCount` from outbox, caption wording, dialog shows parked with Retry. | `tst_OutboxStore` (skip in due/next-due, load old items without field, persist round trip, coalesce into parked stays parked, `clear`), `tst_StuckWrites` (park decision), `tst_Gateway` (all 4 senders park only on terminal; timeout/offline/401/409 never park) | Medium. Parked write stops auto-retry until user taps Retry; that is the intended behaviour and S1's dialog already exists. |
| **S3** | **Discard + resync** | `Gateway.discardParked(requestId)` (offline-disabled), `parkedWriteDiscarded` signal, one `DataModel` handler, confirm dialog, operation-item handling. | `tst_Gateway` (discard removes item, emits once, refuses offline, unknown id no-op, operation item resyncs each entity and fails the awaiting caller), `tst_DataModel` handler per entity, e2e against the emulator: reject a write, park, discard, store equals server | Highest (destructive). Last on purpose. |
| **S4** | Cleanup pass | Roadmap + KNOWN-ISSUES closed, README, SKILLS entry, AGENTS entry, test plans consolidated. | none new | None |

Each slice also ships its own test plan (Skill 49 template: unit, functional, rules, e2e, on-device, happy / negative / edge / multi-scenario / monkey). Server code is untouched in B, so no Node tests are planned; say so in each test plan rather than pad.

### Monkey / edge cases to bake into the plans

Tap Retry and Discard repeatedly; relaunch mid-dialog; item leaves the outbox (sent by another path) while the dialog is open; parked item + new edit + relaunch; two parked items for one record (in-flight then edit); 20+ parked items; sign out with parked items; go offline while the confirm dialog is open; discard a create whose record already has photos queued; discard an operation whose awaiting caller already timed out.

## Decisions (Taher, 2026-09-29)

| # | Question | Chosen | Consequence |
|---|---|---|---|
| P1 | Park trigger | **Terminal-only** (`write-rejected`) | Unknown / transient 500s never park and never offer Discard. A real server bug that answers `write-failed` retries forever (accepted). |
| P2 | Discard re-pull | **One `DataModel` handler, each store's existing full `syncFromFirebase()`** | List resets, first page refills, other pending edits hidden until they land or next resync (accepted). No new REST path. |
| P3 | Edit while parked | **Merge into the parked item, stay parked** | Zero new code. New edit stays stuck until user taps Retry. Dialog must make that obvious. |
| P4 | Slice order | **Not asked. Default stands:** S1 dialog + Retry-now, S2 park, S3 Discard | Next session starts S1; Taher can overrule in the PR. |

## Alternatives considered (kept for the record)

- **P1 park trigger.** PROPOSED terminal-only. Cost: an unknown `write-failed` 500 that is really a server bug has no escape hatch, only auto-retry forever. Alternative: also park unknown 500s after a longer window, with a stronger confirm on Discard.
- **P2 discard mechanism.** PROPOSED full-store resync via one `DataModel` handler. Cost: the store list resets and refills only the first page; unrelated pending edits are hidden until they land or the next resync. Alternative: per-record fetch (new REST path, code in 6 stores, more tests).
- **P3 edit while parked.** PROPOSED coalesce and stay parked. Alternative: auto-unpark on merge (a fixed edit heals itself but a still-bad edit re-hammers the server for 3 minutes), or block edits to that record.
- **P4 slice order.** PROPOSED S1 dialog/Retry-now, S2 park, S3 Discard. Alternative: park first, but that ships a silent stop with no exit.

## Interplay with photos (for the consolidation session)

- A parked `inventory` create keeps `hasPendingForEntity` true, so photos queued for that product wait. Discarding it later means those photos 404 and end `failed` in `PhotoQueue`, the same shape as the G2 gap found for item 4. Handle together.
- S3's resync of `inventory` re-reads `photoIds` from Firestore. That is correct, but check `PhotoQueue` does not double-add after a resync.

## Definition of done for B

Rejected write parks after ~3 min, survives relaunch, is visible in one dialog, can be retried, can be discarded online with the local store matching the server afterwards; a transient outage never parks or offers Discard.
