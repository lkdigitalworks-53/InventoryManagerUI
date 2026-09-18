# CHECKPOINT — 2026-09-18: scoping "next important E2E-roadmap item" (design gate, no code yet)

**Session date:** 2026-09-18
**Branch:** `docs/2026-09-18-idempotency-scoping-checkpoint`, off `main` @ `bec7cd4`
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-14-order-completion-double-submit-CHECKPOINT.md`
(PR #70 is already merged into `main` as `a66fb8f`; that file was still sitting at the repo root,
describing the PR as "merging now".)
**Skills invoked by Taher:** `superpowers:brainstorming` (HARD-GATE: no implementation before an
approved design), `qt-development-skills:qt-qml`, `ponytail:ponytail`. Caveman mode: FULL.

## Ask

"Clone the repo and take the next important item from the e2e roadmap."

## Step log (append-only; resume from the last ticked step)

- [x] 1. Cloned `lkdigitalworks-53/InventoryManagerUI` fresh (public clone, no token). Commit identity set
      to `Taher (via Claude session) <tsowner@lkdigitalworks.com>`, the repo's own convention for Claude
      sessions (latest such commits are dated 2026-09-18). Not verified against the claude.ai account email.
- [x] 2. Read `CHECKPOINT.md` and `docs/superpowers/E2E-TESTING-ROADMAP.md` on `main`.
- [x] 3. Checked live GitHub state (not inferred from local): open PRs #72, #73 and 6 older ones.
- [x] 4. Read `docs/superpowers/ASYNC-REENTRANCY-BUGS.md` and PR #73's diff (adds C-3).
- [x] 5. Traced the idempotency plumbing in code (findings below) to ground the approach trade-offs.
- [x] 6. Created this branch, archived the stale checkpoint, wrote this file.
- [x] 7. Posted findings + Q1-Q3 to Taher (PR #74 opened as draft).
- [x] 8. Taher asked: rebase PR #73 first, report if mergeable, then discuss scope. Rebased
      `docs/2026-09-16-order-completion-idempotency-gap-v2` onto `main` @ `bec7cd4`. One conflict, in
      `E2E-TESTING-ROADMAP.md` (both sides inserted after the XHR-timeout item). Kept both whole; C-3 entry
      placed first (Critical before the Medium/Low audit findings, and it references the timeout item just
      above it). `ASYNC-REENTRANCY-BUGS.md` auto-merged. Diff vs `main` is exactly the same 2 files, +103/-0.
      Commit re-authored to `Taher (via Claude session)`, force-pushed with lease. CI on `88bf85b`: all 5
      checks green, `mergeable_state: clean`. Trial merge of rebased #73 with PR #72: no conflicts.
- [x] 9. Taher asked: should C-2 (PR #72) merge before C-3 starts, and when should C-1 start? Verified
      before answering: PR #72 touches only ~8 lines of `DataModel.qml` (`onAddOrder` failure branch, near
      line 73), 1 line of `Logic.qml`, and `NewOrderDialog.qml`, so there is almost no code overlap with
      C-3 (`_tryCompleteOrder`, ~line 425) or C-1 (`_tryAdjustOrder`, ~line 763, `ConfirmReturnSheet`).
      The real conflict cost between PRs is docs: `SKILLS.md` numbering, `AGENTS.md`, `README.md`,
      `ASYNC-REENTRANCY-BUGS.md`, `CHECKPOINT.md`. One real code dependency: `onAddOrder`'s auto-approve
      branch calls `_tryCompleteOrder`, so C-3 must build on #72's `onAddOrder`. C-1 confirmed still
      unguarded on #72's branch (`ConfirmReturnSheet` still closes right after `confirmed(...)` and releases
      the lock in `onClosed`). #72's dialog test is a plain-JS stand-in, so green CI does not prove the real
      dialog; its test plan has an on-device section.
- [ ] 10. **Scope discussion with Taher** (his call after step 8). Q1-Q3 below still open. Then brainstorming
      step 4/5 (approaches, design in sections, approval), design doc under `docs/superpowers/specs/`,
      then `superpowers:writing-plans`.

**Provenance note (Taher asked directly):** the item was NOT taken from the list on `main`'s
`E2E-TESTING-ROADMAP.md`. The detailed C-3 entry lives in `ASYNC-REENTRANCY-BUGS.md`; the roadmap only gets a
pointer to it via PR #73, which was unmerged and conflicted at the time. The roadmap items actually on `main`
(XHR timeout, staff cleanup, ActivityLog, Category/Channel writes) were passed over on my own judgement.

Not done, deliberately: no code, no tests, no test plan, no `SKILLS.md`/`AGENTS.md`/`README.md` edits.
There is no change to test or document yet; the test plan is written together with the approved design.
App not built or run (standing instruction). No Qt tooling installed in the sandbox (standing instruction).

## Live state found (2026-09-18)

- `main`'s roadmap is **stale**: it does not list C-3. That entry only exists in PR #73
  (`docs/2026-09-16-order-completion-idempotency-gap-v2`), which was `mergeable_state: dirty` (fixed in step 8: now rebased, CI green, clean).
- PR #72 (`fix/2026-09-16-new-order-double-submit`, C-2 fix): CI all green (QML, Functions, Rules, E2E,
  summary comment), `mergeable_state: clean`, awaiting Taher's merge.
- C-1 (`ConfirmReturnSheet` -> `_tryAdjustOrder` double-deduct) is still unfixed and Critical.
- Roadmap items on `main` are: systemic XHR timeout (deferred by Taher), `StaffStore.deleteStaff` orphaned
  auth docs (Medium), `ActivityLog.record` bypasses durable path (Medium-low), Category/OrderChannel config
  writes (Low).

## Code findings that shape the design

- The server already has transport-level idempotency: `recordMutation`/`recordDelta`/batch carry a
  `requestId`, the `audit_log` doc id IS that id, and a repeat returns `idempotentReplay: true` without
  re-applying (`functions/index.js` header, `functions/lib/gatewayLogic.js` ~138-150 and ~187-194).
- It is defeated one layer up: `Gateway._nextRequestId()` (`qml/model/Gateway.qml:130`) mints a fresh
  `"req-" + Date.now() + "-" + random` per call, so a re-run of `_tryCompleteOrder` after its in-memory
  guard is lost gets new ids and the server cannot recognise them as the same operation.
- `StockBatchStore.consumeFifo` plans from *local* `qtyRemaining` and reconciles floor rejections against
  the server's `current`; its plan is therefore not stable across attempts.
- `Gateway.recordDelta` coalesces queued deltas for the same entity+entityId, so the surviving
  `requestId` can belong to an earlier call. Any caller-supplied key scheme has to account for that.
- Reasoning, not measured: adding XHR timeouts *before* operation-level idempotency turns "hung" into
  "outcome unknown", which is the exact state that produces double-apply on retry. PR #73 makes the same
  ordering argument.

## Candidate approaches for C-3 (Taher's stated direction: general, not a one-call patch)

- A. Stable operation keys only: callers pass a deterministic `requestId` into `recordDelta`/`recordMutation`.
  Smallest diff, no server change. Holes: FIFO plan drift (partial-drain case), same key + different delta is
  silently replayed with the old `after`, key reuse across a legitimate re-completion needs an epoch.
- B. Write-ahead intent + stable keys: persist the plan on the order first (one durable mutation), derive every
  step's key from the intent id, resume from the persisted plan on retry. Closes A's holes; reusable for C-1.
  Costs: order schema field, Firestore rules/validation, old-client compatibility, resume trigger design.
  Logic can live in a pure JS helper so it is measurable in Node (100% coverage claim checkable there).
- C. Server-side `completeOrder` Cloud Function with a Firestore transaction: true atomicity, fully
  Node-testable here. Costs: no precedent in this codebase, offline-first tension, must re-home FIFO/top-up
  and tax/discount math, deploy-order coupling with client releases. Largest blast radius.
- Recommendation on record: B, scoped first to `_tryCompleteOrder`, C-1 as the second consumer; A only if
  Taher wants a stopgap. Not a new network layer.

## Proposed sequencing (recommendation, awaiting Taher's decision)

1. Merge PR #73 (docs, clean, CI green). No dependency on anything.
2. Taher device-checks PR #72 (same bar as PR #70), then merge it. Everything after branches from `main`.
3. Same sitting: on-device repro of C-1 (double-tap Confirm on an exchange with extra quantity). C-1 and C-2
   were found by static trace/sweep, not reproduced; only the original #70 bug and C-3 were.
4. C-3 *design* (docs only) proceeds now, in parallel. C-3 *implementation* branches after #72 merges.
5. C-1 fix (same two-layer pattern as #70/#72: in-flight guard + busy wiring, lock release moved to after
   completion) starts right after #72 merges, before C-3 implementation. Open point: a busy state with no
   XHR timeout can stay stuck forever, so C-1's sheet needs a defined exit.
   Trade-off on record: fixing C-1 first adds a third in-memory guard that C-3 may later restructure;
   waiting for C-3 leaves an easy-to-trigger Critical open for a multi-session arc.

## Open decisions for Taher

- Q1. Confirm the item: C-3/idempotency (with C-1/C-2 as consumers) over the roadmap-listed Medium/Low items
  and over XHR timeouts first.
- Q2. Approach A, B or C. Deciding fact I need: can two devices/staff sessions complete orders for the same
  product concurrently in real use?
- Q3. Sequencing: merge PR #72 first, then branch off `main`; and whether I should rebase PR #73 (docs only).

## Resume instructions

Fresh session: clone, read this file, re-check PR #72/#73 state live, then continue at step 7. Do not
start implementation before the design is approved. `CHECKPOINT.md` will conflict with PR #72's copy when
both land; resolve by keeping the branch version and archiving `main`'s under `docs/superpowers/specs/`
(for `git rebase`, `--theirs` keeps the branch's content).
