# CHECKPOINT — 2026-09-20: order-completion double-consume (C-3) design kickoff (design gate, no code yet)

**Session date:** 2026-09-20
**Branch:** `docs/2026-09-18-idempotency-scoping-checkpoint`, rebuilt as a single commit on `main` @ `318dd38`
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-16-new-order-double-submit-CHECKPOINT.md`
(byte-identical to what PR #75 archives at the same path, so the two merge cleanly).
**Skills invoked by Taher:** `superpowers:brainstorming` (HARD-GATE: no implementation before an approved
design), `qt-development-skills:qt-qml`, `ponytail:ponytail`. Caveman mode: FULL.
**Commit identity:** `Taher (via Claude session) <tsowner@lkdigitalworks.com>` (repo convention; not verified
against the claude.ai account email). PAT is supplied by Taher in chat each session and is never written to
the repo, `.git/config`, or memory.

## Step log (append-only; resume from the last ticked step)

- [x] 1. Cloned repo, read roadmap, tracker (`ASYNC-REENTRANCY-BUGS.md`) and PR state live.
- [x] 2. Told Taher the item was NOT picked from `main`'s roadmap list: it came from the tracker's C-3 entry
      (the roadmap only got a pointer via PR #73). Taher moved on to sequencing without objecting.
- [x] 3. Rebased PR #73 onto `main` (one roadmap conflict, both sides kept), CI green, then merged by Taher.
- [x] 4. Sequencing analysis: merge #72 first (Taher's on-device retests came back clean per the tracker), then C-3 / C-1. PR #72 and #73 are
      now both merged (`main` @ `318dd38`).
- [x] 5. Taher asked to triage PR #64. Verdict: obsolete, recommend close without merging (below).
- [x] 6. Found a **label collision** on `main` (below) and a new open PR #75 that touches `Gateway.qml`.
- [ ] 7. **Blocked on Taher's answers to Q1-Q4 below.** Next: brainstorming step 4/5 (approaches, design in
      sections, approval), design doc under `docs/superpowers/specs/`, then `superpowers:writing-plans`.

Not done, deliberately: no code, no tests, no test plan, no `SKILLS.md`/`AGENTS.md`/`README.md` edits: there
is no change to test or document yet; the test plan is written together with the approved design.
App not built or run (standing instruction). No Qt tooling installed in the sandbox (standing instruction).

## PR #64 triage (2026-08-30 docs, 3 commits, 72 behind `main`)

Same topic as work that has since shipped, older snapshot. Its roadmap text says the batch-id mint fix is
"blocked on N3" and the `orderMath.js` parity gap is "decision pending". On `main`: N3 was run on-device and
the mint item was fixed 2026-09-14 (retry queue; `topUpOldest` always synthesizes a batch); `orderMath.js`
parity was implemented 2026-09-01 (100% line and branch); its handler-parity checkpoint is already on `main`
(PR #49). Merging would replace `main`'s root `CHECKPOINT.md` and reintroduce "pending" text on resolved
items. One nugget worth keeping in mind for C-3: `StockBatchStore.topUpOldest` (`:593`) still calls its
callback unconditionally, even if `addBatch` returned no doc; a failed mint now lands in the retry queue,
so it is no longer silent data loss, but the callback still carries no error.

## Findings that shape the C-3 design

- The server already has transport-level idempotency: `recordMutation`/`recordDelta`/batch carry a
  `requestId`, the `audit_log` doc id IS that id, and a repeat returns `idempotentReplay: true` without
  re-applying (`functions/index.js` header, `functions/lib/gatewayLogic.js` ~138-150 and ~187-194).
- It is defeated one layer up: `Gateway._nextRequestId()` (`qml/model/Gateway.qml:130`) mints a fresh
  `"req-" + Date.now() + "-" + random` per call, so a re-run of `_tryCompleteOrder` after its in-memory
  guard is lost gets new ids and the server cannot recognise them as the same operation.
- `StockBatchStore.consumeFifo` plans from *local* `qtyRemaining` and reconciles floor rejections against
  the server's `current`; its plan is not stable across attempts.
- `Gateway.recordDelta` coalesces queued deltas for the same entity+entityId, so the surviving `requestId`
  can belong to an earlier call. Any caller-supplied key scheme must account for that.
- Reasoning, not measured: adding XHR timeouts *before* operation-level idempotency turns "hung" into
  "outcome unknown", which is what produces double-apply on retry.

## Candidate approaches (Taher's stated direction: general, not a one-call patch)

- A. Stable operation keys only (deterministic `requestId` passed by callers). Smallest diff, no server
  change. Holes: FIFO plan drift on partial drain, same key + different delta silently replayed with the
  old `after`, key reuse across a legitimate re-completion needs an epoch.
- B. Write-ahead intent + stable keys: persist the plan on the order first, derive every step's key from the
  intent id, resume from the persisted plan. Closes A's holes, reusable for C-1. Costs: order schema field,
  rules/validation, old-client compatibility, resume trigger. Logic can live in a pure JS helper so 100%
  coverage is measurable in Node.
- C. Server-side `completeOrder` Cloud Function with a Firestore transaction: true atomicity, fully
  Node-testable. Costs: no precedent, offline-first tension, FIFO/top-up/tax math re-homed, deploy-order
  coupling with client releases. Largest blast radius.
- Recommendation on record: B, scoped first to `_tryCompleteOrder`, C-1 as second consumer; A only as a
  stopgap. Not a new network layer.

## Found this session, needs a decision

- **Two different bugs are both labelled "C-3" on `main`.** `ASYNC-REENTRANCY-BUGS.md:175` is the
  `RestockDialog` double-press entry (resolved, no repro: stale-build explanation, no code changed) and
  `:214` is `_tryCompleteOrder` (this arc). `AGENTS.md:453` and `README.md:720` mean the Restock one; the
  roadmap (`:59-73`) and PR #73 mean the order-completion one. Textually the two PRs merged without
  conflict, which hid it. Proposed fix: renumber the Restock entry to C-4 (closed) and update its cross-refs.
- **PR #75** (open, not from this session, CI 1108/1108, `mergeable_state: clean`): Gateway "stuck write"
  indicator. Touches `Gateway.qml` `_send`/`_sendBatch`/`_sendDelta`, the same file C-3 would touch.
  Recommend merging it before the C-3 implementation branch, same reasoning as #72.

## Open decisions for Taher

- Q1. Rename the Restock "C-3" to C-4 (docs-only PR before design work), or another scheme?
- Q2. Merge #75 before C-3 implementation branches?
- Q3. Must order completion keep working fully offline (queued in the outbox), or is "completion needs a
  connection" acceptable? This decides whether approach C is even on the table.
- Q4. Can two devices/staff sessions complete orders for the same product at the same time in real use?
  This decides how hard B's resume path gets (floor-rejection while resuming).

## Resume instructions

Fresh session: clone, read this file, re-check open PR state live (#64, #74, #75), then continue at step 7.
Do not start implementation before the design is approved. `CHECKPOINT.md` will conflict with PR #75's copy;
resolve by keeping the branch version and archiving `main`'s under `docs/superpowers/specs/`.
