# L4a: non-blanking data refresh on resume and reconnect

Branch `feat/2026-11-02-l4a-resume-refresh`, cut from `main` @ `4c88ed9` (PR #180 L3 slice A and PR #181 R3 merged). Parent plans: `2026-10-25-multi-role-login-design.md` (D5, L4) and `2026-10-31-l3-session-lifecycle-design.md` (L3-D1c: "L4 straight after slice A"). Test plan: `../test-plans/2026-11-02-l4a-resume-refresh-test-plan.md`. Skill 151.

## 1. Intent and scope

Slice A of L3 stopped the app from re-reading every list on each token refresh and reconnect (that read blanked the lists and showed the sign-in cover). Taher accepted the cost: an owner who uses two phones no longer gets the accidental hourly refresh. L4 replaces it on purpose.

- **L4a (this change):** the engine and two automatic triggers (app resume, reconnect). No new screen.
- **L4b (next):** pull-to-refresh on the lists and a "last updated" caption. It needs UI design (qt-ui-design) and calls `DataModel.requestRefresh("manual")`, which already exists and is tested.
- **L4c (later, not designed):** incremental refresh (only documents changed since the last sync) and refresh of `ActivityLog`, `CategoryStore`, `OrderChannelStore`.

Out of scope and unchanged: what the server refuses, the sign-in sync (`tenantContextReady` still blanks and refills), the discard resync (`_resyncForDiscard`).

## 2. Facts found in the code (read, not run)

- F1. Every list store refreshes with `_resetAndFetch()`: it sets the list to `[]`, then pages in. On screen that is a blank list, a reset scroll position, and for the length of the fetch every row that exists only on this device (a queued create) is gone. The sign-in sync accepts that. A resume sync cannot: it would run mid-task.
- F2. `InventoryStore.listComplete` is `!hasMore && !loadingMore`. Anything that reuses `loadingMore` or `hasMore` for a background refresh flips `listComplete` to false across the app. The refresh therefore keeps its own flags.
- F3. `OutboxStore.revision` changes on every enqueue, ack, failure and removal. `OutboxStore.items.length` is the number of unsent writes (parked ones included). `LockManager._held` is the one lock this device holds. `PhotoQueue.pendingCount` counts queued photo uploads. `Gateway.inFlight` counts requests on the wire.
- F4. `FirebaseService` sets no request timeout (KNOWN-ISSUES). A read can hang for good.
- F5. All six paged lists are read to the end at sign-in, so a refresh costs one read per document of six collections (orders, inventory, stock batches, suppliers, staff, transactions). That cost grows with the business.
- F6. `SalesStore` derives from `OrdersStore.revision`; it needs no refresh of its own.

## 3. Decisions (all vetoable in the PR; defaults are built)

**L4-D1 Mechanism.** (a) Reuse `syncFromFirebase()` behind a gate. Smallest, but blanks lists and loses queued rows (F1). (b) **Shadow fetch:** page the whole collection into a private buffer, replace the list in one assignment only if the gate still allows it, otherwise drop the buffer. Never blanks; a refused swap costs reads, never data. More code (about 55 lines in each of six stores, identical text). **Built: (b).** Honest cost: six near-copies of the same block; QML has no shared mixin. A drift guard (`refreshWiring.test.js`) pins that all six keep the same rules.

**L4-D2 Gate (start and swap).** Online, session open, not blocked (a block ends with its own full load), no silent access check running, token not about to expire (its refresh runs a check), no store loading or refreshing, **outbox empty (any item, parked included)**, nothing in flight, no lock held, **no edit form open (L4-D10)**, no photo queued. Whole outbox, not per entity: an order operation touches inventory, batches and transactions, and a per-entity rule would have to know that. Cost: a parked write that nobody clears blocks refreshes for that user until Retry or Discard (the stuck-writes dialog already nags). **At swap time** the same gate runs again and the outbox revision must equal the one seen at start: a write that was queued, sent and acknowledged during the fetch leaves an empty outbox but a server copy that may predate it. Built.

**L4-D3 Triggers.** Resume (the hook slice A added), reconnect (`AuthService.isOnline` turning true), manual (L4b). Polling and Firestore streaming rejected (battery and quota, REST streaming in Qt is hard; the parent design already chose resume + pull). Built: resume and reconnect.

**L4-D4 Cost control.** Resume and reconnect refresh only when the lists are at least `STALE_MS` = 5 minutes old; manual ignores that; any two starts are at least `SPACING_MS` = 15 s apart. "Last synced" = the start of the sign-in sync, or a refresh in which all six stores committed. Trade-off: after a resume an owner can look at data up to 5 minutes old; pull-to-refresh (L4b) is the answer for "now". Why not 60 s like the access check: that check is one document, this one is the whole business. Both constants are in `RefreshPolicy.js`.

**L4-D5 A refresh that has to wait.** It waits (poll every 5 s) and forgets after 2 minutes; it is dropped at once if the account becomes blocked, the phone goes offline, or the lists became fresh another way. A copy dropped because writes happened meanwhile is retried once per trigger (so a stream of writes cannot loop it).

**L4-D6 Partial results.** Each store swaps on its own. The lists count as current only if all six committed. Cross-list skew (orders from second 0, batches from second 2) is the same as at sign-in. A store that failed keeps its list.

**L4-D7 Hung read.** A run older than 3 minutes is cancelled by the next trigger or poll (`runLost`); every store answers "superseded". A reset (sign-in sync, discard resync) or `clear()` also cancels a running refresh first, and a late answer from a cancelled run is ignored by a sequence number.

**L4-D8 Where the state lives.** The pure decisions are `qml/helper/RefreshPolicy.js` (no stores, no clock reads, tested in Node and in Qt). `DataModel.qml` reads the live state into one snapshot and drives the stores; it is the only caller of `refreshFromFirebase` (pinned). Not a new singleton: no CMake or qmldir change.

**L4-D9 A load that started during the refresh blocks the swap (added in the 2026-11-03 review sweep, finding F1).** The gate at the swap (`swapOk`) looks at the outbox, the lock, photos and the block state, but not at whether a store's own load is running, because the refreshing store reports itself as busy. A load can start during the copy's read: `TransactionStore` retries a failed sign-in page on a backoff timer (3 s doubling to 30 s) and nothing stops that timer from firing mid-refresh. If the copy then replaced the list, the retry's next page would be appended on top of rows the copy already holds: duplicate transactions, wrong totals. Built: each store's `_refreshPage` drops the copy (`discarded`, which re-arms one wait) when `loadingMore` or `_resetPending` is true at commit time, and `TransactionStore._commitRefresh` stops the retry timer because the list is complete. Alternative rejected: refuse to start while a retry is pending. That would leave a half-loaded Transactions list unhealed for as long as the retry loop lives, and the refresh is exactly what heals it. Cost: one dropped copy (a re-read of one collection) in a rare overlap.

**L4-D10 An open edit form holds the refresh (Taher's decision, 2026-11-03; it was the open question).** Before: only a held lock held the refresh, so a New Order or Add Product form could have the lists change under what was being typed. Now: nine forms (Add product, Edit product, New order, Order detail, Restock, Add staff, Staff detail, Import preview, Confirm return) opt in with `holdsRefresh: true` on the shared `BottomSheet`; read-only sheets (filters, export, notifications, sign-out, stuck writes, staff action sheet, categories, channels, invites, profile) do not, and a wiring test pins that exact list. `BottomSheet` takes the hold when it is about to show and lets go when it closes or is destroyed (idempotent per sheet); the count lives in `LockManager.editHolds` (`anyEditing` is what the gate reads), reset on sign-out. A hold is a soft blocker (the refresh waits) and also refuses the swap. Trade-offs, honestly: (1) a form left open for hours stops automatic refresh for that time; the wish is forgotten after 2 minutes, so when the last form closes `DataModel` makes one new request as a resume (staleness and spacing still apply, a saved form leaves the outbox busy so it waits for the acknowledgement). (2) The data under an open form can be older than the server's for as long as it is open; the order detail still has its lock and conflict handling for the one record being edited. (3) The Staff action sheet and the category and channel managers are left out on purpose: a choice sheet is momentary, and categories and channels are not refreshed anyway. (3b) Audited 2026-11-03: the only dialogs outside `BottomSheet` are `ConfirmDialog` and `AlertDialog` (momentary yes/no, they act on an id they were given, not on a list index) and small pickers (`PhotoSourceSheet`, `AppComboBox`, `InlineDatePicker`), which are only ever opened from inside a form that already holds; no page edits a row inline outside these forms. (4) One more place that must stay in sync (the list of forms); the wiring test fails if a new form forgets the flag or a read-only sheet gets it.

## 4. Known limits (also in KNOWN-ISSUES)

- A parked write blocks automatic refresh until the user resolves it.
- An open edit form blocks automatic refresh while it is open (L4-D10); closing the last form asks once.
- If the sign-in sync fails, the lists are treated as current for up to 5 minutes (manual refresh covers it, L4b).
- `ActivityLog`, categories and channels are not refreshed (L4c).
- A refresh re-reads every document; no incremental read (L4c).
- Nothing was built or run on a device. The real foreground transition, the Felgo lifecycle and what the lists draw are device-only.

## 5. Build notes

Six stores each gain `refreshing`, `_refreshSeq`, `_refreshDone`, `refreshFromFirebase(guard, done)`, `_finishRefresh`, `_cancelRefresh`, `_refreshPage`, `_commitRefresh`, and a first line `_cancelRefresh()` in `_resetAndFetch()` and `clear()`. `LockManager.anyHeld`, `AuthService.isSessionOpen()` and `tokenNeedsRefresh()` expose existing facts. `Main.qml`'s resume hook calls `dataModel.requestRefresh("resume")` after `AuthService.onAppResumed()`. `sessionRecheckWiring.test.js` was updated for the hook's new shape and now allows `DataModel` (logic, not UI) to read `AuthService.checking`.

## 6. Review sweep 2026-11-03 (requesting-code-review, qt-qml-review, ponytail-audit, qt-ui-design)

Scope: the whole PR (27 files, read in full: policy, coordinator, six stores against their original fetch paths, hooks, tests, docs). Lint: 52 hits on changed lines, triaged below. CI on the head before the sweep: all green, 3910/3910.

**Fixed in this PR**
- F1 (must fix, confidence 85): refresh commit versus a running or timer-started load duplicates rows (L4-D9). Tests: behaviour tests for all six stores (busy at commit, busy only mid-way, can refresh again), three Transaction timer tests, 5 wiring mutants, one QML test. Three hand mutants of the fix are killed.
- F2 (should fix): `refreshBehavior.test.js` header named a QML file that does not exist (`tst_OrdersStore_refresh.qml`); now names `tst_StoreRefresh.qml`.

**Lint triage (qt_qml_lint.py, changed lines only):** 52 hits, none needs a change. `var` (JS-1, 33) and `property var` (BND-1, 8) match the house style of every store (the functions hold arrays and a callback, which need `var`). JS-2 (6) are false positives: the lines use `!==`. ORD-1 (3) and STY-6 (1, `_refreshWaitTimer`) follow the layout the files already have (properties declared next to the code that owns them, `_logicBus` style ids). Moving them would add merge noise in six hot files for no behaviour gain.

**Investigated, not fixed (need a device or a decision)**
- I1 (65): the swap does not compare the tenant id. Today a workspace change calls every store's `_resetAndFetch`, which cancels first, so no stale copy can land. A path that changes the workspace without a reset would be missed. Cheap to add later (snapshot key plus a start value), but it touches the policy contract and three test suites; no concrete path found, so left.
- I2 (62): a refresh waiting on `tokenNeedsRefresh()` depends on the token refresh that `onAppResumed` or the 120 s timer starts. If the refresh is throttled and the timer fires late, the 2 minute wait can end first and the resume refresh is forgotten (the next trigger covers it). Device-only to confirm.
- I3 (60): replacing a whole list array may reset a `ListView`'s scroll position even though the list never blanks. Which pages bind to the arrays directly, and what the delegates keep, is only visible on a device (test plan step 1 already asks for "scroll position kept"; treat a failure there as a finding for L4b).
- Lean (ponytail): six near-copies of about 58 lines each (about 300 lines) could shrink to one pure paging helper plus a few lines per store. Not done: it rewrites six stores whose behaviour is now pinned by 130 tests, and the wiring test would need a new shape. Honest trade-off: copy cost now versus refactor risk in a slice that is already green. Candidate for L4c, where the sign-in sync moves to the shadow fetch and the helper pays for itself twice.

**qt-ui-design audit (PR has no screen):** nothing to critique on screen. Two carry-overs for L4b: (1) a silent swap gives no cue; the "last updated" caption and pull-to-refresh are the planned answer (wayfinding, feedback within 400 ms); (2) reduced motion and keyboard reach are not affected by this change.
