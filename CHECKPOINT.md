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
- [x] 3. SERVER: `product` counter, `addProduct` opType, activity kind tied to opType, `checkActivityOp(opType)` (commit 704d761).
- [x] 4. TESTS: 32 new + guard rows/5 mutants + 2 handler + 3 emulator (CI only) + 4 flipped pins. Functions 1720 -> 1754 green (1766 after the PR #199 sweep: +K-2, +K-3, +10 role-gate), 100% line/branch/func on both files, 16/16 hand mutants killed.
- [x] 5. DOCS: test plan, README, AGENTS, SKILLS 168 + index, STATUS section 14, KNOWN-ISSUES 34-39, test-plans README row.
- [ ] 6. Push, open PR, read CI.

## Out-of-scope findings (documented, NOT fixed here): KNOWN-ISSUES 34 (inventory doc shape not validated: non-numeric stock gets no ledger row), 35 (opening stock is a `receipt`), 36 (duplicate name/SKU), 37 (dialog inline supplier still old path, AP3), 38 (offline add), 39 (Skill 167 claimed by two other branches).

## NEXT (if this session stops)
Continue at the first unchecked step. Each commit is independent. Never force-push this branch.

## PR #199 review sweep, 2026-11-15 (done; pushed to this branch)
- [x] Read diff + connected code; full functions suite with coverage: 100% line/branch/func on `counterRegistry.js` and `operationLogic.js`.
- [x] Three lenses run one after another (no parallel agents): code review, QML review (no QML in the PR, nothing to lint), ponytail audit. AP1's own server code: no defect.
- [x] +K-2, +K-3 pinned (KNOWN-ISSUES 40, 41; design D-AP-11, D-AP-12; Skill 168 rule 10; AGENTS carry-over). Both are AP2's to settle.
- [x] FIXED: `recordOperation` and `recordMutationsBatch` had no owner/admin gate for staff delete and the `removed_staff` tombstone (KNOWN-ISSUES 42). One shared helper in `functions/index.js`, +10 handler tests (6 failed on the unfixed code), +1 emulator case (CI only), test plan `2026-11-15-owner-only-writes-test-plan.md`. Functions 1766/1766.
- [ ] CI result on the new head (fill in the test plans).
- [ ] Taher: D-AP-7, D-AP-4 (earlier), D-AP-11, D-AP-12 (new). Deploy of this PR now touches live endpoints (`index.js`), so it is no longer "dormant only": the role gate goes live on merge.

