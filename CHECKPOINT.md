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
- [x] 2. Node tests: `functions/test/addProductPlan.test.js` 42/42, drift test C-2 widened, AP1 G-1 narrowed; full suite 1861/1861 (baseline 1819); 35 of 35 hand mutants killed (runner was throwaway in /tmp, list in the test plan).
- [x] 3. QML twins written (`tst_AddProductPlan.qml` + rows in OperationKeys, FailureCause, DescribeItem); 180 rows green in a throwaway Node harness; the real qmltestrunner result is CI's.
- [x] 4. Docs: design (D-AP2-1..11), test plan, README, AGENTS, SKILLS 170 + index (169 is taken by the picker S5a branch), STATUS section 15, KNOWN-ISSUES 40/41 updated + 43-45, test-plans README row.
- [x] 5. Pushed, PR #201 opened, CI all green on `1a99696` (QML, Functions, Rules, E2E; Deploy skipped).
- [ ] 6. Taher reviews PR #201 and answers the grill questions below; merge. Then AP3.

## Found, not fixed (documented)
KNOWN-ISSUES 43 (`RestockPlan` accepts any non-empty `now`), 44 (dialog values the planner refuses = AP3 checklist), 45 (skill numbers).

## Grill questions for Taher (veto in the PR)
1. D-AP2-2: planner refuses bad numbers and tax outside 0..100 (stricter than today). OK?
2. D-AP2-5: typed text is trimmed before storing. OK?
3. D-AP2-7: `created` row stores exact stock (old path rounded 2.5 to 2).

## NEXT (if this session stops)
AP3 after #201 merges: read design section 6 checklist first.
Continue at the first unchecked step. Each commit is independent. Never force-push this branch.
