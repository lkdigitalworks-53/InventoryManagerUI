# CHECKPOINT: 2026-11-18 P1 S2d-2 (kind hint for derived stock rows) + CA questions document - resume here

**Branch:** `feat/2026-11-18-p1-s2d2-derived-kind-hint`, cut from `main` @ `591077e` (#203 AP3a merged; #204 P1 S2e-1 merged before it).
**Design:** `docs/superpowers/specs/2026-11-18-p1-s2d2-derived-kind-hint-design.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-18-p1-s2d2-derived-kind-hint-test-plan.md`.
**CA document (for Taher's review):** `docs/superpowers/CA-QUESTIONS.md`.
**Previous checkpoint archived:** `specs/2026-11-18-ap3a-merged-prev-CHECKPOINT.md` (AP3a; its follow-ups AP3b and AP4 are NOT done and are NOT P1: still queued, see NEXT).
**Commit rule (Taher's project instructions, replaces the earlier addresses in old checkpoints):** every commit message carries the line `lkdwtaher@gmail.com`; git user email `lkdwtaher@gmail.com`. The PAT is never written to the repo, a doc or memory.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; one short scope per session (token-limited, multi-account). Node tests of `functions/` DO run here (`cd functions && npm ci && node --test`).

## P1 standing (read from `main` @ 591077e, 2026-11-18)
| Slice | State |
|---|---|
| S1a, S1b, S2a-c, S2d-1, S2f-1..7 | merged |
| S4a read model + follow-ups (#193, #195), S4b-1 client engine (#198) | merged |
| S2e-1 reason policy + server-stamped cost (#204) | merged |
| **S2d-2 kind hint for the clamped imported-order deduction** | **THIS BRANCH** |
| S2e-2 pickers (loss, theft, destroyed, write_off, free_sample, gift) | open: UI; design questions Q4/Q5 + KNOWN-ISSUES S2e-1 items 16, 17; wants the CA answers |
| S3 `batchRef` per FIFO portion | open |
| S4b-2 register page + entry point | open: designed, Felgo-only (device-provable, not sandbox-provable) |
| S4c register print/export in the CA's column layout | blocked on the CA (see CA-QUESTIONS.md) |

## Steps (tick as done)
- [x] 0. Clone, read memory, P1 designs, STATUS, KNOWN-ISSUES. Picked S2d-2.
- [x] 1. Branch cut, previous checkpoint archived.
- [x] 2. Server: `HINT_KINDS` + `validateKindHint` (movementLogic), `kindHint` in `validateDeltaRequest` and `applyDelta`; refused (`kind-hint-not-supported`) by recordMutation, recordMutationsBatch and recordOperation; handler passes it through. Commit `2fab951`.
- [x] 3. Client: `StockMovements.validateKindHint` + `canCoalesce` (equal hint), `Gateway.recordDelta(..., movements, kindHint)`, `OutboxStore.enqueueDelta` stores it, `InventoryStore.deductStock` clamp mode sends the kind as a hint (`_kindHintFor`), `DataModel.completeImportedOrder` passes `"sale"`, `FailureCause` classes the three new codes. Same commit.
- [x] 4. Node tests: `functions/test/kindHint.test.js` (20), `kindHintClient.test.js` (16). 21 of 21 hand mutants killed. Functions suite 1999/1999, `.github` suite 1061/1061. Same commit. PUSHED.
- [x] 5. QML twins (CI only, written, not run): `tst_StockMovements`, `tst_OutboxStore_movements`, `tst_InventoryStore_movementKinds` (old clamp-mode case flipped), `tst_Gateway_movements`, `tst_FailureCause`.
- [x] 6. Design doc + test plan + test-plans README row.
- [x] 7. CA questions document (`docs/superpowers/CA-QUESTIONS.md`, 17 questions, 4 blocking, none answered by a CA).
- [x] 8. Docs (done; index regenerated, `.github` suite 1061/1061, functions suite 1999/1999): KNOWN-ISSUES, ATOMIC-OPERATIONS-STATUS, README, AGENTS, SKILLS 176 + `skills-index.js --write`, then the `.github` suite (Skill 175 rule 7).
- [x] 9. Pushed `3c51b70`, PR #205 opened. CI on 3c51b70: Functions, Rules green; QML 3243 pass, 1 fail (my test used entity `orders`, which Gateway refuses earlier with no detail; fixed to `stock_batch` in the next commit); E2E was still running. Read CI again on the new head before trusting it.

## Deploy order (for Taher)
Functions can deploy FIRST or LAST: an old server ignores the new `kindHint` field (the row stays `adjustment`, today's behaviour); an old client sends none. No rules change.

## NEXT (if this session stops)
Continue at the first unchecked step. Then: Taher reviews CA-QUESTIONS.md and sends it to the CA; S4b-2 (register page) or S2e-2 (pickers) once the CA answers; AP3b and AP4 (atomic-ops queue, independent of P1).
Each commit is independent. Do not force-push.
