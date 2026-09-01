# Reason Field for Product Adjustments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one optional, free-text "Reason" field — Edit Product dialog (applies to whatever changed in that save) and Restock dialog — surfaced in the per-product History tab and the dashboard ActivityLog feed.

**Architecture:** `reason` threads through as a plain string argument at every hop of two call chains: the 4-file Edit-Product relay (`EditProductDialog` → `Main.qml` → `Logic.qml` → `DataModel.qml` → `InventoryStore`) and the 2-file Restock chain (`RestockDialog` → `InventoryStore`). It is never stored as a persistent product field — it's transaction metadata only, living on the `TransactionStore`/`ActivityLog` records it annotates.

**Tech Stack:** QML/JS (Felgo/Qt Quick).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-11-product-adjustment-reason-design.md`.
- `reason` is always optional — no validation added anywhere for it.
- `reason` is threaded as a new **trailing** argument at every function/signal in the chain — never inserted before existing params, so no existing call site's positional args shift.
- Do not touch: `InventoryStore.setPhoto()` / photo-change flow, the Batches tab's rendering (data is captured via `StockBatchStore.addBatch()`'s existing `note` param, but not displayed there), the dead `Logic.restockProduct`/`DataModel.onRestockProduct` signal path.
- Do not build or run the Android app as part of this plan.
- Commit after every task.

---

### Task 1: `TransactionStore.qml` — accept and store `reason`

**Files:** Modify `qml/model/TransactionStore.qml`

**Interfaces:** `recordFieldChange`, `recordStockAdjustment`, `recordPurchase` each gain a trailing `reason` param, stored as `reason: reason || ""` on the doc. Consumed by Task 2 (`InventoryStore.qml`) and rendered by Task 5 (`EditProductDialog.qml` `_detailFor`).

No automated test — no `tst_TransactionStore.qml` exists (page/store-level QML can't run headless in this project); covered by the on-device test plan (Task 6).

- [x] **Step 1: `recordPurchase`**

Find:

```js
    function recordPurchase(productId, quantity, unitCost, productName, party) {
        if (!productId || !quantity || quantity <= 0) return
        var doc = {
            txId: _nextId("p"),
            kind: "purchase",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: productId,
            productName: productName || (InventoryStore.getById(productId) || {}).name || "",
            party: party || "",
            quantity: quantity,
            unitCost: typeof unitCost === "number" ? unitCost : 0,
            unitPrice: 0,
            total: quantity * (typeof unitCost === "number" ? unitCost : 0),
            orderId: ""
        }
        _push(doc)
    }
```

Replace with:

```js
    function recordPurchase(productId, quantity, unitCost, productName, party, reason) {
        if (!productId || !quantity || quantity <= 0) return
        var doc = {
            txId: _nextId("p"),
            kind: "purchase",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: productId,
            productName: productName || (InventoryStore.getById(productId) || {}).name || "",
            party: party || "",
            quantity: quantity,
            unitCost: typeof unitCost === "number" ? unitCost : 0,
            unitPrice: 0,
            total: quantity * (typeof unitCost === "number" ? unitCost : 0),
            orderId: "",
            reason: reason || ""
        }
        _push(doc)
    }
```

- [x] **Step 2: `recordFieldChange`**

Find:

```js
    function recordFieldChange(productId, productName, field, before, after) {
        if (!productId || !field) return
        var doc = {
            txId: _nextId("f"),
            kind: "field_change",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: productId,
            productName: productName || "",
            field: field,
            before: before === undefined ? "" : before,
            after: after === undefined ? "" : after,
            quantity: 0,
            unitCost: 0,
            unitPrice: 0,
            total: 0,
            orderId: ""
        }
        _push(doc)
    }
```

Replace with:

```js
    function recordFieldChange(productId, productName, field, before, after, reason) {
        if (!productId || !field) return
        var doc = {
            txId: _nextId("f"),
            kind: "field_change",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: productId,
            productName: productName || "",
            field: field,
            before: before === undefined ? "" : before,
            after: after === undefined ? "" : after,
            quantity: 0,
            unitCost: 0,
            unitPrice: 0,
            total: 0,
            orderId: "",
            reason: reason || ""
        }
        _push(doc)
    }
