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
- [ ] 7. **Blocked on Taher's answers to Q1-Q3 below.** Next: brainstorming step 4/5 (propose approaches,
      present design in sections, get approval), then write the design doc under
      `docs/superpowers/specs/`, then `superpowers:writing-plans`.

Not done, deliberately: no code, no tests, no test plan, no `SKILLS.md`/`AGENTS.md`/`README.md` edits.
There is no change to test or document yet; the test plan is written together with the approved design.
App not built or run (standing instruction). No Qt tooling installed in the sandbox (standing instruction).

## Live state found (2026-09-18)

- `main`'s roadmap is **stale**: it does not list C-3. That entry only exists in PR #73
  (`docs/2026-09-16-order-completion-idempotency-gap-v2`), which is `mergeable_state: dirty`.
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
