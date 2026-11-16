# CHECKPOINT: 2026-11-16 picker S5b (one stock rule, legacy seed deleted) - resume here

**Branch:** `feat/2026-11-16-picker-s5b-one-stock-formula-delete-legacy-seed` (cut from `main` @ `503adda`, AP2 #201 merged).
**Commit rule:** every commit message carries `dextran52@gmail.com` (task prompt of 2026-11-16).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-16-pr201-merged-prev-CHECKPOINT.md` (AP2 sweep, merged).
**Plan:** `docs/superpowers/plans/2026-11-16-product-picker-v2-s5b-one-stock-rule.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5b rows, device steps 104-114).

## Steps
- [x] 0. Clone, memory, skills (caveman, brainstorming), roadmap read: S1-S4, S5a merged; next S5b (KI 28a, 37a, 39a, 30); Q1, Q2 decided as recommended (KI 44).
- [x] 1. Design in the plan (D1-D7, open Q1-Q3). Baseline Node 1882, scripts 1049.
- [x] 2. Code (commit 82e0fbf, pushed): `NP.ceilingOf`; `Edit.ceilingFor/stepUp/stockShortfalls/shortfallText`; `OrderDetailDialog` `+` stepper and `_stockErrors()`; legacy seed deleted; `NewOrderDialog.changeQty` reads `ceilingOf`.
- [x] 3. Tests: NOP-33..35, EOP-32..39, EOW-20..25, NOW-18; EOW-01/09/11/17 updated; twins regenerated; 18 hand mutants killed; guard Q-3 caught reserved word `short`, renamed `need`.
- [x] 4. Docs: plan, test plan, KNOWN-ISSUES 47, Skill 172 + index, README, this checkpoint.
- [ ] 5. CI result of the PR (QML twins have NOT run anywhere yet). Read it, fix red.
- [ ] 6. Taher answers plan Q1 (gone product at Save: skip or refuse), Q2, Q3; reviews and merges.
- [ ] 7. Next: S5c touch targets, Back key, in-stock double toggle (24a, 28b, 8, 19b, 19a). Then S5d, S5e.

## If this session is cut off
Everything is pushed except nothing pending; resume at step 5. Counts to re-measure before claiming: `cd functions && npm ci && node --test` (1900 here, Node 22), `node --test .github/scripts/__tests__/*.test.js` (1049).


---
# REVIEW SWEEP 1 of PR #202 (session 2026-11-16, commit rule: `tsadmin@gmail.com` line in every message) - resume here
**Rules in force (this session):** no build/run; no Qt in sandbox (CI is the oracle); fixes go on THIS branch (same PR); no parallel agents; push without asking; tests + test plan for every change; scope kept small per turn. PAT per command via `git -c http.extraHeader`, never in `.git/config`.
**Skills used:** requesting-code-review, qt-qml-review (3 phases, run single-threaded), ponytail-audit.
**Baseline:** PR head `9495756`, base `main@503adda`, CI green (QML 3163, Functions 1900, Rules 129, E2E 121), `mergeable_state: clean`, 2 commits, 18 files +765 -139.

## Sweep steps
- [x] S0. Clone, scrub PAT from `.git/config`, checkout PR branch, read skills, PR body, CI, plan, production diff.
- [ ] S1. Phase 1 lint (qt_qml_lint.py) on touched QML + helper reads (`EditOrderPicker.js`, `NewOrderPicker.js` in full).
- [ ] S2. Deep read: `OrderDetailDialog.qml` `_save`, `_pickerLookup`, `_findOriginalLine` leftovers, `catalog` references anywhere, legacy no-`products` order Save path.
- [ ] S3. Re-run Node tests here (functions 1900, scripts 1049) before touching code.
- [ ] S4. Fixes (test first, red then green), one commit each.
- [ ] S5. Docs: KNOWN-ISSUES, test plan, skills, README as needed. Read CI on the new head.
- [ ] S6. Final report to Taher: done / next.
