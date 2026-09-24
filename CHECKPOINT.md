# CHECKPOINT — 2026-09-24: compliance reassessment, P1 design (server-side atomic) + S1 plan (docs only, no repo code)

**Branch:** `docs/2026-09-24-compliance-reassessment`, cut from `main` @ `2c1e5f6`
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-21-staff-delete-ui-CHECKPOINT.md` (PR #80, merged;
staff delete UI DONE). That file's own predecessor, `2026-09-21-atomic-operation-outbox-phase2-CHECKPOINT.md`, was archived
earlier from a parallel branch and is unrelated to P1 (C-3 arc; its step 13 is still open: Phase 3 not started).
**Skills invoked by Taher:** `superpowers:brainstorming`, `qt-development-skills:qt-qml`, `ponytail:ponytail`. Also used: `superpowers:writing-plans`. Caveman FULL.
**Commit identity:** `Taher (via Claude session) <tsowner@lkdigitalworks.com>`. PAT comes from chat, never stored in repo/config/memory.
**Constraints this session:** no app build/run; no Qt in sandbox (CI is the QML test oracle); short scope per session
(multi-account, token-limited); push without asking, review happens in the GitHub PR.

## Compliance status vs master spec (`specs/2026-06-06-india-compliance-roadmap-design.md`)

Grep-based on `main` @ `2c1e5f6` plus the P1 branch's own checkpoint.

| Item | Status |
|---|---|
| P0 gateway + immutable `audit_log` | Done. `Gateway.mode = "gateway"` live since 2026-07-29. |
| C-3 atomic `recordOperation` (order completion) | Phase 1 (endpoint, #78) + Phase 2 (pure helpers, #79) merged. **Phase 3 (Outbox/Gateway/stores/DataModel/UI, plan Tasks 6-11) not started.** Needs Taher to deploy `recordOperation` to dev. |
| P1 stock-movement taxonomy | **Partial, unmerged, untested, stale.** Branch `feature/p1-stock-movement-taxonomy`: 10-value kind enum, write-only `StockMovementStore`, 5 wiring points, required kind picker. Zero tests. Register report (opening/closing balance) not started. |
| P2 tax identity (HSN, GSTIN) | Not started. No `hsnCode`/`gstin` anywhere in `qml/` or `functions/`. |
| P3 legal docs + acceptance, P4 DPDP consent, P5 erasure/retention, P6 breach, P7 warehouse | Not started (no consent/erasure/breach code; only an OAuth "consent" string in `GoogleAuthService.qml`). |
| Deferred (56(12), 56(15), OIDAR) | Out of scope per spec. |

## P1 branch verdict: NOT usable as-is, do not rebase-and-continue

- 337 commits behind `main`; merge-base `2748d1b` (2026-07-13). Predicted textual conflicts: `Main.qml`, `Logic.qml`,
  `DataModel.qml`, `InventoryStore.qml`, `qmldir`, `EditProductDialog.qml`.
- Trial rebase (scratch branch, aborted, remote untouched) stopped at commit 4 of 10, `94c6e51` (restock wiring). The conflict is
  semantic, not just textual: `restock()` on main is async + callback-based, uses `Gateway.recordDelta`, and
  `StockBatchStore.addBatch` no longer returns a batch synchronously (async batch-id minting), so the branch's
  `batch.batchId` and `Gateway.recordMutation` wiring is wrong for main even if hunks are merged by hand.
- Order completion (`_tryCompleteOrder`) was reworked on main (atomic completion, `recordOperation`) and Phase 3 will rewrite it again.
  The branch's `sale` wiring is throwaway.
- Reusable from the branch: `kind` enum + `sales_return`/`destroyed` reasoning (CGST 56(2)), `StockMovementStore` shape, kind-picker UX
  in `EditProductDialog`, master test plan `specs/2026-07-11-p0-p1-master-test-plan.md`. Re-apply by hand on fresh `main`; leave old branch untouched.

## Step log (append-only; resume from the last ticked step)

- [x] 1. Cloned repo, read spec, status, P1 checkpoint, C-3 checkpoint. Read skills: brainstorming, qt-qml, ponytail.
- [x] 2. Trial rebase of P1 onto `main`: fails semantically at commit 4/10 (above). Aborted. Old remote branch untouched.
- [x] 3. Wrote this reassessment (docs only: no test plan needed, no code changed).
- [x] 4. Taher chose **B** (server-side atomic) and asked to finish the docs, merge them, and implement in a new session on a new branch.
- [x] 5. Wrote spec (D1-D10, slices S1-S4, open questions Q1-Q4, risks R1-R3), S1 plan (5 tasks, code embedded), test plan (standard format, index row).
      Decisions D2-D10 were taken by me and are written for review; **merging this PR = approving them**. Everything in the plan was run in a scratch
      copy of `functions/` from `main` and replayed step by step: 281/281 (232 existing + 49 new), new `lib/` files 100% line, 10/10 mutations caught.
- [x] 6. AGENTS.md (P1 bullet + scope line) and README.md (one update paragraph) refreshed. `SKILLS.md` untouched (append-only; no new numbered lesson yet).
- [x] 7. PR #85 merged into `main` (6da373d), CI green.
- [ ] 8. (superseded by 9-12 until open questions close) **Implementation session (new branch off `main`):** implement S1 by following `plans/2026-09-24-p1-server-side-stock-movements-s1.md` task by task
      (`cd functions && npm ci` first). Then Taher deploys functions to dev and runs the on-device checklist. S2 planning only after that.

## Next-session start-up

Read this file, the spec section 3 and the plan header. Do not rebase or force-push `feature/p1-stock-movement-taxonomy`. Nothing to grill Taher on
before S1 except the review of D2-D10; open questions Q1-Q4 belong to S2-S4.

## Q1 options (decided: B)

- **A. Client-side second write** (old branch's way): `StockMovementStore.recordMovement` after each stock change.
  Cheap, QML-only. But not atomic with the stock change: crash/offline/kill between the two writes leaves stock changed with no ledger row,
  which is the exact failure an auditor tests. Needs idempotent ids too. Contradicts spec 2 ("working-tier doc AND ledger entry in one transaction").
- **B. Server-side atomic**: `recordDelta` (and `recordOperation` ops) accept an optional `movement {kind, reason, valueAtCost, batchRef}`;
  the function creates the `stock_movements` row in the same transaction, deterministic id from `requestId`, `kind` validated against the enum,
  `actorUid`/`serverTimestamp` server-stamped. Fully testable with `node --test` in this sandbox (100% coverage feasible). Costs: functions change + Taher deploys (D4).
- **C. Hybrid**: B for `sale` (inside `completeOrder`, after C-3 Phase 3), A for the rest. Two mechanisms to maintain; A's gap stays.

Proposed slices if B: S1 server support + tests; S2 client wiring for restock / manual adjust / returns; S3 `sale` via `completeOrder` (after C-3 Phase 3);
S4 opening/closing register report.

## Resume instructions

Fresh session: clone, read this file, then follow step 8. Do not force-push or rebase `feature/p1-stock-movement-taxonomy`. No build/run.

## Session 2 (2026-09-24, same day): open-questions discussion + ponytail audit

Skills: `superpowers:brainstorming`, `ponytail:ponytail-audit`, `qt-development-skills:qt-qml`. No code changes; docs only.

- [x] 9. Ponytail audit, SAMPLED not exhaustive (qml 28.9k lines, functions/lib 1.8k, docs 45k lines; only probes below were run). Ranked:
  1. `delete:` `Gateway.mode = "direct"` + `_writeDirect` / direct batch paths (`qml/model/Gateway.qml` ~153, 291, 309). Gateway live since 2026-07-29. A flag flip skips `audit_log` AND would skip movements.
  2. `delete:` `runCutover` (`functions/index.js` ~709) + `functions/lib/cutoverLogic.js` (85) + its test (140), if P0 cutover is finished for every tenant. Needs Taher to confirm.
  3. `shrink:` six endpoints in `functions/index.js` (928 lines) repeat method/auth/tenant preamble; a `withAuth(handler)` wrapper would cut ~100+ lines. Medium risk (handler harness coupling).
  4. `yagni:` token cost: `SKILLS.md` 3333 lines, `AGENTS.md` 883, `README.md` 774, 79 specs + 30 plans; done specs/plans could move to `docs/archive/`. Not touched (Taher's process).
  5. Low: `MAX_OPS` mirrored in 3 files by comment only; S3 will add a 4th mirror for the movements cap.
- [x] 10. **Blocker found (Q0):** the movement ledger is only complete if every stock change goes through `recordDelta`/`recordOperation`. It does not today:
  `InventoryStore.qml` sends `stock` inside whole-record `recordMutation` on create (~520), `updateProduct` (~623), bulk import (~908), edit (~1283); and
  `firestore.rules` still lets any member write `inventory` directly (generic working-tier fallback; only ledger collections are locked, the comment in the rules file is stale).
  So S1 alone gives rows for restock/sale/return deltas but leaves create/edit/import/direct writes with no row.
- [x] 11. (superseded by 13) Q0 asked with options A/B/C.
- [x] 11b. Q0 answered (see 15). (options in chat: C staged = server rejects stock changes on `recordMutation` for `inventory` after S2 + lock `inventory` in rules + variance tripwire in S4).
- [ ] 12. Then Q1-Q4 (spec section 7) one at a time; then update spec/plan, PR, merge; then implement S1 in a new branch.
- [x] 13. **New fact from Taher: everything is DEV only, no prod code published; tests = new tenant + user + new products/orders.** Consequences:
  earlier "production" framing was wrong (D10 backward compat, "would break prod", "live since 07-29" as prod); no backfill or migration needed;
  Q2 (opening balance) collapses (new tenants start at 0, opening = sum of movements before the period); staged option C is no longer needed for safety.
  Deleting `direct` mode and `runCutover` is cheap now.
- [x] 14. New option D for Q0: server derives a movement for ANY stock change on `inventory` in all four write paths (`recordDelta`, `recordMutation`,
  `recordMutationsBatch`, `recordOperation`): client may supply `movements` (kind picker), else the server derives a default (create => `receipt`,
  whole-record edit / delete => `adjustment`, `completeOrder` => `sale`). No client path can forget a row. Waiting on Taher's pick (see chat list P1-P8).
- [x] 15. **Taher's decisions:** P1 = D (server derives movements on every inventory write path) and split S1a/S1b; P2 keep `valueAtCost`, cut `batchRef`; P3 no role gating;
  P4 no `opening_balance` kind (initial stock/import = `receipt`); P5 clamp solved by derived rows; P6 index in S4; P7 keep ops movements in S1a; P8 delete `direct` mode + `runCutover` (in S2).
- [x] 16. Planning completed and verified in a scratch copy of `functions/` (main @ `6da373d`), replayed step by step: S1a 291/291 (232 existing, 3 re-expected on purpose, + 59 new);
  S1a+S1b 313/313 (+22 new); new/changed lib files 100% line; 12 deliberate mutations caught; the replay caught one real bug (batch derive read the doc after writing it in the fake; fixed to use `item.before`).
  NOT verified: QML/e2e edits in S1b Task 5 (CI only).
- [x] 17. Docs rewritten: spec rev 2 (D1-D13), `plans/...-s1a.md` (renamed from `...-s1.md`), `plans/...-s1b.md`, test plan (S1a+S1b), README index row, AGENTS.md P1 bullet, README paragraph.
- [ ] 18. PR for `docs/2026-09-24-p1-open-questions`: CI green, merge (Taher: "complete the planning").
- [ ] 19. **Next session: implement S1a** on a new branch off `main` by following `plans/2026-09-24-p1-server-side-stock-movements-s1a.md` task by task (`cd functions && npm ci`; run tests with `node --test`).
  Then Taher deploys functions to dev and runs the S1a on-device checklist. Then S1b (its own session). S2 planning only after S1b's checklist passes.

## Resume instructions (rev 2)

Read this file, then spec sections 3-4 and the S1a plan header. Do not rebase or force-push `feature/p1-stock-movement-taxonomy`. Nothing left to grill Taher on before S1a. No build/run.
