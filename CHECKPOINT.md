# CHECKPOINT — 2026-09-20: C-3 spec, plan and test plan written (design only, no implementation)

**Session date:** 2026-09-20
**Branch:** `docs/2026-09-20-atomic-operation-spec-plan`, one commit on `main` @ `318dd38`
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-16-new-order-double-submit-CHECKPOINT.md`
(byte-identical to what PR #75 archives at the same path, so the two merge cleanly).
**Supersedes:** draft PR #74 (this file replaces its checkpoint; #74 is closed).
**Skills invoked by Taher:** `superpowers:brainstorming`, `superpowers:writing-plans` (used for the plan),
`qt-development-skills:qt-qml`, `ponytail:ponytail`. Caveman mode: FULL.
**Commit identity:** `Taher (via Claude session) <tsowner@lkdigitalworks.com>` (repo convention; not verified
against the claude.ai account email). PAT is supplied by Taher in chat each session and is never written to
the repo, `.git/config`, or memory.

## Deliverables in this PR

- `docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md`: the approved design (D1-D5).
- `docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md`: 13 tasks in 3 phases. The code in Tasks 1-5
  is embedded byte for byte from files that were actually run (below).
- `docs/superpowers/test-plans/2026-09-20-atomic-operation-outbox-test-plan.md` (+ index row): standard
  format, each row marked "verified" or "planned".
- Tracker pointer on the `_tryCompleteOrder` entry in `ASYNC-REENTRANCY-BUGS.md` (still marked not fixed).
- Not touched on purpose: `SKILLS.md`, `AGENTS.md`, `README.md`. PR #75 adds a Skill at the same time, so a
  second one here would collide on the number; they are updated in the implementation PRs (plan Task 12).

## Step log (append-only; resume from the last ticked step)

- [x] 1. Cloned repo, read roadmap, tracker, live PR state. The item came from the tracker's C-3 entry, not
      from `main`'s roadmap list (Taher was told; he moved on).
- [x] 2. Rebased PR #73 (one roadmap conflict, both sides kept); Taher merged #72 and #73. PR #64 triaged as
      obsolete; it is now closed, unmerged.
- [x] 3. Found the duplicate "C-3" label; Taher chose to rename the Restock one to C-4: PR #76 (docs only,
      CI green, open).
- [x] 4. Taher's answers: offline outbox must stay; two devices can complete the same product concurrently;
      merge #75 before implementation. Decisions D1 approve approach D, D2 server-first pilot on compound ops
      only, D3 apply an offline-queued completion anyway (drift repair, clamp), D4 Taher deploys functions
      (dev only), D5 timeouts count as stuck writes.
- [x] 5. Wrote the spec, plan and test plan (this PR).
- [x] 6. Verified what can run in the sandbox (no Qt toolchain):
      - Server: `operationLogic.js` + `recordOperation` handler + harness edit applied to a scratch copy of
        `functions/`: whole suite 228/228 pass (195 existing + 33 new), `operationLogic.js` 100% line, branch,
        function; 14/14 deliberate mutations caught. The embedded `index.js` and harness patches were checked
        with `git apply --check` against `main`.
      - Client pure helpers (`CompletionPlan`, `OperationKeys`, `SendPolicy`, `StuckWrites` change): 68 test
        bodies (47 new, 21 being #75's existing StuckWrites tests) executed in Node through a shim: all pass;
        21/21 deliberate mutations caught after two tests were added for the two that survived. NOT run under
        `qmltestrunner`, so QML syntax of those test files is unproven until CI.
      - Tasks 6-11 (Outbox, Gateway, stores, DataModel, UI) are unexecuted drafts.
- [x] 7. Corrections and findings made while writing (all recorded in the spec):
      - "No timeouts anywhere in `qml/`" was too broad: `AuthService._postJson` (20s) and
        `StockBatchStore.nextBatchId` (15s) race a Timer against the XHR. Gateway senders and
        `FirebaseService._request` have none.
      - `OutboxStore.dueItems()` checks in-flight keys only once per pass, so two due items sharing a key can
        be dispatched together; needed a fix because an operation touches many keys (plan Task 6).
      - Orders can be reopened (`_reverseCompletedOrder`), so the key needs an epoch stored on the order.
      - Sale `txId` is random (`_nextId`), so a re-run would also double-book revenue; ids become deterministic.
      - Two lines of one product were validated separately against stock; the planner sums demand.
- [ ] 8. **Waiting on Taher:** review of this PR; merge of #75 and #76. Phase 1 (server endpoint, plan Tasks 1-2)
      does not touch #75's files; ask Taher whether it may start before #75 merges. Phase 2 needs #75 (it edits
      #75's `StuckWrites.js`). Phase 3 needs Phases 1-2 merged and the function deployed to dev by Taher.

## Open questions for Taher

- Review focus: spec 4.6 (rejection handling and D3), 4.2 (marker holds full `after` docs, bounded by the
  200-op cap), and the optimistic apply / revert / re-plan logic in plan Task 10 (the least certain part).
- May Phase 1 (server only) start before #75 merges?
- Confirm the commit email.

## Resume instructions

Fresh session: clone, read this file, re-check open PR state live (#74 closed, #75, #76, this PR), then
continue at step 8. Do not build or run the app until Taher asks. `CHECKPOINT.md` will conflict with PR #75's
copy; resolve by keeping the branch version and archiving `main`'s under `docs/superpowers/specs/`.
