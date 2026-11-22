# CHECKPOINT: 2026-11-22 NO2 create-order client plan - resume here

**Branch:** `feat/2026-11-22-no2-create-order-client-plan` (cut from `main` @ `a3227e7`, #208 merged).
**Commit rule:** every commit carries `dextran52@gmail.com` (author and message), per the task prompt of 2026-11-22. The previous checkpoint and KNOWN-ISSUES 80 say the project rule is `allibaas1998@gmail.com`; the conflict is KNOWN-ISSUES 111 and waits for the owner. Main's KI 99 closure (2026-11-22, PR #213 sweep prompt) names a third address, `allibaas52@gmail.com`; see item 118. History is not rewritten.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; PAT per command via `git -c http.extraHeader`, never in `.git/config`; keep scope short so another account can take over.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-22-pr208-merged-prev-CHECKPOINT.md`.
**Design:** `docs/superpowers/specs/2026-11-22-no2-create-order-client-plan-design.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-22-no2-create-order-client-plan-test-plan.md`.
**Skills used:** caveman, brainstorming (design + decisions defaulted, vetoable in the PR, as ordered), qt-qml and qt-ui-design (pure helpers + QML twins only, no UI), ponytail (redundant lines deleted after the mutant sweep).

## Steps
- [x] 0. Clone, memory read, roadmap read (`ATOMIC-OPERATIONS-STATUS.md` sections 14-18, NO1 design). State: steps 1-2 done, NO1 merged (#208); next = NO2.
- [x] 1. Code read: `AddProductPlan.js`, `OperationKeys.js`, `FailureCause.js`, `DescribeItem.js`, `OrdersStore._normalizeOrder/computeOrderTotals/addOrder`, `NewOrderDialog.trySubmit`, server `checkCreateOrder`.
- [x] 2. Design written (D-NO2-1..9, Q-NO2-1..3).
- [x] 3. Code: `OperationKeys` (3 functions), `OrderPlan.js` (new), `FailureCause.forCreateOrder`, `DescribeItem` label, `AddProductPlan` exports `isIsoInstant/isIsoDate` (build uses them).
- [x] 4. Node tests `createOrderPlan.test.js` (34), guards widened (NO1 G-1, AP G-1), `failureCauseCodes` C-2. Functions 2206/2206, scripts 1199/1199 (after the rebase onto #210).
- [x] 5. Hand mutants: 60 -> 12 survivors -> 9 test rows + 3 deleted/simplified lines -> 56/56 killed.
- [x] 6. QML twins: `tst_OrderPlan.qml` (new) + additions to four files; harness-checked, CI is the oracle.
- [x] 7. Docs: design, test plan (+ index row), KNOWN-ISSUES 107-112, Skill 185 + index, AGENTS, README, ATOMIC-OPERATIONS-STATUS 19.
- [x] 8. Committed, rebased onto main (#209, #210 took the doc numbers, then #213 and #214 did: see R6), pushed, PR #212, CI all green on `3ddef0c`, recorded in test plan section 5.
- [ ] 9. Owner review and merge (review sweep below is done and pushed); answers to Q-NO2-1..3 and the commit email (KNOWN-ISSUES 111 and 118).

## Review session 2026-11-22 (PR #212 sweep: requesting-code-review + qt-qml-review + ponytail-audit; ONE agent, no sub-agents, as ordered)
**Commit email for these commits:** `allibaas1998@gmail.com` (the project's standing instruction, KNOWN-ISSUES 118). PR #212's first three commits keep `dextran52@gmail.com` (history is not rewritten).
- [x] R0. Cloned through the session proxy, checked out the PR branch (head `36677ec`). CI on it was green (5810/5810); no owner comments or reviews.
- [x] R1. Lint (`qt_qml_lint.py` on the 5 changed QML tests): 206 hits = 200 JS-1 `var` + 5 STY-1 (the project's test style, unchanged) + 1 ORD-1 at `tst_OrderPlan.qml:20` (false positive: a `return {` literal inside a function). The PR changes no component, binding, layout, loader, delegate or state: the six QML review domains have nothing to review. KNOWN-ISSUES 113.
- [x] R2. Deep read of `OrderPlan.js` against `OrdersStore._normalizeOrder/computeOrderTotals/addOrder`, the server `checkCreateOrder` and mint, and the `NewOrderDialog` inputs. The money invariants equal the store's rounding (same sum order; a float sum is monotone, so discount <= subtotal always holds). Judged non-changes: KNOWN-ISSUES 116.
- [x] R3. FIX, commit `9de5437`: a unit price above `RestockFlow.MAX_UNIT_COST` (1e9) is `bad-line`; node rows, QML twin rows, 3 mutants killed. KNOWN-ISSUES 114.
- [x] R4. Docs fixed in the second review commit: "94-88" typo (STATUS, CHECKPOINT), the PR body's "87" (the item was 98 then, 111 now), stale totals (2183/1061 were pre-rebase), refusal-row count (55), AGENTS entry moved next to its NO1 sibling, Skill 185 rule 7, README, design D-NO2-4, test plan section 6. KNOWN-ISSUES 113-118.
- [x] R5. CI read on `c6ac2bc`: all green (QML 3351, Functions 2206, Rules, E2E; 5810/5810), recorded in test plan section 6. PR description updated (87 -> 111, totals, review section). Memory updated. Only the owner's review, merge and the Q-NO2 answers remain (step 9).

- [x] R6. (2026-11-23; functions 2258/2258 and scripts 1199/1199 RUN on the rebased tree) Rebased onto `main` @ `01c0ff5` (#213, #214 took KNOWN-ISSUES 94-106 and Skills 183-184): six commits replayed, CHECKPOINT kept as this branch's, README, SKILLS, SKILLS-INDEX and KNOWN-ISSUES merged by hand (both sides kept), `pr210-merged-prev-CHECKPOINT.md` is main's. Force-pushed with a lease. My docs renumbered in a follow-up commit: KNOWN-ISSUES 94-105 -> 107-118, Skill 183 -> 185 (the PR description too). Commit email for the rebase and the follow-up stays `allibaas1998@gmail.com` (the standing instruction); main's KI 99 closure says `allibaas52@gmail.com`: owner to confirm (item 118).
- [ ] R7. Read CI on the rebased tip and record it in test plan section 6.

## Next slice (NO3, not started)
Wire `OrdersStore.addOrder` to `OrderPlan` (design section 3): `recordOperation("createOrder", ..., { awaitServer: true })`, offline refused with a clear text, callback `(ok, id)` from `reflect`, `DataModel` route for `operationApplied/Rejected`, auto-approve after the answer, delete the no-lines branch (KNOWN-ISSUES 110), replace the dormancy guards with a wiring guard. Copy the shape of AP3a (`AddProductFlow.js`, `InventoryStore.addProduct`, `tst_InventoryStore_addProduct.qml`, `addProductWire.test.js`). Ask the owner Q-NO2-1 first. NO3 must also: cap `NewOrderDialog._setLinePrice` at `RestockFlow.MAX_UNIT_COST` with a visible message (KNOWN-ISSUES 114) and give every planner refusal reason a person-facing text (KNOWN-ISSUES 115).
