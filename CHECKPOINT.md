# CHECKPOINT — 2026-10-15 PR #144 (Task 11): rebase + option B

**Branch:** `feat/2026-10-14-task11-saved-syncing` (PR #144, base `main`). Commit identity `taher.lkdw@gmail.com`. PAT only in push commands.
**Rules in force:** no build/run until Taher says so; no Qt tools in sandbox (CI is the proof); branch + push without asking; honest trade-offs; short scope.
**Archived previous checkpoints:** `docs/superpowers/specs/2026-10-15-pr144-review-session-prev-CHECKPOINT.md` (review session), `docs/superpowers/specs/2026-10-15-pr144-sweep-prev-CHECKPOINT.md` (Task 11 build session).

## Request (Taher)
Go with B (hide caption when the write is parked). PR #145 merged into #144. Rebase #144 on `main`, keep it ready.

## Steps
- [x] 1. Found #145 was squash-merged into #144 (no `main` ancestry), so #144 was dirty again
- [x] 2. Rebuilt #144 on `main` (cherry-pick the 4 commits; tree identical to the merged state, verified `git diff` empty); force-with-lease push; GitHub: mergeable clean, 4 commits, 16 files
- [x] 3. Option B: `Gateway.isParkedKey` (read-only), `_refreshSyncing` skips parked keys, `stuckTerminalCount` listener
- [x] 4. Tests: 6 new QML cases + monkey park/retry actions (QML file now 23 cases); node guard 15/15 (12 mutants), script suite 109/109
- [x] 5. Docs: design D-5, test plan, review note finding 2 RESOLVED, Skill 120 rules 6-7, SKILLS-INDEX
- [ ] 6. Push, watch CI (the 6 new QML cases are unrun until CI; suspect my test harness first if `qml-tests` is red)
- [ ] 7. Taher: device-test the plan (incl. parked completion + Retry + Discard), merge #144
