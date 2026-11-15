# CHECKPOINT: 2026-11-15 AP2, add product client PURE layer, dormant - resume here

**Branch:** `feat/2026-11-15-ap2-add-product-client-plan`, cut from `main` @ `59734ce` (#199 AP1 merged). Contract: `docs/superpowers/specs/2026-11-13-add-product-atomic-operation-design.md` section 9 (D-AP-11 nonce in ids, D-AP-12 neutralise `{{`/`}}`; both decided by Taher). This slice's own design: `docs/superpowers/specs/2026-11-15-ap2-add-product-client-plan-design.md`.
**Commit rule:** every commit message ends with a line `allibaas52@gmail.com` (user instruction 2026-11-15; git user `Taher (via Claude session)`). PAT per command via `git -c http.extraHeader`, never in a URL, `.git/config`, the repo or memory.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`. Node tests of `functions/` DO run here (`cd functions && npm ci && node --test`, baseline 1819/1819 on `59734ce`).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-15-pr199-merged-prev-CHECKPOINT.md`.
**Test plan:** `docs/superpowers/test-plans/2026-11-15-ap2-add-product-client-plan-test-plan.md`.

## Step 2 arc
AP1 server (merged #199). **AP2 client pure layer (THIS BRANCH):** `OperationKeys.addProductNonce/addProductKey/isAddProductKey/createdTxId/productAddedActId`, `qml/helper/AddProductPlan.js` (`build`, `reflect`, `neutralisePlaceholders`), `FailureCause.forAddProduct`, `DescribeItem` label. Nothing calls it (dormant). AP3 = wire `InventoryStore.addProduct` + `AddProductDialog` + `DataModel` route (D-AP-7 refuse offline, D-AP-8 photo from live answer, both decided). AP4 = docs + device test. Then step 3 (new order, `_tryAdjustOrder`, imported completion, reverse), step 4 (import chunking; G5, G9 need designs).

## Steps
- [x] 0. Clone, memory, skills, STATUS, design read; baseline 1819/1819; branch cut.
- [x] 1. Code: OperationKeys, AddProductPlan.js, FailureCause.forAddProduct, DescribeItem (smoke-tested against the real server validator).
- [ ] 2. Node tests (`functions/test/addProductPlan.test.js`, drift test C-2 widened) run green + coverage.
- [ ] 3. QML twins (`tests/tst_AddProductPlan.qml`, OperationKeys, FailureCause, DescribeItem rows) - CI only.
- [ ] 4. Docs: design, test plan, README, AGENTS, SKILLS + index, STATUS section 15, KNOWN-ISSUES, test-plans README row.
- [ ] 5. Push, open PR, read CI.

## NEXT (if this session stops)
Continue at the first unchecked step. Each commit is independent. Never force-push this branch.
