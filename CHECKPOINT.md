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
