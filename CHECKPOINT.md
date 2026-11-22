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
- [x] 6b. PR #215 opened against `main`. CI on head `5f04e7a`: QML Tests, Functions Tests, Firestore + Storage Rules Tests, E2E Tests all success (deploy jobs skipped, as for any PR). Test counts inside the jobs were not read.
- [x] 7. Final report: done / open / next. NEXT SESSION: S5e-3b (13 text-child buttons, number-field names KI 108, font and theme audit).

## Review sweep 2026-11-23 (PR #215: requesting-code-review + qt-qml-review + ponytail-audit; ONE agent, no sub-agents, as ordered)
**Commit email for these commits:** `lkdigitalworks@gmail.com` (this session's instruction; git user `Taher (via Claude session)`). PR #215's own earlier commits keep `tsadmin@gmail.com`. History is not rewritten.
- [x] R0. Cloned through the session proxy, PR head `95aacc9`, base `main` @ `01c0ff5`. Baseline: functions 2249/2249 (matches the PR), new file 24/24.
- [x] R1. Lint (`qt_qml_lint.py` on the 13 touched QML files, filtered to the 39 changed lines): 1 style hit (`NewOrderDialog.qml:223` ORD-1, the repo's own Layout-first order, not changed). Identifiers used by the new dynamic names all resolve (`dlg._addPartyOpen`, `root._renaming`, `root.workspaceEditMode`, `modelData.status`).
- [x] R2. FOUND: main had moved on (#212 NO2 took Skill 185 and KNOWN-ISSUES 107-118), so the PR conflicted in 5 doc files and clashed on numbers. Renumbered ours (Skill 185 -> 186, KI 107-110 -> 119-122, commit `341ba54`), merged `origin/main` @ `5948767`, kept both sides, archived main's checkpoint as `docs/superpowers/specs/2026-11-22-no2-merged-prev-CHECKPOINT.md`. After the merge: functions 2283/2283 (2258 on main + 25), scripts 1199/1199, `skills-index.js --check` current.
- [ ] R3. FOUND (must fix): `IconActionButton` (38 dp, icon only) is used 13 times; 11 icon-only instances have no spoken name and the Dashboard profile button speaks the user's initial. The S5e-3a scanner skips wrapper components by design, so its "zero unnamed" ratchet is blind to them. Fix: `IconActionButton.label`, 12 labels, instance ratchet, root-button-component pin.
- [ ] R4. FOUND (investigate, no change): `ListCard` and `ActionTile` (root buttons) keep their label only in a child `Text`; log in KNOWN-ISSUES, pin the list of root-button components.
- [ ] R5. Docs for R3/R4 (KI 97 note, new KIs, Skill 186 rule, README, AGENTS, test plan rows and device checks, plan section 8), then push and read CI.
- Note on the +25 test count: `node --test` with no arguments also runs every `.js` under `test/`, so the new support file `testSupport/qmlButtonScan.js` counts as one test file (the "+1 not traced" in the plan).

## If this session is cut off
Resume at the first unticked R step above. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check`.
