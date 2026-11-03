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

**L4-D2 Gate (start and swap).** Online, session open, not blocked (a block ends with its own full load), no silent access check running, token not about to expire (its refresh runs a check), no store loading or refreshing, **outbox empty (any item, parked included)**, nothing in flight, no lock held, no photo queued. Whole outbox, not per entity: an order operation touches inventory, batches and transactions, and a per-entity rule would have to know that. Cost: a parked write that nobody clears blocks refreshes for that user until Retry or Discard (the stuck-writes dialog already nags). **At swap time** the same gate runs again and the outbox revision must equal the one seen at start: a write that was queued, sent and acknowledged during the fetch leaves an empty outbox but a server copy that may predate it. Built.

**L4-D3 Triggers.** Resume (the hook slice A added), reconnect (`AuthService.isOnline` turning true), manual (L4b). Polling and Firestore streaming rejected (battery and quota, REST streaming in Qt is hard; the parent design already chose resume + pull). Built: resume and reconnect.

**L4-D4 Cost control.** Resume and reconnect refresh only when the lists are at least `STALE_MS` = 5 minutes old; manual ignores that; any two starts are at least `SPACING_MS` = 15 s apart. "Last synced" = the start of the sign-in sync, or a refresh in which all six stores committed. Trade-off: after a resume an owner can look at data up to 5 minutes old; pull-to-refresh (L4b) is the answer for "now". Why not 60 s like the access check: that check is one document, this one is the whole business. Both constants are in `RefreshPolicy.js`.

**L4-D5 A refresh that has to wait.** It waits (poll every 5 s) and forgets after 2 minutes; it is dropped at once if the account becomes blocked, the phone goes offline, or the lists became fresh another way. A copy dropped because writes happened meanwhile is retried once per trigger (so a stream of writes cannot loop it).

**L4-D6 Partial results.** Each store swaps on its own. The lists count as current only if all six committed. Cross-list skew (orders from second 0, batches from second 2) is the same as at sign-in. A store that failed keeps its list.

**L4-D7 Hung read.** A run older than 3 minutes is cancelled by the next trigger or poll (`runLost`); every store answers "superseded". A reset (sign-in sync, discard resync) or `clear()` also cancels a running refresh first, and a late answer from a cancelled run is ignored by a sequence number.

**L4-D8 Where the state lives.** The pure decisions are `qml/helper/RefreshPolicy.js` (no stores, no clock reads, tested in Node and in Qt). `DataModel.qml` reads the live state into one snapshot and drives the stores; it is the only caller of `refreshFromFirebase` (pinned). Not a new singleton: no CMake or qmldir change.

**Open question for Taher (not built):** should an open edit dialog (not only a held lock) also hold the refresh? Today only a held lock does. An open New Order dialog keeps its own copy of what you typed; the lists under it may change, which is the point of a refresh. Say if you want it stricter.

## 4. Known limits (also in KNOWN-ISSUES)

- A parked write blocks automatic refresh until the user resolves it.
- If the sign-in sync fails, the lists are treated as current for up to 5 minutes (manual refresh covers it, L4b).
- `ActivityLog`, categories and channels are not refreshed (L4c).
- A refresh re-reads every document; no incremental read (L4c).
- Nothing was built or run on a device. The real foreground transition, the Felgo lifecycle and what the lists draw are device-only.

## 5. Build notes

Six stores each gain `refreshing`, `_refreshSeq`, `_refreshDone`, `refreshFromFirebase(guard, done)`, `_finishRefresh`, `_cancelRefresh`, `_refreshPage`, `_commitRefresh`, and a first line `_cancelRefresh()` in `_resetAndFetch()` and `clear()`. `LockManager.anyHeld`, `AuthService.isSessionOpen()` and `tokenNeedsRefresh()` expose existing facts. `Main.qml`'s resume hook calls `dataModel.requestRefresh("resume")` after `AuthService.onAppResumed()`. `sessionRecheckWiring.test.js` was updated for the hook's new shape and now allows `DataModel` (logic, not UI) to read `AuthService.checking`.
