# CHECKPOINT: 2026-11-16 AP3a (add product wired to the atomic operation) - resume here

**Branch:** `feat/2026-11-16-ap3a-add-product-wire`, cut from `main` @ `503adda` (#201 merged, device tested by Taher). Contract: `docs/superpowers/specs/2026-11-13-add-product-atomic-operation-design.md` sections 7 to 9; this slice: `docs/superpowers/specs/2026-11-16-ap3a-add-product-wire-design.md`.
**Commit rule (current, Taher 2026-11-16, replaces the earlier address):** every commit message carries the line `allibaas52@gmail.com`; git user email `allibaas52@gmail.com`. The PAT is never written to the repo, a doc or memory.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; no parallel agents. Node tests of `functions/` DO run here (`cd functions && npm ci && node --test`).
**Previous checkpoint archived:** `specs/2026-11-16-pr201-merged-prev-CHECKPOINT.md`.
**Test plan:** `docs/superpowers/test-plans/2026-11-16-ap3a-add-product-wire-test-plan.md`.

## Step 2 arc (add product with opening stock)
AP1 server (#199), AP2 client pure layer (#201) merged. **AP3 is split (D-AP3-1):** AP3a (THIS BRANCH) = `AddProductFlow.js`, `InventoryStore.addProduct` rewrite + apply/answer hooks, `DataModel` route, e2e helpers, guards; the dialog gets only the status handling. AP3b = dialog (inline supplier "Use" row, strict number parsing, limits, submit body tested in Node). AP4 = docs + device test of the whole arc.

## Steps (tick as done)
- [x] 0. Clone, memory, read STATUS section 14/15, designs AP1/AP2, store, dialog, DataModel, e2e files. Next task = AP3.
- [x] 1. Branch cut, previous checkpoint archived, this file written.
- [x] 2. Design doc + test plan written (`specs/2026-11-16-ap3a-add-product-wire-design.md`, `test-plans/2026-11-16-ap3a-add-product-wire-test-plan.md`, README index row).
- [x] 3. `AddProductFlow.js` + `RestockFlow.queuedNewSupplierClash` covers addProduct ops; Node tests.
- [x] 4. `InventoryStore.addProduct` rewrite, `applyAddProductResults`, answer hooks, remove `_resolveSupplierId`.
- [x] 5. `DataModel` route (call site + Connections).
- [x] 6. Dialog status handling only.
- [x] 7. e2e: 5 `_createProduct` helpers (scoped online flip), 3 files point `operationFunctionUrl` at the emulator.
- [x] 8. Guards: delete AP1 G-1 and AP2 G-1, update SB-4, P-2, add wiring pins.
- [x] 9. QML twins (CI-only): `tests/tst_AddProductFlow.qml` (16), `tests/tst_InventoryStore_addProduct.qml` (12).
- [x] 10. `node --test` in `functions/`: 1918/1918 pass (1899 + `addProductWire.test.js` 19).
- [x] 11. Docs: STATUS section 16, KNOWN-ISSUES 47-52, README, AGENTS, SKILLS 172 + index, test plan.
- [ ] 12. Push, read CI if reachable, final report (done / next).

## Review sweep of PR #203 (chat session 2026-11-16, no parallel agents)
- [x] R0. Clone, read memory, fetch `refs/pull/203/head`, check out the PR branch (no rebase needed: `main` still `503adda`).
- [x] R1. CI read via API: Functions, QML, Rules green on f01a59c; **E2E RED: 29 of 71 failed**, all inside the `_createProduct*` helpers (`addProduct callback never fired` / `did not return a productId`). Raw logs are on a blocked host; the PR bot comment named the tests.
- [x] R2. Root cause: the helpers flip `AuthService.isOnline = true`; `AuthService.onIsOnlineChanged` runs `init()` because the e2e files set `AuthStore.idToken/uid/tenantId` directly (`isAuthenticated` stays false); `init()` -> `loadSession()` -> `clear()` wipes the fixture; `Gateway._sendOperation` returns silently on an empty token; the awaiting callback never fires. Fix: save the three fields, flip, restore at once (six files). Guard: `functions/test/addProductE2eHelpers.guard.test.js` (25 tests, mutation-checked).
- [x] R2b. CI on 83ed1e0: Functions, QML, Rules AND E2E green. The fix is proven.
- [x] R3. Store twin `tests/tst_InventoryStore_addProduct.qml` strengthened (+3 functions: stock 0, sync-first, no bookkeeping; vacuous replay assertion made strict). qt-qml-review lint on changed lines: nothing to fix (KNOWN-ISSUES 55). ponytail-audit: `nextProductId` kept on purpose (issue 50). KNOWN-ISSUES 49 rewritten, 53..55 added; test plan and Skill 172 updated. Functions suite 1943/1943.
- [x] R4. CI on 710bef6: Functions, QML (incl. the 3 new twin cases), Rules, E2E all GREEN. `PR Test Summary Comment` job fails even with every test job green (so it is the bot step, not a test; cause not read, annotations only show Node 20 deprecation warnings).
- [ ] R5. Next session: AP3b (dialog inline supplier "Use" row, strict parsing/limits, submit body in Node), then AP4 (docs + device test). Seed SupplierStore in ProductPhotosE2E and StockBatchStoreE2E with a CI run (KNOWN-ISSUES 54).
- NOTE for the next session: PR #203 is review-clean and green; only the human review and the device test (test plan, on-device section) remain.

## CI
PR #203 opened. Functions Tests + Rules success on b7ccbfd; QML Tests and E2E were still running when last read. Unproven locally: both QML twins, the six e2e files.

## NEXT (if this session stops)
If CI is red, fix on this branch first. Then AP3b (dialog inline supplier "Use" row, strict parsing/limits, submit body in Node), AP4 (device test).

Continue at the first unchecked step. Each commit is independent. Do not force-push.
