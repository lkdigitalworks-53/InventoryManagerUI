# P1 (stock-movement taxonomy, CGST 56(2)) — status review, 2026-10-31

**Type:** docs only, no code changed, so no test plan (nothing to test). Read-only review of `main` @ `f18445e`. Open PRs seen: #175 (docs, L3), #172 (R2 mint engine), plus old #67/#39/#29. None is P1.
**Method:** read spec, S1a/S1b plans, S2 + S2d designs, test plans, `movementLogic.js`, `StockMovements.js`, callers, `git log`. I did not dispatch a reviewer subagent (no such tool here), did not re-verify C-3 Phase 3 tasks 6-11 on `main`, did not run anything.
**Honest summary:** capture of stock changes into the ledger is mostly done. The thing the law asks for, the register (opening / receipts / supplies / closing), is 0%.

## Done (merged on `main`)

| Slice | What | PR |
|---|---|---|
| Design | Spec rev 2 D1-D13, S1a/S1b plans, test plan, open questions Q1-Q4 resolved | #85, #86 |
| S1a | `functions/lib/movementLogic.js`; `recordDelta` + `recordOperation` delta ops write `stock_movements` rows in the SAME transaction (explicit or derived); write budget; `stock_movement` closed to client endpoints | #146 |
| S1b | Derived rows on `recordMutation` / batch / mutation ops; batch cap 200 -> 150 + `Gateway.maxBatchSize`; requestId guard (D-2) | #149 |
| S1a/S1b device checklists | Marked done by Taher 2026-10-21 (28 of 29 plan boxes ticked; the 1 open box is automated-only, not a device step) | `f6ad772` |
| S2b | Server `runCutover` + `cutoverLogic.js` deleted (deployed copy deleted by hand) | #151 |
| S2a-1 / S2a-2 | Client `runCutover` deleted; `direct` mode + `mode` property deleted (no flag flip can skip the ledger) | #152/#153, #154 |
| S2c | `inventory` locked in `firestore.rules` (gateway-only writes), closes spec risk R2 | #156 |
| S2d-1 | Client describes kinds: restock -> `receipt`, return / reopen / rollback -> `sales_return`, exchange -> `sale`; `StockMovements.js`, `Gateway.recordDelta` 7th arg, outbox coalescing rule | #170 |

Server-derived rows already exist for every other path (D11): create -> `receipt`, `completeOrder` -> `sale` (per product line), any other edit / delete -> `adjustment`. So **no stock change can bypass the ledger**. That is the auditor-critical property and it holds.

Tests present: functions `movementLogic` 24, `movementDerive` 32, `movementStrict` 10, `movementWiring` 31, plus `stockMovementsParity`; QML `tst_StockMovements`, `tst_Gateway_movements`, `tst_OutboxStore_movements`, `tst_InventoryStore_movementKinds`, `tst_DataModel_movementKinds`. CI on the S2d-1 sweep head: 3528/3528.

## Pending

| Slice | Work | Blocked by | Sandbox-testable | My effort estimate |
|---|---|---|---|---|
| Verify S2d-1 | Device steps 8, 15, 16 were "not yet run" at 2026-10-28; functions must be deployed (deploy-on-merge CI #173 exists now, which shrinks risk R3) | Taher | n/a | 0.5 session |
| **S4 register** | Opening / receipts / supplies / closing per product and period; composite index (`productId` + `serverTimestamp`); pure math + report UI + export | CA for column grouping (spec §8) | Math yes, UI via CI | 2 sessions |
| S2d-2 | Server "kind hint" so an imported-order completion that clamps stays a `sale` instead of derived `adjustment` (K9) | none | Yes (`node --test`) | 1 session |
| S2e | Intent pickers: `loss`, `theft`, `destroyed`, `write_off`, `free_sample`, `gift` + `valueAtCost`; split "edit fields" vs "change stock" in the product form; damaged return = `sales_return` vs `destroyed` (Q4) | **CA** (parked by Taher's Q1) + UX undecided | Server no change; UI via CI | 2-3 sessions, highest rework risk |
| S3 | `sale` rows per FIFO portion with `batchRef` (instead of one derived row per product line) | C-3 Phase 3 (not re-verified), and need undecided | QML via CI | 2-3 sessions |
| Prod reset path | No in-app way to wipe a tenant ledger since `runCutover` died (Q6). Design before the first prod tenant | first prod tenant | n/a | design only |

By slice count: 7 of 11 done (about 64%). By legal deliverable: the register is 0%, intent classification is 0%.

## Known weak spots (verified in docs/code, not guesses)

1. **Coarse labels.** Manual stock edit in the product form, bulk import quantity change and delete all record `adjustment` (spec R4). A loss and a typo fix look identical to an auditor until S2e.
2. **K9 mislabel.** Imported-order completion with a clamp records `adjustment`, not `sale`. Supplies column would be understated for those rows.
3. **`valueAtCost` is client-stated (R1) and derived rows carry 0.** Input-tax-credit reversal on loss / theft / gift cannot be computed from derived rows. Confirm the rule with the CA.
4. **K6/K7 labels are my predecessors' defaults, flagged "CA to confirm"** (reopen as `sales_return`, rollback pair).
5. **No role gating** for `loss` / `theft` / `write_off` (Q1, resolved as "none now"). Once S2e adds pickers, any staff can write stock off. Revisit then.
6. **S3 may be unnecessary.** Server already writes a `sale` row per product line. Per-batch rows only matter if the CA or an auditor needs batch-level traceability. Nobody has said so.

## Spec contradiction worth fixing

Spec §4 says S4 "depends on S2, S3". It does not need either to produce the four register columns: `receipt`, `sale`, `sales_return`, `adjustment` rows already exist. Only intent breakdown needs S2e.

## Decisions for Taher (default = my recommendation)

| # | Question | Options | Recommend |
|---|---|---|---|
| Q1 | Next slice | S4 register / S2d-2 / S2e / S3 | **S4 first**, then S2d-2. Gives the CA real output to react to. Cost: if the CA wants other grouping, report math is reworked (pure JS, cheap) |
| Q2 | S3 per-FIFO `batchRef` rows | build / defer / drop | **Defer** until CA or auditor asks. Cost of building: rewrites completion plan, highest-churn code in the app |
| Q3 | S2e pickers | now / after CA | **After CA** (your own Q1 decision stands). Without the CA, pickers may be thrown away |
| Q4 | Role gating for loss / theft / write-off | none / owner+admin only / configurable | Decide at S2e. Default **owner+admin only** for `write_off`/`theft`, because staff-written losses are the classic leakage path. Cost: more UI states, more tests |
| Q5 | `valueAtCost` source | client-stated / server-derived from FIFO batch cost | **Server-derived** for the intent kinds. Cost: server reads batches inside the transaction (write budget, contention). Needs design |
| Q6 | S4 export | in-app view only / xlsx / both | xlsx first: the CA works in Excel, and `XlsxService` exists |

Open question to you: have you contacted the CA? S4 grouping, S2e, K6/K7 and valueAtCost all wait on one conversation. That conversation is the real critical path, not code.

## Next

1. Taher: run S2d-1 device steps 8, 15, 16; answer Q1-Q6; talk to the CA with these 4 asks: register columns, damaged return, ITC value rule, reopen/rollback labels.
2. Next session: S4 design spec + plan + test plan (docs PR), then S4 math.
