# Test plan — Discard a parked write + resync (part B, S3)

**Branch:** `feat/2026-10-01-s3-discard-parked-writes` (stacked on design PR #109 -> PR #106). **Design:** `../specs/2026-09-30-s3-discard-resync-design.md`.
**Status:** written with the code, before CI. **Nothing was built or run.** No Qt toolchain in the sandbox; CI is the QML signal.

## What S3 changes
A parked (server-rejected) write gets an exit. The Discard button (rejected rows only, online only) opens a confirm; confirming removes that one outbox item, answers anyone waiting on it (`discarded`), and `DataModel` re-reads the affected stores from Firestore. Later edits merged into the parked write go with it; writes queued behind it survive. Server untouched.

## What was actually executed in the session (Node, not Qt)
`StuckWrites.entitiesOf` (single / batch / delta / operation, malformed parts, prototype names, junk inputs, 300-step random-shape monkey) plus a line-for-line mirror of the DataModel entity -> store mapping: **630 assertions passed** (throwaway harness, not committed). **Not executed:** `tst_Gateway.qml`, `tst_DataModel_discardResync.qml` (need Qt), the sheet and everything on device.

## 1. Unit (headless, `tests/`)
| File | New | Covers |
|---|---|---|
| `tst_StuckWrites.qml` | 9 | `entitiesOf`: one entity for single / batch / delta; operation lists each entity once in first-seen order and ignores the top-level entity; empty `ops`; malformed parts; junk inputs never throw; `constructor` / `toString` are plain names; fresh array each call; random-shape monkey |
| `tst_Gateway.qml` | 23 | `discardParked`: removes the write, clears stuck + parked counts and the row, emits once with requestId + entities; no toast; refuses outage-stuck, rejected-below-threshold, unknown / empty / undefined / null ids, offline (works once back online), in flight (works after), direct mode, second call, after sign-out, after a Retry (until rejected again); touches only the chosen write; discards a merged edit with it; frees a same-record write held behind it; relaunch afterwards shows nothing; works right after a relaunch before `resumeStuck`; batch item; delta item fails both coalesced callers once; operation item fails its waiter, fires `operationRejected`, lists every entity; operation nobody awaits; operation whose waiter already timed out; 25 parked discarded one by one; 400-step monkey (random failures, retries, discards, relaunches, offline flips, in-flight: a discarded id never returns, every true return emits once, rows always match counts) |
| `tst_DataModel_discardResync.qml` (new) | 14 | `_storesToResync`: each entity -> its store, staff + removed_staff once, `stock_movement` / unknown / prototype names ignored, order kept without repeats, junk input; **every `Gateway._collections` entity is mapped or ignored**; `_resyncForDiscard` resyncs only the affected stores (observed via `_resetPending` while `loadingMore` is forced true, so no network); every store really resyncs; unmapped / empty / junk resync nothing; Gateway's real signal reaches the handler; 200-step monkey |

## 2. Functional / rules / e2e
- **Functional:** the Gateway cases use the real singletons and real `OutboxStore` persistence.
- **Rules:** `firestore.rules` / `storage.rules` untouched; no rules tests.
- **Server / Node:** server untouched; no `functions/` tests.
- **e2e (emulator):** none. Reject -> park -> discard -> store equals server needs a real `write-rejected`, and **no verified recipe exists yet** (carried from S2b). Until one does, S3's happy path has no end-to-end coverage. Follow-up: a debug-only emulator flag that makes `recordMutation` answer `write-rejected` for a chosen entity id.

## 3. On-device checklist (only coverage for the sheet, confirm, Back behaviour and copy)
Setup: **dev/test** environment, **new tenant**, online. Needs a parked write; see the e2e note: a 403 / 404 setup gives a NON-rejected stuck write, which must show NO Discard button (use it for the negative cases). For a real rejection ask Claude for a current recipe first.

**Happy path**
- [ ] Parked row shows Retry and Discard; tap Discard: confirm sheet with the warning text; tap Discard: toast "Change discarded", row and header line disappear, the record matches the server (edited value reverted / deleted record back / never-created record absent).
- [ ] Cancel in the confirm: nothing changes, row still parked.

**Negative**
- [ ] Outage-type stuck row (403 / 404 setup): only "Retry now", no Discard.
- [ ] Airplane mode: Discard is disabled on a parked row; back online it enables.
- [ ] Go offline WHILE the confirm is open, then confirm: toast "Could not discard...", write still parked.
- [ ] Tap Retry (in flight) then Discard: Discard disabled while "Sending...".

**Edge**
- [ ] Back (Android) and tap-outside while the confirm is open: the confirm closes or stays, the sheet underneath does NOT close.
- [ ] Edit the record while parked, then Discard: the edit is gone too (the confirm says so); the record shows the server value.
- [ ] Two writes for one record (second queued while the first is in flight, first then parks): Discard the first; the second then sends (may conflict or be rejected and park: expected, see design Q-S3-1 A).
- [ ] Force-close and reopen while parked, Discard at once: works.
- [ ] Discard a rejected product create that has a queued photo: photo ends `failed` with its own Retry/Discard tile (roadmap item 4, known).
- [ ] Discard a rejected staff removal: the name may still show as removed until relaunch (known, design fact 5).
- [ ] After discard the list refills from the first page; other pending edits reappear once they land.

**Monkey**
- [ ] Tap Discard, Cancel, Discard, Retry rapidly on several parked rows; rotate; toggle airplane mode; force-close mid-confirm. No crash, no resurrected row, header count equals rows.

## 4. Regression watch
`tst_Gateway` stuckRows / retryStuck / park / relaunch cases, `tst_StuckWrites`, `tst_OutboxStore` park cases, and the existing DataModel tests must stay green. The sheet layout changed (two buttons in a column per row): check row height on a small phone.