```

- [x] **Step 3: `recordStockAdjustment`**

Find:

```js
    function recordStockAdjustment(productId, productName, before, after) {
        if (!productId) return
        var b = parseInt(before) || 0
        var a = parseInt(after) || 0
        if (a === b) return
        var doc = {
            txId: _nextId("a"),
            kind: "stock_adjustment",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: productId,
            productName: productName || "",
            before: b,
            after: a,
            delta: a - b,
            quantity: 0,
            unitCost: 0,
            unitPrice: 0,
            total: 0,
            orderId: ""
        }
        _push(doc)
    }
```

Replace with:

```js
    function recordStockAdjustment(productId, productName, before, after, reason) {
        if (!productId) return
        var b = parseInt(before) || 0
        var a = parseInt(after) || 0
        if (a === b) return
        var doc = {
            txId: _nextId("a"),
            kind: "stock_adjustment",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: productId,
            productName: productName || "",
            before: b,
            after: a,
            delta: a - b,
            quantity: 0,
            unitCost: 0,
            unitPrice: 0,
            total: 0,
            orderId: "",
            reason: reason || ""
        }
        _push(doc)
    }
```

- [x] **Step 4: Commit**

```bash
git add qml/model/TransactionStore.qml
git commit -m "feat(history): accept an optional reason on field/stock/purchase records"
```

---

### Task 2: `InventoryStore.qml` — thread `reason` through `updateProduct` and `restock`

**Files:** Modify `qml/model/InventoryStore.qml`

**Interfaces:** `updateProduct(productId, fields, reason)` and `restock(productId, amount, party, unitCost, reason)`. Consumed by Task 3 (`DataModel.qml`) and Task 4 (`RestockDialog.qml`).

No automated test — data-layer plumbing, no `tst_InventoryStore.qml` exists. Covered by the on-device test plan (Task 6).

- [x] **Step 1: `updateProduct` signature + reason-aware calls**

Find:

```js
    function updateProduct(productId, fields) {
```

Replace with:

```js
    function updateProduct(productId, fields, reason) {
```

Find:

```js
        products = arr
        ActivityLog.record("product_updated",
                           "Product updated: " + p.name,
                           (p.sku ? p.sku + " · " : "") + "stock " + p.stock,
                           productId)
        for (var ci = 0; ci < fieldChanges.length; ++ci) {
            var c = fieldChanges[ci]
            TransactionStore.recordFieldChange(productId, p.name, c.field, c.before, c.after)
        }
        if (stockChange)
            TransactionStore.recordStockAdjustment(productId, p.name, stockChange.before, stockChange.after)
        Gateway.recordMutation("inventory", productId, "update", auditBefore, p)
    }
```

Replace with:

```js
        products = arr
        var reasonText = (reason || "").trim()
        ActivityLog.record("product_updated",
                           "Product updated: " + p.name,
                           (p.sku ? p.sku + " · " : "") + "stock " + p.stock
                               + (reasonText ? " · " + reasonText : ""),
                           productId)
        for (var ci = 0; ci < fieldChanges.length; ++ci) {
            var c = fieldChanges[ci]
            TransactionStore.recordFieldChange(productId, p.name, c.field, c.before, c.after, reasonText)
        }
        if (stockChange)
            TransactionStore.recordStockAdjustment(productId, p.name, stockChange.before, stockChange.after, reasonText)
        Gateway.recordMutation("inventory", productId, "update", auditBefore, p)
    }
```

- [x] **Step 2: `restock` signature + reason-aware calls**

Find:

```js
    function restock(productId, amount, party, unitCost) {
```

Replace with:

```js
    function restock(productId, amount, party, unitCost, reason) {
```

Find:

```js
        var supplierId = _resolveSupplierId(party);
        var supplierName = supplierId ? SupplierStore.nameOf(supplierId) : "";
        var batchCost = (typeof unitCost === "number" && !isNaN(unitCost)) ? unitCost : (changed.price || 0);

        ActivityLog.record("product_restocked",
                           "Restocked: " + changed.name,
                           "+" + addedQty + " · now " + changed.stock + " in stock"
                               + (supplierName ? " · from " + supplierName : ""),
                           productId);
        TransactionStore.recordPurchase(productId, addedQty, batchCost, changed.name, supplierId);
        // The receipt also lands as a FIFO batch — this is what every
        // subsequent sale will draw from in date order.
        StockBatchStore.addBatch(productId, supplierId, addedQty, batchCost, "");
        Gateway.recordMutation("inventory", productId, "update", before, changed);
    }
```

Replace with:

```js
        var supplierId = _resolveSupplierId(party);
        var supplierName = supplierId ? SupplierStore.nameOf(supplierId) : "";
        var batchCost = (typeof unitCost === "number" && !isNaN(unitCost)) ? unitCost : (changed.price || 0);
        var reasonText = (reason || "").trim();

        ActivityLog.record("product_restocked",
                           "Restocked: " + changed.name,
                           "+" + addedQty + " · now " + changed.stock + " in stock"
                               + (supplierName ? " · from " + supplierName : "")
                               + (reasonText ? " · " + reasonText : ""),
                           productId);
        TransactionStore.recordPurchase(productId, addedQty, batchCost, changed.name, supplierId, reasonText);
        // The receipt also lands as a FIFO batch — this is what every
        // subsequent sale will draw from in date order. The reason rides
        // along in the batch's existing (currently unrendered) note field.
        StockBatchStore.addBatch(productId, supplierId, addedQty, batchCost, reasonText);
        Gateway.recordMutation("inventory", productId, "update", before, changed);
    }
