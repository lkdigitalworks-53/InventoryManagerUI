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
- [x] R1. Measured by running: functions 2404/2404, scripts 1199/1199, skills-index current (matches the PR claim).
- [x] R2. Deletion safety: no ref to the 5 names anywhere (whole tree), CMake globs (`CONFIGURE_DEPENDS`), no qmldir entry, no computed-string load, no `Constants` member orphaned. SAFE.
- [x] R3. QML review of `PhotoSourceSheet` (+ linter 0 findings on changed lines): FOUND (a) sheet not scrollable, capped 80%, rows now grow with the font: sideways from ~1.3x the Remove row leaves the screen (manifest `screenOrientation=user`); stale comment claims a ScrollView that does not exist; (b) labels do not wrap: long label runs out of the row at ~2.0x (pixel numbers are my arithmetic, not measured); (c) handle used bare width/height in a Layout.
- [x] R4. Scanner + tests review: FOUND `deadQmlFiles` counted "has any other user" (misses chains and dead cycles); unused `outsideText` export; Skill 190 rule 1 claimed `qmldir`/`tests/` are scanned (they are not). Tests are source scans only (nothing runs QML); S5F-11 only exercises `Math.max` (kept, low value).
- [x] R5. Docs review: README/AGENTS counts and KI 121/128/143/146 consistent except KI 146 `tests/` claim (fixed).
- [x] R6a. Commit `fe60214` scanner reachability (S5F-06/07 fixed, S5F-13 new, S5F-08 oracle rebuilt, 6 mutants killed).
- [x] R6b. Commit `338d0e7` (C, revert alone) sheet Flickable + wrap + Layout handle; S5F-14..16; 14 mutants killed.
- [x] R6c. Docs commit (this one): Skill 190 (+ rule 8, index regenerated, still 191 skills), AGENTS, README, KI 146/147 rewritten + 148/149 new, plan section 9 (D7, D8, Q5-Q7), test plan (cases 13-16, checks 209-212, counts). Measured: functions 2408/2408, scripts 1199/1199, skills-index current.
- [ ] R7. CI on the new head: read the PR comment (verdicts AND counts).
- [ ] R8. Owner: Q1-Q7 (plan section 9), device checks 203-212 (207 first, then 209 and 210), merge.

## Next
(1) Read CI on the newest head; if QML tests fail, the cause is almost surely `PhotoSourceSheet.qml` commit C: revert `338d0e7` and report. (2) Owner device pass (S5e-4). (3) KI 146 delete the two Auth buttons. (4) KI 143 colour literals.

## If this session is cut off
Resume at the first unticked step. Re-measure before claiming counts: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check`. Push with `git -c http.extraheader="Authorization: Basic $(printf 'x-access-token:%s' $PAT | base64 -w0)" push origin HEAD`.
