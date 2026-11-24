# CHECKPOINT: 2026-11-24 picker S5e-3c (font-scale and theme source audit) - resume here

**Branch:** `feat/2026-11-24-picker-s5e3c-font-and-theme-audit` (cut from `main` @ `a40e8c0`, PR #216 S5e-3b merged).
**Commit rule (this session):** every commit message carries `dextran52@gmail.com` (owner instruction of 2026-11-24; older checkpoints name other addresses, KI 125 still open).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking (PAT per command, remote URL kept clean); tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; short scope so another account can take over from the remote branch; defaults taken for open questions (owner: "go with recommended").
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-24-pr216-merged-prev-CHECKPOINT.md`.
**Skills used:** superpowers:brainstorming (design in the plan, decisions with defaults, veto in the PR), qt-qml, qt-ui-design, ponytail, caveman. **Plan:** `docs/superpowers/plans/2026-11-24-product-picker-v2-s5e3c-font-and-theme-audit.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5e-3c rows, checks 194 on).

## Steps
- [x] 0. Cloned fresh, skills read, roadmap read: S1 to S5e-3b merged (#216 merged). Left: S5e-3c, S5e-4 (device pass, KI 29 number).
- [x] 1. Recon by script: 347 Text/Label (3 without `color`, all invisible), 378 `pixelSize` (19 not via `sp()`, all outside the picker arc), picker arc has 0 hex literals; 5 typed-text fields in the arc with NO colour (SearchField, 2 in New Order, 2 in Edit Order) on fixed light fills.
- [x] 2. QML: 5 `color:` pins (+ `placeholderTextColor` on SearchField). 11 lines, 3 files.
- [x] 3. Scanner `functions/test/testSupport/qmlThemeScaleScan.js` + `pickerS5e3cAudit.test.js` (22 cases). 17 hand mutants, all killed (2 survived first run, test hardened).
- [x] 4. Docs: plan (D1 to D8, Q1 to Q4), test plan (row, unit table, checks 194 to 202, affected area, verification row), KNOWN-ISSUES 142 to 145, Skill 189 + index (190 skills), AGENTS, README.
- [x] 5a. Measured by running: functions 2352/2352, scripts 1199/1199, skills-index current.
- [x] 5b. Committed `3238f90`, pushed, PR #218 opened. CI on that head: QML, Functions, Rules, E2E all success (counts not read, only verdicts); Deploy steps skipped.
- [x] 6. Final report given. NEXT (owner): answer plan Q1 to Q4, run device checks 194 to 202 (194 and 201 first, on a phone set to dark).
- [ ] 6. Final report: done / next (S5e-4, owner decisions).

## Measured (this session, by running it)
functions 2352/2352; scripts 1199/1199; `skills-index.js --check` current. Not run: CI, any device check (194 to 202), the repo's QML lint (not in the tree).

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check`.

NEXT SLICES: (1) login fields + Restock SpinBox colour pins (KI 142, owner Q2), (2) dead-helper cleanup (KI 143, owner Q3), (3) S5e-4 curated device pass (not code) and KI 29 with a number.
