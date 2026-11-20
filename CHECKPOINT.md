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
- [x] 4. Docs: plan, test plan, KNOWN-ISSUES 57, Skill 176 + index, README, this checkpoint.
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

## Sweep steps (state at the last push)
- [x] S0 clone, scrub PAT from `.git/config`, checkout PR branch, read skills/PR/CI/plan/diff.
- [x] S1 Phase 1 lint on the 4 touched QML files: 4 hits on added lines = 3 JS-1 `var` (house style) + 1 DEL-1 `model.x` (pre-existing delegate pattern). No change.
- [x] S2 deep read; `catalog`/`_rebuildCatalog` have no stray readers; `_findOriginalLine` still serves the tax forecast.
- [x] S3 baseline functions 1900/1900, scripts 1049/1049.
- [x] S4 fixes, each red-first with hand mutants killed, twin regenerated:
  - F1 `72ac23a` completed order saved unchanged was refused (two lines of one product, fractional qty): `heldAtCompletion`, `stepUp` floors cap. EOP-40..43, EOW-26; EOP-32/30/33 + EOW-11 corrected on purpose.
  - F2 `f985f0b` Save of a lineless order zeroed total and items: `Edit.lineFields`, `_noLinesStored`. EOP-44, EOW-27, 2 QML cases in `tst_OrdersStore_mutations`.
  - F3 `4dff61b` New Order `+` deleted/lowered rows: `NP.stepQty`. NOP-36/37, NOW-18, EOW-24.
  - ponytail: dead `_whole` removed from EditOrderPicker.js.
- [x] S5 docs: KNOWN-ISSUES 57 fixed up + 48/49/50, Skill 176 rules 3/5/9-11, README, AGENTS (S5b entry added), plan (decisions Q1-Q4 + sweep), test plan steps 115-119 (values checked against the helper).
- [x] S5b-rebase `main` moved twice while the sweep ran (#198, then #203 and #204 -> `591077e`). The branch was first merged with main, then, on Taher's request, REBASED onto `origin/main` (merge commit dropped, 11 commits replayed, force-with-lease push; the old tip is only in the local ref `backup/pre-rebase-sweep1`). Conflicts were docs only: CHECKPOINT.md kept as ours; SKILLS, SKILLS-INDEX, KNOWN-ISSUES union-merged, then renumbered in one commit: Skill 172 -> **176**, KNOWN-ISSUES 47-50 -> **57-60**, one code-comment pointer fixed (the lineless-subtotal item is 59, two comments said 48). Main's own CHECKPOINT of #198 is already archived on main. Node suites on the rebased tree: see the S6 line.
- [x] S6 CI on the REBASED head `29f22cb` (run 44222901686): QML 3232/3232, Functions 1990/1990, Rules 129/129, E2E 121/121 = 5472/5472, PR `mergeable_state: clean`. This checkpoint line was added in a docs-only commit after it, which re-runs CI: glance at it before merging.
- [ ] S7 final report to Taher.

## Decisions (Taher, 2026-11-16, "as recommended")
Q1 skip gone product at Save. Q2 accept + track (KNOWN-ISSUES 59: `_normalizeOrder` zeroes subtotal/tax/discount of lineless orders). Q3 `trySubmit` stays on raw stock. Q4 Save keeps whole units although completion compares raw stock. F3 was decided by the reviewer (robustness first); say if you want it reverted.

## Findings (all proven with the real helper in Node before the fix)
- F1, F2, F3 fixed (above). F4 = Q4, decided, documented (KNOWN-ISSUES 58).
- Judged, not changed (KNOWN-ISSUES 60): fractional `NP.availableFor` with a fractional cart (no bad outcome); Save fails open for a product the reader cannot return (Q1); blank-id lines cannot be raised.

## Not reviewed in depth (be honest)
Older S5a/S5b wiring tests other than EOW-11/20/22/24/26/27 and NOW-18; QML twins beyond regeneration; `ProductPickerSheet` visuals; real-device behavior (no device, no Qt here). QML-side tests (twins, `tst_OrdersStore_mutations`) are unproven until CI runs.
