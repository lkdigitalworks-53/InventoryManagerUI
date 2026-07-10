# Design: Product tax export/import + optional Size field

**Date:** 2026-07-10
**Status:** Approved (pending written-spec review)
**Scope:** finish the already-started product tax export/import wiring; add a new optional
`size` field to products end-to-end (schema, dialogs, export, import, history).

---

## 1. Problem statement

**Tax export/import.** Products already carry `taxable` (bool) and `taxPercent` (number) — set in
`AddProductDialog`/`EditProductDialog`, persisted on the product doc, and shown in edit-history
diffs. A previous session started wiring these into export/import and stopped partway through,
leaving two TODO comments in the code:

- `InventoryStore.qml` (`upsertMany` overwrite path) — the fields object sent to `updateProduct()`
  on overwrite has `taxable`/`taxPercent` commented out, with a note to finish the export first.
  The commented-out code as written also has a latent bug: it references bare `taxable`/
  `taxPercent` variables instead of `r.taxable`/`r.taxPercent`, which doesn't exist in scope.
- `ImportPreviewDialog.qml` (`_validateProductRows`) — same TODO, columns never read.

Neither `kProductHeaders` in `src/XlsxService.cpp` nor the products README sheet mention tax at
all, so today a product export/re-import round-trip silently drops taxable status and rate.

**Size field.** No size/variant descriptor exists on products today. Karobar's product base spans
apparel, footwear, food, hardware, etc., so this needs to be a free-text optional field, not an
enum.

---

## 2. Decisions (locked with Taher, 2026-07-10)

