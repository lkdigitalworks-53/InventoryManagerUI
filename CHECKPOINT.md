# CHECKPOINT — 2026-10-18 P1 slice S1b: derived ledger rows for whole-record inventory mutations (resume here)

**Branch:** `feature/2026-10-18-p1-s1b-derived-mutations`, cut from `main` @ `f9e8fe4` (S1a, PR #146, merged).
**Commit identity:** `lkdwtaher@gmail.com` (Taher's rule; the first two commits on this branch carry `taher.lkdw@gmail.com`, left as is: fixing it needs a force-push). PAT only in the push command, never in a file or git config; after push `grep -c ghp_ .git/config` must print 0.
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
- [x] 9b. **Review round (2026-10-18, same PR, no new PR).** Taher's answers: D-1 = he has NOT tested a 150-row import; asked what happens on an order-line `operation-too-large` at the 166 cap; "rest as recommended". The earlier open-question list lived only in the old chat (nothing on the PR, no review branch, no checkpoint), so "the rest" = a fresh sweep of the PR diff, recommendations below.
  - Status found: PR #149 open, not draft, mergeable `clean`, CI 5/5 green on `5ae38da` (2980 tests), no review comments.
  - Re-verified: `cd functions && node --test` 739/739 before my change, 740/740 after; 100% line on the 4 touched lib files (branch gaps remaining are the old `after || {}` fallbacks, not S1b lines).
  - Answer to the 166 question: unreachable for orders (planner stops at 200 ops, about 66 lines, local message, order stays `pending`); server `operation-too-large` would re-send 3x then flag `out of stock` (latent, KNOWN-ISSUES). New Node pin `movementWiring.test.js` "write budget accepts the largest order the client planner can send": mutation-checked (`MAX_OPS` 210, `MAX_TXN_WRITES` 480 both fail it).
  - Test plan: the wrong "166+ lines" item replaced by two real ones (about 60-line order completes = D-1 for orders; about 70-line order refused on the device); D-1 import item marked NOT YET RUN.
  - D-1 decision: keep 150 / 200 (recommendation: A now, C on dev). New evidence: Firestore's public quotas page (checked today) lists no per-commit write COUNT, only 10 MiB request size, 270 s transaction time, 500 field transforms per document; documented as "not documented", not "no limit". Fallback if dev fails: `MAX_BATCH_SIZE` + `Gateway.maxBatchSize` + pins (about 100), and `MAX_OPS` if the 60-line order fails.
  - Docs: comments in `operationLogic.js` / `batchMutationLogic.js`, `KNOWN-ISSUES.md` entry, SKILLS 122 (+ index), AGENTS.md P1 line, test plan.
  - Not done on purpose: no QML change (the latent `limit` handling is unreachable; code would be CI-only and untestable from the app).
- [ ] 10. **Taher:** deploy functions to dev; run S1a + S1b on-device checklists in `test-plans/2026-09-24-p1-stock-movements-test-plan.md`. Especially the 150-row import AND one ~60-line order (D-1: pessimistic write count 750 for the import, unverified).
- [ ] 11. After that: plan **S2** in its own session (kind pickers, delete `direct` mode and `runCutover`, lock `inventory` in rules, rules test).

## Open items / risks
- **D-1 (unverified write ceiling):** a 150-item inventory batch is 450 docs; if each `serverTimestamp()` counts as an extra write it is 750 and the real call fails. Pinned in a test, settled only by the dev deploy check. Fallback: cap about 100 (server + `Gateway.maxBatchSize` + pins).
- Ledger is still not complete for compliance until S2 locks the rules (R2): a member can still write `inventory` directly.
- Role gate / `valueAtCost` upper bound (PR #146 review item 4): decide before production, not done here.

## NEXT
Step 10 is Taher's: merge PR #149 after review, deploy functions to dev, run the S1a + S1b checklists (150-row import = D-1 check). Then plan S2 in a new session on a new branch off `main`.
