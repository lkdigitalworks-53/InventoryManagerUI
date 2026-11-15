# CHECKPOINT: 2026-11-16 AP3a (add product wired to the atomic operation) - resume here

**Branch:** `feat/2026-11-16-ap3a-add-product-wire`, cut from `main` @ `503adda` (#201 merged, device tested by Taher). Contract: `docs/superpowers/specs/2026-11-13-add-product-atomic-operation-design.md` sections 7 to 9; this slice: `docs/superpowers/specs/2026-11-16-ap3a-add-product-wire-design.md`.
**Commit rule (current, Taher 2026-11-16):** every commit message carries the line `lkdwtaher@gmail.com`; git user `Taher (via Claude session) <lkdwtaher@gmail.com>`. PAT per command via `git -c http.extraHeader`, never in `.git/config`, the repo or memory.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; no parallel agents. Node tests of `functions/` DO run here (`cd functions && npm ci && node --test`).
**Previous checkpoint archived:** `specs/2026-11-16-pr201-merged-prev-CHECKPOINT.md`.
**Test plan:** `docs/superpowers/test-plans/2026-11-16-ap3a-add-product-wire-test-plan.md`.

## Step 2 arc (add product with opening stock)
AP1 server (#199), AP2 client pure layer (#201) merged. **AP3 is split (D-AP3-1):** AP3a (THIS BRANCH) = `AddProductFlow.js`, `InventoryStore.addProduct` rewrite + apply/answer hooks, `DataModel` route, e2e helpers, guards; the dialog gets only the status handling. AP3b = dialog (inline supplier "Use" row, strict number parsing, limits, submit body tested in Node). AP4 = docs + device test of the whole arc.

## Steps (tick as done)
- [x] 0. Clone, memory, read STATUS section 14/15, designs AP1/AP2, store, dialog, DataModel, e2e files. Next task = AP3.
- [x] 1. Branch cut, previous checkpoint archived, this file written.
- [ ] 2. Design doc + test plan skeleton (written with the docs step 11, after the code).
- [x] 3. `AddProductFlow.js` + `RestockFlow.queuedNewSupplierClash` covers addProduct ops; Node tests.
- [x] 4. `InventoryStore.addProduct` rewrite, `applyAddProductResults`, answer hooks, remove `_resolveSupplierId`.
- [x] 5. `DataModel` route (call site + Connections).
- [x] 6. Dialog status handling only.
- [x] 7. e2e: 5 `_createProduct` helpers (scoped online flip), 3 files point `operationFunctionUrl` at the emulator.
- [x] 8. Guards: delete AP1 G-1 and AP2 G-1, update SB-4, P-2, add wiring pins.
- [ ] 9. QML twins (CI-only).
- [~] 10. `node --test` in `functions/`: 1899/1899 pass after steps 3-8 (commit 1 of the code). Still to add: `addProductWire.test.js` (real InventoryStore bodies in Node) then re-run.
- [ ] 11. Docs: STATUS section 16, KNOWN-ISSUES, README/AGENTS/SKILLS, test plan numbers.
- [ ] 12. Push, read CI if reachable, final report (done / next).

## NEXT (if this session stops)
Continue at the first unchecked step. Each commit is independent. Do not force-push.
