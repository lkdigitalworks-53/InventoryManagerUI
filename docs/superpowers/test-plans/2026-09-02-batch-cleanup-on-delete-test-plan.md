# Test plan — clean up stock batches and photo on product delete (Tier C)

**Covers:** `InventoryStore.deleteProduct()` cascading to remove every batch for the deleted
product (audit-preserved) and cleaning up the product photo; `InventoryStore._activeBatches()`,
the shared filter that replaces four duplicated inline guards; `Main.qml`'s enhanced delete
confirm-dialog copy when stock remains. Full design:
`docs/superpowers/specs/2026-09-02-cleanup-batches-photo-on-product-delete.md`.

## 1. Unit tests

### 1.1 Written this pass (`tests/tst_InventoryStore_deleteProductCascade.qml`, 6 cases)

**Corrected 2026-09-14 after a real CI failure**, not written correctly the first time: the
original version tried to verify audit routing by reassigning `Gateway.recordMutation` to a spy
function. That throws `Cannot assign to read-only property "recordMutation"` — a QML `function`
member isn't a reassignable JS property. All 7 tests in the file failed identically, every one
at that same line in `init()`, before reaching any actual assertion. Fixed by removing the spy
and the one test that depended on it (verifying exactly what `Gateway.recordMutation` was called
with, without a working spy technique, isn't achievable here — same "not independently unit-
tested" territory `tst_Gateway.qml` already documents for Gateway's real network dispatch).
Confirmed safe to call the *real* `Gateway.recordMutation` in the remaining tests rather than
avoiding it entirely: `tst_DataModel_deleteGuards.qml` already exercises the real,
pre-cascade `deleteProduct()` → `Gateway.recordMutation` path and passes on CI.

- Cascade removes every batch for the deleted product — both an open (`qtyRemaining > 0`) and an
  already-exhausted (`qtyRemaining === 0`) batch — while leaving another product's batch alone.
- No batches at all for the product: doesn't throw, product still deletes.
- **Photo-cleanup safety**: `StorageService.deleteProductPhoto` falls through to a native
  `ImageProcessor` singleton only registered by the real app's `main.cpp` — undefined in this
  test environment, same failure class as the `logic`/`dispatcher` bug (Skill 58). Test confirms
  the `try/catch` around that call means `deleteProduct()` still completes (product gone, batches
  gone) despite the photo call throwing.
- Regression: `deleteProduct()` still removes only the targeted product, others untouched.
- `_activeBatches()` directly: excludes an orphaned batch, returns empty array cleanly when
  nothing matches.

### 1.2 Regression coverage from the two earlier bug fixes (unmodified, should still pass)

`tst_InventoryStore_valueOrphanedBatch.qml` (5 cases) and
`tst_InventoryStore_potentialProfitOrphanedBatch.qml` (4 cases) test the *external* behavior of
`totalValue`/`valueByProduct`/`valueBySupplier`/`valueByCategory`/`potentialProfitByDimension` —
all five were refactored this pass to read through the new `_activeBatches()` helper instead of
their own duplicated inline guard. Neither test file needed to change; if the refactor altered
behavior, they'd fail. Deliberately not rewritten to double-check this — their continuing to
pass on CI *is* the regression check.

### 1.3 Not independently tested — same reasoning as before

- **Which entity/action `Gateway.recordMutation` was actually called with for each cascaded
  batch** — not just the network effect. Confirmed no working spy technique exists for a QML
  `function` member (see 1.1's correction note); verifying call arguments would need inspecting
  `OutboxStore`'s internal queue directly, unproven and not attempted.
- The real network effect of the `stock_batch` delete mutations and the product photo delete —
  same untestable-without-mock-HTTP-infrastructure limitation as every other `Gateway`/
  `StorageService` network path in this suite.
- `Main.qml`'s confirm-dialog copy change — Felgo page, can't compile under this CI job (see
  `test/felgo-dependent/README.md`); covered by an on-device check below instead.

## 2. Regression checklist

- [ ] Restock and other existing `InventoryStore`/`StockBatchStore` flows unaffected — nothing
      about receiving stock or FIFO consumption changed this pass.
- [ ] Deleting a product with **zero** stock still shows the plain (non-enhanced) confirm
      message — the enhanced wording only appears when `remainingFor(productId) > 0`.
- [ ] Deleting an order, or any other entity, unaffected — this pass only touched product delete.

## 3. On-device plan

| # | Scenario | Expect |
|---|---|---|
| H1 | Delete a product with open stock in one or more batches. | Confirm dialog shows the enhanced message (quantity + currency-formatted value). Confirming removes the product from Inventory, and its batches no longer appear anywhere in Sales Analysis (Value, Potential profit, or otherwise). |
| H2 | Delete a product with zero remaining stock. | Confirm dialog shows the plain, unenhanged message — no regression from before this change. |
| H3 | Delete a product, then check Firebase Storage / local file for its photo (if one was set). | Photo is removed (or a warning is logged if it wasn't there to begin with) — doesn't block or visibly affect the delete either way. |
| N1 | Delete a product with stock across **multiple** batches from different suppliers. | All of that product's batches are gone, not just the first one found. |
| N2 | Delete a product, then check `audit_log` (or wherever the ledger is inspectable) for the batch entries. | Each cascaded batch has its own `delete` audit entry, distinguishable from the product's own delete entry — the compliance trail survives even though the working docs are gone. |
| E1 | Delete a product whose only batch has `qtyRemaining === 0` (fully sold out, never restocked since). | Still cleaned up — the cascade doesn't skip exhausted batches. |

## 4. Explicitly out of scope for this pass

- Backfill for batches orphaned by deletes that happened *before* this ships — still an open
  question in the spec doc, not decided or acted on here.
- Exact final wording of the confirm-dialog message — implemented with the spec doc's proposed
  copy; revise directly in `Main.qml` if the wording doesn't land well on-device.
