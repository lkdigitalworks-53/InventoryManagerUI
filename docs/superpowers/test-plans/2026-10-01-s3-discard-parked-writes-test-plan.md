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

### 3.0 Prerequisites (read first; added in the PR #110 final sweep)
**Build / environment**
- [ ] App built from this PR (or the review branch on top of it) and installed on an Android device. **dev or test environment only, never prd.**
- [ ] `Gateway.mode` is `"gateway"` (the default). In `"direct"` mode Discard always refuses ("Could not discard...").
- [ ] Cloud Functions of that environment are deployed and reachable (S3 changes no server code, but the write must reach `recordMutation`).
- [ ] Device is online, screen kept on, battery saver off (it can pause timers).

**Account / data**
- [ ] A **new tenant**, logged in as **owner**. At the start the header shows no "not syncing" / "rejected" line and the sheet says "Nothing is stuck right now." If anything is stuck, clear it first.
- [ ] Seed at least 3 products (call them A, B, C), 1 supplier and 1 order. Write down A's name, description and stock.
- [ ] Firestore console open on the environment's database (dev -> `dev1`, test -> `test`). Server truth lives at `tenants/{tenantId}/inventory/{productId}`; `tenantId` is in `users/{uid}.tenantId`. Compare the document before and after every Discard.

**Making a write get stuck (pick the recipe per case)**
| Recipe | Gives | How | Expect in the sheet |
|---|---|---|---|
| R1, no code (403 `no-tenant-context`) | NON-rejected stuck write | Console: `tenants/{tenantId}/members/{uid}.status` -> `"suspended"`. Edit product A's name and save (a single-write action; **not Restock**, it queues two writes). Set `status` back to `"active"` to fix the cause. | "Not syncing. Still retrying.", button "Retry now", **no Discard** |
| R2, no code, **verified on device 2026-10-04** (oversize field) | REJECTED (parked) write | Edit product B, paste more than 1 MiB of text into **Description** (paste, select all, copy, paste twice, repeat about 11 times), save. Firestore refuses a document over 1,048,576 bytes with INVALID_ARGUMENT, which the server classifies `write-rejected`. | After about 3 minutes: toast "paused", header "N change(s) rejected by the server. Tap to retry or discard.", row "Rejected by the server. Paused until you tap Retry or Discard.", buttons Retry + Discard |
| R3, debug flag | REJECTED write | **Not built.** Open decision, see the PR description. | n/a |
- **R2 caveats.** Taher ran R2 on device: an oversize Description does produce a parked row. If the row stays "Not syncing. Still retrying." the server answered with a non-rejected code: stop, take the Cloud Function log line `recordMutation write failed` and send it back. Pasting 1 MiB can make the text field laggy; the oversize write sits in the device outbox until you Discard it, so use a throwaway product and never a real one.
- **Wait time.** A write must fail 5 times before it is stuck. Retry delays are 2 s, 8 s, 30 s, 2 min (jittered), so about 3 minutes online. **Retry** on a parked row restarts the count and re-parks it after ONE attempt.
- **Do not use:** a Firestore rules change (Cloud Functions use the Admin SDK and bypass rules), a stopped emulator (counts as offline, not stuck), or editing the document in the console (only gives the 409 "changed elsewhere" toast, deliberately not counted).
- **Resetting between cases:** Discard the parked row (that is the feature) or fix the cause and Retry. If state gets muddled, start a new tenant.

**Evidence to keep per case:** screenshot of the row, the confirm and the toast; console document before / after; optional `adb logcat | grep -i gateway`.

### 3.1 Checks
**Happy path**
- [ ] Parked row shows Retry and Discard; tap Discard: confirm sheet with the warning text; tap Discard: toast "Change discarded", row and header line disappear, the record matches the server (edited value reverted / deleted record back / never-created record absent).
- [ ] Cancel in the confirm: nothing changes, row still parked.

**Negative**
- [ ] Outage-type stuck row (403 / 404 setup): only "Retry now", no Discard.
- [ ] Airplane mode: Discard is disabled on a parked row; back online it enables.
- [ ] Go offline WHILE the confirm is open, then confirm: toast "Could not discard...", write still parked.
- [ ] Confirm Discard, then go offline at once (during the reload): the lists may stay empty or partial until you are back online and refresh (same behaviour as any failed sync, a reload clears the list first). Confirm they refill on reconnect or pull-to-refresh; report if they stay empty.
- [ ] Tap Retry (in flight) then Discard: Discard disabled while "Sending...".

**Edge**
- [ ] Back (Android button / gesture) and tap-outside while the confirm is open: the sheet underneath must NOT close. **Report exactly what Back does** (closes the confirm, or nothing). If Back does nothing and only Cancel / tap-outside leaves the confirm, that is a UX decision for Taher (review note R-2).
- [ ] Copy: row text ends "...Retry or Discard.", header ends "...Tap to retry or discard.", sheet caption says "Retry or Discard".
- [ ] Edit the record while parked, then Discard: the edit is gone too (the confirm says so); the record shows the server value.
- [ ] Two writes for one record (second queued while the first is in flight, first then parks): Discard the first; the second then sends (may conflict or be rejected and park: expected, see design Q-S3-1 A).
- [ ] Force-close and reopen while parked, Discard at once: works.
- [ ] Discard a rejected product create that has a queued photo: photo ends `failed` with its own Retry/Discard tile (roadmap item 4, known).
- [ ] Discard a rejected staff removal: the name may still show as removed until relaunch (known, design fact 5).
- [ ] After discard the affected lists reload from the server (briefly empty or partial, then complete); other pending edits reappear once they land.

**Monkey**
- [ ] Tap Discard, Cancel, Discard, Retry rapidly on several parked rows; rotate; toggle airplane mode; force-close mid-confirm. No crash, no resurrected row, header count equals rows.

## 4. Regression watch
`tst_Gateway` stuckRows / retryStuck / park / relaunch cases, `tst_StuckWrites`, `tst_OutboxStore` park cases, and the existing DataModel tests must stay green. The sheet layout changed (two buttons in a column per row): check row height on a small phone.

## 5. PR #110 final sweep (2026-10-01) — what the review changed
Behaviour-neutral: row copy and header caption now mention Discard (SKILLS 89 rule: grep the strings), `StuckWritesSheet` members reordered (properties before the `ConfirmDialog` child), and the duplicated recordDelta-callback block in `Gateway` now uses one helper (`_answerDeltaCallbacks`, was `_failDeltaCallbacks`). Existing `tst_Gateway` delta cases cover the helper on both paths (terminal send answer and discard); no new cases needed. **Known gap:** `StuckWritesSheet` (Discard visibility, `enabled`, confirm wiring, toasts) has no automated test; the repo cannot load Felgo-dependent pages under `qmltestrunner`, so section 3 is its only coverage.

## 6. Device results (Taher, 2026-10-04, build = #110 + #112 code)
- All section 3.1 checks passed.
- R-1: R2 (oversize Description) produced a parked row. No debug flag needed.
- R-3: not exercised. Discard + resync finished before airplane mode could be switched off. Accepted as a corner case, no change.