```

- [x] **Step 3: Commit**

```bash
git add qml/model/InventoryStore.qml
git commit -m "feat(inventory): thread reason through updateProduct and restock"
```

---

### Task 3: Relay `reason` through the Edit-Product signal chain

**Files:**
- Modify: `qml/pages/EditProductDialog.qml`
- Modify: `qml/Main.qml`
- Modify: `qml/logic/Logic.qml`
- Modify: `qml/model/DataModel.qml`

**Interfaces:** `EditProductDialog.productUpdateRequested(productId, fields, reason)` → `Logic.updateProduct(productId, fields, reason)` (signal) → `DataModel.onUpdateProduct(productId, fields, reason)` → `InventoryStore.updateProduct(productId, fields, reason)` (Task 2).

No automated test — same reasoning as prior tasks. Covered by the on-device test plan (Task 6).

- [x] **Step 1: `EditProductDialog.qml` — signal declaration + doc comment**

Find:

```qml
// Product detail / edit — bottom sheet. Public contract preserved:
//   signal productUpdateRequested(productId, fields)
//   function openFor(id, startInEdit)
//   property string productId
//   property bool editMode
//   property string photoUrl
BottomSheet {
    id: root

    sheetTitle: editMode ? "Edit product" : "Product details"
    primaryAction: editMode ? "Save changes" : (AuthStore.canManageInventory ? "Edit" : "")
    secondaryAction: editMode ? "Cancel" : "Close"

    signal productUpdateRequested(string productId, var fields)
```

Replace with:

```qml
// Product detail / edit — bottom sheet. Public contract preserved:
//   signal productUpdateRequested(productId, fields, reason)
//   function openFor(id, startInEdit)
//   property string productId
//   property bool editMode
//   property string photoUrl
BottomSheet {
    id: root

    sheetTitle: editMode ? "Edit product" : "Product details"
    primaryAction: editMode ? "Save changes" : (AuthStore.canManageInventory ? "Edit" : "")
    secondaryAction: editMode ? "Cancel" : "Close"

    signal productUpdateRequested(string productId, var fields, string reason)
```

- [x] **Step 2: `EditProductDialog.qml` — reset `reasonField` in `openFor()`**

Find:

```qml
        errorLabel.text = ""
        photoBusy = false
        // Supplier picker — refresh the model from SupplierStore and select
        // by id rather than by combobox string (the underlying list sorts
        // alphabetically, so positions shift on every add).
        root._refreshSupplierPicker(TransactionStore.lastSupplierFor(id) || "")
        root._renaming = false
        renameField.text = ""
        open()
    }
```

Replace with:

```qml
        errorLabel.text = ""
        photoBusy = false
        reasonField.text = ""
        // Supplier picker — refresh the model from SupplierStore and select
        // by id rather than by combobox string (the underlying list sorts
        // alphabetically, so positions shift on every add).
        root._refreshSupplierPicker(TransactionStore.lastSupplierFor(id) || "")
        root._renaming = false
        renameField.text = ""
        open()
    }
```

- [x] **Step 3: `EditProductDialog.qml` — clear `reasonField` on the View→Edit transition**

`openFor()` (Step 2) only resets it when the dialog is freshly opened. Tapping "Edit" from view mode
doesn't call `openFor()` again — it just flips `editMode`, so a reason typed in a previous edit
session (then cancelled) could otherwise leak into the next one. Find:

```qml
    onPrimaryClicked: {
        if (!editMode) editMode = true
        else _submit()
    }