| # | Decision |
|---|---|
| Tax scope | **`taxable`/`taxPercent` only.** The separate `hsnCode` roadmap item (SKILLS.md Skill 24 / P2) is explicitly **out of scope** for this pass. |
| Spec/branch structure | **One combined spec, one combined branch.** Both features touch the same product schema, both dialogs, `XlsxService.cpp`, and the import-preview validator — splitting them would mean touching the same functions twice. |
| `addProduct()` signature | **Extend positional args** (14th param: `size`). Not refactoring to a fields-object, even though the only live caller (`AddProductDialog.qml`) would make that cheap — keeping the diff minimal per Taher's call. |
| `InventoryStore._mergeRecord()` | **Leave alone.** Confirmed dead code (defined, never called — `upsertMany`'s real overwrite path builds its own inline fields object). Out of scope; not deleting, not wiring in. |
| `Taxable` cell format | **`Yes`/`No` text**, not `true`/`false` or `1`/`0` — matches the app's existing convention for other enum-like export columns (e.g. Discount Type as `flat`/`percent`), and is legible to a non-technical retailer editing the sheet by hand. |
| Column placement | **Appended at the end** of `kProductHeaders`/`writeProductsSheet`/README rows — `Size`, `Taxable`, `Tax %`, in that order after `Supplier`. Not inserted near `Unit`/`Category` conceptually, because `readSheet()` reads columns by fixed position against the header list index, not by matching header text in the file. Inserting mid-list would misalign every later column for anyone re-importing an older export. |
| Product-list card (`InventoryPage.qml`) | **Not touched.** Showing Size on the compact "Name / SKU · price" card is a real option but wasn't requested; flagged to Taher as a follow-up, not built by default (YAGNI). |
| Dead `Logic.qml`/`DataModel.qml` `addProduct` signal path | **Not touched.** Confirmed dead (never emitted anywhere), already stale (missing 2 params) before this session. Out of scope. |

---

## 3. Workstreams

*Implementation note: all QML/JS changes below follow the `qt-development-skills:qt-qml` coding
conventions (qsTr() wrapping, Layout.* sizing, no anchors+Layout mixing — the codebase already
does this consistently) and the `qt-development-skills:qt-ui-design` principles for the dialog
change (B2).*

### A. Tax export/import wiring

**A1. Fix the overwrite-path bug (`InventoryStore.qml`, `upsertMany`).**
Uncomment and correct the two lines in the `updatedProducts.push({..., fields: {...}})` object:
```js
taxable: !!r.taxable,
taxPercent: r.taxable
    ? (typeof r.taxPercent === "number" ? r.taxPercent : parseCurrency(r.taxPercent))
    : 0,
```
This mirrors the exact convention every other field in that object already uses (always take the
imported sheet's value — there is no "blank keeps existing" merge behavior anywhere in the live
overwrite path today, so none is introduced here either). Also add `size: r.size || ""` alongside
it (Workstream B).

**A2. New-row import path — no change needed.** `_normalizeRecord()` (used for new rows and
`rename`-policy rows) already normalizes `taxable`/`taxPercent` correctly. Confirmed by reading the
function; not touching it except to add `size` (Workstream B).

**A3. `ImportPreviewDialog._validateProductRows()`.** Read the two new columns into the `rec`
object built for each row:
```js
var taxableRaw = (r["Taxable"] || "").toString().trim().toLowerCase()
rec.taxable = (taxableRaw === "yes" || taxableRaw === "true" || taxableRaw === "1")
var taxPctRaw = r["Tax %"]
rec.taxPercent = rec.taxable ? (parseFloat(taxPctRaw) || 0) : 0
```
No hard-reject or warning needed — both columns are optional, absent/invalid defaults cleanly to
"not taxable, 0%", matching the Add dialog's own behavior when Taxable is left off.

**A4. Export (`src/XlsxService.cpp`).**
- Extend `kProductHeaders` with three new trailing entries, in this exact order, so the final list
  reads: `..., "Photo URL", "Supplier", "Size", "Taxable", "Tax %"`.
- `writeProductsSheet()`: write `Taxable` as `Yes`/`No` from the product's boolean, `Tax %` as a
  plain number (0 when not taxable — already true of the stored data, no extra logic needed).
  `Size` as plain text (see B3 for the Size-specific write).
- `readWorkbook()`/`readSheet()` need no changes — they're already generic over `kProductHeaders`.

**A5. README (`writeReadmeSheet`, "products" branch).** Add two rows:
```
{"Taxable", "no", "text", "Yes/No. Defaults to No if blank or unrecognized."},
{"Tax %",   "no", "number", "GST-style rate. Ignored (treated as 0) when Taxable is No."},
```

**A6. `Main.qml` `_exportProducts()` — no change needed.** It already does a full
`JSON.parse(JSON.stringify(p))` clone of each product before export, so `taxable`/`taxPercent`
(and the new `size`) ride along automatically once they exist on the product doc.

### B. Size field, end-to-end

**B1. Schema (`InventoryStore.qml`).**
- `addProduct(name, sku, category, description, price, unit, stock, minStock, sellingPrice,
  taxable, taxPercent, party, unitCost, size)` — `size` appended as the 14th and final parameter,
  defaulting to `""` when omitted/undefined.
- Stored on the product doc as `size: string`.
- `_normalizeRecord()`: add `size: r.size || ""`.
- `upsertMany()` overwrite-path fields object: add `size: r.size || ""` (alongside A1).
- `updateProduct()`: add `size` to the field-whitelist block (`prevSnap.size`, the
  `if (fields.size !== undefined) { ... }` line) — this one is a one-line addition since
  `updateProduct` already takes a named-fields object.
- `TransactionStore.recordCreated()` snapshot (called from `addProduct()`) and
  `_bookImportedProduct()`'s snapshot: add `size` so it round-trips through product-created history
  entries the same way `sku`/`category`/`unit` already do.

**B2. UI — `AddProductDialog.qml` and `EditProductDialog.qml`.**
Standalone full-width `AuthTextField` (`label: qsTr("Size")`, placeholder
`qsTr("e.g. M, L, XL, 500ml")`), positioned **after the Category/Unit `RowLayout`, before
Description** in both dialogs. Reasoning (per `qt-ui-design` principles — Jakob's Law, Proximity &
Similarity, Ockham's Razor): Category+Unit is already a tight 2-column row on phone width; a 3rd
combobox there risks truncating longer category names, while a standalone field matches how SKU
and Description already sit (one full-width field per row) — visually consistent, zero relayout of
existing fields, and groups Size with the other classification attributes (Category, Unit) it
conceptually belongs with.
- `AddProductDialog.onOpened`: reset `sizeField.text = ""`.
- `AddProductDialog` submit handler: pass `sizeField.text.trim()` as the new `addProduct()` arg.
- `EditProductDialog.openFor()`: `sizeField.text = p.size || ""`.
- `EditProductDialog` save handler: include `size: sizeField.text.trim()` in the
  `productUpdateRequested` fields object.
- `EditProductDialog._fieldLabel()`: add `case "size": return qsTr("Size")` so a size change shows
  correctly in the product's history feed (falls through to the existing default string formatter
  in `_fieldFormat()` — no special-casing needed there).

**B3. Export/import.** `Size` column — part of the same appended trio as A4
(`..., "Supplier", "Size", "Taxable", "Tax %"`). `writeProductsSheet()` writes it as plain text.
`ImportPreviewDialog._validateProductRows()` reads `(r["Size"] || "").toString().trim()` into
`rec.size`, same pattern as `Category`/`Description`. README gets one row:
`{"Size", "no", "text", "Optional — e.g. clothing size, volume, dimension."}`.

**B4. Not building.** Size on the `InventoryPage.qml` product-list card (flagged to Taher as a
follow-up option, not requested).

---

## 4. Files touched

| File | Workstream |
|---|---|
| `qml/model/InventoryStore.qml` | A1 (bug fix), B1 (schema, `addProduct`, `_normalizeRecord`, `upsertMany`, `updateProduct`, snapshot fields) |
| `qml/pages/ImportPreviewDialog.qml` | A3, B3 (`_validateProductRows`) |
| `src/XlsxService.cpp` | A4, A5, B3 (headers, write, README) |
| `qml/pages/AddProductDialog.qml` | B2 |
| `qml/pages/EditProductDialog.qml` | B2 (incl. `_fieldLabel`) |
| `qml/Main.qml` | none required (A6 — already generic) |

Not touched (confirmed out of scope, see Decisions): `InventoryStore._mergeRecord()`,
`DataModel.qml`/`Logic.qml` dead `addProduct` signal path, `InventoryPage.qml` product card,
`hsnCode`/GSTIN roadmap items.

---

## 5. Testing

No headless QML test coverage planned for the XlsxService/import-preview changes — consistent
with the prior import/export workstream, since page-level QML and QXlsx file I/O can't run under
`qmltestrunner`. A manual on-device test plan will be written alongside this spec (matching the
existing `docs/superpowers/2026-06-19-on-device-test-plan-revenue-reconciliation.md` /
`2026-06-21-custome-device-test-plan.md` pattern), covering:

- Add a product with Taxable on + a Tax %, and with a Size value → verify both save and reload
  correctly in Edit view.
- Export products → open the sheet, verify `Size`, `Taxable`, `Tax %` columns appear (appended,
  correct values, `Yes`/`No` legible).
- Edit the exported sheet (change Taxable/Tax %/Size on an existing row, identified by Product ID)
  and re-import with the overwrite policy → verify the in-app product reflects the edited values
  and that the product's history shows the field-change entries (including a "Size" entry).
- Import a **new** row with Taxable=No and a stray Tax % value → verify it's stored as 0%, not the
  stray value (per A3's `rec.taxable ? ... : 0` clamp).
- Import a row with an unrecognized `Taxable` value (e.g. blank, or "maybe") → verify it defaults
  to Not Taxable rather than rejecting the row.
- Re-import an **old** export (from before this change, missing the three new columns) → verify
  existing columns still parse correctly (appended-column placement doesn't break old files).

---

## 6. Regression guardrails

- No change to `_normalizeRecord()`'s existing `taxable`/`taxPercent` handling (A2) — only adding
  `size` to it.
- Overwrite-path fix (A1) follows the *existing* always-overwrite convention for that fields
  object; does not introduce a new "blank keeps existing" merge rule not already present for
  sibling fields.
- Column additions are append-only, preserving backward compatibility with previously-exported
  files per the position-based `readSheet()` reader.
- `addProduct()`'s only live caller (`AddProductDialog.qml`) is updated; the dead
  `Logic.qml`/`DataModel.qml` signal path is left as-is (already stale, not this session's
  responsibility).
