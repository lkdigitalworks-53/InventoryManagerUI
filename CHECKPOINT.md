# CHECKPOINT: 2026-11-20 picker S5c (touch targets, Back route, in-stock double toggle) - resume here

**Branch:** `feat/2026-11-20-picker-s5c-touch-back-toggle` (cut from `main` @ `0ce6534`, PR #202 S5b merged).
**Commit rule:** every commit message carries `taher.lkdw@gmail.com` (task prompt of 2026-11-20).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; PAT per command via `git -c http.extraHeader`, never in `.git/config`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-20-pr202-merged-prev-CHECKPOINT.md`.
**Plan:** `docs/superpowers/plans/2026-11-20-product-picker-v2-s5c-touch-back-toggle.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5c rows).
**Skills used:** caveman, brainstorming, qt-qml, qt-ui-design, ponytail.

## Steps
- [x] 0. Clone, memory read, roadmap read: S1-S5b merged; next = S5c (KI 8, 19a, 19b, 24a, 28b). S5d (measure) and S5e (TalkBack, themes, font scale, KI 26, KI 29) stay open.
- [x] 1. Findings from the code (before any design):
  - F-A: the app routes Android Back through Felgo `onBackButtonPressedGlobally` -> `Main.qml _handleBack()`, which closes the FIRST open entry of `_allDialogs()`. The picker sheet is not in that list. So KI 8's belief ("Back does nothing with a draft") is unproven AND the router can close `newOrderDlg` / `orderDetail` (parent) without the discard question.
  - F-B: `OrderDetailDialog` line controls (price field 64 + three 28 dp buttons) sit in the `ListCard` trailing slot; at 48 dp they need ~246 dp, which would crush the title on a 360 dp phone. They must move to their own row.
  - F-C: the cart steppers have no `Accessible.name` (TalkBack reads "unlabeled button").
- [x] 2. Plan `plans/2026-11-20-product-picker-v2-s5c-touch-back-toggle.md` (decisions D1..D9, evidence, risks).
- [x] 3. Code (pushed `f9494e9`): helpers `CartStepperGeometry.js`, `PickerGuards.js`, `BackRouter.js`; `CartStepper.qml`; both dialogs; `ProductPickerSheet.handleBack` + `_toggleStockA11y`; `BottomSheet.routesBack`; `Main._handleBack` via `BackRouter`.
- [x] 4. Tests (pushed `1027926`): CSG 7, PGD 11, BR 11, S5C 14, three QML twins; EOW-23, WIRE-18, `main-back-uses-list` (+ mutant), accessBlockBehavior updated on purpose. Functions 2033/2033, scripts 1061/1061 RUN; mutants: 26 helper (24 killed, 1 deleted, 1 equivalent), 15 QML-source (all killed).
- [x] 5. Docs: test plan (unit section, checks 120 to 133, affected areas, status row), KNOWN-ISSUES (8, 19, 24, 28 amended; 70 to 73 new after the 2026-11-20 rebase, were 61 to 64), Skill 179 + index (was 178 before the rebase), AGENTS, README.
- [x] 6. Docs pushed `6292b22`; PR #206 opened (was `dirty` vs main @ `6951b1d`); main merged in, my skill renumbered 177 -> 178. CI not yet read on the merge head.
- [x] 6b. REBASE onto `main` @ `e064270` (#207 AP3b merged; 2026-11-20, asked by Taher, linear history, merge commit `5825a35` dropped). Conflicts: CHECKPOINT.md = branch version kept; SKILLS.md + SKILLS-INDEX.md = both kept, this slice renumbered 178 -> 179 (main took 177 and 178); KNOWN-ISSUES.md = both kept, this slice items 61-64 -> 70-73 under their own header (main took 61-69); refs fixed in AGENTS.md (Skill 179) and the S5c plan (KI 70 to 72); `skills-index.js --write` run, no drift. Old tip `5825a35` replaced by force-with-lease. CI NOT read yet on the new head. Device checks 120-133 and the test-plan rows still say S5c, unchanged. Run `grep -rn "Skill 178" docs README.md AGENTS.md` after the next main merge: 178 now belongs to AP3b.
- [ ] 7. Final report to Taher: done / open decisions D1..D9 / device checks 120 to 133 / next = S5d, S5e.

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`.
