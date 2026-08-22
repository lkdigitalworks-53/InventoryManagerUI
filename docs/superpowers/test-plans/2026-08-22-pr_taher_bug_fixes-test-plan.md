# Test plan — `pr_taher_bug_fixes`

**Branch:** `pr_taher_bug_fixes` (`main` @ `bc0a8fb` → `4944c1d`, later merged forward with
`main` @ `3adbc18` in `aba371b` — that merge brought in an unrelated feature
(`fix/return-analysis-revenue-not-updated`) and is **out of scope** for this plan; see its own
coverage in `docs/superpowers/specs/2026-08-20-return-analysis-revenue-bug-CHECKPOINT.md`)
**Date:** 2026-08-22
**Covers:** all 12 commits specific to this PR — the 8 Taher wrote (`03319ee` … `fb180d8`) plus
the 4 from this review session (`c81e8ba`, `b5e2488`, `050c1a5`, `4944c1d`). Full list and
per-commit narrative: `SKILLS.md` Skill 46.

**Purpose of this doc:** one place that says, per change, exactly what's covered by a test that
has genuinely been RUN, what's covered only by static trace, and what has zero coverage of any
kind — instead of leaving that spread across 12 commit messages and a skill entry. Mirrors
`2026-08-08-review-round2-test-plan.md`'s three-tier structure (also now in this same folder).

---

## 1. What's actually verified — automated, genuinely run

Every file below was run with a real `qmltestrunner -input tests -platform offscreen` in this
session — **531 passed, 0 failed** as of the last run. Two honest caveats, stated once here
rather than repeated per row:

- This Cloud sandbox only has Qt **6.4.2** installed (`apt`); CI runs **6.8**. A real, unrelated
  API difference (`Settings` moved `Qt.labs.settings` → `QtCore` between those versions) makes 14
  pre-existing files fail to compile under 6.4.2 — confirmed identical on `main`, nothing to do
  with this PR. To get a genuine run of everything including those 14 (and thereby everything
  below), verification was done in a **throwaway scratch copy** with a temporary compat shim
  (`Qt.labs.settings` swapped in, `location:` properties stripped) — the real working tree was
  never touched by the shim, and the scratch copy was deleted after. Full detail: `SKILLS.md`
  Skill 46.
- "Run" here means `qmltestrunner`, not the real app. Nothing in this section touched a device,
  the Felgo `App` context, or a real Firestore/Cloud-Functions backend.

| File | Change it covers | Scenarios |
|---|---|---|
| `tests/tst_InventoryStore_cloneSymmetry.qml` (new, 6 cases) | `652998f`'s `_clone()`/`addProduct()` field drift (Bug 1 — the actual CI-breaking bug) | **Unit/regression**: `_newProductDoc()`'s field set exactly matches `_clone()`'s whitelist (`Object.keys` equality, both content and count); `supplierId` is present at creation, not just defaulted later; survives a second `_clone()` pass unchanged. |
| `tests/tst_InventoryStore_upsertMany.qml` (new, 11 cases) | `03319ee`/`652998f`/`fb180d8`'s SKU-generation changes, and the overwrite-clobber bug (Bug 2) found this session | **Unit**: `generateSku()` with an explicit suffix; two distinct suffixes never collide (the actual mechanism `03319ee` fixed). **Functional, all 3 `_conflictPolicy` branches** (previously only implicitly exercised, never directly tested): `overwrite` with blank sku preserves the real existing sku (regression for Bug 2) / `overwrite` with blank sku on a legacy no-sku record still synthesizes one (edge case) / `overwrite` with a provided sku keeps it verbatim (negative — confirms the fix doesn't over-preserve) / `rename` with blank sku generates a fresh unique one, original product untouched / `rename` with a provided sku goes through `ImportMath.renameSku`, not `generateSku` / `skip` leaves the matched product completely untouched (CRUD: no-op branch). **Multi-record**: two same-named new rows in one batch get distinct SKUs (the original `03319ee` bug, direct regression test). |
| `tests/tst_StockSnapshotMath.qml` (new, 14 cases) | `05eb0e4`'s stock-snapshot export column misalignment (Bug 3) | **Unit**: `columnCount()`/`buildRow()`/`buildTotalRow()` return exactly one cell per header column, for both `showSup` true/false. **Regression**: the non-supplier row leads with `productId` (the exact bug — it used to omit this and shift every value left). **Functional**: full column-order assertion for the supplier view (all 11 positions individually). **Edge cases**: `sellingPrice` missing falls back to `price`; `stock`/`minStock` missing default to `0`, not `undefined`. |

**This is the strongest claim in this doc: these 31 new cases (plus the pre-existing 500) were
actually executed, not asserted.** Re-run it yourself: see `AGENTS.md`'s Testing & QA Agent
section for the exact command, and `SKILLS.md` Skill 46 for the scratch-copy workaround if your
sandbox has the same Qt-version gap.

## 2. What CI will verify that this sandbox cannot — real Qt 6.8 + real Firebase emulator

