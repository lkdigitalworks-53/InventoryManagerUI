# Gateway stuck writes: Retry / Discard and server error classification — options

**Date:** 2026-09-28
**Branch / PR:** `docs/2026-09-28-gateway-stuck-write-retry-discard-options` (docs only, draft)
**Status:** DECIDED 2026-09-28 (Taher answered Q1-Q5, see Decisions). Design approved at option level; per-PR detail still needs a plan before code.
**Source:** `docs/superpowers/DELETE-FEATURE-ROADMAP.md` item 1 remainder; follow-ups B and C in
`docs/superpowers/KNOWN-ISSUES.md` ("Gateway._send terminal-failure black hole").
**Builds on:** `2026-09-19-gateway-stuck-write-indicator-design.md` (PR #75, merged).

## What is still broken

PR #75 made a stuck write visible. It did not fix it. A write that can never succeed (rules change,
poison payload, server bug) still:

1. retries forever (backoff caps at 10 min),
2. leaves local state showing something the server never accepted,
3. gives the user no action. The caption says "still retrying" and that is the end of it.

## Code facts (traced, not run)

- Server: every write exception -> `500 write-failed` at five sites in `functions/index.js`. Client cannot tell
  poison from blip. PR #75 recorded this; still true.
- Client detection: 5th server-side failure of one `requestId` (~3 min) = stuck, in-memory only
  (`qml/helper/StuckWrites.js`). Restarts on relaunch.
- Outbox item has `attempts` and `nextAttemptAt`, persisted. No `parked` / `terminal` field.
- Rollback hooks per store today:
  - `mutationConflicted`: Supplier, Orders, StockBatch, Staff, Inventory.
  - `batchMutationFailedPermanently`: Supplier, Orders, Inventory.
  - none: Party, Category, OrderChannel, and the operation sender.
- UI: `GlassHeader` caption already shows "N change(s) not syncing". It is not tappable.

## The two pieces

**C, server classification.** Map Firestore/Admin error codes to distinct statuses instead of blanket 500:
terminal (permission-denied, invalid-argument, failed-precondition, not-found, already-exists) -> 4xx;
transient (unavailable, deadline-exceeded, resource-exhausted, aborted, internal) -> 503. Client learns
"terminal" vs "transient" from the status, not a counter.

**B, park + Retry/Discard.** A stuck write stops auto-retrying, sits in the outbox marked parked, and the
user chooses Retry (un-park, resend) or Discard (remove it and fix local state).

## Why order matters (my honest read)

B alone hangs its trigger on the 5-failure counter. A 3-minute Cloud Functions outage or a bad deploy would
park *valid* writes and then offer the user a Discard button. One tap and real data is gone. The counter
was fine for a toast; it is a bad trigger for a destructive action. C is what makes B's trigger safe.

