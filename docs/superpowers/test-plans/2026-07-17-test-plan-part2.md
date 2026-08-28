# Test plan (part 2) — fix/order-import-stock-and-holistic-bugs

**Covers:** everything committed on this branch after the 2026-07-14 test plan
(`docs/superpowers/test-plans/2026-07-14-test-plan.md`) was written. Three phases:

- **Phase A — the 3 Critical fixes + 2 follow-ons** (commits `5549541`, `f3eaa4c`, `b03a74f`,
  `c40f595`, `fae5613`, `948bb0f`): cross-order stock oversell in import batches, `AddStaffDialog`'s
  missing double-submit guard, a dropped null-safety guard in the productId-only refactor, a typed
  id on a new import row colliding with a renamed row's minted id, and the import writes that were
  firing one-at-a-time instead of batched (the actual cause of the 300+-row import hang).
- **Phase B — 5 bugs from Taher's own on-device testing** (commits `b6a35af` through `9b4ff26`):
  order-overwrite silently skipping non-completed orders and never updating contact/date fields;
  the order-import stock check not knowing which conflict policy would be chosen; `_tryAdjustOrder`
  having no stock-sufficiency check at all; the stock-check warning text not being specific; and —
  the latest refinement — a brand-new order line that can't fit total stock getting imported as
  **pending** instead of being dropped or silently oversold.
- **Phase C — 10 items clearing the rest of the original rescue review's backlog** (commits
  `df8f188` through `5b571d9`): supplier-creation failures now surfaced instead of silent, mint
  retries no longer wasted on non-retryable auth failures, jittered backoff added, three RBAC
  gates added/verified (revert a completed order, delete a completed order, a defensive check in
  `RestockDialog`), supplier rename uniqueness, the import audit-trail reason text no longer
  overclaiming a conflict, and `ActivityLog`'s Firestore collection actually getting pruned instead
  of just the local cache.

**Read this first, same caveat as before:** everything in Phase A/B/C was verified by Node
extraction (pure-JS logic tested directly, or QML orchestration logic extracted and tested against
a mocked `Gateway`/`FirebaseService`) and static tracing — **none of it has touched a real device, a
real build, or a real Firestore backend.** Section 3 below is where that gap closes. A few items
(marked below) are genuinely difficult to exercise without specific test data or timing — noted
honestly rather than glossed over.

---

## 1. Unit tests

### 1.1 Already covered (automated, in `tests/tst_ImportMath.qml`)
The committed suite grew from 39 to 48 test functions this session, covering the two purely
functional pieces added:

- `checkOrderLineStockAcrossBatch` (9 cases) — new-line fits both full and remaining stock;
  fits full stock but not what's left after earlier rows in the same batch (`crossOrder: true`,
  the actual cross-order-oversell fix); doesn't fit even at full stock; existing-line increase
  fits (net-new is the delta, not the full quantity); existing-line increase clamped by what's
  left (also `crossOrder: true`); existing-line increase that doesn't fit even at full stock;
  existing-line decrease frees up the pool (negative net-new); existing-line unchanged is a
  no-op; non-completing rows never decrement the running tally.
- `findOrderLineByProductId` — one new case: a falsy/empty `pid` never spuriously matches a line
  that's also missing `productId` (the hardening fix, alongside the two real fixes in
  `DataModel._findLine`/`OrderDetailDialog._findOriginalLine`, which live in QML files and can't
  be added to this suite the same way — see 1.2).

Run: `qmltestrunner -input tests/tst_ImportMath.qml`.

### 1.2 Gap — verified only by Node extraction in this sandbox, not by any committed test
Everything below lives inline in a QML singleton or dialog, not a `.pragma library` helper, so it
can't be added to `tst_ImportMath.qml` the way the pieces above were. Each was Node-extracted and
RED→GREEN tested against a faithful copy of the real logic during development, but that's not the
same as `qmltestrunner` coverage. Recommend closing this gap with proper QML tests at some point,
not urgent enough to block this branch on its own:

- `DataModel._findLine` / `OrderDetailDialog._findOriginalLine` / `NewOrderDialog._inCartQty`'s
  restored falsy-productId guards.
- `_tryAdjustOrder`'s new pre-flight stock-sufficiency check (the added-units-vs-current-stock
  loop before any side effect runs).