```

Replace with:

```qml
    onPrimaryClicked: {
        if (!editMode) { editMode = true; reasonField.text = "" }
        else _submit()
    }
```

- [x] **Step 4: `EditProductDialog.qml` — add the Reason field to the form**

Find:

```qml
                        SupplierStore.updateSupplier(sid, { name: newName })
                        // Refresh model + restore selection by id (the new
                        // name reshuffles the alphabetical sort order).
                        root._refreshSupplierPicker(sid)
                        root._renaming = false
                        renameField.text = ""
                    }
                }
            }
        }

        Text {
            id: errorLabel
            Layout.fillWidth: true
            visible: text.length > 0
            color: Constants.danger
            font.pixelSize: sp(Constants.fsSmall)
            wrapMode: Text.Wrap
        }
```

Replace with:

```qml
                        SupplierStore.updateSupplier(sid, { name: newName })
                        // Refresh model + restore selection by id (the new
                        // name reshuffles the alphabetical sort order).
                        root._refreshSupplierPicker(sid)
                        root._renaming = false
                        renameField.text = ""
                    }
                }
            }
        }

        // Reason is transaction metadata, not a persistent product field —
        // unlike every other field above, there's nothing to show back in
        // view mode, so this is visible-only (not readOnly-toggled) and
        // reset to blank at the start of every edit session (see openFor()
        // and onPrimaryClicked above).
        AuthTextField {
            id: reasonField
            Layout.fillWidth: true
            visible: root.editMode
            label: qsTr("Reason for this change (optional)")
            placeholderText: qsTr("e.g. damaged stock, recount, price correction")
        }

        Text {
            id: errorLabel
            Layout.fillWidth: true
            visible: text.length > 0
            color: Constants.danger
            font.pixelSize: sp(Constants.fsSmall)
            wrapMode: Text.Wrap
        }
```

- [x] **Step 5: `EditProductDialog.qml` — surface reason in `_detailFor()`**

Find:

```qml
                case "purchase":
                    if (d.unitCost > 0)
                        return qsTr("@ %1 each · total %2")
                                .arg(InventoryStore.formatCurrency(d.unitCost))
                                .arg(InventoryStore.formatCurrency(d.total || 0))
                    return ""
                case "sale":
                    if (d.unitPrice > 0)
                        return qsTr("%1 × %2 = %3")
                                .arg(d.quantity || 0)
                                .arg(InventoryStore.formatCurrency(d.unitPrice))
                                .arg(InventoryStore.formatCurrency(d.total || 0))
                    return ""
                case "legacy_update":
                    return d.note || ""
```

Replace with:

```qml
                case "purchase":
                    var purDetail = (d.unitCost > 0)
                            ? qsTr("@ %1 each · total %2")
                                    .arg(InventoryStore.formatCurrency(d.unitCost))
                                    .arg(InventoryStore.formatCurrency(d.total || 0))
                            : ""
                    if (d.reason && d.reason.length > 0)
                        purDetail += (purDetail ? " · " : "") + d.reason
                    return purDetail
                case "sale":
                    if (d.unitPrice > 0)
                        return qsTr("%1 × %2 = %3")
                                .arg(d.quantity || 0)
                                .arg(InventoryStore.formatCurrency(d.unitPrice))
                                .arg(InventoryStore.formatCurrency(d.total || 0))
                    return ""
                case "legacy_update":
                    return d.note || ""
                case "field_change":
                    return d.reason || ""
                case "stock_adjustment":
                    return d.reason || ""
```

Note: `"return"`'s `d.reason` (an enum: `exchange`/`modify`/`other`) and this feature's `d.reason`
(free text) are different uses of the same field name across different `kind`s — safe because
`_titleFor`/`_detailFor` switch on `k` before interpreting `d.reason`, so a `"return"` doc's
enum-valued `reason` is never read by the new `"field_change"`/`"stock_adjustment"`/`"purchase"`
cases, and vice versa. No collision, just a naming coincidence worth knowing about if you're
reading this code later.

- [x] **Step 6: `EditProductDialog.qml` — pass reason in `_submit()`**

Find:

```qml
        productUpdateRequested(root.productId, {
            name: nameField.text.trim(),
            sku: skuField.text.trim(),
            category: categoryCombo.currentText,
            description: descField.text.trim(),
            unit: unitCombo.currentText,
            price: cost,
            sellingPrice: sell,
            taxable: taxable,
            taxPercent: taxable ? taxPercent : 0,
            stock: stk,
            minStock: ms
        })
