# CHECKPOINT — docs/2026-09-02-batch-cleanup-on-delete-design

Session date: 2026-09-02
Branch: `docs/2026-09-02-batch-cleanup-on-delete-design`, off `main` @ `a6228f4`

## Status: Tier C implemented, tests written, about to commit + push

## What's done

1. Archived the stale `CHECKPOINT.md` (inherited from the merged `feature/product-order-
   delete-ui` branch) to
   `docs/superpowers/specs/2026-08-30-product-order-delete-ui-CHECKPOINT.md`.
2. Wrote a design doc, compared 3 tiers on 3 throwaway branches
   (`docs/2026-09-02-batch-cleanup-tier-a-noop`, `-tier-b-centralized-filter`,
   `-tier-c-cascade-delete`) via `superpowers:brainstorming` + `ponytail:ponytail-audit`. Taher
   picked Tier C. All 3 comparison branches deleted (remote + local) per instruction.
3. Updated the spec doc (`docs/superpowers/specs/2026-09-02-cleanup-batches-photo-on-product-
   delete.md`) to record the decision and the two open questions the audit cut outright
   (audit-reason granularity, separate role gate).
4. **Implemented Tier C**:
   - `InventoryStore._activeBatches()` — new shared helper (Tier B's design, layered in as a
     defensive backstop per the spec doc), replacing four duplicated inline
     `if (!getById(...)) continue` guards across `totalValue`/`valueByProduct`/
     `valueBySupplier`/`valueByCategory`/`potentialProfitByDimension`.
   - `SalesPage.qml`'s two duplicate inline walks (Potential-profit block, `_valueMaps`'s
     filtered path) switched to `InventoryStore._activeBatches()` too.
   - `InventoryStore.deleteProduct()` now cascades: removes every batch for the deleted product
     (open and exhausted), each routed through `Gateway.recordMutation("stock_batch", ...,
     "delete", ...)`; calls `StorageService.deleteProductPhoto()`, wrapped in `try/catch`
     deliberately — that call falls through to a native `ImageProcessor` singleton only
     registered by the real app's `main.cpp`, undefined in a headless test environment, same
     failure class as the `logic`/`dispatcher` bug (Skill 58) — guarded against directly this
     time instead of found the hard way.
   - `Main.qml`'s `onDeleteProductClicked` now checks `StockBatchStore.remainingFor(pid)` and
     shows an enhanced confirm message (quantity + currency value) when stock remains.
5. Wrote `tests/tst_InventoryStore_deleteProductCascade.qml` (7 cases) — cascade removes all
   batches (open + exhausted), audit routing verified via a `Gateway.recordMutation` spy (real
   function replaced for the test, restored in `cleanup()` — no real network call), photo-cleanup
   try/catch actually protects the rest of the function, regression check that only the targeted
   product is removed, `_activeBatches()` tested directly.
6. Confirmed by re-reading, not assumed: `tst_InventoryStore_valueOrphanedBatch.qml` and
   `tst_InventoryStore_potentialProfitOrphanedBatch.qml` test the *external* behavior of the five
   refactored functions and weren't modified — their continued passing is the regression check
   for the `_activeBatches()` refactor.
7. Wrote test plan: `docs/superpowers/test-plans/2026-09-02-batch-cleanup-on-delete-test-plan.md`,
   added to the index.
8. Updated `KNOWN-ISSUES.md`: marked the "product delete doesn't clean up stock batches or
   photo" entry RESOLVED with a summary of what shipped; updated the "bigger question" (should
   delete-with-stock even be allowed) from open to answered.
9. All touched files brace-balanced (Python character-walk, no toolchain in this sandbox).

## Remaining

- Commit everything, push.
- CI should confirm the new test file and the two regression files still pass.

## Also done (second pass, same session) — real CI failure, debugged and fixed

