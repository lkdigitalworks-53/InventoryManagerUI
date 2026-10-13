# CHECKPOINT — 2026-10-13 error-cause UI design (resume here)

**Branch:** `docs/2026-10-13-completion-error-cause-design` (design only, from `main` @ 0716427 = PR #90 merged). Implementation branch to use: `feat/2026-10-13-completion-error-cause`.
**Commit identity:** `dextran52@gmail.com` (Taher, this session; the archived #90 checkpoint said another address). PAT only in the push command, never in a file or git config.
**Rules in force:** do not build/run the app; no Qt tools in the sandbox (CI is the proof); push without asking, Taher reviews in the PR; short scope (token budget); honest trade-offs, grill before deciding.
**Archived previous checkpoint:** `docs/superpowers/specs/2026-10-13-pr90-final-sweep-prev-CHECKPOINT.md`.

## Steps
- [x] 1. Cloned repo, read memory, #90 sweep note, DELETE roadmap, plan Task 11
- [x] 2. Picked next item = error-cause UI (Taher's own request in #90 D-1), then Task 11, then C-1
- [x] 3. Traced causes in code: P1..P5 in the design (silent revert of a queued completion; stuck row shows a stock batch id; server keeps only the class of the 500 error)
- [x] 4. Design doc + test plan + roadmap/test-plan index lines written
- [x] 5. Committed and pushed, PR raised
- [ ] 6. Taher answers Q-EC-1..3

## NEXT
Implement S1 (pure `FailureCause.js` + 16 Node-runnable cases), then S2, then S3, on `feat/2026-10-13-completion-error-cause`, with the recommended defaults A/A/A unless Taher says otherwise. README / AGENTS / SKILLS get updated at S2/S3 (new Skill only when code lands). Then Task 11, then C-1.
