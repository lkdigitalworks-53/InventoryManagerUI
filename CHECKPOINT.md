# CHECKPOINT — 2026-10-13 error-cause UI (resume here)

**Branch:** `feat/2026-10-13-completion-error-cause`, stacked on design PR #139 (`docs/2026-10-13-completion-error-cause-design`). Main @ 0716427 (PR #90 merged).
**Commit identity:** `dextran52@gmail.com`. PAT only in the push command, never in a file or git config.
**Rules in force:** do not build/run the app; no Qt tools in the sandbox (CI is the proof); push without asking, Taher reviews in the PR; short scope (token budget); honest trade-offs, grill before deciding.
**Archived previous checkpoints:** `docs/superpowers/specs/2026-10-13-pr90-final-sweep-prev-CHECKPOINT.md`.

## Decisions (Taher, 2026-10-13): Q-EC-1 A client-only text, Q-EC-2 A one toast, Q-EC-3 A persist `lastError`

## Steps
- [x] 1. Design PR #139 pushed (see design doc, test plan)
- [x] 2. S1 `qml/helper/FailureCause.js` (+ `tests/tst_FailureCause.qml`, 16 cases)
- [x] 3. S2 stuck path: `StuckWrites` lastError, `OutboxStore.setStuckMeta`, `Gateway.stuckRows().cause`, `StuckWritesSheet` cause line, `DescribeItem` order label
- [x] 4. S3 `DataModel._failCompletion(announce)`, `Logic.orderCompletionReverted`, `Main.qml` Toast
- [x] 5. Tests: 48 written; pure-JS 142 green in a Node shim (29 new), 6 mutations caught; rest CI-only
- [x] 6. Docs: Skill 116 (+ `SKILLS-INDEX.md` regenerated, 21/21 script tests), AGENTS, README, test plan status, roadmap line
- [x] 7. Pushed, PR #140 raised (base = design branch of #139)
- [ ] 8. Read CI result on #140 and fix

## NEXT
Read CI on the PR and fix. After #139 and this PR merge: Task 11 "Saved, syncing" hint (`DataModel.completionsSyncing`, caption in `OrderDetailDialog`), then C-1 (`_tryAdjustOrder` atomic). Open items: e2e for the cause (no recipe to force `write-rejected`); exhausted-re-plan branch still marks the order `out of stock` whatever the cause (Skill 116 rule 6); `recordOperation` deploy + device run are Taher's (Task 13).
