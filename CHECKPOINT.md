# CHECKPOINT — 2026-09-26: C-3 Task 10 (`_tryCompleteOrder` atomic rewrite) implemented, PR #90 open, CI pending

**Session date:** 2026-09-26, continued session (continues the 2026-09-18/20/22/26 arc)
**Branch (this update):** `feat/2026-09-26-complete-order-atomic`, off `main` @ `66ffa4f` (PR #87's merge
commit — live-verified via GitHub API `state=closed, merged=true`, not assumed)
**Previous branches:** `feat/2026-09-26-completion-store-hooks` (PR #87, merged);
`docs/2026-09-26-c3-task10-design-checkin` (PR #89, docs-only, opened earlier this same session, not yet
merged — merging is Taher's call).
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-22-atomic-operation-outbox-CHECKPOINT.md`
**Commit identity:** `Taher (via Claude session) <tsowner@lkdigitalworks.com>` (confirmed by Taher). PAT is
supplied by Taher in chat each session and is never written to the repo, `.git/config`, or memory — it was
injected into the push URL only, transiently, and confirmed absent from `.git/config` after each push this
session (`grep -ci ghp_ .git/config` → 0). Flagged for rotation regardless, since chat history isn't a secrets
store.
**Spec:** `docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md` (D1-D5 approved, on `main`).
**Plan:** `docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md` (13 tasks, 3 phases; Task 10's steps
updated this session — see step log).
**Test plan:** `docs/superpowers/test-plans/2026-09-20-atomic-operation-outbox-test-plan.md` (updated this
session for Task 10 — see its own "Updated 2026-09-26 for Task 10" note).

## Where things actually stand (all live-checked, not assumed)

**Merged to `main`:** everything through #87 (Phase 3 PR 2 — Task 9: store hooks). See the archived
2026-09-22 checkpoint and this file's own prior revision (in git history) for that lineage.

**Design check-in (step 21c, opened earlier this session) — Taher answered all three, in chat, before any
Task 10 code was written:**
1. `maxReplans` stays 3.
2. A completion queued offline (or whose await window elapses) keeps showing as `completed` immediately —
   Task 11's "Saved, syncing…" caption handles the UX; no new order status.
3. **New finding, not in the original plan draft** (reopening an order while its completion is still open in
   `_openCompletions` was unhandled — see the previous revision of this file for the full mechanism): Taher
   chose to fix it now, folded into Task 10, rather than block reopen or defer it as a known gap.

**This session: Task 10 implemented against `main` re-read fresh** (`DataModel.qml`'s current
`_tryCompleteOrder`/`_reverseCompletedOrder`, `Gateway.recordOperation`, `CompletionPlan.build`,
`OperationKeys.js` — not the plan document's 2026-09-20 draft, which predates Task 9 and was confirmed still
substantially correct in step 21b, with the reopen gap being the one real deviation):

- `DataModel._tryCompleteOrder` now builds a `CompletionPlan` and sends it as one `completeOrder`
  `Gateway.recordOperation` call instead of the old per-line FIFO-consume + `deductStock` chain. Handles:
  server-applies-in-time, queued/offline, await-timeout, stock/batch-conflict re-plan (bounded at
  `maxReplans`), a completed-elsewhere conflict, idempotent replay, and `too-many-ops`.
- `_reverseCompletedOrder` gained the decision-3 fix: clears any open completion (`_openCompletions` +
  `_completingOrderIds`) for the order being reopened, before its existing reversal logic runs. Every
  settle/reject handler already treats a missing `_openCompletions` entry as a no-op, so this is the whole
  fix — no Gateway/outbox-level cancellation needed.
- `SalesStore.recordSale(...)` deliberately dropped from this path (it's a no-op wrapper per its own doc
  comment, superseded by `OrdersStore.revision`'s own recompute — already true before this task, not a
  behaviour change).
- The `Connections { target: Gateway ... }` block was placed next to the existing
  `Connections { target: OrdersStore ... }` block (near the top of the file), not at the end after the new
  functions, to avoid a `qt_qml_lint.py` ORD-1 finding the existing block doesn't trigger. Two remaining
  ORD-1 hits at the new `_completionInput`/`_completionHooks` functions are confirmed false positives (the
  linter misreads a multi-line `return { ... }` JS object literal as a QML child object) — the same pattern
  already exists, unflagged-as-an-issue, in unmodified `OrdersStore.qml` (4 identical hits there).

**Tests: `tests/tst_DataModel_completeOrderAtomic.qml` (new, 16 cases — the plan's 15 plus the reopen-race
case) and `tests/tst_DataModel_completeOrderReentrancy.qml` (updated — see below). `tests/tst_DataModel_
adjustOrderSyncGuard.qml` re-checked and confirmed unaffected (never calls `_tryCompleteOrder`).**

**One real test-harness finding, not obvious from `tst_Gateway.qml`'s own tests (see SKILLS Skill 72):**
simulating a server answer via `Gateway._finishOperation({requestId, opType}, result)` alone does not remove
the item from `OutboxStore.items` — only production's real `_sendOperation` XHR-completion path calls
`OutboxStore.markSent()` first. Skipping that in a test means a re-plan's second `recordOperation` call for
the same key silently coalesces into the first (already-rejected) payload instead of sending the corrected
one, per `OutboxStore.enqueueOperation`'s own same-key-twice behaviour. Fixed by having the new test file's
`_answer()` helper call `OutboxStore.markSent(key)` immediately before `_finishOperation`, matching
production's order — this affects every re-plan case (4, 5, 8, 10).

**A second real finding: `tst_DataModel_completeOrderReentrancy.qml`'s "still in flight" tests needed their
setup changed, not just re-verified.** Before this rewrite, `AuthStore.idToken = ""` alone produced a genuine
"never resolves" window (the old code's `deductStock` callback was wired straight to a real XHR that silently
no-ops when signed out). After this rewrite, `Gateway.recordOperation`'s callback fires **synchronously**
whenever `AuthService.isOnline` is false or `awaitServer` isn't requested — so that same setup now resolves
the first call before a second could ever race it, and the file's whole premise (two sequential real calls
racing a genuinely-still-open first call) would have silently stopped testing anything. Fixed: `init()` now
sets `AuthService.isOnline = true` (the only case where `recordOperation` registers a waiter instead of
resolving), `cleanup()` resets it. Every existing assertion is unchanged — only how the in-flight window is
produced changed. Full explanation in that file's own header (updated this session).

**Docs updated this session (in need — nothing speculative):** `docs/superpowers/plans/2026-09-20-atomic-
operation-outbox.md` (Task 10 steps + the decision-3 code addition), `docs/superpowers/test-plans/2026-09-20-
atomic-operation-outbox-test-plan.md` (case statuses, case 16, the two findings above), `SKILLS.md` (Skill 72,
the `markSent`/`_finishOperation` gotcha), `AGENTS.md` and `README.md` (both had stale "Task 10 not started /
no callers yet" lines from before this session — corrected).

**Not done this session, deliberately:** no build, no app run (Taher's call, per standing rule). No local
`qmltestrunner` (no Qt toolchain in the sandbox, per standing convention — see `AGENTS.md`). No merge of this
branch or of PR #89 (docs checkpoint, still open) into `main` — that's Taher's call, and he reviews everything
via PR per his own standing instruction.

## Step log (append-only; resume from the last ticked step)

- [x] 1-20d (2026-09-18 through 2026-09-26): see the archived 2026-09-22 checkpoint and this file's own prior
      revision (git history, branch `docs/2026-09-26-c3-task10-design-checkin`, PR #89) for full detail —
      spec, plan, test plan, Phases 1-2, Phase 3 PR 1 (#83) and PR 2/Task 9 (#87) through merge.
- [x] 21a-21b. Live-reverified session state and re-read `_tryCompleteOrder`/`_reverseCompletedOrder`/
      `CompletionPlan.build` fresh; found the reopen-vs-in-flight-completion gap. (Full detail in the prior
      revision of this file / PR #89.)
- [x] 21c. Design check-in posed to Taher; he answered all three (see above) in the same session.
- [x] 22a. Implemented Task 10 (`_tryCompleteOrder` rewrite + the decision-3 `_reverseCompletedOrder`
      addition) against `main` re-read fresh. Ran this repo's brace-balance check and `qt_qml_lint.py` on
      `DataModel.qml` before committing (pre-commit review pattern) — balanced; only pre-existing-pattern
      `var`-usage style hits and two confirmed-false-positive ORD-1 hits, no new real findings.
- [x] 22b. Wrote `tests/tst_DataModel_completeOrderAtomic.qml` (16 cases) and updated
      `tst_DataModel_completeOrderReentrancy.qml`'s harness (see the two findings above). Hand-traced against
      the actual current source of every store/Gateway/OutboxStore function involved, not the plan draft.
- [x] 22c. Updated the plan doc, test plan doc, `SKILLS.md` (Skill 72), `AGENTS.md`, `README.md`.
- [x] 22d. Committed and pushed this branch, opened as **PR #90** against `main`. **CI result not yet seen
      by this session** — that's the next thing a resumed session (or Taher) should check first, before
      assuming Task 10 is actually green.
- [ ] 23. After Task 10's CI comes back: if red, fix and re-push before anything else. If green: Phase 3 PR 3
      (plan Task 11, the "Saved, syncing" UI hint) and Task 12 (docs/tracker/`SKILLS.md` sweep for the whole
      Phase 3 arc — check the current highest `SKILLS.md` number before picking one; as of this session it's
      72). Task 13 (deploy + on-device plan, including the two new on-device cases this session added for
      decision 3) is Taher's, throughout. PR #89 (docs-only checkpoint, still open) and this session's Task 10
      PR both await Taher's review/merge — do not merge either without his say-so.

## Resume instructions

Fresh session: clone, read this file, re-check live PR/CI state for whatever this session's Task 10 branch/PR
turned into (don't assume — the last three sessions in a row each found something had changed since the file
was last written: PR #87 merged mid-arc, and now this). Do not build or run the app until Taher asks. If CI
came back red on Task 10: read the actual failure before touching code — this file's own findings above
(the `markSent`/`_finishOperation` test gotcha, the reentrancy harness's online+awaiting requirement) are the
two most likely places a first CI run surfaces something, precisely because neither was obvious from reading
`tst_Gateway.qml`'s existing tests alone. If CI is green: proceed to Task 11 (step 23). `CHECKPOINT.md`
conflicts are resolved by keeping the branch's version and archiving `main`'s copy under
`docs/superpowers/specs/`.
