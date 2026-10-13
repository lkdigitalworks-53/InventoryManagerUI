# CHECKPOINT — 2026-10-14 PR #139 rebased onto main (resume here)

**Branch:** `docs/2026-10-13-completion-error-cause-design` (PR #139, base `main`). PR #140 (`feat/2026-10-13-completion-error-cause`) was merged into it, so #139 now carries design + implementation. Rebased 2026-10-14 onto `main` @ d426773 (#141, #142 merged).
**Commit identity:** `taher.lkdw@gmail.com`. PAT only in the push command, never in a file or git config.
**Rules in force:** do not build/run the app; no Qt tools in the sandbox (CI is the proof); push without asking, Taher reviews in the PR; short scope (token budget); honest trade-offs, grill before deciding.
**Archived previous checkpoints:** `docs/superpowers/specs/2026-10-13-pr90-final-sweep-prev-CHECKPOINT.md`.

## Decisions (Taher, 2026-10-13): Q-EC-1 A client-only text, Q-EC-2 A one toast, Q-EC-3 A persist `lastError`

## Steps
- [x] 1. Design PR #139 pushed (see design doc, test plan)
- [x] 2. S1 `qml/helper/FailureCause.js` (+ `tests/tst_FailureCause.qml`, 16 cases)
- [x] 3. S2 stuck path: `StuckWrites` lastError, `OutboxStore.setStuckMeta`, `Gateway.stuckRows().cause`, `StuckWritesSheet` cause line, `DescribeItem` order label
- [x] 4. S3 `DataModel._failCompletion(announce)`, `Logic.orderCompletionReverted`, `Main.qml` Toast
- [x] 5. Tests: 48 written; pure-JS 142 green in a Node shim (29 new), 6 mutations caught; rest CI-only
- [x] 6. Docs: Skill 118 (+ `SKILLS-INDEX.md` regenerated, 21/21 script tests), AGENTS, README, test plan status, roadmap line
- [x] 7. Pushed, PR #140 raised (base = design branch of #139), merged into #139's branch
- [x] 8. CI round 1: QML compile error (reserved word `long` in tst_FailureCause), fixed; round 2 ALL GREEN on 4b8d823 (QML, Functions, Rules, E2E)
- [x] 9. 2026-10-14 rebase of #139 onto main: conflicts in CHECKPOINT (branch kept; main's version archived on main as the s4-cleanup prev-CHECKPOINT), DELETE-FEATURE-ROADMAP (main block + Update line), test-plans/README (both rows), SKILLS (branch Skill 116 renumbered to 118, main has 116/117), SKILLS-INDEX regenerated (119 skills). Code files auto-merged clean; no QML/JS conflict. Script tests 94/94.
- [ ] 10. Force-push with lease, fix PR #139 title/body, wait for CI on the new tip

## NEXT
CI on the rebased tip decides. If green: Taher reviews and squash-merges #139. After: Task 11 "Saved, syncing" hint (`DataModel.completionsSyncing`, caption in `OrderDetailDialog`), then C-1 (`_tryAdjustOrder` atomic).
