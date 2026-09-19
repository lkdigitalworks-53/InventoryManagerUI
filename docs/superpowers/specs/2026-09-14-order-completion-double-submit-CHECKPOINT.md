# CHECKPOINT — order-completion double-submit fix, CI green, PR #70 open for review

**Session date:** 2026-09-14
**Branch:** `fix/2026-09-14-order-completion-double-submit`, off `main` @ `0be21fb`
**PR:** https://github.com/lkdigitalworks-53/InventoryManagerUI/pull/70 (Taher tested all scenarios on device, confirmed working; rebased onto main post-PR#71 and merging now)
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-02-price-adjust-tax-delta-CHECKPOINT.md`
(that session's branch had already been merged to `main`; its final CHECKPOINT.md was sitting
unarchived at the repo root when this session's clone was made — same "may be one commit behind"
gap flagged as an open item at the end of that session. Archived first, per this repo's own
archive-before-overwrite discipline, before writing this file.)

## What this session is

Taher reported a bug via `/superpowers:systematic-debugging` (Stay in full caveman mode - FULL):
add a pending order, the Orders page's "approve pending" affordance completes it, but completing
takes noticeable time with zero progress indicator. Pressing Approve a second time (before the
first press's write resolved) deducted stock and marked the item sold AGAIN. The order cart itself
still showed the correct 1 item, but Transaction History, Product History, and Sales Analysis pages
all showed figures for 2 items. Explicit asks: why does a repeated request go unhandled, and block
the UI during the transaction if needed.

## Root cause (traced statically — no Qt toolchain in this sandbox, per standing rule)

`DataModel._tryCompleteOrder`'s only "already completing" guard was
`if (o.status === "completed") return`, reading `OrdersStore.getById(orderId)` — the LOCAL cache.
That field only flips to `"completed"` at the very end of the function (inside `_afterAllDeltas`,
after every line's FIFO consumption + `InventoryStore.deductStock` has actually resolved). A second
call for the same order arriving before the first finishes sees the same stale `"pending"` status,
sails past the guard, and re-runs the entire stock deduction + `SalesStore.recordSale` +
`TransactionStore.recordSaleFromOrder` from scratch. `SalesStore`'s dashboard KPI is self-correcting
(recomputes from `OrdersStore` rather than accumulating — itself a fix for a near-identical prior
bug, per its own header comment), so it didn't show the doubling; the DISCRETE ledger writes
(`TransactionStore.entries`) and stock deltas did — exactly what Transaction/Product History and
Sales Analysis read from.

**Why the existing UI gave no protection:** `OrderDetailDialog._save()` fired `logic.updateOrder`
(a fire-and-forget signal) and called `dlg.close()` on the very next line — zero connection to
whether the underlying write had even started resolving. Nothing stopped the user from reopening
the order and hitting Save again while the first save's async chain was still running.

**Why `LockManager` doesn't (and structurally can't) catch this either:** traced
`functions/lib/lockLogic.js`'s `acquireLock` — it grants automatically when
`current.holderUid === params.actorUid` ("sameHolder"), required so a lock-renewal heartbeat can
re-acquire its own lock. That means the SAME logged-in user re-entering while their own previous
request is still in flight sails through too. `OrdersPage._approveAllPending()` already wraps each
completion in a real `LockManager.acquire`/`release` pair and still isn't protected against a
same-user double-click, for this exact reason.

**Notable confirming detail:** `_tryCompleteOrder`'s own header comment already says making this
function genuinely async (round 4 of the async-write-sequencing design) was specifically so a
caller could show "a real busy indicator instead of a decorative one" — the infrastructure for
this fix already existed and was simply never wired up on `OrderDetailDialog`'s side.

## Fix — two layers, one root cause ("no in-flight tracking for order completion, at any layer")

1. **`qml/model/DataModel.qml`** — new `_completingOrderIds` property (orderId → true while a
   completion is between entry and callback), set synchronously right after the existing
   `!o`/`already-completed` checks and before any async call, cleared on all 3 remaining exit
   paths (stock-validation failure, delta failure, success). Independent of `OrdersStore`'s own
   stale status field and of which caller invokes it — protects `OrderDetailDialog`'s save,
   `OrdersPage._approveAllPending`'s bulk loop, and `onAddOrder`'s auto-approve branch alike.
2. **`qml/pages/OrderDetailDialog.qml`** — wired up to `BottomSheet.qml`'s existing
   `busy`/`busyMessage` mechanism (already used correctly by `RestockDialog`/`AddProductDialog`/
   `AddStaffDialog`/`ImportPreviewDialog` — this dialog was the one holdout). `_save()` now sets
   `busy = true` + a message before firing `logic.updateOrder`, and a new `Connections { target:
   logic }` block waits for `logic.orderUpdated`/`logic.orderCompletionFailed` — scoped to
   `_pendingSaveOrderId`, since both signals are on the shared dispatcher and fire for unrelated
   orders too — before clearing `busy` and closing (success) or showing the error without closing
   (failure). Also added a defensive `if (busy) return` at the top of `_save()` and a `busy = false`
   / `_pendingSaveOrderId = ""` reset in `openFor()`, matching this dialog's own existing defensive
   idioms elsewhere (`_lockState` reset).

## Tests (TDD — written before the fix, per `superpowers:test-driven-development`)

**New file `tests/tst_DataModel_completeOrderReentrancy.qml`** — 6 cases, real
`DataModel._tryCompleteOrder` calls, same child-item-instantiation pattern as
`tst_DataModel_adjustOrderSyncGuard.qml`. **Genuinely run via CI on PR #70 — 818/818 QML tests
passing (1025/1025 overall), confirmed via `commits/{sha}/check-runs`** — but only after two rounds
of real CI-driven corrections to the test file itself, both worth remembering for future sessions:

1. **Round 1 (Skill 62):** the first version tried to reassign `StockBatchStore.consumeFifo` to
   simulate a race — threw `Cannot assign to read-only property` at runtime. A QML top-level
   `function` declaration compiles to a read-only invokable member, not a mutable JS property the
   way a plain object's method would be; none of this codebase's store methods can be stubbed by
   reassignment. That version also leaked `_completingOrderIds` state across test functions (`dm`
   is instantiated once for the whole `TestCase`, not per test) since `init()` never reset it.
2. **Round 2 (Skill 63):** the corrected version still assumed `_tryCompleteOrder`'s happy path
   resolves synchronously, like every other `DataModel` orchestration function in this suite. It
   doesn't: `InventoryStore.deductStock`'s callback is wired straight to `Gateway.recordDelta`'s own
   callback, which only fires from a REAL `XMLHttpRequest` response — with `AuthStore.idToken`
   empty (this suite's "offline" convention), `Gateway._sendDelta` returns immediately without ever
   invoking the callback at all. No local-apply shortcut here, unlike `_tryAdjustOrder`'s
   callback-less `creditStockNoBatch`/`restoreFifo`.

The final version turns limitation 2 into the test mechanism: two REAL sequential
`_tryCompleteOrder` calls for the same order, since the first call's own callback genuinely never
resolves in this harness — no monkey-patching, no manually-seeded state. The already-completed
short-circuit and missing-order cases seed their own preconditions directly (same convention
`tst_DataModel_adjustOrderSyncGuard.qml` uses for its own guard). The genuine Gateway happy path
(a live Cloud Function actually returning `ok:true`) remains out of reach for plain `qmltestrunner`
— documented as an E2E/on-device gap, same tier as `OrderDetailDialog`'s own busy-state UI.

No automated coverage for `OrderDetailDialog`'s own busy-state UI wiring — Felgo-dependent dialog,
out of this harness's reach (see `test/felgo-dependent/README.md`); on-device only, see the test
plan.

## Docs updated this session

- `SKILLS.md` — appended **Skill 61** (root cause + fix writeup), **Skill 62** (QML `function`
  members are read-only, can't be monkey-patched), and **Skill 63** (`_tryCompleteOrder`'s happy
  path needs a live Gateway backend to test) — all append-only.
- `AGENTS.md` — Data Model & Orchestration Agent section: new bullet on the in-flight-guard
  convention (`_completingOrderIds`) and why `LockManager` can't substitute for it. Pages &
  Dialogs Agent section: new bullet on the busy/wait-for-ack convention for any dialog whose save
  can trigger slow `DataModel` orchestration.
- `README.md` — new dated entry under "Concurrency & Conflict Resolution" (2026-09-14).
- `docs/superpowers/test-plans/2026-09-14-order-completion-double-submit-test-plan.md` — new,
  standard format (Skill 49): automated coverage sections 1–4, then On-Device Test Plan
  (Happy Path / Negative / Edge Cases / Affected Areas / Regression Tests).
- `docs/superpowers/test-plans/README.md` — new index row, newest first.
- `docs/superpowers/specs/2026-09-02-price-adjust-tax-delta-CHECKPOINT.md` — archived copy of the
  previous session's final CHECKPOINT.md (see note at top of this file).

## Explicitly out of scope this session (flagged to Taher, not silently dropped)

- `OrdersPage._approveAllPending()`'s "Approve all pending" banner has no busy/disabled state of
  its own. Now safe from a DATA-correctness standpoint (shares the `_completingOrderIds`-guarded
  engine), but still gives no visual feedback while working — same underlying UX gap, different
  file/UI surface. Not pulled into this fix since the actual reported defect (double-deduction)
  doesn't depend on it.
- `ConfirmReturnSheet`'s lock-span gap (pre-existing open item, `overview.md`) — untouched.
- `StockBatchStore`'s FIFO functions still on whole-record `recordMutation` (pre-existing open
  item) — untouched.

## Status / next steps

- [x] Root cause traced and confirmed (static trace, both the primary UI bug and the lock's
      `sameHolder` gap).
- [x] Branch created off `main`.
- [x] Failing test written first (TDD).
- [x] Production fix implemented (both layers).
- [x] Docs updated (SKILLS.md, AGENTS.md, README.md, test plan + its index).
- [x] Previous session's stale CHECKPOINT.md archived.
- [x] Committed and pushed (3 commits: fix, round-1 test correction, round-2 test correction) using
      Taher's authorship convention (`Taher (via Claude session)` / `tsowner@lkdigitalworks.com`)
      and PAT embedded directly in each one-off push command — `.git/config` verified clean of the
      token after every push.
- [x] **PR #70 opened** against `main` (`checks.yml` only triggers on PR/push-to-main, not raw
      feature-branch pushes) —
      https://github.com/lkdigitalworks-53/InventoryManagerUI/pull/70
- [x] CI genuinely green — **1025/1025 tests passing** (818 QML, 138 Functions, 28 Firestore
      Rules, 41 E2E), confirmed via `commits/{sha}/check-runs` + the PR's auto-posted test-summary
      comment, not assumed. Took 2 rounds of test-file corrections to get there (Skills 61–62) —
      the production fix itself (`DataModel.qml`, `OrderDetailDialog.qml`) was correct from the
      first push; only the new test file needed fixing.
- [x] Not building/running the app this session, per standing instruction.
- [x] Taher tested all scenarios on device — confirmed working.
- [x] Reviewed against `/superpowers:requesting-code-review`, `qt-development-skills:qt-qml-review`,
      and `/ponytail:ponytail-review` (done directly, no subagent-dispatch tool in this environment) —
      zero findings in the actual diff (pre-existing whole-file style debt excluded per the QML
      review skill's own diff-scoping rule).
- [x] Rebased onto `main` (which had picked up PR #71 in the meantime) — resolved the two expected
      conflicts: `CHECKPOINT.md` (kept branch version per convention) and `SKILLS.md` (renumbered
      this branch's Skill 60/61/62 to 61/62/63 to sit after the audit's own Skill 60 — fixed every
      cross-reference to the old numbers across README.md, AGENTS.md, the test file, the test plan,
      and `docs/superpowers/ASYNC-REENTRANCY-BUGS.md`).
- [x] **Correction mid-rebase**: `git checkout --ours` during a `git rebase` means the opposite of
      what it means during a `git merge` — `--ours` gave main's content, not the branch's, on both
      `CHECKPOINT.md` conflicts. Caught it by checking the actual file content immediately after
      instead of trusting the flag name, and recovered the correct branch content via
      `git show <pre-rebase-branch-tip>:CHECKPOINT.md`. Worth remembering: **for rebase conflicts,
      use `--theirs` to keep the branch's own content, not `--ours`.**
- [ ] **Next: merge to `main`, push.**

## Open items carried forward, unchanged (from `overview.md`, not re-verified this session)

- P1 stock-movement taxonomy branch (`feature/p1-stock-movement-taxonomy`) — rebase conflict in
  `InventoryStore.qml`, unresolved; `tst_StockMovementStore.qml` still not implemented.
- `StockBatchStore`'s FIFO functions still whole-record `recordMutation`, not `recordDelta`.
- `ConfirmReturnSheet`'s lock doesn't span into `OrderDetailDialog`'s confirmation handoff window.
