# On-device test plan — product tax export/import + Size field

Manual verification for docs/superpowers/specs/2026-07-10-product-tax-export-size-field-design.md.
Automated coverage: `tests/tst_ImportMath.qml` (Taxable/Tax % cell parsing). Everything below needs
a real device/emulator build since it exercises QML pages and QXlsx file I/O, neither of which run
under `qmltestrunner`.

## 1. Add + Edit dialogs

- [ ] Add a product with Taxable = On, Tax % = 18, Size = "L". Save. Open it in Edit view — all
      three values reload correctly.
- [ ] Add a product with Taxable = Off, Size left blank. Save. Open in Edit — Tax % shows 0,
      Size shows empty (not "undefined" or a stray placeholder).
- [ ] Edit an existing product's Size only (leave everything else unchanged). Save. Check the
      product's History tab — a "Size: (empty) → L" (or similar) entry appears.
- [ ] Restock the product (unrelated mutation) via the Restock dialog. Re-open Edit — Size is
      still present (regression check for the `_clone()` whitelist fix: without it, Size would
      silently disappear here).

## 2. Export

- [ ] Export Products. Open the sheet. Confirm column order ends
      `..., Photo URL, Supplier, Size, Taxable, Tax %` (appended, not inserted near Unit/Category).
- [ ] Confirm a taxable product shows `Taxable = Yes` and its correct `Tax %` number.
- [ ] Confirm a non-taxable product shows `Taxable = No` and `Tax % = 0`.
- [ ] Confirm the Size value is legible plain text, not a formula or numeric-coerced value.
- [ ] Open the README sheet — Size/Taxable/Tax % rows are present, all marked optional.

## 3. Import — overwrite

- [ ] In the exported sheet, change an existing row's Taxable/Tax %/Size (identify the row by
      Product ID). Re-import with the overwrite conflict policy.
- [ ] Confirm the in-app product reflects the edited values.
- [ ] Confirm the product's History tab shows field-change entries for whichever of
      Taxable/Tax %/Size actually changed (not entries for unchanged fields).

## 4. Import — new rows

- [ ] Add a new row to the sheet with Taxable = No and a stray Tax % value (e.g. 25) filled in
      anyway. Import as new. Confirm the product saves with Tax % = 0, not 25 — the stray value
      must not leak through.
- [ ] Add a new row with an unrecognized Taxable value (blank cell, or free text like "maybe").
      Import as new. Confirm it saves as Not Taxable — the row must import successfully (no
      hard-reject), just defaulted.
- [ ] Add a new row with Taxable = "TRUE" (mixed case, alternate accepted spelling) and confirm it
      still parses as taxable.

## 5. Backward compatibility

- [ ] Re-import a product sheet exported **before** this change (missing the three new columns
      entirely). Confirm existing columns (Name, SKU, Cost Price, etc.) still import correctly —
      the appended-column placement must not shift or corrupt any existing column's meaning.
