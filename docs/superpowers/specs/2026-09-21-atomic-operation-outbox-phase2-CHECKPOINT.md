# CHECKPOINT — 2026-09-20: C-3 spec, plan and test plan written (design only, no implementation)

**Session date:** 2026-09-20
**Branch:** `docs/2026-09-20-atomic-operation-spec-plan`, rebased onto `main` @ `55451b3` (after #75 and #76 merged)
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-CHECKPOINT.md`
(PR #75's arc; the older #72 arc was archived by #75 itself).
**Supersedes:** draft PR #74 (this file replaces its checkpoint; #74 is closed).
**Skills invoked by Taher:** `superpowers:brainstorming`, `superpowers:writing-plans` (used for the plan),
`qt-development-skills:qt-qml`, `ponytail:ponytail`. Caveman mode: FULL.
**Commit identity:** `Taher (via Claude session) <tsowner@lkdigitalworks.com>` (confirmed by Taher). PAT is supplied by Taher in chat each session and is never written to
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
- [x] 8. Taher answered: Phase 1 (server) may start now; PRs #75 and #76 are under his review and he will
      update; the commit email `tsowner@lkdigitalworks.com` is confirmed.
- [x] 9. Phase 1 implemented as PR #78 (`feature/2026-09-21-record-operation-endpoint`, cut from `main`):
      tests written first and seen failing (`Cannot find module '../lib/operationLogic'`), then
      `operationLogic.js` + the `recordOperation` handler + harness edit. Local run on the branch: `functions/`
      suite 228/228 (195 existing + 33 new), `operationLogic.js` 100% line/branch/function, `index.js` 99.89%
      (the same pre-existing uncovered line). CI on PR #78: all 5 checks green, `mergeable_state: clean`.
      README update and an AGENTS bullet added; `SKILLS.md` deliberately not touched (Skill-number collision
      with #75). `git push -u` briefly wrote the token URL into `.git/config`; removed and verified (sandbox
      only, never in the repo). Use plain `git push <url> <branch>` without `-u`.
- [x] 10. Taher: PR #75 merged (and #76); he will deploy `recordOperation` himself; asked whether #77 and #78
      can merge, then "next steps".
- [x] 11. Checked live: #78 `mergeable_state: clean`, CI green. #77 was `dirty`: rebased onto `main` @
      `55451b3` (two conflicts: this file, kept mine and archived main's under
      `specs/2026-09-19-gateway-stuck-write-indicator-CHECKPOINT.md`; `test-plans/README.md`, both index rows
      kept, newest first). Refreshed the statements that went stale (spec status, tracker pointer).
      The embedded `StuckWrites` patch still applies to the merged file (`git apply --check`).
- [x] 12. Phase 2 (plan Tasks 3-5, pure helpers) implemented as PR #79
      (`feature/2026-09-21-operation-helpers`, cut from `main` @ `55451b3`), four commits: `StuckWrites`
      timeouts (D5), `SendPolicy` + `OperationKeys`, `CompletionPlan`, docs notes. Tests first: the new
      StuckWrites tests were seen failing (4 of 6; the other 2 assert unchanged behaviour), the new helper
      tests failed on the missing modules. Before pushing: 68 test bodies (47 new) executed in Node through
      a shim, 21/21 deliberate mutations caught against the repo files. **CI on #79: all 5 checks green, and
      the QML job ran the new files under the real `qmltestrunner`**: 901 -> 954 tests (+53 = 47 new + an
      `initTestCase`/`cleanupTestCase` pair for each of the 3 new files). This settles the earlier caveat
      that QML syntax of those test files was unproven.
- [ ] 13. **Waiting on Taher:** merge of #77, #78, #79 (all `clean`, CI green; suggested order #77, #78, #79,
      no dependency between them); deploy of `recordOperation` to dev (curl expecting `401 missing-token`).
      Phase 3 (plan Tasks 6-11, Outbox/Gateway/stores/DataModel/UI) needs #78 and #79 merged and the
      function deployed. It is the largest and least certain part; Task 10's optimistic apply / revert /
      re-plan logic should get Taher's review first.

## Open questions for Taher

- Review focus: spec 4.6 (rejection handling and D3), 4.2 (marker holds full `after` docs, bounded by the
  200-op cap), and the optimistic apply / revert / re-plan logic in plan Task 10 (the least certain part).
- Deploy result of `recordOperation` on dev (expected `401 missing-token` from an unauthenticated POST).

## Resume instructions

Fresh session: clone, read this file, re-check open PR state live (#75 and #76 merged, #74 closed, #77, #78, #79), then
continue at step 13. Do not build or run the app until Taher asks. `CHECKPOINT.md` will conflict with PR #75's
copy; resolve by keeping the branch version and archiving `main`'s under `docs/superpowers/specs/`.