- `OrdersStore.upsertMany`'s restructured overwrite branch (envelope-fields-always,
  products-only-if-completed).
- `_validateOrderRows`'s policy-aware stock check and the `forcePending` group-level tracking.
- `InventoryStore`/`OrdersStore.upsertMany`'s pre-scan fix (never trust a typed id on a
  non-matching row).
- `FirebaseService.mintCounterValue`/`mintCounterBatch`'s 401/403 non-retry logic and the
  backoff/jitter delay calculation (the delay math itself, `_computeRetryDelayMs`, is pure and was
  Node-verified deterministically; the actual `Timer`-based delay execution is real QtQuick and
  genuinely can't be Node-tested at all).
- `TransactionStore`/`StockBatchStore`/`SupplierStore`'s `deferWrite` parameter and `*Many()`
  batch-write companions.
- `ActivityLog`'s `_pruneOldEntries`/`_pruneFromCursor` two-stage query-then-delete logic.
- `SupplierStore.updateSupplier`'s rename-collision check.
- `_resolveSupplierId`'s distinct failure signal.

---

## 2. Regression tests

Nothing in this list should have changed behavior, **except where explicitly marked** — three
things in Phase C deliberately do change existing behavior, listed here so they're not mistaken
for accidental regressions during testing.

- [ ] Manually creating an order (`NewOrderDialog`) still computes totals identically — untouched
      by everything in this phase.
- [ ] **Changed on purpose:** reverting a completed order back to non-completed
      (`OrderDetailDialog`'s edit flow, status dropdown) now requires owner/admin/manager — a
      lower-role user attempting this should be blocked with a clear message, not silently allowed
      as before. See N10.
- [ ] **Changed on purpose:** deleting a completed order (`OrdersPage`'s delete button) is now
      rejected outright — previously this deleted the order with no reversal of its stock/FIFO/
      sale-event impact. See N11.
- [ ] **Changed on purpose:** renaming a supplier to a name that collides (case-insensitively)
      with a different existing supplier is now rejected — previously silently allowed. See N12.
- [ ] Updating a product (`onUpdateProduct`) still works — untouched.
- [ ] Adjusting/reverting a completed order for a **valid** quantity change (return, exchange,
      price correction where nothing exceeds stock) still works exactly as before — only the
      *rejection* path for an added quantity that doesn't fit is new; everything that fits should
      behave identically to pre-this-session.
- [ ] Category/order-channel management, product/staff/supplier/order list and detail views,
      export (products/orders to XLSX), Dashboard KPIs — all untouched by this phase.
- [ ] Add Staff, Add Order, Add Supplier (inline, from Add Product/Restock) — untouched by Phase
      A/B/C except AddStaffDialog's busy-guard (Phase A) and the RestockDialog defensive role
      check (Phase C, which only adds a check for a role that already couldn't reach the button).

---

## 3. On-device tests

### 3.1 Happy path

| # | Flow | Steps | Expect |
|---|---|---|---|
| H19 | Cross-order oversell prevention | Import one file containing 3 separate completed orders, each with a line for the **same** product, each requesting 5 units, where that product has exactly 10 in stock | First two orders' worth (10 units total) accepted normally; the third shows a warning specifically naming how many are left "after earlier rows in this import" (not a generic insufficient-stock message) |
| H20 | Typed id on a new row alongside a renamed row | Import a file with 2 rows: row 1 is a genuinely new product with a manually-typed id that matches nothing existing (e.g. guessing "last id + 1"); row 2 has an existing product's id, conflict policy set to rename | Both rows get **different** ids — row 1 keeps behaving as a new product with a freshly minted id (its typed value is not trusted), row 2 gets its own fresh renamed id. Confirm via product detail that neither's data was lost or overwritten by the other |
| H21 | Large product import completes without hanging | Import 300+ new products into an account with existing products, several rows sharing a handful of new supplier names, most rows with stock > 0 | Import completes in a reasonable time (a handful of network round trips, not hundreds); exactly one new record per distinct new supplier name; no hang requiring a force-close |
| H22 | Order-overwrite updates contact fields on a non-completed order | Import a file overwriting an existing **pending or processing** order's customer name, email, phone, date, and notes | All of those fields update on the order — previously this silently did nothing at all for a non-completed order |
| H23 | Order-overwrite updates contact fields on a completed order too | Same as H22 but the existing order is **completed** | Contact/date/notes fields update; the order's products/stock impact is unaffected unless the imported row's products actually differ (handled by the existing adjust path, unchanged) |
| H24 | Order-overwrite, insufficient increase | Import overwriting an existing completed order, increasing one line's quantity by more than the product's current stock can cover | Warning shows the exact shortfall number and says the increase "will not be imported since this order is completed"; the order's actual quantity for that line stays at whatever it already was — confirm via order detail it didn't silently apply a wrong number |
| H25 | Rename policy, insufficient stock — imports as pending | Import a row whose id conflicts with an existing order, choose rename, with a quantity that doesn't fit the product's total available stock | The new (renamed) order **is created**, with the full requested quantity on its line — **not dropped**. Its status is **pending**, regardless of what the file's Status column said. Warning explains this. Confirm the product's stock was **not** deducted for this order |
| H26 | Interactive order adjustment still works for valid changes | `OrderDetailDialog` → adjust a completed order → increase one line's quantity by an amount that **does** fit current stock | Succeeds exactly as before — this branch only added a rejection path for the case that *doesn't* fit, nothing about the working case should have changed |
| H27 | Revert a completed order as an elevated role | As owner, admin, or manager: `OrderDetailDialog` → change a completed order's status back to pending | Succeeds exactly as before — confirm the elevated-role path still works, not just that the blocked path blocks |
| H28 | Delete a non-completed order | `OrdersPage` → delete a pending or processing order | Still deletes normally — only completed orders are newly rejected |
| H29 | Rename a supplier to a genuinely new name | `EditProductDialog`'s inline supplier rename → type a name that doesn't exist yet → Save | Renames successfully, picker refreshes with the new name |
| H30 | Restock with a supplier that fails to attribute | Hard to force deliberately — if a supplier-creation failure can be simulated (e.g. toggling airplane mode at the exact moment of an inline new-supplier creation during Restock), confirm the restock itself still completes (stock updates), with a toast noting the supplier specifically couldn't be recorded |

### 3.2 Negative tests

| # | Scenario | Expect |
|---|---|---|
| N10 | Attempt to revert a completed order to pending/processing as a non-owner/admin/manager role | Blocked with "You do not have permission to reopen a completed order" — order's status unchanged |
| N11 | Attempt to delete a completed order (any role) | Blocked with "Completed orders can't be deleted directly — reopen it to pending first, then delete" — order still exists afterward |
| N12 | Rename a supplier to a name that already belongs to a different supplier, including a case/whitespace-only variant (e.g. "ACME CO" vs "Acme Co") | Rejected with "A supplier named X already exists" — the supplier's original name is unchanged, nothing else about it was modified either |
| N13 | Order import, overwrite policy, increase exceeds available stock (see H24) | Warning is specific (shortfall number + "will not be imported"), not the old generic "quantity kept unchanged" |
| N14 | Order import, rename policy, brand-new line exceeds total stock (see H25) | Order is created as pending, not dropped, not silently completed oversold |
| N15 | Interactive order adjustment where an increase doesn't fit stock (exchange or plain quantity increase) | The **whole** adjustment is rejected up front — confirm nothing partially applied (not just the over-quantity line; if the adjustment also includes an unrelated valid return on a different line, confirm that return did **not** apply either, since this is reject-the-whole-thing, not reject-one-line) |
| N16 | Add Product where a brand-new supplier name is being typed AND network drops exactly during that supplier's creation (not the product's own write) | Product is **not** created at all (this specific path aborts cleanly); no product with a missing/empty supplier silently appears |

### 3.3 Edge cases

| # | Scenario | Expect |
|---|---|---|
| E10 | **The cross-order oversell repro, exact numbers.** Product with exactly 10 in stock. One import file, 3 separate completed orders, each with a 5-unit line for that product. | Total accepted across the batch is bounded to 10, not 15 — this is the single most important new test in Phase A, confirm it precisely rather than approximately |
| E11 | **The id-collision repro, exact numbers.** 6 existing products (PRD-001..006). Import 2 rows: row 1 = new product, id column manually typed as "PRD-007"; row 2 = existing PRD-005, policy = rename ("add as new"). | Row 1 and row 2 end up with **different** ids — neither silently overwrites the other after restart. Restart the app and confirm both products actually exist with correct, distinct data |
| E12 | **The pending-downgrade repro, exact numbers.** Existing completed order already has 5 of a product booked; product's current stock is 3; import the same order+product with quantity 9, policy = rename. | New order created with quantity 9 on that line (not dropped, not clamped); its status is pending; the product's stock is still 3 afterward (untouched) |
| E13 | **300+ product import, force-closed mid-import.** Fresh account, import 300+ new products, force-close the app partway through (or as soon as the button is tapped, to maximize the chance of catching it mid-flight), reopen. | This is **not** fully closed by this session's work — the underlying counter/write non-atomicity is a known, still-open gap (see checkpoint's "next scopes"). Batching reduced the exposure window from ~600 individual network calls to ~5-6, but a kill during that narrower window can still leave the counter advanced with fewer (or zero) actual products created. Document what you observe — this is expected-imperfect, not a regression, but worth confirming the window is meaningfully narrower than before (e.g. products actually created up to the point of closing, rather than none at all) |
| E14 | Legacy order data without `productId` on any line (requires seeded test data — not producible through normal current-app usage, since every current creation path always sets `productId`) | If such data can be seeded: adjusting/reverting that order correctly does **not** misattribute FIFO/tax data to the wrong line. If seeding isn't feasible, mark this untestable-as-is and rely on the Node verification already done |
| E15 | Simulated auth-token expiry during Add Product / Restock / Import (requires a way to force token expiry — may not be practically achievable on-device) | The operation fails fast (not after 8 retries) — if this can't be forced, mark untestable on-device and rely on the Node-verified retry-decision logic |
| E16 | ActivityLog collection size after extended normal use | Hard to verify without direct Firestore console access — if available, confirm the `activity_log` collection in Firestore actually stays near 50 documents after many operations, not growing unbounded. If console access isn't available to the tester, this is effectively untestable on-device and relies on the Node-verified query/delete logic |

### 3.4 Monkey testing
- Everything from the original plan's monkey-testing section still applies.
- Additionally: rapidly toggle between "overwrite" and "rename" on the same conflicting row in an
  import preview several times before applying — confirm the stock-check warning updates each
  time to match the currently-selected policy (this is the re-validation-on-policy-change piece,
  the one part of Phase B with no automated coverage at all, pure UI-interaction behavior).

---

## 4. Suggested order of attack
1. **E10, E11, E12** — the three exact-numbers repros from Taher's own bug reports. These matter
   most because they're not hypothetical; they're what was actually observed on-device.
2. **H19–H29** happy paths for everything in Phase A/B/C.
3. **N10–N16** negative paths, especially N15 (the whole-adjustment-rejected-not-partial check).
4. **E13** (the 300+ import force-close) — document the outcome even though it's known-imperfect;
   useful evidence either way for deciding whether to pursue full atomicity later.
5. Regression checklist (Section 2), paying particular attention to the three items marked
   "changed on purpose" so they aren't mistaken for bugs.
6. E14–E16 — attempt if feasible, mark untestable-on-device if not, don't block sign-off on them.
7. Monkey testing last.

## 5. Sign-off checklist
- [ ] `tst_ImportMath.qml`'s 48 cases passing in the actual build (Section 1.1)
- [ ] E10 (cross-order oversell) explicitly confirmed with the exact numbers above
- [ ] E11 (id-collision) explicitly confirmed — restart the app and verify both products persist
      correctly, not just that the preview looked right
- [ ] E12 (pending-downgrade) explicitly confirmed — check the order's actual status and the
      product's actual stock afterward, not just the warning text
- [ ] H19–H29 happy paths pass
- [ ] N10–N16 negative paths degrade correctly — especially N15, since a partial-apply bug here
      would be easy to miss if only checking the rejected line and not the rest of the order
- [ ] The three "changed on purpose" regression items (Section 2) confirmed as intended new
      behavior, not reported as bugs
- [ ] E13 outcome documented either way (this is expected to still show *some* residual gap —
      that's fine, it's a known, already-flagged limitation, not a surprise)
- [ ] E14–E16 attempted if feasible; explicitly marked untestable-on-device if not, rather than
      silently skipped
- [ ] Monkey testing (including the overwrite/rename toggle check) found nothing alarming
