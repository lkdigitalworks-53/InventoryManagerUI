# CHECKPOINT — 2026-09-26: C-3 Phase 3 PR 2 (store hooks, Task 9) ready for review, Task 10 needs a design check-in

**Session date:** 2026-09-26 (continues the 2026-09-18/20/22 arc)
**Branch:** `feat/2026-09-26-completion-store-hooks`, off `main` @ `277f246` (PR #83's merge commit — verified
via `git merge-base`, not assumed)
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
12, `tst_OrdersStore_buildOrderUpdate.qml` 15, `tst_TransactionStore_buildSaleDocs.qml` 20), hand-traced
against the live store files (no Qt toolchain in the sandbox) — same caveat as `tst_OutboxStore.qml` in #83:
unproven until CI's real `qmltestrunner` run.

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
- [x] 20c. Committed, pushed, opened as **PR #87** against `main`. CI requested; not yet observed to
      completion in this session — a fresh session should check its status first, not assume green or red.
- [ ] 21. **Before Task 10 (`DataModel._tryCompleteOrder` rewrite):** flagged again, more specifically now —
      this is the optimistic apply/revert/re-plan logic, "has never run" per the plan's own self-review, and
      is where a mistake would actually reach users (unlike Task 9's hooks, which nothing calls yet). Worth a
      short design check-in with Taher first, specifically on: the re-plan bound (`maxReplans=3` in the plan
      draft — still right?), whether "queued while offline" should show as `completed` to the user before the
      server confirms, and how the guard interacts with `_reverseCompletedOrder`. Do not start Task 10 code
      without that check-in. When it does start: re-read `DataModel.qml`'s current `_tryCompleteOrder` fully
      first — same lesson as Task 7 and this session's Task 9 findings, the plan document's draft code for
      Task 10 is written against an older, smaller version of that function.
- [ ] 22. After PR 2: Phase 3 PR 3 (plan Task 11, the "saved, syncing" UI hint) and Task 12 (docs/tracker/
      `SKILLS.md` sweep for the whole Phase 3 arc — check the current highest `SKILLS.md` number before
      picking one; as of this session it's 70). Task 13 (deploy + on-device plan) is Taher's, throughout.

## Resume instructions

Fresh session: clone, read this file, re-check live PR/CI state for whatever PR step 20c opens (or opens it,
if this checkpoint was committed before that happened — check first, don't assume). Do not build or run the
app until Taher asks. **Do not start Task 10** without the design check-in in step 21 having actually
happened in the conversation. Before touching `DataModel.qml` for Task 10, re-read it fresh on current
`main` — do not assume the plan document's draft code still matches reality (this session found two similar
staleness issues in Task 9's supposedly-simpler files). `CHECKPOINT.md` conflicts are resolved by keeping the
branch's version and archiving `main`'s copy under `docs/superpowers/specs/`.