```

Replace with:

```qml
        productUpdateRequested(root.productId, {
            name: nameField.text.trim(),
            sku: skuField.text.trim(),
            category: categoryCombo.currentText,
            description: descField.text.trim(),
            unit: unitCombo.currentText,
            price: cost,
            sellingPrice: sell,
            taxable: taxable,
            taxPercent: taxable ? taxPercent : 0,
            stock: stk,
            minStock: ms
        }, reasonField.text.trim())
```

- [x] **Step 7: `Main.qml` — relay reason**

Find:

```qml
        onProductUpdateRequested: function(pid, fields) {
            logic.updateProduct(pid, fields)
        }
```

Replace with:

```qml
        onProductUpdateRequested: function(pid, fields, reason) {
            logic.updateProduct(pid, fields, reason)
        }
```

- [x] **Step 8: `Logic.qml` — signal signature**

Find:

```qml
    signal updateProduct(string productId, var fields)
```

Replace with:

```qml
    signal updateProduct(string productId, var fields, string reason)
```

- [x] **Step 9: `DataModel.qml` — forward reason to InventoryStore**

Find:

```qml
        function onUpdateProduct(productId, fields) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can update products")
                return
            }
            // Capture the pre-edit stock so we can reconcile the FIFO batch
            // ledger after the product update. A manual stock edit only touches
            // product.stock; without this the batch ledger (which backs the
            // Value / Potential-profit / by-supplier Analysis reports) drifts.
            var before = InventoryStore.getById(productId)
            var oldStock = before ? before.stock : undefined
            InventoryStore.updateProduct(productId, fields)
            _reconcileBatchesForStockEdit(productId, oldStock, fields.stock)
            logic.productUpdated(productId)
        }
```

Replace with:

```qml
        function onUpdateProduct(productId, fields, reason) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can update products")
                return
            }
            // Capture the pre-edit stock so we can reconcile the FIFO batch
            // ledger after the product update. A manual stock edit only touches
            // product.stock; without this the batch ledger (which backs the
            // Value / Potential-profit / by-supplier Analysis reports) drifts.
            var before = InventoryStore.getById(productId)
            var oldStock = before ? before.stock : undefined
            InventoryStore.updateProduct(productId, fields, reason)
            _reconcileBatchesForStockEdit(productId, oldStock, fields.stock)
            logic.productUpdated(productId)
        }
```

- [x] **Step 10: Commit**

```bash
git add qml/pages/EditProductDialog.qml qml/Main.qml qml/logic/Logic.qml qml/model/DataModel.qml
git commit -m "feat(product): add optional Reason field to Edit Product, relay through to history"
```

---

### Task 4: `RestockDialog.qml` — add the Reason field

**Files:** Modify `qml/pages/RestockDialog.qml`

**Interfaces:** Consumes `InventoryStore.restock(productId, amount, party, unitCost, reason)` (Task 2).

No automated test — same reasoning as prior tasks. Covered by the on-device test plan (Task 6).

- [x] **Step 1: Reset `reasonField` in `openFor()`**

Find:

```qml
        addPartyField.text = ""
        dlg._addPartyOpen = false
        dlg.open()
    }
```

Replace with:

```qml
        addPartyField.text = ""
        dlg._addPartyOpen = false
        reasonField.text = ""
        dlg.open()
    }
```

- [x] **Step 2: Pass reason into `InventoryStore.restock()`**

Find:

```qml
    onPrimaryClicked: {
        var supplierId = partyCombo.currentIndex > 0
                ? dlg._supplierIds[partyCombo.currentIndex]
                : ""
        var unitCost = parseFloat(unitCostField.text)
        if (isNaN(unitCost) || unitCost < 0) unitCost = 0
        InventoryStore.restock(productId, qtyField.value, supplierId, unitCost)
        restockConfirmed(productId, qtyField.value)
        Toast.show("Restocked +" + qtyField.value + " units")
        dlg.close()
    }
