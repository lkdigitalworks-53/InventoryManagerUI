# On-device test plan — Reason field for product adjustments

Manual verification for docs/superpowers/specs/2026-07-11-product-adjustment-reason-design.md.
No automated coverage this time — unlike the previous feature, there's no pure-JS parsing logic to
extract (reason is passed straight through as a string), and every touched file is page-level QML
or App-context stores that can't run under `qmltestrunner` regardless.

## 1. Edit Product — single field

- [ ] Edit a product's Name only, with a reason typed. Save. Open History — the "Name" field_change
      row shows the reason as its detail text.
- [ ] Edit a product's Stock only, with a reason typed. Save. Open History — the stock_adjustment
      row shows the reason. Check the dashboard Activity feed — the "Product updated" entry's
      subtitle includes the reason.
- [ ] Edit a product's Stock only, leave Reason blank. Save. Confirm no stray " · " or blank-reason
      artifact appears in History or the Activity feed.

## 2. Edit Product — multiple fields, one reason

- [ ] Edit Name + Price + Stock together, one reason. Save. Confirm all three resulting History
      rows show the same reason text (expected, not a bug — one reason per save action).

## 3. Edit Product — reason typed, nothing changed

- [ ] Open Edit, type a reason, don't change any field, Save. Confirm no History rows are created
      (matches existing behavior: unchanged fields don't get a field_change/stock_adjustment row)
      but the Activity feed's "Product updated" entry still shows the reason.

## 4. Reason field reset behavior

- [ ] View a product → Edit → type a reason → Cancel. Tap Edit again. Confirm Reason is blank (not
      leaked from the cancelled attempt).
- [ ] View a product → Edit → type a reason → Save successfully. Open Edit again on the same
      product. Confirm Reason is blank (not pre-filled with the last-used reason).

## 5. Restock

- [ ] Restock with a reason. Check History — the purchase row shows "@ cost · total · reason".
      Check the Activity feed — the "Restocked" entry's subtitle includes the reason.
- [ ] Restock without a reason. Confirm no stray " · " or blank-reason artifact appears anywhere.

## 6. Permissions (unrelated regression check)

- [ ] As a non-owner/admin role, confirm attempting to edit/restock still correctly blocks with
      the existing auth error — the reason threading in DataModel.qml must not have disturbed the
      `_hasAnyRole` check ordering.
