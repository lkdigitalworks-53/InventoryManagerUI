# Test plan — `pr_taher_bug_fixes`

**Branch:** `pr_taher_bug_fixes`, rebased onto `main` @ `cf01870` (2026-08-25) — linear history,
no merge commit; every commit SHA below is post-rebase. Two waves of unrelated `main` content are
now part of this branch's tree as a result and are **out of scope** for this plan:
`fix/return-analysis-revenue-not-updated` (`docs/superpowers/specs/2026-08-20-return-analysis-
revenue-bug-CHECKPOINT.md`, `SKILLS.md` Skill 42) and `docs/e2e-testing-phase2-followup`
(`SKILLS.md` Skills 43-45) — the latter includes a real `functions/index.js` fix in the same
CAS/conflict subsystem this plan's Bug 1 touches, confirmed non-interacting via a full post-rebase
suite re-run (645 QML + 94 Functions tests, 0 failed).
**Date:** 2026-08-22, restructured 2026-08-26 to the standard UT/Regression/E2E/on-device format
(`SKILLS.md` Skill 49).
**Covers:** all 12 commits specific to this PR — the 8 Taher wrote (`c4f276a` … `e571ed3`) plus
the 4 from this review session (`45b3d85`, `ca75cf5`, `0fa2c32`, `519d8d0`). Full per-commit
narrative: `SKILLS.md` Skill 46 (the three bugs) and Skill 48 (the test-plan consolidation).

Every count below comes from a genuine `qmltestrunner`/`node --test` run (verified 2026-08-26 by
counting each file's actual `function test_...` declarations, not carried forward from an earlier
approximate claim) — see "How this was verified" at the end for exact commands and the one
sandbox caveat that applies throughout (Qt 6.4.2 here vs CI's 6.8, worked around with a throwaway
scratch copy; real CI on Qt 6.8 is what actually confirms the E2E section).

---

## 1. Unit test coverage

Pure-logic correctness, independent of any specific bug — would exist even if nothing had ever
broken. 18 cases.