```

Replace with:

```qml
    onPrimaryClicked: {
        var supplierId = partyCombo.currentIndex > 0
                ? dlg._supplierIds[partyCombo.currentIndex]
                : ""
        var unitCost = parseFloat(unitCostField.text)
        if (isNaN(unitCost) || unitCost < 0) unitCost = 0
        InventoryStore.restock(productId, qtyField.value, supplierId, unitCost, reasonField.text.trim())
        restockConfirmed(productId, qtyField.value)
        Toast.show("Restocked +" + qtyField.value + " units")
        dlg.close()
    }
```

- [x] **Step 3: Add the Reason field to the form**

Find (the end of the inline "Add new party" row, last thing in the `ColumnLayout`):

```qml
            PrimaryButton {
                id: addPartyBtn
                text: qsTr("Save")
                implicitHeight: dp(44)
                implicitWidth: dp(80)
                onClicked: {
                    var n = (addPartyField.text || "").trim()
                    if (n.length === 0) return
                    // SupplierStore.addSupplier returns the existing record
                    // when the name already exists, so we always have an id.
                    var s = SupplierStore.addSupplier({ name: n })
                    dlg._refreshSuppliers(s ? s.supplierId : "")
                    addPartyField.text = ""
                    dlg._addPartyOpen = false
                }
            }
        }
    }
}
```

Replace with:

```qml
            PrimaryButton {
                id: addPartyBtn
                text: qsTr("Save")
                implicitHeight: dp(44)
                implicitWidth: dp(80)
                onClicked: {
                    var n = (addPartyField.text || "").trim()
                    if (n.length === 0) return
                    // SupplierStore.addSupplier returns the existing record
                    // when the name already exists, so we always have an id.
                    var s = SupplierStore.addSupplier({ name: n })
                    dlg._refreshSuppliers(s ? s.supplierId : "")
                    addPartyField.text = ""
                    dlg._addPartyOpen = false
                }
            }
        }

        Text {
            text: qsTr("Reason (optional)")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }
        AuthTextField {
            id: reasonField
            Layout.fillWidth: true
            placeholderText: qsTr("e.g. delayed shipment, emergency restock")
        }
    }
}
```

- [x] **Step 4: Commit**

```bash
git add qml/pages/RestockDialog.qml
git commit -m "feat(restock): add optional Reason field"
```

---

### Task 5: On-device test plan doc

**Files:** Create `docs/superpowers/test-plans/2026-07-11-on-device-test-plan-adjustment-reason.md`

**Interfaces:** none — documentation only.

- [x] **Step 1: Write the on-device test plan**

Create `docs/superpowers/test-plans/2026-07-11-on-device-test-plan-adjustment-reason.md`:

```markdown
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
      the existing auth error — the reason threading in Task 3/DataModel.qml must not have
      disturbed the `_hasAnyRole` check ordering.
```

- [x] **Step 2: Commit**

```bash
git add docs/superpowers/test-plans/2026-07-11-on-device-test-plan-adjustment-reason.md
git commit -m "docs: on-device test plan for reason field feature"
```

---

## Plan self-review notes

- **Spec coverage:** A1–A5 (spec §4A) → Task 3. B1–B2 (spec §4B) → Task 4 Steps 2–3 + Task 2 Step 2. C (spec §4C) → Task 1. D (spec §4D) → Task 3 Step 5. All spec workstreams have a task.
- **Placeholder scan:** no TBD/TODO in any step; every step shows exact before/after code.
- **Argument-order consistency check across the whole chain:** `reason` is the trailing argument at every hop —
  `EditProductDialog.productUpdateRequested(productId, fields, reason)` →
  `Main.qml logic.updateProduct(pid, fields, reason)` →
  `Logic.qml signal updateProduct(productId, fields, reason)` →
  `DataModel.qml onUpdateProduct(productId, fields, reason)` →
  `InventoryStore.updateProduct(productId, fields, reason)`. Verified identical param order at
  every hop before finalizing this plan.
- **Restock chain:** `RestockDialog onPrimaryClicked` → `InventoryStore.restock(productId, amount, party, unitCost, reason)` — also trailing, also verified.
- **Every current line quoted in a "Find" block was re-viewed fresh in this branch (not reused from
  the previous session's exploration)** since `main` had advanced 3 commits — confirmed no drift
  affecting any of the planned edits (the one overlapping change, `EditProductDialog.qml`'s
  min-stock validation fix, is nowhere near any of this plan's insertion points).
