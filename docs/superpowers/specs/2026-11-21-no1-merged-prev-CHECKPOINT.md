# CHECKPOINT: 2026-11-21 NO1 create order server operation - resume here

**Branch:** `feat/2026-11-21-no1-create-order-server-op` (cut from `main` @ `68afa5c`, #206 merged).
**Commit rule:** every commit message carries `allibaas1998@gmail.com` (the project rule). The first three commits of this PR carry `dextran52@gmail.com` by mistake (KNOWN-ISSUES 80); history is not rewritten, every later commit uses the project email.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; PAT per command via `git -c http.extraHeader`, never in `.git/config`; keep scope short so another account can take over.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-21-pr206-merged-prev-CHECKPOINT.md`.
**Design:** `docs/superpowers/specs/2026-11-21-create-order-atomic-operation-design.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-21-no1-create-order-server-test-plan.md`.
**Skills used:** caveman, brainstorming (design + decisions defaulted, vetoable in the PR, as ordered), qt-qml and qt-ui-design (no QML touched), ponytail.

## Steps
- [x] 0. Clone, memory read, roadmap read (`ATOMIC-OPERATIONS-STATUS.md` sections 1-17): step 1 restock and step 2 add product merged (AP3b #207); AP4 is the owner's device pass; next = step 3 new order. `main` also has #205 and #206.
- [x] 1. Code read: `OrdersStore.addOrder` = REST mint (`counters/orders`) then `recordMutation` create; no feed row, no ledger row; auto-approve = a SECOND `completeOrder` op. Engine (`operationLogic.js`) already mints and writes in one transaction.
- [x] 2. Design written (D-NO-1..9, Q-NO-1..4). Slicing: NO1 server dormant -> NO2 client planner -> NO3 wire -> NO4 device test.
- [x] 3. Server: `counterRegistry.js` `order` entry; `operationLogic.js` `createOrder` in `OP_TYPES`.
- [x] 4. Tests: new `operationLogic.createOrder.test.js` (35), guard rows +5 / mutants +5, handler +2, owner-only grid +1 row +1 test, three pins flipped, three emulator cases (CI only). Functions 2147/2147 RUN (2149 after step 10), scripts 1061/1061 RUN, 100% line/branch/function on both changed files, 8/8 hand mutants killed.
- [x] 5. Docs: test plan, KNOWN-ISSUES 74-78, Skill 180 + index (`skills-index.js --check` clean), AGENTS, README, ATOMIC-OPERATIONS-STATUS section 18.
- [x] 6. Committed and pushed `d721d66`; PR #208 opened. CI read: all green (Functions, Rules, E2E incl. the 3 NO1 cases, QML), recorded in test plan section 5.
- [x] 7. Final report to the owner: done / open questions Q-NO-1..4 / device steps / next = NO2.
- [x] 8. PR #208 deep review (2026-11-21, skills: requesting-code-review, qt-qml-review, ponytail-audit; sequential, no parallel agents). Read: design, test plan, all 19 files of the diff, `operationLogic.js` in full, `gatewayLogic.validateMutationRequest`, the e2e diff, CI wiring. Re-ran: functions 2147/2147 green on the PR head.
- [x] 9. Finding F1 (must fix): the open `createOrder` op type was lax: an empty/missing order doc (burns a number, leaves `orders/ORD-nnn` with no fields), a stock delta riding along (an `adjustment` ledger row under a createOrder audit row), a composite id (`X-{{ord}}`), a second order, an owner-only write (staff delete, tombstone) all passed. Fix: `checkCreateOrder` in `operationLogic.js` (error `invalid-order`), `FailureCause._BUG_CODES` entry. Design D-NO-5b.
- [x] 10. Tests for F1: `operationLogic.createOrder.test.js` 35 -> 37 (S-1..S-5 replace K-1/K-3/K-4; S-5 = 1500-case monkey with an independent oracle; B-12/B-13 via `runUnchecked`); `index.handlers.ownerOnlyWrites.test.js` (generic grid row removed, + smuggle test for all roles); e2e case 2 rewritten (CI only). Functions 2149/2149, scripts 1061/1061, 100% line/branch/function on `operationLogic.js` and `counterRegistry.js`. 13 hand mutants of the new check: 7 killed, 1 killed after a new test case, 5 equivalent (listed in the test plan).
- [x] 11. Q-NO-3 answered by the owner (no new order offline, option A). Code check found restock and completion DO queue offline: KNOWN-ISSUES 79, design Q-NO-3.
- [x] 12. Lint sweep of the NO3 consumer files (`qt_qml_lint.py`): style noise only, KNOWN-ISSUES 81. Docs updated: design, test plan, KNOWN-ISSUES 75, 76, 79-82, Skill 180, AGENTS, README, ATOMIC-OPERATIONS-STATUS 18.
- [ ] 13. CI result of the review commit: read it on the PR and add it to test plan section 5 (the emulator e2e case 2 is CI-only and was never run). Open for the owner: Q-NO-1, Q-NO-2, Q-NO-4, and the global offline question (KNOWN-ISSUES 79).

## Next slice (NO2, not started)
Client pure layer, dormant: `OperationKeys.createOrderNonce/createOrderKey/isCreateOrderKey`, `qml/helper/OrderPlan.js` (`build`, `reflect`, typed-brace neutralising per KNOWN-ISSUES 75), `FailureCause.forCreateOrder`, `DescribeItem` label, QML twins, the planner running through the REAL server validator and apply in Node (pattern: `addProductPlan.test.js`). Read `qml/helper/AddProductPlan.js`, `OperationKeys.js`, `FailureCause.js` first and copy their shape.

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`.