| File | Cases |
|---|---|
| `tests/tst_InventoryStore_cloneSymmetry.qml` | `test_newProductDoc_sends_supplierId_at_creation` — `supplierId` is part of the create payload at all, separate from the drift-with-`_clone()` question §2 covers. |
| `tests/tst_InventoryStore_upsertMany.qml` | `test_generateSku_uses_the_explicit_numOfProducts_suffix` (correct prefix/year/suffix format); `test_overwrite_with_blank_sku_falls_back_to_generated_when_existing_also_has_none` (legacy-data fallback still works); `test_overwrite_with_a_provided_sku_keeps_the_provided_value` (doesn't over-preserve); `test_rename_policy_with_blank_sku_generates_a_fresh_unique_sku`; `test_rename_policy_with_provided_sku_gets_a_renamed_suffix_not_a_fresh_one` (goes through `ImportMath.renameSku`, not `generateSku`); `test_skip_policy_leaves_the_existing_product_untouched`. |
| `tests/tst_StockSnapshotMath.qml` | `test_columnCount_matches_SalesPage_snapHeaders_supplier_view` / `_non_supplier_view`; `test_buildRow_supplier_view_has_exactly_one_cell_per_header_column` / `_non_supplier_view_has_exactly_one_cell_per_header_column`; `test_buildRow_supplier_view_column_order`; `test_buildTotalRow_supplier_view_has_exactly_one_cell_per_header_column` / `_non_supplier_view_has_exactly_one_cell_per_header_column`; `test_buildTotalRow_supplier_view_places_label_and_total_under_supplier_and_stock` / `_non_supplier_view_places_label_and_total_under_category_and_stock`; `test_buildRow_falls_back_to_price_when_sellingPrice_missing`; `test_buildRow_handles_zero_stock_and_missing_minStock`. |

## 2. Regression test coverage

Tests that exist *specifically because* a bug was found — each one pins down the exact defect so
it can't come back silently. 7 cases.

| Test | Regression for | What it locks down |
|---|---|---|
| `test_newProductDoc_fields_exactly_match_clone_whitelist`, `test_clone_preserves_supplierId_across_a_second_touch`, `test_clone_key_count_matches_created_doc_key_count` (`tst_InventoryStore_cloneSymmetry.qml`) | **Bug 1** — `addProduct()`'s create payload silently missing `supplierId`, breaking `_clone()` symmetry | `_newProductDoc()` and `_clone()`'s field sets stay exactly equal (same keys, same count) — the mechanism the server's CAS check (`functions/lib/gatewayLogic.js` `_deepEqual`) requires to avoid a false 409. |
| `test_overwrite_with_blank_sku_preserves_the_existing_sku` (`tst_InventoryStore_upsertMany.qml`) | **Bug 2** — overwrite generated a brand-new SKU instead of preserving the existing one | A blank `sku` column on an overwrite row no longer clobbers the product's real SKU. |
| `test_generateSku_with_different_explicit_numbers_never_collide`, `test_new_rows_in_one_batch_get_distinct_skus` (`tst_InventoryStore_upsertMany.qml`) | The **original bug** `c4f276a` fixed — every SKU-less row in one import batch collided on the same suffix (`products.length` read once, frozen for the whole loop) | Two same-named new products in one batch get distinct SKUs. |
| `test_buildRow_non_supplier_view_leads_with_productId` (`tst_StockSnapshotMath.qml`) | **Bug 3** — the non-supplier export row omitted `productId`, shifting every column left | Confirms the leading column is `productId`, not `name`. |

## 3. E2E test coverage

`test/e2e/tst_InventoryE2E.qml`, run via `firebase emulators:exec` against a real Firestore/Auth
emulator — the only layer in this plan that exercises the real server-side CAS check, not a
fabricated local product.

| Test | Status |
|---|---|
| `test_addProduct_creates_real_emulator_doc` | Passed before and after this session's fixes — creation has no CAS "before" to compare, so Bug 1 never affected it. |
| `test_updateProduct_persists_to_emulator` | **Failed before the fix** (false 409 from Bug 1), confirmed green after — via the real GitHub Checks API against this branch's CI run, all four checks (QML/Functions/Firestore-Rules/**E2E**) green. |
| `test_deleteProduct_removes_from_emulator` | Same as above — failed before, confirmed green after, same root cause. |

This is the one section this sandbox cannot run itself (no local Firebase emulator, Qt 6.4.2 vs
CI's 6.8) — its result comes from the real CI run, not a local workaround.

---

## 4. On-device test plan

### Happy path

1. Bulk-import a CSV of brand-new products, several sharing a first-and-last-initial (so they'd
   get the same SKU prefix), all with blank SKU cells — confirm every imported product gets a
   distinct SKU (the original sibling bug, `c4f276a`).
2. Bulk-import a CSV that updates several *existing* products' stock/price but leaves the SKU
   column blank for all of them — confirm every product's SKU is completely unchanged afterward
   (Bug 2).
3. Add a single new product via the "Add Product" dialog, then immediately edit it (price or
   stock) — confirm the edit saves without an unexpected "conflict" error (Bug 1, the real E2E
   failure this session fixed).
4. View the stock-snapshot export from the Sales page as an owner/admin (`canViewSuppliers`) —
   confirm all 11 columns (Product ID through Tax%) line up correctly, Total row included.
5. View the same export as a staff user without `canViewSuppliers` — confirm all 7 columns line
   up (this is the combination that was actually broken pre-fix, Bug 3).
6. Export the orders sheet, confirm the "Channel" column sits correctly among Staff/tax/line-item
   columns (`ad9f5f7` — verified correct by static trace this session, never click-tested).
7. Search the inventory list by typing a product ID (not name/SKU/category) — confirm it matches
   (`6ece50a`).
8. Open a completed order's history for a product that has a SKU — confirm the row reads
   "`<productId> | SKU: <sku> | ₹<price>`".

### Negative

1. Bulk-import a CSV row whose `productId` doesn't match any existing product and has no SKU,
   using the "overwrite" policy — since there's nothing to overwrite, confirm this doesn't crash
   and produces a sane fallback (worth confirming which path it actually takes — this plan's
   automated tests only exercise the matched case).
2. Add a product with a name under 2 characters via the "Add Product" dialog's SKU-suggest button
   — `generateSku()` returns `""` for `name.length < 2`; confirm the UI handles an empty
   suggestion gracefully rather than showing a malformed SKU.
3. Try to view the stock-snapshot export with zero products in inventory — confirm the Total row
   still renders with correct column count (grandTotal = 0) rather than an empty/malformed row.

### Edge cases

1. A product created before this fix landed (so it has no `supplierId` field in Firestore at
   all) — edit it once now that the fix is live; confirm the edit succeeds (existing pre-fix
   data, distinct from "new data created after the fix," and not covered by any automated test
   since those all start from a freshly-created record).
2. Overwrite an existing product whose *stored* SKU is itself already blank (legacy data,
   pre-dating SKU enforcement) with a CSV row that also has a blank SKU — confirm a SKU gets
   synthesized rather than staying permanently blank (covered automatedly by
   `test_overwrite_with_blank_sku_falls_back_to_generated_when_existing_also_has_none`, worth one
   real click-through since it's a legacy-data path).
3. A product with a completely blank SKU (not just "no supplierId") viewed in an order's history
   — confirm the row reads "`<productId> | ₹<price>`" with no dangling "SKU: " label (fixed this
   session, cosmetic).
4. Import a CSV batch large enough that `pullProductId()`'s minted numeric suffix crosses from
   3 digits to 4 (e.g. product #999 → #1000) — confirm the generated SKU still looks sane
   (`padStart(3,'0')` only pads, doesn't truncate, so this should be fine, but hasn't been
   click-tested).

### Affected areas

Every file this PR touches, and its current automated-coverage status, for anyone deciding where
else to look:

| File | Automated coverage | Notes |
|---|---|---|
| `qml/model/InventoryStore.qml` | Unit + regression (§1, §2) | `generateSku`, `_upsertManySync`, `_newProductDoc`, `_clone` |
| `qml/helper/StockSnapshotMath.js` (new) | Unit + regression (§1, §2) | Extracted specifically to make Bug 3 testable |
| `qml/pages/SalesPage.qml` | Indirect only — the helper is tested, the page's call site isn't | Confirm on-device (happy path #4-#5) |
| `qml/pages/InventoryPage.qml` | **None** — UI page, no test harness under this project's convention | Search-by-ID (happy path #7) and delegate text (no dedicated scenario, low risk) |
| `qml/pages/OrderDetailDialog.qml` | **None** — UI page | Happy path #8, edge case #3 |
| `src/XlsxService.cpp` | **None** — zero C++ test harness exists anywhere in this repo | Happy path #6; re-checked by static trace this session for the same "column added, index not fully shifted" bug class as Bug 3 and found correct, but never click-tested |
| `functions/index.js` (from the rebase, not this PR) | Node unit tests, `functions/test/` | Out of scope — see header |

### Regression tests

On-device re-verification of the 3 bugs found this session, for anyone who wants to confirm on a
real device/emulator rather than trust the automated suite:

1. **Bug 1 (false CAS conflict):** happy path #3 above. If this ever regresses, the symptom is a
   "conflict"/sync error on the *second* edit of a product, never the first.
2. **Bug 2 (SKU clobber):** happy path #2 above. If this regresses, existing products' SKUs
   silently change after any bulk edit that omits the SKU column.
3. **Bug 3 (export misalignment):** happy path #5 above (the non-supplier view is the one that
   was actually broken — #4 was already fine before the fix). If this regresses, column headers
   stop matching their data, most visibly the last column or two going blank.

---

## How this was verified

- QML: `qmltestrunner -input tests -platform offscreen` (Qt 6.4.2 in this sandbox vs CI's 6.8 —
  the `Settings`/`QtCore` API gap between them is worked around with a throwaway scratch copy;
  see `SKILLS.md` Skill 46 for the exact technique). §1+§2's 25 cases, plus the pre-existing
  suite, all passing post-rebase (645 QML tests total, 0 failed).
- Cloud Functions: `cd functions && npm test` — 94 tests, 0 failed.
- E2E: confirmed via the real GitHub Checks API against this branch's CI run, not locally — see §3.
