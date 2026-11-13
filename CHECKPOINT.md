# CHECKPOINT: 2026-11-13 AP1, add product with opening stock = ONE atomic operation, SERVER slice, dormant - resume here

**Branch:** `feat/2026-11-13-ap1-add-product-server-op`, cut from `main` @ `024a6f6` (#197 merged). Design: `docs/superpowers/specs/2026-11-13-add-product-atomic-operation-design.md` (D-AP-1..10, all vetoable in the PR; section 7 lists the four questions Taher would be grilled on, recommendation taken).
**Commit identity:** `Taher (via Claude session) <lkdigitalworks@gmail.com>` as git user AND last line of every commit message (project instruction of 2026-11-13; the Claude trailers come before it). PAT per command via `git -c http.extraHeader`, never in a URL, `.git/config`, the repo or memory.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests and a test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`. Node tests of `functions/` DO run here (`cd functions && npm ci && node --test`, baseline 1720/1720 on `024a6f6`). Server deploy BEFORE the client.
**Skills used:** `brainstorming` (design doc written; one-turn rule replaced the approval gate, decisions vetoable in the PR), `qt-qml` and `qt-ui-design` (N/A in AP1: no QML, no UI), `ponytail` (one registry entry, one opType, one branch in `checkActivityOp`, no new endpoint, no per-opType shape check D-AP-6).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-13-pr197-merged-prev-CHECKPOINT.md`.
**Skill number:** 168 (167 is taken on two open branches, `feat/2026-11-12-p1-s4b1-register-client-engine` and `feat/2026-11-12-picker-s4-edit-order`). If either merges first, renumber nothing: 168 stays.
**Test plan:** `docs/superpowers/test-plans/2026-11-13-ap1-add-product-server-test-plan.md`.

## Step 2 arc (the whole thing, so the next session knows where it is)
- AP1 server, dormant (THIS BRANCH). AP2 client pure layer (`OperationKeys.addProductKey`, `AddProductPlan.build/reflect`, `FailureCause`, `DescribeItem`). AP3 wire `InventoryStore.addProduct` + `AddProductDialog` (+ inline supplier row, R5a "Use" pattern) + `DataModel` route; needs Taher's answer to D-AP-7 (offline add: refuse) and D-AP-8 (photo from the live answer). AP4 docs + device test of the whole arc.
- Roadmap order after step 2: step 3 (new order, `_tryAdjustOrder`, imported completion, reverse), step 4 (import chunking; G5 product delete and G9 account writes need designs). R6 (device test of the restock arc) is Taher's and still open.

## Steps
- [x] 0. Clone, memory + STATUS + CHECKPOINT + KNOWN-ISSUES read, baseline 1720/1720, branch cut, identity set.
- [x] 1. Evidence read: `addProduct` (7 independent writes), `RestockPlan`, `operationLogic`, `counterRegistry`, `movementLogic` (create derives a `receipt` row), no role gate on `recordOperation` (same as `recordMutation`), drift guard, e2e twin pattern.
- [x] 2. Design doc written (this commit).
- [ ] 3. SERVER: `product` counter, `addProduct` opType, activity kind tied to opType, `checkActivityOp(opType)`.
- [ ] 4. TESTS: `operationLogic.addProduct.test.js`, guard rows + mutants, widened source pin, dormancy guard, e2e emulator case (CI only).
- [ ] 5. DOCS: test plan, README, AGENTS, SKILLS 168 + index, STATUS section 14, KNOWN-ISSUES, test-plans README row.
- [ ] 6. Push, open PR, read CI.

## NEXT (if this session stops)
Continue at the first unchecked step. Each commit is independent. Never force-push this branch.
