# PR #90 final sweep — review note (2026-10-13)

PR #90 = plan Task 10 of `2026-09-20-atomic-operation-outbox.md`: `DataModel._tryCompleteOrder` sends one atomic `completeOrder` operation. Branch `feat/2026-09-26-complete-order-atomic`, pushed in place (no stacked PR, Taher's call). Method: skills requesting-code-review (SHA-based review, done by hand, no subagent), ponytail-audit (report format), qt-qml-review (Phase 1 linter only). Honest scope at the end.

**What this repo does:** Qt/QML + Firebase inventory app for one small business. Load assumed: a handful of devices, offline-first, one operator at a time.

## Branch health (verified by command)
- Branch was 79 commits behind `main`. `main` merged in (`b95df35`); only AGENTS.md, CHECKPOINT.md, SKILLS.md conflicted (docs). The PR's Skill 74 became Skill 114.
- `DataModel.qml` and `test/e2e/tst_OrdersE2E.qml` auto-merged. Read by hand: PR #121's parked/unsynced guard is intact and runs before `_completingOrderIds` is set.
- CI on `1595d62`: QML 1993, Functions 626, Rules 45, E2E 93, all green (2757/2757).
- `qt_qml_lint.py` on the 5 changed QML files vs `main`: no new real findings (only line-shift duplicates and the file's existing `var`/ordering conventions).

## Findings
### Must fix
1. **Discarding a parked completion re-sent the sale** (`qml/model/DataModel.qml`, `_onCompletionRejected`). **FIXED in this PR.**
   - What this is: a completion shown as done while offline can be parked after the server answers `write-rejected`. S3 lets the user Discard it; `Gateway.discardParked` finishes it with `{ok:false, error:"discarded", discarded:true}` and no `opIndex`.
   - Problem: the handler treated it as a server rejection, reverted, then re-planned clamped and queued the same sale again. The server rejects it again, so Discard never ends.
   - Fix: a `discarded` branch first: undo the shown state, release the guard, no re-plan; a caller still waiting gets `false` + a message (not "out of stock").
   - Tests: `tst_DataModel_completeOrderAtomic.qml` cases 17-19. Lesson: Skill 115.
   - Not verified on a device (no verified recipe to force `write-rejected`).

### Should fix (open, not in this PR)
2. **`recordOperation` deploy is not confirmed anywhere in the docs.** This PR is its first production caller. Before merge: `firebase deploy --only functions:recordOperation`, then `curl -i -X POST <url>` must return 401 `missing-token`. If it is missing, every completion retries and ends up stuck.
3. **Task 11 ("Saved, syncing") is not built.** An offline completion looks finished with no hint; only the header "not syncing" line appears once it is stuck. The test plan used to promise the hint; corrected.
4. **Other multi-write paths are still the old non-atomic chains:** `_tryAdjustOrder` (C-1, 11 old-primitive calls), `completeImportedOrder` (4), `_reverseCompletedOrder` (3), `_reconcileBatchesForStockEdit`, `RestockDialog` restock. Ledger kinds `created`, `purchase`, `photo_change`, `sale`, `return`, `price_adjust` still use separate writes.
5. **Server-side role gate for `recordOperation` not checked** (it derives the tenant role but this sweep did not trace whether it is enforced per op). Recorded as unchecked, not as a bug.

### Nice to have
6. Doc drift fixed here: README cited "Skill 72" for the harness note (now 114), and AGENTS/README cited "Skill 74" for the HTTP-status rule (it is Skill 84). `ASYNC-REENTRANCY-BUGS.md` C-3 and the E2E roadmap entry now state the real status (implemented, not merged).

## Roadmap status (from the roadmap docs, not re-derived in code)
**Delete roadmap:** done: stuck-write handling C, S1, S2a, S2b, S3; staff delete UI; sales-analysis labels; product-delete batch cascade BC1/BC2; photos PH3, PH3b (deployed, DV-1..9 reported done), PH4, PH5. Open: S4 cleanup docs; device re-check of O1 and O2; `ConfirmReturnSheet` lock gap; `StockBatchStore` FIFO on whole-record `recordMutation`.
**Atomic operations (E2E roadmap C-3):** Tasks 1-9 on `main`; Task 10 = this PR; Task 11 not built; Task 12 partly done (tracker, roadmap, skill, test plan updated now; coverage sweep not done); Task 13 (deploy, device) is Taher's. Then C-1 as second consumer, then the paths in finding 4.

## Decisions for Taher
- **D-1 Discard meaning** (chosen: revert). Alternative: resend. Trade-off: resend honours "the sale already happened" (D3) but contradicts the button and loops against a server that keeps rejecting; revert is predictable, but if the goods really were sold, the operator must re-approve the order.
- **D-2 Merge order:** deploy `recordOperation`, merge #90, then device-test, vs build Task 11 first. Merging first is faster but ships a silent "syncing" state; Task 11 first delays the fix for the original double-consume bug.

## Decisions taken (Taher, 2026-10-13)
- **D-1:** Discard of a parked completion = revert to `pending` (as built). Follow-up for a NEXT session: show the cause of the error in the UI (the stuck-writes sheet / completion failure message), not only a generic message.
- **D-2:** merge PR #90 first; Task 11 (syncing hint) and the error-cause UI come after.
- **Deploy:** Taher deploys `recordOperation` himself before merging.

## Not checked
Real `qmltestrunner` (CI only); Phase 2 of qt-qml-review (six agents) not run; no reviewer subagent; no device run; `functions/lib/operationLogic.js` and `CompletionPlan.js` not re-reviewed (Tasks 1-5, already merged); server role gating (finding 5).