`test/e2e/tst_InventoryE2E.qml`'s `test_updateProduct_persists_to_emulator` and
`test_deleteProduct_removes_from_emulator` are the tests that actually failed on the real CI run
against this branch before this session's fixes (confirmed via the GitHub Checks API, not
guessed — see Skill 46). Section 1's `tst_InventoryStore_cloneSymmetry.qml` tests the same
invariant these two rely on, but against a **fabricated local product**, not a real Firestore
document and not the real `functions/lib/gatewayLogic.js` CAS check running server-side. The E2E
run against the real emulator (which this sandbox cannot start — no Firebase emulator, and Qt 6.4.2
here vs CI's 6.8) is the actual end-to-end confirmation. **Check this once CI runs on the latest
push** — that's the one claim in this whole plan that genuinely can't be settled from this sandbox.

## 3. What has NO automated coverage — static trace only, no test file exists

Not "untested this round" — these files/functions have never had a test harness, consistent with
this project's established pattern (UI pages need the full Felgo `App` context and don't load
under `qmltestrunner`; there is no C++ test harness of any kind in this repo — no CMake test
target, no QTest `.cpp` file, checked this session).

| File / change | What changed | Trace performed this session |
|---|---|---|
| `qml/pages/InventoryPage.qml` — `baf2fab` (search by product ID) | `filteredProducts`'s `hay` string gained `p.productId` | Read the full filter function; confirmed the new field is concatenated before `name`/`sku`/`category`, so existing name/sku/category search behavior is unchanged (pure addition, not a reorder) — a page-level UI page, not extractable to a `.pragma library` helper without a bigger refactor than this PR's scope. |
| `qml/pages/InventoryPage.qml` — `a6f8be5` (delegate text when SKU absent) | Moved the `" | "` separator outside the SKU-conditional so it always appears before the price | Traced both branches by hand (see the review conversation): SKU present → identical output to before; SKU absent → separator now correctly appears (previously price ran directly into productId with no separator — that was the bug). |
| `qml/pages/OrderDetailDialog.qml` — `9a11e28` + this session's `050c1a5` | Visibility gated on `productId` instead of `sku`; SKU segment now conditional on `ohRow._sku` being non-empty | Traced all 4 combinations of (productId present/absent) × (sku present/absent) by hand; only the previously-broken "productId present, sku absent" case needed the fix, and it now renders without a dangling `"SKU: "` label. |
| `src/XlsxService.cpp` — `d111a0e` (order channel column in orders export) | Inserted a "Channel" column at position 5 in `kOrderHeaders`, `writeOrdersSheet`'s per-row/per-line writes, and every `setColumnWidth` call | **Re-checked this session specifically for the same bug class as Bug 3** (an inserted column not fully propagated): confirmed every `doc.write(r, N, ...)` index after the insertion point was incremented by exactly 1, all the way through the line-item columns, and every `setColumnWidth` call likewise — unlike the SalesPage bug, this one was done completely and correctly. Still zero test coverage: this project has no C++ test harness at all (no CMake test target, no QTest `.cpp` files exist anywhere in the repo), so this confirmation is static trace, not a run. |

## 4. On-device / manual checklist

For the row in §3 with the highest blast radius if wrong (silently wrong data in a file someone
hands to an accountant or a supplier), in priority order:

1. **Export the orders sheet after this branch, open it in Excel/LibreOffice, eyeball the header
   row against the first few data rows.** This is the one item worth actually clicking through —
   it's the only §3 change touching money/tax figures in a file that leaves the app. Confirm
   "Channel" lands in its own column and every column after it (Staff onward, including all the
   line-item columns) still lines up with its header.
2. **Bulk-import a CSV where several existing products' rows omit the SKU column entirely**
   (the real-world scenario `03319ee`/Bug 2 are about), confirm after import that those products'
   SKUs are unchanged from before the import — this is the one behavior in this PR that's easy to
   get "looks right" wrong (Section 1 tests it directly, but only against a fabricated local array;
   worth one real click-through against real app state).
3. **View the stock-snapshot export (Sales page) as a staff-role user (no `canViewSuppliers`)**
   and as an owner/admin, confirm every column header matches its column's data for both — Section
   1 tests the row-shaping function directly, but not that `SalesPage.qml` actually calls it with
   the right arguments in the real page context.
4. Everything else in §3 (delegate text, order-history dialog text, search-by-productId) is
   low-risk/cosmetic-or-additive; a quick look is enough, not worth a dedicated numbered scenario.

## 5. What this plan deliberately does not cover

- **The `aba371b` merge-from-`main` content** (the `fix/return-analysis-revenue-not-updated`
  feature) — separately designed, implemented, and tested; see its own checkpoint
  (`docs/superpowers/specs/2026-08-20-return-analysis-revenue-bug-CHECKPOINT.md`) and Skill 42's
  own entry there if one exists by the time you're reading this.
- **The full `_normalizeOrder`-style unification** flagged as a deferred trade-off in Skill 46 —
  not implemented, so nothing here tests it. `_normalizeRecord` (bulk import's own doc-shape
  builder) still independently duplicates `_newProductDoc()`/`_clone()`'s shape; a future test
  for THAT drift risk would need the unification to exist first.
- **Setting up any C++ test harness for `XlsxService.cpp`.** The gap in §3 is real and repo-wide
  (not introduced by this PR), but building one is a project-level infrastructure decision, not
  something to fold into a bug-fix PR's test plan unilaterally.