First push's CI run failed: QML Tests job, 7/794 failed, all in the new
tst_InventoryStore_deleteProductCascade.qml, all identical error --
`Cannot assign to read-only property "recordMutation"`. Root cause: tried to
spy on Gateway.recordMutation by reassigning it to a mock function
(`Gateway.recordMutation = function(...) {}`) to verify audit routing --
QML `function` members aren't reassignable JS properties like a plain
object's, unlike what worked for other things this session (SignalSpy on a
real signal, or a genuine JS property like Toast.show).

Couldn't fetch raw CI logs directly (blob storage host not in this sandbox's
network allowlist) -- got the failure detail from the PR's own posted test-
summary comment instead (`gh api .../issues/65/comments`), which had the
exact assertion/exception text needed to root-cause it without guessing.

Fixed: removed the monkey-patch and the one test that depended on it.
Confirmed calling the REAL (non-mocked) deleteProduct() -> Gateway.
recordMutation path is safe before relying on it -- tst_DataModel_
deleteGuards.qml already does exactly that for the pre-cascade version of
this function and passes on CI, so the remaining 6 tests call the real
function with confidence rather than another guess. Test plan doc and this
file's own header comment corrected to explain what happened and why,
matching this whole session's established correction convention rather
than silently editing the mistake away.

Re-pushing now.

## Also done (third pass, same session) — on-device review found a real regression + UI fix

Taher tested the PR on-device (confirmed CI/tests fine) and raised three points:

1. Why allow deleting a product after a completed order, and does the batch really get cleaned
   up when only part of it was sold? Investigated precisely: the STOCK BATCH does get correctly
   cascade-deleted regardless of qtyRemaining (verified by re-reading the exact code, not
   assumed). But tracing further surfaced a REAL, separate regression: StockBatchStore.
   restoreFifo/topUpOldest (11 call sites in DataModel.qml, fired whenever a completed order
   gets reopened/reversed/adjusted) synthesize a phantom unitCost:0 batch when no batch exists
   for a productId -- exactly the state deleteProduct()'s own cascade leaves behind on purpose.
   Fixed with two shared wrappers (_restoreFifoSafe, _topUpOldestSafe) checking product
   existence first, routing all 11 call sites through them instead of guarding each
   individually. Test: tests/tst_DataModel_restoreFifoSafeGuards.qml (5 cases, skip-path only).
2. Proposed blocking delete until all transactions are reverted. Reconsidered rather than
   implemented -- doesn't solve the trapped-user problem: no way to revert a purchase at all
   (no such feature), and reverting a sale increases stock, doesn't provide a path to zero.
   Documented the reasoning in KNOWN-ISSUES.md rather than silently declining.
3. permissionErrorDlg (raw unstyled QQC.Dialog, hardcoded color) didn't match the app's theme.
   Replaced with a new actionBlockedDlg instance of the ALREADY-EXISTING AlertDialog component
   (same one stockErrorDlg already used) -- discovered it already existed before building a
   duplicate from scratch. Updated the back-button dialog-priority array and removed the now-
   unused permissionErrorMessage property and QQC import.

All touched files brace-balanced. Docs updated: KNOWN-ISSUES.md (new regression entry, follow-up
note on the reconsidered blocking proposal), test plan (section 5 added -- briefly lost section 4
in the same edit, caught immediately via a heading grep, restored).

## Also done (fourth pass, same session) — the real root cause, found via exact repro

Taher gave an exact, reproducible on-device scenario: create product (stock 10, supplier S1),
sell 1 via a completed order, delete the product -- product gone, batch stays in Firestore at
qtyRemaining 9, confirmed directly in Firestore console (not just app UI).

Traced end to end rather than guessed:
- deleteProduct()'s cascade sends the LOCALLY-CACHED batch object as the CAS `before` for a
  delete mutation.
- Server-side applyMutation does a real CAS check (_deepEqual(current, before)) -- legitimate,
  not the bug.
- Found the actual bug: StockBatchStore.consumeFifo/restoreFifo/topUpOldest's success handlers
  stamped a fresh client-generated `updatedAt: new Date().toISOString()` onto the local cache
  after every successful Gateway.recordDelta call. Server-side applyDelta never touches
  updatedAt -- only the delta's target field. So local and server permanently diverge on that
  one field the moment any batch is first consumed against.
