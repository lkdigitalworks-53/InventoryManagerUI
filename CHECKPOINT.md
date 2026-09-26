# CHECKPOINT — 2026-09-26: C-3 PR #87 (Task 9) merged; Task 10 design check-in opened, awaiting Taher's decisions

**Session date:** 2026-09-26, continued session (continues the 2026-09-18/20/22/26 arc)
**Branch (this update):** `docs/2026-09-26-c3-task10-design-checkin`, off `main` @ `66ffa4f` (PR #87's merge
commit — live-verified via GitHub API `state=closed, merged=true`, not assumed)
**Previous branch:** `feat/2026-09-26-completion-store-hooks` (PR #87, merged)
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-22-atomic-operation-outbox-CHECKPOINT.md`
**Commit identity:** `Taher (via Claude session) <tsowner@lkdigitalworks.com>` (confirmed by Taher). PAT is
supplied by Taher in chat each session and is never written to the repo, `.git/config`, or memory.
**Spec:** `docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md` (D1-D5 approved, on `main`).
**Plan:** `docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md` (13 tasks, 3 phases, on `main`).
**Test plan:** `docs/superpowers/test-plans/2026-09-20-atomic-operation-outbox-test-plan.md` (updated this
session for Task 9 — see its own "Updated 2026-09-26" note).

## Where things actually stand (all live-checked, not assumed)

**Merged to `main`:** everything through #83 (Phase 3 PR 1 — Tasks 6-8: `OutboxStore`/`Gateway` transport).
See the archived 2026-09-22 checkpoint for that history.

**This session (not yet a PR at session start — opened partway through, see step log):** Task 9, the four
store hooks the plan calls for, implemented against `main` re-read fresh (not the plan document's draft
code, which was stale in two ways — see below):

- `InventoryStore.applyRemoteStock(productId, stock)` — replaces stock, returns previous or `undefined`.
- `StockBatchStore.applyRemoteQty(batchId, qty)` / `addLocalBatch(doc)` / `removeLocalBatch(batchId)`.
- `OrdersStore.buildOrderUpdate(orderId, fields)` (pure half of `updateOrder`, no Gateway/local-state side
  effects) / `applyRemoteOrder(doc)`.
- `TransactionStore.buildSaleDocs(order, epoch, legacyIds)` (pure half of `recordSaleFromOrder`) /
  `addLocalEntries(docs)` / `removeLocalEntries(txIds)`.

56 new tests across 4 new files (`tst_InventoryStore_applyRemote.qml` 9, `tst_StockBatchStore_applyRemote.qml`
12, `tst_OrdersStore_buildOrderUpdate.qml` 15, `tst_TransactionStore_buildSaleDocs.qml` 20). **Verified in CI,
1356/1356 green** (PR #87) — one genuine test bug caught and fixed along the way (see step 20c/20d below), so
the hand-tracing-before-push discipline this arc uses is not a substitute for CI, just a way to keep the
false-positive rate low before it runs.

**Two real findings from re-reading live code instead of trusting the plan draft:**

1. `OrdersStore._normalizeOrder` returns a fixed-field object literal — it does NOT carry unknown fields
   through. The plan's Task 9 draft set `o.completionEpoch` and assumed it would just persist; it would have
   been silently dropped by the very next `_clone()`/normalize pass (every `updateOrder` call, every sync),
   which would have broken the deterministic-key mechanism Task 10 depends on in a way that's easy to miss in
   review (works once, then quietly stops). Fixed `_normalizeOrder` (and `_normalizeOrders`, the
   Firestore-sync path, for consistency) to carry `completionEpoch` through. Added
   `test_completionEpoch_survives_an_unrelated_updateOrder_call` specifically to pin this — same lesson as
   Task 7 finding the `signal.connect()` disconnect-handle bug, and the CAS shape-mismatch lesson already in
   `docs`/memory: a field-list mismatch between construction paths is the recurring failure mode in this
   codebase.
2. `TransactionStore.recordSaleFromOrder`'s `allocByProduct` lookup is keyed by `productId`, so two lines of
   the *same* product in one order silently collide — the second line's `OrderMath.allocate` result
   overwrites the first's in the map, and both lines then read the second line's tax/discount allocation.
   Pre-existing, not introduced by extracting `buildSaleDocs` out of it, not previously covered by any test.
   **Not fixed here** — fixing it is a GST-relevant behaviour change and deserves its own decision, not a
   drive-by inside a refactor PR. Flagged in a code comment and to Taher directly.

**Nothing calls these hooks yet.** `DataModel._tryCompleteOrder` still uses the old per-line delta chain.
App behaviour is unchanged by PR #87. The C-3 bug is **still not fixed** — that's Task 10.

**Since this checkpoint was last written, Taher merged PR #87 into `main` himself** (live-verified: GitHub
API reports `state: closed, merged: true`, tip `66ffa4f`) — Task 9 is fully landed, not just CI-green and
awaiting review.

**A third finding, from re-reading `_reverseCompletedOrder` and its only call site (`onUpdateOrder`'s
completed→non-completed edge) against the Task 10 plan draft, not yet fixed or decided:** nothing in the
draft's `_openCompletions` bookkeeping is touched by reopen. If a completion is showing as `completed`
optimistically (queued offline, or the await window ran out) and the order is reopened before the server
actually answers, `_reverseCompletedOrder` reverses stock/batches/ledger off the *predicted* state and clears
`consumption[]`, but the original `_openCompletions[key]` entry survives untouched. When the deferred
`operationApplied`/`operationRejected` for that key eventually arrives, `_settleApplied`/`_reconcileFromRejection`
will still run and re-apply the original sale's stock delta and `applyRemoteOrder` onto an order the user has
since reopened (and possibly already re-completed under a new epoch) — a second, differently-shaped double-
consume, on the very PR meant to close the first one. `_completingOrderIds[orderId]` also stays untouched by
reopen for the same reason. Not in the plan draft; raised to Taher as part of the Task 10 design check-in
(see step 21 below) rather than decided unilaterally.

## Step log (append-only; resume from the last ticked step)

- [x] 1-18 (2026-09-18 through 2026-09-25): see the archived 2026-09-22 checkpoint for full detail — spec,
      plan, test plan, Phases 1-2, and Phase 3 PR 1 (#83) through merge.
- [x] 19. Taher's decision on Phase 3 PR 2 arrived as "start with next phase … pick up tasks immediately" —
      read as: proceed with Task 9 (store hooks), the lower-risk, more mechanical half of PR 2, and hold
      Task 10 for the design check-in already flagged in step 20 below rather than bundle both into one PR.
- [x] 20a. Re-read all four target store files fresh on current `main` (not the plan draft) before writing
      anything, per this file's own resume instructions. Found the two issues above.
- [x] 20b. Implemented and tested all four Task 9 hooks (56 tests, see above). Updated the test plan's
      "Store hooks" row and header note.
- [x] 20c. Committed, pushed, opened as **PR #87** against `main`. CI ran: 1355/1356 passed first try —
      `Functions Tests`, `Firestore Rules Tests`, `E2E Tests` all green; `QML Tests` failed exactly 1 of 1111,
      per the `pr-comment` job's summary: `OrdersStore_buildOrderUpdate::test_completionEpoch_defaults_to_zero_when_absent`.
      Real cause (test bug, not a store bug): `getById()` returns the raw stored object with no
      normalization, and the test's raw fixture never set `completionEpoch`, so it read `undefined`, not the
      store's `0` default (which only applies inside `_normalizeOrder`, i.e. after a `_clone()`). Fixed by
      routing the fixture through `buildOrderUpdate` first, same as this file's other normalize-path tests.
      This is the first PR in this arc where the "hand-traced, unproven until CI" caveat on every store-hook
      test actually caught something — worth remembering next time that caveat is written off as boilerplate.
- [x] 20d. Pushed the fix. **CI green: 1356/1356** (QML 1111, Functions 176, Firestore Rules 28, E2E 41).
      PR #87 is genuinely CI-verified now, not just hand-traced. Task 9 is done and ready for Taher's review;
      the PR has not been merged by this session (merging `main` is Taher's call per the standing rule of
      never pushing to `main` without explicit instruction — that extends to merging a PR into it).
- [x] 21a. Re-verified live state at the start of this continued session (not trusting this file's own prior
      content per the resume instructions): PR #87 merged to `main` (GitHub API), no other open PR touches
      C-3, `main` tip is `66ffa4f`.
- [x] 21b. Re-read `DataModel.qml`'s current `_tryCompleteOrder` (lines ~489-659) and `_reverseCompletedOrder`
      (lines ~771-800) fresh, plus `CompletionPlan.build` in `qml/helper/CompletionPlan.js`, against the plan
      draft's Task 10 code — confirms `consumption[]` IS carried through the new plan (`CompletionPlan.build`
      populates it per line, threaded into `orderUpdate(lines)`), so `_reverseCompletedOrder`'s read of
      `line.consumption` keeps working for the settled-outcome case. Found the reopen-vs-in-flight-completion
      gap logged above, which the plan draft does not address.
- [ ] 21c. **Design check-in posed to Taher, not yet answered.** Before Task 10 code starts, need his call on:
      (i) the re-plan bound (`maxReplans=3` in the plan draft — still right?), (ii) whether "queued while
      offline" should keep showing as `completed` to the user before the server confirms, or something else,
      (iii) how reopen should interact with an in-flight completion (block reopen while one is open / cancel-
      supersede the open completion on reopen / accept the gap for now and fix later — see the finding above).
      **Do not start Task 10 code without his answers landing in this file first.**
- [ ] 22. After PR 2: Phase 3 PR 3 (plan Task 11, the "saved, syncing" UI hint) and Task 12 (docs/tracker/
      `SKILLS.md` sweep for the whole Phase 3 arc — check the current highest `SKILLS.md` number before
      picking one; as of this session it's 70). Task 13 (deploy + on-device plan) is Taher's, throughout.

## Resume instructions

Fresh session: clone, read this file, re-check live PR/CI state (don't assume — this session found PR #87 had
been merged since the file was last written). Do not build or run the app until Taher asks. **Do not start
Task 10** until step 21c's three questions have Taher's answers recorded in this file. When it does start:
`_tryCompleteOrder`/`_reverseCompletedOrder` and `CompletionPlan.build` were re-read fresh this session (see
21b) and the plan draft's shape still holds except for the reopen-race gap — re-check anyway rather than
trusting this note, same lesson as every prior arc session. `CHECKPOINT.md` conflicts are resolved by keeping
the branch's version and archiving `main`'s copy under `docs/superpowers/specs/`.
