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
