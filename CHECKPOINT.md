# CHECKPOINT: 2026-11-24 picker S5f (dead-helper cleanup + photo-sheet sp()) - resume here

**Branch:** `feat/2026-11-24-picker-s5f-dead-helper-cleanup` (cut from `main` @ `eaa0934`, PR #218 S5e-3c merged).
**Commit rule:** every commit of this branch carries `taher.lkdw@gmail.com` (owner instruction 2026-11-24; ignore the addresses on older commits).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking (PAT per command, remote URL kept clean); tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; short scope so another account can take over from the remote branch; no parallel agents.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-24-pr218-merged-prev-CHECKPOINT.md`.
**Skills used:** superpowers:brainstorming (design in the plan), qt-qml, qt-ui-design, ponytail, caveman.

## Steps
- [x] 0. Cloned fresh, memory + repo docs read, roadmap read: picker v2 S1 to S5e-3c merged (#218). Left on the roadmap: KI 143 cleanup slice (this), S5e-4 device pass (phone job, not code).
- [x] 1. Recon by grep: CardKPI, OrderRow, PlaceholderPage, SegmentedNav, StatusBadge have no user outside tests/docs (StatusBadge only used by OrderRow); no qmldir/CMake/qrc entry (CMake globs `qml/*.qml`); `qml/tests` none. PhotoSourceSheet has 7 bare sizes: 16, 14 x3, 11 x3 = tokens fsTitle, fsBodyLg, fsCaption.
- [x] 2. Commit A done: 5 files deleted, ratchets fixed (S5E3-05/06/07, S5E3B-21, S5E3C-08/10/12), new `pickerS5fDeadHelpers.test.js` (S5F-01..08) + `testSupport/deadQmlScan.js`. Scanner also found 3 more unused QML files: AuthPrimaryButton, AuthSecondaryButton (dead, new KI 146, NOT deleted: out of scope) and AnalysisService (dormant on purpose, README says so).
- [x] 3. Commit B `b5e36b2` (own commit, revertable alone): PhotoSourceSheet 7 sizes -> `sp(Constants.fs*)` (tokens equal old numbers), 3 rows `Math.max(56, labelColumn.implicitHeight + 20)`; S5E3C-10 pins zero bare sizes; S5F-09..12. 11 hand mutants, all killed (one no-op redone; a mutant loop once reverted uncommitted work, redone from the committed state).
- [x] 4. Docs: plan `docs/superpowers/plans/2026-11-24-product-picker-v2-s5f-dead-helper-cleanup.md` (D1..D6, Q1..Q4), test plan (row, unit table, checks 203 to 208, affected areas, verification row), KNOWN-ISSUES (121, 128 fixed, 143 shrunk, new 146, 147), Skill 190 + index (191 skills), AGENTS (helper list, status), README (tree, status).
- [x] 5. Measured by running: functions 2404/2404 (main was 2391), scripts 1199/1199, skills-index current.
- [x] 6. Pushed, PR #220 opened. CI on head `9b9c821` read: QML 3408, Functions 2404, Rules 129, E2E 124 = 6065/6065 green; Deploy steps skipped. This checkpoint-only commit goes on top (CI on it not read).
- [ ] 7. Owner: veto D1/D2, device check of the photo sheet at normal and 2.0x font, merge.

## Next
(1) Owner: Q1..Q4 in the PR, device checks 203 to 208 (207 first), merge. (2) S5e-4 curated device pass (phone job, KI 29 number). (3) KI 146 cleanup of the two dead Auth buttons. (4) KI 143 colour literals to tokens, one file at a time.

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check`.

---
# PR #220 REVIEW SESSION (2026-11-25, different account) - resume here
**Branch:** same PR branch `feat/2026-11-24-picker-s5f-dead-helper-cleanup` (owner: "add fixes in the same PR"). Review commits carry `tsadmin@gmail.com` in the message text (owner instruction 2026-11-25; supersedes `taher.lkdw@gmail.com` above for NEW commits).
**Rules in force:** no build/run app; no Qt in sandbox (CI is the oracle); no parallel agents; short scope per turn; push without asking (PAT per command via http.extraheader, remote URL kept clean); tests + test plan for every change; docs updated as needed.
**Skills used:** requesting-code-review, qt-qml-review (diff scope, linter not in sandbox if missing), ponytail-audit (lens), caveman.
## Review steps
- [x] R0. Cloned, checked out PR head `965c778`, read plan/checkpoint/diff. CI on head: 6065/6065 green (QML 3408, Functions 2404, Rules 129, E2E 124).
- [x] R1. Measured: `functions` 2404/2404 by running (matches PR claim).
- [x] R2. Deletion safety: no ref to the 5 names anywhere (whole tree), no CMake file list (GLOB_RECURSE + CONFIGURE_DEPENDS), no qmldir entry, no dynamic load that could build their names, no Constants member orphaned (deleted files used literals only).
- [ ] R3. QML review of PhotoSourceSheet (findings in the report below, filled as found).
- [ ] R4. Scanner + tests review.
- [ ] R5. Docs review (KI, README, AGENTS, Skill 190, test plan).
- [ ] R6. Fixes + tests + test plan + docs, commit, push.
- [ ] R7. CI on new head read.
