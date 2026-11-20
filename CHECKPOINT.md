# REVIEW SWEEP 1 of PR #207 (AP3b Add Product sheet; session 2026-11-20; commit rule: `tsadmin@gmail.com` line in every message) - resume here
**Rules in force:** no build/run; no Qt in the sandbox (CI is the oracle); fixes go on THIS branch `feat/2026-11-20-ap3b-add-product-dialog` (same PR); no parallel agents; push without asking; tests + test plan for every change; scope kept small per turn. PAT per command via `git -c http.extraheader`, never in `.git/config` or a doc.
**Skills used:** requesting-code-review, qt-qml-review (3 phases, single-threaded), ponytail-audit.
**Baseline:** PR head `ad23cb4`, base `main@6951b1d`, 4 commits, 18 files +1152 -163, `mergeable_state: clean`.

## Sweep steps
- [x] S0 clone, PR branch checked out, identity set, skills + PR + conventions read.
- [x] S1 Phase 1 lint on the 2 touched QML files, ADDED lines only: 31 hits = 25 JS-1 `var` (house style) + 3 BND-2 on `.text =` (plain controls, no `text:` binding: false positive) + 2 ORD-1 (house layout) + STY-1 root id (`id: dlg`, house style). No change.
- [x] S2 deep read (single-threaded, all 6 qt-qml-review focus areas): `AddProductFlow.js`, the dialog diff, `InventoryStore.addProduct`, `RestockFlow` supplier helpers, `AuthTextField` aliases (`maximumLength`, `inputMethodHints` exist). Findings confirmed by running the real code in Node, then fixed (below).
- [x] S3 baseline: functions 2059/2059 (before), scripts 1061/1061.
- [x] S4 fixes + tests, 10 hand mutants all killed: functions now 2065/2065 (+6: FM-12b, FM-12c, FM-12d, FM-13b, SB-17, SB-18), 2 new QML twin functions (CI only).
- [x] S5 docs: KNOWN-ISSUES 65 amended, 67 (fixed), 68 (OPEN decimals), 69 (not checked); design D-AP3b-10; Skill 178 rules 11-15 (index still current); test plan rows + device steps 22-28; STATUS evidence line; AGENTS line.
- [x] S6 pushed `123a827`; CI on it: QML 3274/3274, Functions 2065/2065, Rules 129/129, E2E 121/121 = 5589/5589, `mergeable_state: clean`, 5 commits. This checkpoint line came in a docs-only commit after it, which re-runs CI: glance at it before merging.
- [x] S7 final report given in chat.
- [ ] S8 Taher: answer D-AP3b-2/9 (fractional stock, below-cost), D-AP3b-10 (markup floor), item 68 (decimals); review and merge. Not reviewed: see below.

## Fixed in this sweep (KNOWN-ISSUES 67)
1. Markup pill showed a price Save refuses (over the limit). 2. Markup could round BELOW cost (10.40 at 0% -> 10, "Price < cost"). 3. Over-limit values said "not a whole number" / "not valid". 4. Answer handler (outside the try/catch) could skip toast + close -> duplicate add. 5. `qsTr("New: ") + name`.
Code: `qml/helper/AddProductFlow.js` (`_moneyState`, `_wholeState`, `_resolvePrices`, `_markupPrice` floor, `_tooBig`), `qml/pages/AddProductDialog.qml` (callback guards, `finally` close, `qsTr("New: %1")`).

## Not reviewed in depth (be honest)
QML twin `tests/tst_AddProductForm.qml` is unproven until CI (no Qt here); the real dialog on a device; unit/category fields have no length limit (they come from combos, not typed); cost/price fields have no `maximumLength` (item 69); money with more than 2 decimals is OPEN (item 68).

---
# CHECKPOINT: 2026-11-20 AP3b (Add Product sheet: strict form, limits, "Use" supplier, safe submit) - resume here

**Branch:** `feat/2026-11-20-ap3b-add-product-dialog` (cut from `main` @ `0ce6534`; #202, #203, #204 merged).
**Commit rule:** every commit message carries `dextran52@gmail.com`. **Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md` (items 61 to 66).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-20-pr202-merged-prev-CHECKPOINT.md`.
**Design:** `docs/superpowers/specs/2026-11-20-ap3b-add-product-dialog-design.md` (D-AP3b-1..9). **Test plan:** `docs/superpowers/test-plans/2026-11-20-ap3b-add-product-dialog-test-plan.md`.

## Steps
- [x] 0. Clone, memory, skills (caveman, brainstorming, ponytail, qt-qml, qt-ui-design), roadmap (`ATOMIC-OPERATIONS-STATUS.md`) read: next = AP3b (#203 AP3a merged).
- [x] 1. Design written with defaulted, vetoable decisions (the standing working model; no live Q and A in a one-turn chat).
- [x] 2. Code, commit `8a87da2` pushed: `AddProductFlow.fromForm/moneyFromText/wholeFromText/priceSummary`, dialog rewrite.
- [x] 3. Tests: `addProductForm` 15, `addProductDialogSubmit` 16, `tst_AddProductForm.qml` 10 (twin harness-checked), `sheetBusyOverlay` SB-4 updated. Full functions 2021/2021 before the rebase, scripts 1061/1061. 12 hand mutants.
- [x] 4. Docs: design, test plan, KNOWN-ISSUES 61-66 (+44/47/51 closed), Skill 178 + index, README, AGENTS, ATOMIC-OPERATIONS-STATUS section 17, test-plans README.
- [x] 4b. PR #207 opened; it was `dirty` (main took #205) so CI never started. REBASED onto `origin/main@6951b1d` (docs-only conflicts: own CHECKPOINT kept, #205 checkpoint archived to `specs/2026-11-20-pr205-sweep1-prev-CHECKPOINT.md`, SKILLS / KNOWN-ISSUES / status union-merged, index regenerated; Skill 178 stays, main has 177). After the rebase: functions 2059/2059, scripts 1061/1061.
- [x] 5. Rebased head `ffe3a28` pushed. CI GREEN (QML, Functions, Rules, E2E, PR Test Summary), PR #207 `mergeable_state: clean`. This line is a docs-only commit after it, which re-runs CI: glance before merging. (was: push the rebased head, then, open the PR, read CI (QML twin and the dialog are CI and device only).)
- [ ] 6. Taher: answer the two questions (fractional stock; selling below cost), review, merge, device pass (test plan steps 1-21).
- [ ] 7. Next: AP4 device pass, then step 3 (new order, `_tryAdjustOrder`, imported completion, reverse). Small: Edit Product lenient parsing (KI 62).

## If this session is cut off
Code is pushed; resume at step 5. Counts to re-measure before claiming: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`.
