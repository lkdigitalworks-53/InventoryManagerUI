# CHECKPOINT — 2026-10-18 P1 slice S1b: derived ledger rows for whole-record inventory mutations (resume here)

**Branch:** `feature/2026-10-18-p1-s1b-derived-mutations`, cut from `main` @ `f9e8fe4` (S1a, PR #146, merged).
**Commit identity:** `taher.lkdw@gmail.com`. PAT only in the push command, never in a file or git config; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** do not build/run the app; no Qt in the sandbox (CI is the QML oracle); push without asking, Taher reviews in the PR; short scope (token budget, multi-account hand-off); honest trade-offs; caveman FULL.
**Skills used:** `superpowers:brainstorming`, `qt-development-skills:qt-ui-design`, `qt-development-skills:qt-qml`, `ponytail:ponytail`. No UI in this slice (server + one QML constant), so no design step was needed.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-17-p1-s1a-prev-CHECKPOINT.md`.

## Why this item
Taher said "s2b". In the repo S2b = "park terminal writes" (2026-09-30), already merged. P1's S2 needs S1b deployed first, so this session read it as **P1 S1b** (next slice in the S1a checkpoint, step 10). Assumption flagged in the PR; if he meant something else, this branch is still the required predecessor of P1 S2.

## Scope (one slice = one PR)
Plan: `plans/2026-09-24-p1-server-side-stock-movements-s1b.md` (patches drifted, hand-applied; drift note added at the top of the plan). Plus D-2 from the PR #146 review (requestId guard), chosen by Taher for S1b.

## Steps
- [x] 1. Cloned, read memory + S1a checkpoint + S1b plan + PR #146 review (D-1/D-2/D-3), branch cut.
- [x] 2. Tests first: `functions/test/movementDerive.test.js` (32, strict fake in `test/testSupport/strictDb.js`), 22 red.
- [x] 3. `movementLogic.stockOf` / `deriveForMutation`; `applyMutation`, `applyMutationsBatch`, operation mutation ops write the derived row after the CAS check; batch rejects `movements`; `MAX_BATCH_SIZE` 200 -> 150.
- [x] 4. D-2: `gatewayLogic.isClientRequestId` (no `~`, no `/`, 1..200 chars); applied in the `recordMutation` and `recordDelta` handlers (`index.js`) and in the batch validator (requestId and entityId). Shared validators untouched on purpose (`recordOperation` passes `~` ids through them). `functions/test/requestIdGuard.test.js` (13).
- [x] 5. Existing tests re-expected: `batchMutationLogic.test.js` (pin 150, F36b 150, RES-B1 probe id).
- [x] 6. Server suite `cd functions && node --test` = **739/739**; 100% line on the 4 touched lib files; 11 mutations all caught, files restored.
- [x] 7. Client mirror (CI only): `Gateway.maxBatchSize` 150; `tests/tst_Gateway.qml` pin + the 250-item split test (150 + 100: the plan missed this one), `tst_InventoryStore_upsertMany.qml` message, `tst_BulkImportChunkingE2E.qml` indices 149/150, `tst_OrdersStoreE2E.qml` message.
- [x] 8. Docs: README, AGENTS.md, S1b plan drift note, P1 test plan (S1b rows to real numbers, D-2 + on-device items), test-plans index row.
- [x] 9. Pushed, **PR #149** opened. CI on `5ae38da` via check-runs API: 5/5 green (QML, E2E, Rules, Functions, PR comment). QML/E2E cap-mirror edits therefore verified by CI.
- [ ] 10. **Taher:** deploy functions to dev; run S1a + S1b on-device checklists in `test-plans/2026-09-24-p1-stock-movements-test-plan.md`. Especially the 150-row import (D-1: pessimistic write count 750, unverified).
- [ ] 11. After that: plan **S2** in its own session (kind pickers, delete `direct` mode and `runCutover`, lock `inventory` in rules, rules test).

## Open items / risks
- **D-1 (unverified write ceiling):** a 150-item inventory batch is 450 docs; if each `serverTimestamp()` counts as an extra write it is 750 and the real call fails. Pinned in a test, settled only by the dev deploy check. Fallback: cap about 100 (server + `Gateway.maxBatchSize` + pins).
- Ledger is still not complete for compliance until S2 locks the rules (R2): a member can still write `inventory` directly.
- Role gate / `valueAtCost` upper bound (PR #146 review item 4): decide before production, not done here.

## NEXT
Step 10 is Taher's: merge PR #149 after review, deploy functions to dev, run the S1a + S1b checklists (150-row import = D-1 check). Then plan S2 in a new session on a new branch off `main`.
