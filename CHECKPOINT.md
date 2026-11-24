# CHECKPOINT: 2026-11-24 picker S5e-3c (font-scale and theme source audit) - resume here

**Branch:** `feat/2026-11-24-picker-s5e3c-font-and-theme-audit` (cut from `main` @ `a40e8c0`, PR #216 S5e-3b merged).
**Commit rule:** the first four commits of this PR carry `dextran52@gmail.com` (owner instruction earlier on 2026-11-24); the rebase and PR-review commits carry `allibaas52@gmail.com` (owner's current standing rule; KI 125 still open, old commits not rewritten).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking (PAT per command, remote URL kept clean); tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; short scope so another account can take over from the remote branch; defaults taken for open questions (owner: "go with recommended").
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-24-pr216-merged-prev-CHECKPOINT.md`.
**Skills used:** superpowers:brainstorming (design in the plan, decisions with defaults, veto in the PR), qt-qml, qt-ui-design, ponytail, caveman. **Plan:** `docs/superpowers/plans/2026-11-24-product-picker-v2-s5e3c-font-and-theme-audit.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5e-3c rows, checks 194 on).

## Steps
- [x] 0. Cloned fresh, skills read, roadmap read: S1 to S5e-3b merged (#216 merged). Left: S5e-3c, S5e-4 (device pass, KI 29 number).
- [x] 1. Recon by script: 347 Text/Label (3 without `color`, all invisible), 378 `pixelSize` (19 not via `sp()`, all outside the picker arc), picker arc has 0 hex literals; 5 typed-text fields in the arc with NO colour (SearchField, 2 in New Order, 2 in Edit Order) on fixed light fills.
- [x] 2. QML: 5 `color:` pins (+ `placeholderTextColor` on SearchField). 11 lines, 3 files.
- [x] 3. Scanner `functions/test/testSupport/qmlThemeScaleScan.js` + `pickerS5e3cAudit.test.js` (22 cases, 23 after the review). 17 hand mutants, all killed (2 survived first run, test hardened).
- [x] 4. Docs: plan (D1 to D8, Q1 to Q4), test plan (row, unit table, checks 194 to 202, affected area, verification row), KNOWN-ISSUES 142 to 145, Skill 189 + index (190 skills), AGENTS, README.
- [x] 5a. Measured by running: functions 2352/2352, scripts 1199/1199, skills-index current.
- [x] 5b. Committed `3238f90`, pushed, PR #218 opened. CI on that head: QML, Functions, Rules, E2E all success (counts not read, only verdicts); Deploy steps skipped.
- [x] 6. Final report given (first session).
- [x] 7. PR REVIEW (2026-11-24, next session): rebased on main `fc4eee5` (#217), CHECKPOINT kept, SKILLS-INDEX / SKILLS / KNOWN-ISSUES clash with NO3a resolved by renumbering KI 135-138 to 142-145 and Skill 188 to 189 (190 skills), force-pushed `609a972`.
- [x] 8. Review fixes, code (`25ea4e4`): login fields pin `color` + `placeholderTextColor`; Restock SpinBox pins `palette.text` (KI 142 had advised `color:`, invalid on a SpinBox); `S5E3C-07` now zero-left, `S5E3C-23` new; 5 hand mutants killed; QML linter 0 findings; functions 2391/2391.
- [x] 9. Review fixes, docs (this commit): KI 142 and 145 rewritten (145 line ref 219 to 215 after the rebase), plan D2/D5/D8, test plan rows and check 201, Skill 189 rule 8, AGENTS, README, counts.
- [ ] 10. Still to do from the review: ponytail pass (net cut list), CI result on the new head, device checks 194 to 202 (owner).

## Measured (this session, by running it)
functions 2391/2391 (after rebase and review fixes; 2352 before the rebase); scripts 1199/1199; `skills-index.js --check` current; QML linter (qt-qml-review skill, diff scope) 0 findings. Not run: CI on the newest head, any device check (194 to 202).

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check`.

NEXT SLICES: (1) [done in the PR review: login fields + Restock SpinBox pins], (2) dead-helper cleanup (KI 143, owner Q3), (3) S5e-4 curated device pass (not code) and KI 29 with a number.
