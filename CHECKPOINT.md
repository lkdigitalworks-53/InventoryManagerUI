# CHECKPOINT: 2026-11-22 picker S5e-3a (name the icon-only buttons, KI 70 a+b) - resume here

**Branch:** `feat/2026-11-22-picker-s5e3-unnamed-buttons-targets` (cut from `main` @ `01c0ff5`, PR #214 S5e-2 merged).
**Commit rule (this session, owner instruction):** every commit message carries `tsadmin@gmail.com`; git user `Claude <tsadmin@gmail.com>`. (Earlier sessions used `taher.lkdw@gmail.com` and `lkdwtaher@gmail.com`: three addresses now, flagged to the owner, nothing rewritten.)
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking (PAT per command, remote URL kept clean); tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; short scope so another account can take over from the remote branch.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-22-pr214-merged-prev-CHECKPOINT.md`.
**Skills used:** superpowers:brainstorming (design in the plan, decisions with defaults, veto in the PR), qt-qml, qt-ui-design, ponytail. **Plan:** `docs/superpowers/plans/2026-11-22-product-picker-v2-s5e3a-unnamed-buttons-and-targets.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5e-3a rows, checks 162 on).

## Steps
- [x] 0. Cloned fresh (remote URL scrubbed of the PAT), skills read, roadmap read from the repo and the GitHub API: S1-S5e-2 merged (#214 merged); open PRs #212 (NO2), #211, #178, #39, #29, none picker. Next on the picker roadmap = S5e-3, then S5e-4.
- [x] 1. Recon: KI 97's scan was lenient (a `text:` anywhere in a block, even a ToolTip, counted as a name). Depth-aware scan over `qml/**`: 10 icon-only buttons with no spoken name (not 8): FloatingActionButton (3 instances), back x3 (Activity, Profile, Staff), supplier + toggles (AddProduct, Restock), rename toggle (EditProduct), workspace edit (ProfileSettings), Suspend and Remove (MemberManagement). A second class (13 buttons whose label lives only in a child `Text`) is a different fix: S5e-3b.
- [x] 2. Plan doc (scope, decisions D1 to D7, trade-offs, what is NOT done).
- [x] 3. Code: names + `FloatingActionButton.label`; "Manage channels" link 48 dp with its own `text`; four price/discount fields `Layout.minimumHeight: dp(48)`.
- [x] 4. Tests: `functions/test/pickerS5e3Names.test.js` (+ `testSupport/qmlButtonScan.js`), run in Node only.
- [x] 5. Docs: test plan rows and device checks, KNOWN-ISSUES (97 and 70 updated, new findings), Skill 185 + index, AGENTS, README, this file.
- [x] 6a. Committed `6eb5671` (code, tests, plan, test plan, KNOWN-ISSUES) and pushed; docs commit (Skill 185, index, AGENTS, README, this file) follows.
- [ ] 6b. Open PR against `main`, read CI on its head (QML, Functions, Rules, E2E), fix anything red.
- [ ] 7. Final report: done / open / next. Then S5e-3b (13 text-child buttons, number-field names KI 108, font and theme audit).

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`.