C alone is nearly free of risk **if the client keeps retrying regardless** (today's policy). A mis-mapped
code then only changes a label, never drops data. The blast radius grows only when B starts acting on it.

## Options

| | What ships | Gain | Cost / risk |
|---|---|---|---|
| **1. C first, client never drops** (recommended) | Server maps codes -> 4xx/503. Client reads it: caption says "rejected by server" vs "server unreachable", counter unchanged. | Small, safe, testable in Node today (real `npm test`). Unblocks B without gambling on a heuristic. | User-visible gain is only a better caption. Poison write still retries forever until B lands. |
| **2. B only, counter trigger** | Park at 5 failures, Retry/Discard. | Gives users an action now. | Destructive button behind a heuristic. Outage -> valid writes offered for discard. Needs per-store rollback for 3+ stores with no hook. Largest QML surface, CI-only signal. |
| **3. C + B in one PR** | Both. | One coherent behaviour. | Big for one free-plan session. If the token budget dies mid-way, a half-built destructive path is on the branch. Violates the small-scope rule. |
| **4. Do neither, close item 1** | Accept surface-only. | Zero work. | Silent divergence stays. In a dev-only env this is defensible; before real tenants it is not. |

Recommendation: **Option 1 now, B in the next session.** Reason: it is the only slice that is honest
about what it can verify in this sandbox, and it removes the one thing that makes B dangerous.

Ponytail check on Option 1: is C needed at all? Yes, but only the mapping plus the client label. No new
helper file, no new outbox field yet. The `parked` field belongs to B.

## Questions

**Q1. Sequence.** Option 1 (C now, B later), 2, 3 or 4?
Challenge: if you pick 2 or 3, say how you want Discard to be prevented on a transient outage. "The user
will know" is not an answer; users do not read status codes.

**Q2. Discard semantics** (needed to size B, answer now or in the B session).
- (a) Roll back to the item's `before`. Cheap. But `before` can itself be stale, which is exactly what the CAS
  work exists to handle. Party / Category / OrderChannel have no hook, so each gets new code.
- (b) Drop and re-pull the record from Firestore. Truth wins, one mechanism. Needs a per-store refresh path
  and an online device; wrong for a create that never reached the server (nothing to pull).
Leaning (b) for update/delete, (a)-style removal for create. Tell me if you disagree.

**Q3. Persist "parked"?** In the outbox (survives relaunch, poison write is not re-hammered after every
restart) vs in memory (simple, but every relaunch retries the poison write for 3 more minutes and re-toasts).
Leaning persisted. Cost: outbox schema gains a field; old queued items must load without it.

**Q4. UI entry.** Make the existing header caption tappable -> one dialog listing stuck writes with
Retry / Discard, vs a new Sync Issues page in Settings. Leaning the dialog: no new page, no navigation
work. Cost: a dialog is cramped if 20 writes are stuck. Do you expect that?

**Q5. Item 4 (photo cleanup on delete).** Is a Storage plan active now? What is the state of
`feature/2026-09-21-product-photos-firebase-storage`? This session cannot verify either. If Storage is live,
item 4 becomes a pure on-device check for you, not code.

## Decisions (Taher, 2026-09-28)

| # | Question | Chosen | Consequence |
|---|---|---|---|
| Q1 | Sequence | **C first** (server classification, client never drops), B in a later session | Next PR = Option 1 sketch below. No `parked` field, no Discard yet. |
| Q2 | Discard semantics | **Re-pull from Firestore** | B needs a per-store refresh path + online device. A create that never reached the server has nothing to pull: needs its own handling (plain removal). Party / Category / OrderChannel need the refresh path built. |
| Q3 | Persist "parked" | **Yes, survives relaunch** | B adds a persisted outbox field. Old queued items must load without it. |
| Q4 | UI entry | **Tappable header caption -> dialog** | No new page. Watch the many-stuck-writes case in B. |
| Q5 | Item 4 | **Storage plan is active. Photos branch (`feature/2026-09-21-product-photos-firebase-storage`) works, merges in a couple of days.** | Item 4 is now an on-device check for Taher, gated on that merge. Not code for this session. |

Order of work: (1) C now, (2) B next, (3) item 4 verification once the photos branch merges. Taher said
"include it for next priority item": read as item 4 joining the queue behind C and B, and pulled forward the
moment the photos branch lands, since it is a check, not a build. Flag if that reading is wrong.

Open detail for B, not blocking C: Q2's re-pull plus an in-memory-only refresh path on a device that is
offline at Discard time. Proposed: Discard is disabled offline. Decide in the B session.

## Out of scope here

- Auth-doc cascade cleanup, general per-entity authorization matrix in `recordMutation` (separate KNOWN-ISSUES).
- Making the stuck counter persistent (only matters if B is not built).
- Any change to 401 / 409 / status-0 handling. Those stay as PR #75 defined them.

## If Option 1 is chosen: sketch of the implementation PR (for sizing only, not approved)

- `functions/lib/`: one pure `classifyWriteError(e) -> {status, error}`; five `catch` sites call it.
- Node tests: every mapped code, unknown code -> 500, non-Firestore error -> 500, the five sites via existing
  handler harness. Runs for real in the sandbox.
- `Gateway.qml`: read the new statuses; `StuckWrites.js` gains a `terminal` flag per requestId; `GlassHeader`
  caption picks its text from it. QML tests for the helper; caption is on-device only (same limit as PR #75).
- Test plan from the Skill 49 template; `SKILLS.md` entry; `KNOWN-ISSUES.md` and roadmap status update.
