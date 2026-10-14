# CHECKPOINT — 2026-10-14 Task 11 "Saved, syncing" hint (stacked on PR #139)

**Branch:** `feat/2026-10-14-task11-saved-syncing` (base = PR #139 branch `docs/2026-10-13-completion-error-cause-design` @ cbd3363). Commit identity `taher.lkdw@gmail.com`. PAT only in the push command, never in files or the remote URL.
**Rules in force:** no build/run until Taher says so; no Qt tools in the sandbox (CI is the proof); branch + push without asking; honest trade-offs, grill before deciding; tests for every change (100% target) + a test plan; short scope, remote branch always resumable by another account.
**Archived previous checkpoint:** `docs/superpowers/specs/2026-10-14-pr139-prev-CHECKPOINT.md`.
**Skills used:** brainstorming (BOUNDED path), qt-qml, ponytail.

## Request (Taher)
On top of PR #139: check E2E roadmap + delete roadmap, pick the next priority item, design it, implement if design ready, raise PR, show next steps.

## What the roadmaps say (read, not re-derived)
- Delete roadmap: COMPLETE 2026-10-13. Only device re-checks left (O1 purge, O2 sign-out; `test-plans/2026-09-30-photos-s3-s4-s5-test-plan.md` L266-267, Taher).
- E2E roadmap C-3 atomic-operation arc, recorded order (PR #90 sweep, D-2): merge #90 -> error-cause UI (= PR #139, in review) -> **Task 11 "Saved, syncing" hint** -> Task 12 docs -> Task 13 deploy+device (Taher) -> C-1 `_tryAdjustOrder` etc.
- Higher risk but bigger and needs decisions: restock as one atomic operation (KNOWN-ISSUES top entry, DECIDED 2026-09-30, not built).

## Decision (mine, flagged to Taher)
Pick Task 11: it is the recorded next step, design exists in the plan, fits one session. NOT the highest-risk item (restock is) - see PR body for why and the grill list.

## Steps
- [x] 1. Cloned, read memory/skills/roadmaps/plan Task 11, read DataModel completion state machine + OrderDetailDialog
- [x] 2. Branch created from PR #139 head, checkpoint written
- [ ] 3. Design spec `specs/2026-10-14-task11-saved-syncing-design.md`
- [ ] 4. Implement DataModel (`syncingOrderIds`, `completionsSyncing`, `_closeOpen`, `_refreshSyncing`) + OrderDetailDialog caption
- [ ] 5. Tests: `tests/tst_DataModel_completionsSyncing.qml`, node wiring guard
- [ ] 6. Test plan + index row, Skill, SKILLS-INDEX regen, README/AGENTS lines, roadmap status lines
- [ ] 7. Push, PR (base = PR #139 branch), CI read

## NEXT (for the next session / account)
Read the PR checks first. QML tests are CI-only.
