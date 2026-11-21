# CHECKPOINT: 2026-11-21 NO1 create order server operation - resume here

**Branch:** `feat/2026-11-21-no1-create-order-server-op` (cut from `main` @ `68afa5c`, #206 merged).
**Commit rule:** every commit message carries `dextran52@gmail.com` (task prompt of 2026-11-21).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; PAT per command via `git -c http.extraHeader`, never in `.git/config`; keep scope short so another account can take over.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-21-pr206-merged-prev-CHECKPOINT.md`.
**Design:** `docs/superpowers/specs/2026-11-21-create-order-atomic-operation-design.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-21-no1-create-order-server-test-plan.md`.
**Skills used:** caveman, brainstorming (design + decisions defaulted, vetoable in the PR, as ordered), qt-qml and qt-ui-design (no QML touched), ponytail.

## Steps
- [x] 0. Clone, memory read, roadmap read (`ATOMIC-OPERATIONS-STATUS.md` sections 1-17): step 1 restock and step 2 add product merged (AP3b #207); AP4 is the owner's device pass; next = step 3 new order. `main` also has #205 and #206.
- [x] 1. Code read: `OrdersStore.addOrder` = REST mint (`counters/orders`) then `recordMutation` create; no feed row, no ledger row; auto-approve = a SECOND `completeOrder` op. Engine (`operationLogic.js`) already mints and writes in one transaction.
- [x] 2. Design written (D-NO-1..9, Q-NO-1..4). Slicing: NO1 server dormant -> NO2 client planner -> NO3 wire -> NO4 device test.
- [x] 3. Server: `counterRegistry.js` `order` entry; `operationLogic.js` `createOrder` in `OP_TYPES`.
- [x] 4. Tests: new `operationLogic.createOrder.test.js` (35), guard rows +5 / mutants +5, handler +2, owner-only grid +1 row +1 test, three pins flipped, three emulator cases (CI only). Functions 2147/2147 RUN, scripts 1061/1061 RUN, 100% line/branch/function on both changed files, 8/8 hand mutants killed.
- [x] 5. Docs: test plan, KNOWN-ISSUES 74-78, Skill 180 + index (`skills-index.js --check` clean), AGENTS, README, ATOMIC-OPERATIONS-STATUS section 18.
- [x] 6. Committed and pushed `d721d66`; PR #208 opened. CI read: all green (Functions, Rules, E2E incl. the 3 NO1 cases, QML), recorded in test plan section 5.
- [x] 7. Final report to the owner: done / open questions Q-NO-1..4 / device steps / next = NO2.

## Next slice (NO2, not started)
Client pure layer, dormant: `OperationKeys.createOrderNonce/createOrderKey/isCreateOrderKey`, `qml/helper/OrderPlan.js` (`build`, `reflect`, typed-brace neutralising per KNOWN-ISSUES 75), `FailureCause.forCreateOrder`, `DescribeItem` label, QML twins, the planner running through the REAL server validator and apply in Node (pattern: `addProductPlan.test.js`). Read `qml/helper/AddProductPlan.js`, `OperationKeys.js`, `FailureCause.js` first and copy their shape.

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`.