- This predates Tier C entirely -- consumeFifo/restoreFifo/topUpOldest are pre-existing
  functions. Nothing before the cascade-delete feature ever sent a previously-delta-touched
  batch through a CAS-protected write, so the drift never surfaced.
- The delete gets silently rejected as a 409 conflict (conflicts never retried);
  StockBatchStore._onMutationConflicted DOES exist and DOES fire, quietly restoring the batch
  to the local array with the server's real (still-existing) document -- no toast by design,
  invisible unless you check Firestore directly, exactly what happened.

Fixed: removed the synthetic updatedAt bump from all three success handlers (3 occurrences,
same pattern each time). Object.assign's base object already preserves the field correctly once
the override is gone.

Not independently unit tested -- verifying needs a real Gateway.recordDelta network round-trip
to fire the success callback, same untestable territory as every other Gateway-adjacent test
this session. Verified by exact code trace (client success handler vs server applyDelta, side
by side, confirming exactly which fields each one touches). Documented in KNOWN-ISSUES.md and
SKILLS.md Skill 60 (new). On-device re-test of the exact repro is the real verification --
recommended before considering this closed, not claimed as proven here.

## Also done (fifth pass, same session) — reviewed and completed already-started uncommitted work

Found 52 lines of uncommitted, purely-additive changes across 8 files already in the working
tree at the start of this pass -- an earlier continuation of this same task that got cut off
before committing or explaining. Reviewed every diff carefully as if reviewing someone else's
PR (git diff per file, checked function signatures/API surface referenced actually exist,
verified no Felgo/native risk, confirmed no deletions anywhere) rather than trusting it blindly.
Found it correct, complete, and well-tested -- matching what I would have designed myself for
both of Taher's reports:

1. Reversal/reopen silently skipping stock restoration for a deleted product (Skill 60's guards
   doing their job correctly, but invisibly) -- fixed with a new Logic.stockRestorationSkipped
   signal, wired to a Toast in Main.qml. Test file extended with 2 new cases using SignalSpy on
   the real signal (not a repeat of the earlier Gateway.recordMutation monkey-patch mistake).
2. Activity feed never showing delete operations at all -- ActivityLog.record(...) added to
   deleteProduct/deleteOrder/deleteStaff, matching icon/gradient entries added to
   ActivityPage.qml (reusing the existing "delete" icon name from Constants.colorIconSet).
   New test file, 4 cases, cleanly and fully testable since ActivityLog.record's local update
   is synchronous.

All 9 touched/new files brace-balanced. Docs (KNOWN-ISSUES.md, this checkpoint) were the
missing piece -- writing those now, then committing and pushing everything together.

## Also done (sixth pass, same session) — a real CI failure from the previous push, fixed

The stock-restoration-visibility push (previous pass) already made it to the remote and CI ran
-- QML Tests failed. `tst_OrderMetadataEditPreservesConsumption.qml` (and 3 other pre-existing
test files) instantiate `DataModel { id: dm }` with no `dispatcher` set. QML's Connections
defaults `target` to its parent when unset, so `dispatcher` there silently resolves to the
DataModel instance itself -- which has no `stockRestorationSkipped` function -- and the bare
`dispatcher.stockRestorationSkipped(...)` call threw. Real production code unaffected (Main.qml
always wires a real Logic instance). Fixed with a `typeof` guard in both wrapper functions
rather than touching any of the 4 unrelated test files. Regression test added reproducing the
exact no-dispatcher setup. Also had to rebase again -- main moved 3 commits, real overlap in
SKILLS.md (both branches independently used "Skill 60" for different content -- kept both,
renumbered mine to Skill 65) and KNOWN-ISSUES.md (auto-merged clean). DataModel.qml overlap was
in a different function (_tryCompleteOrder, unrelated). Verified: 65 total skills, no
duplicates, no leftover conflict markers.
