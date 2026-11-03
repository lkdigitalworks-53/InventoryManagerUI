# CHECKPOINT: 2026-11-03 product picker v2, S1 (pure helpers) built, awaiting CI - resume here

**Branch:** `docs/2026-11-03-product-picker-v2-design`, cut from `main` @ `4c88ed9` (PR #181, R3 restock plan, merged).
**Commit identity:** author `Taher <lkdwtaher@gmail.com>`, and that email is also in every commit message, as this session's project instructions say. Confirmed by Taher 2026-11-03. The PAT comes from the chat prompt only and is passed per command with `git -c http.extraHeader=...`, never in a remote URL, `.git/config`, the repo or memory. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build or run until Taher says so; no Qt in the sandbox (CI is the QML oracle); always a branch; push without asking; short scope per chat turn; honest trade-offs and grilling before decisions; tests of every kind and a test plan in the standard format (Skill 49) for every code change; update skills, AGENTS and README on a need basis; caveman FULL in chat only, documents in normal prose; do not touch other PRs or branches.
**Skills used:** `brainstorming` (hard gate: no code before the design is approved), `qt-qml`, `qt-ui-design`, `ui-ux-pro-max` (accessibility and touch rules), `ponytail` (smallest complete slices). SKILLS-INDEX read first, then Skills 5, 78 and 83 in full.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-03-r3-merged-prev-CHECKPOINT.md`. R3 is merged; its next step (R4 restock rewrite, then R5) is untouched and recorded there.

## The ask
Product picker in New Order and Edit Order: detailed, searchable, editable item counts, seamless. Robustness first. Slices that each finish in one chat turn. Check whether a design already exists and whether it is relevant, correct and current.

## Steps
- [x] 1. Cloned the public repo fresh into `/home/claude/InventoryManagerUI` (the first attempt used `rm -rf`, the sandbox denied it, cloned without deleting instead).
- [x] 2. Found the existing design: `origin/feature/product-picker-search`, docs only, July 15, never implemented, `main` 423 commits ahead of it.
- [x] 3. Audited it against `main` (13 claims, table in the brief section 3). Verdict: direction reusable, NOT safe to implement as written (it would delete the pending-mint guard), and it does not cover the new requirements.
- [x] 4. Read the current pickers: `NewOrderDialog.qml` (`_pickerProducts`, `_rebuildPickerNames`, `addSelectedProduct`, `changeQty`) and `OrderDetailDialog.qml` (`_rebuildCatalog`, `_availableStock`, the add handler); `BottomSheet.qml`; `SearchField.qml`; `ChipScroller.qml`; `AvatarBadge.qml`; `InventoryPage._filteredProducts`.
- [x] 5. Wrote `docs/superpowers/specs/2026-11-03-product-picker-v2-audit-and-decisions.md`: audit, guard inventory, requirements, UI options, units, decisions D1 to D6, slices S0 to S5, test strategy, risks, not-checked list. Every checkable claim re-verified against the code before commit (one count corrected).
- [x] 6. Skill 151 added, `SKILLS-INDEX.md` regenerated, script tests run.
- [x] 7. Taher answered D1 to D4 on 2026-11-03 (brief section 8).
- [x] 8. Taher answered on 2026-11-03 01:35 IST: commit email `lkdwtaher@gmail.com` in the message text; whole units only (weight and length later); D2 = hide ALL sync cases uniformly (pending mint, queued restock, unsynced edit, delete in flight), out-of-stock shown disabled; design APPROVED as a whole.
- [x] 9. Wrote the approved design (`specs/2026-11-03-product-picker-v2-design.md`), the S1 plan (`plans/2026-11-03-product-picker-v2-s1-pure-helpers.md`) and the test plan (`test-plans/2026-11-03-product-picker-v2-test-plan.md`); audit brief synced to the final answers; README index row added.
- [x] 10. Docs committed and pushed on `docs/2026-11-03-product-picker-v2-design` (6f038c1).
- [x] 11. S1 built on `feat/2026-11-03-picker-s1-pure-helpers` (stacked on the docs branch, because the plan lives there): `ProductSearch.js`, `ProductPickability.js`, `PickerDraft.js`, `tests/pickerFixtures.js`, Node tests (96/96 RUN: SRCH 28, PICK 25, DRFT 30, FLOW 8, DORM+PAIR 5), QML twins DERIVED by `functions/test/testSupport/pickerTwin.js`, 53/55 hand mutants killed (2 equivalent), V8 block coverage 100%, functions suite 1083/1083, scripts 741/741. Skill 152 added.
- [ ] 12. Push S1, read CI. QML twins are unrun until CI answers; fix any QML-only failure and record it in the test plan "CI OBSERVED".
- [ ] 13. Plan S2 (PickerRowGeometry.js, ProductPickerSheet.qml, ProductPickerRow.qml, BottomSheet.scrollBody) in its own plan file, after S1 merges.

Deviations from the S1 plan, on purpose: (a) SRCH-04 expected order was wrong in the plan (equal score, so name order: `PRD-001`, `PRD-002`); (b) helpers also reject `[]` and id-less objects as products; (c) added SRCH-10b, FLOW-01..08, PAIR-01..02 and the derived-twin mechanism; (d) the S1 branch is stacked on the docs branch.

## Decisions (full text and trade-offs in the brief, section 8; build spec in the design)
- D1 = B: sheet stays open, quantity stepper per row, one commit button.
- D2 final: hide every product that cannot be sold yet, the same in both dialogs; out-of-stock shown disabled with a reason.
- D3: photo in each row, category chips, in-stock-only toggle. No sort, no barcode scan in v1.
- D4 = add N more: the picker only adds, never removes or reduces a line.
- D5 `BottomSheet` `scrollBody` opt-in, D6 helpers-first delivery, D7 footer line counting hidden products: accepted with the approval.
- Units: whole numbers only in v1.

## NEXT (resume rule)
1. Read CI for the S1 branch. Fix anything red (QML-only differences are likely: reserved words, number handling), regenerate twins with `node functions/test/testSupport/pickerTwin.js --write`, push.
2. Open PRs: docs branch to `main`, S1 branch stacked on it (or retarget to `main` once the docs merge).
3. Write the S2 plan, then build S2. S3 New Order, S4 Edit Order, S5 sweep. Do not touch `origin/feature/product-picker-search`.
