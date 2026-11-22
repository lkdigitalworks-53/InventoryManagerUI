# CHECKPOINT: 2026-11-22 NO2 create-order client plan - resume here

**Branch:** `feat/2026-11-22-no2-create-order-client-plan` (cut from `main` @ `a3227e7`, #208 merged).
**Commit rule:** every commit carries `dextran52@gmail.com` (author and message), per the task prompt of 2026-11-22. The previous checkpoint and KNOWN-ISSUES 80 say the project rule is `allibaas1998@gmail.com`; the conflict is KNOWN-ISSUES 98 and waits for the owner. History is not rewritten.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; PAT per command via `git -c http.extraHeader`, never in `.git/config`; keep scope short so another account can take over.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-22-pr208-merged-prev-CHECKPOINT.md`.
**Design:** `docs/superpowers/specs/2026-11-22-no2-create-order-client-plan-design.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-22-no2-create-order-client-plan-test-plan.md`.
**Skills used:** caveman, brainstorming (design + decisions defaulted, vetoable in the PR, as ordered), qt-qml and qt-ui-design (pure helpers + QML twins only, no UI), ponytail (redundant lines deleted after the mutant sweep).

## Steps
- [x] 0. Clone, memory read, roadmap read (`ATOMIC-OPERATIONS-STATUS.md` sections 14-18, NO1 design). State: steps 1-2 done, NO1 merged (#208); next = NO2.
- [x] 1. Code read: `AddProductPlan.js`, `OperationKeys.js`, `FailureCause.js`, `DescribeItem.js`, `OrdersStore._normalizeOrder/computeOrderTotals/addOrder`, `NewOrderDialog.trySubmit`, server `checkCreateOrder`.
- [x] 2. Design written (D-NO2-1..9, Q-NO2-1..3).
- [x] 3. Code: `OperationKeys` (3 functions), `OrderPlan.js` (new), `FailureCause.forCreateOrder`, `DescribeItem` label, `AddProductPlan` exports `isIsoInstant/isIsoDate` (build uses them).
- [x] 4. Node tests `createOrderPlan.test.js` (34), guards widened (NO1 G-1, AP G-1), `failureCauseCodes` C-2. Functions 2183/2183, scripts 1061/1061.
- [x] 5. Hand mutants: 60 -> 12 survivors -> 9 test rows + 3 deleted/simplified lines -> 56/56 killed.
- [x] 6. QML twins: `tst_OrderPlan.qml` (new) + additions to four files; harness-checked, CI is the oracle.
- [x] 7. Docs: design, test plan (+ index row), KNOWN-ISSUES 94-88, Skill 183 + index, AGENTS, README, ATOMIC-OPERATIONS-STATUS 19.
- [x] 8. Committed, rebased onto main (#209, #210 took the doc numbers: KNOWN-ISSUES 94-99, Skill 183), pushed, PR #212, CI all green on `3ddef0c`, recorded in test plan section 5.
- [ ] 9. Owner review and merge; answers to Q-NO2-1..3 and the commit email (KNOWN-ISSUES 98, also 93).

## Next slice (NO3, not started)
Wire `OrdersStore.addOrder` to `OrderPlan` (design section 3): `recordOperation("createOrder", ..., { awaitServer: true })`, offline refused with a clear text, callback `(ok, id)` from `reflect`, `DataModel` route for `operationApplied/Rejected`, auto-approve after the answer, delete the no-lines branch (KNOWN-ISSUES 97), replace the dormancy guards with a wiring guard. Copy the shape of AP3a (`AddProductFlow.js`, `InventoryStore.addProduct`, `tst_InventoryStore_addProduct.qml`, `addProductWire.test.js`). Ask the owner Q-NO2-1 first.
