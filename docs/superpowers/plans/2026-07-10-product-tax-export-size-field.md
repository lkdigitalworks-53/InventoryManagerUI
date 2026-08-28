# Product Tax Export/Import + Size Field Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Also apply `qt-development-skills:qt-qml` (coding conventions) and `qt-development-skills:qt-ui-design` (Task 4/5 dialog changes) throughout, per Taher's instruction.

**Goal:** Finish the already-started product tax (`taxable`/`taxPercent`) export/import wiring, and add a new optional `size` field to products end-to-end — schema, Add/Edit dialogs, export, import, and edit-history.

**Architecture:** No new files, no new stores. Three trailing columns (`Size`, `Taxable`, `Tax %`) are appended to the existing product export/import pipeline (`XlsxService.cpp` → `ImportPreviewDialog.qml` → `InventoryStore.qml`). `size` becomes a plain string field alongside `taxable`/`taxPercent` everywhere those already flow through the product schema. Two new pure parsing helpers land in the existing `ImportMath.js` (already the designated home for headlessly-testable import logic) so the riskiest bit of new logic — parsing a human-typed "Taxable" cell — carries an automated test.

**Tech Stack:** QML/JS (Felgo/Qt Quick), C++ (Qt 6, QXlsx), `qmltestrunner`/`QtTest`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-10-product-tax-export-size-field-design.md` — every task below implements a specific section of it; read it first if anything here is ambiguous.
- New export columns are **appended only** — `kProductHeaders` final order must be `..., "Photo URL", "Supplier", "Size", "Taxable", "Tax %"`. Never insert a new column before an existing one (`readSheet()` reads by fixed column position, not header text).
- `Taxable` cell is written/read as `Yes`/`No` text, never `true`/`false`/`1`/`0`.
- `addProduct()` gets `size` as its 14th and final positional parameter — no refactor to a fields-object (explicit call from Taher).
- Do not touch: `InventoryStore._mergeRecord()` (dead code, leave as-is), the `DataModel.qml`/`Logic.qml` `addProduct` signal path (dead, already stale), `InventoryPage.qml`'s product card, any `hsnCode`/GSTIN roadmap work.
- Do not build or run the Android app as part of this plan — Taher builds/runs when he's ready. Tasks 1's tests run via `qmltestrunner` only (no app build required).
- Commit after every task, following the repo's existing Conventional-Commits-ish style (`feat: …`, `fix: …`, `docs: …`) visible in `git log`.

---

### Task 1: `ImportMath.js` — pure Taxable/Tax % parsing helpers

**Files:**
- Modify: `qml/helper/ImportMath.js`
- Test: `tests/tst_ImportMath.qml`

**Interfaces:**
- Produces: `ImportMath.parseTaxableCell(raw)` → `boolean`. `ImportMath.parseTaxPercentCell(raw, taxable)` → `number`. Both are pure functions with no QML context dependency — consumed by Task 6 (`ImportPreviewDialog.qml`).

- [x] **Step 1: Write the failing tests**

Add to `tests/tst_ImportMath.qml`, inside the existing `TestCase { name: "ImportMath" ... }` block, after `test_rename_double_digit`:

```qml
    function test_taxable_yes_is_true() {
        compare(IM.parseTaxableCell("Yes"), true)
    }

    function test_taxable_case_insensitive() {
        compare(IM.parseTaxableCell("yES"), true)
        compare(IM.parseTaxableCell("TRUE"), true)
        compare(IM.parseTaxableCell("1"), true)
    }

    function test_taxable_no_is_false() {
        compare(IM.parseTaxableCell("No"), false)
    }

    function test_taxable_blank_is_false() {
        compare(IM.parseTaxableCell(""), false)
        compare(IM.parseTaxableCell(undefined), false)
    }

    function test_taxable_unrecognized_defaults_false() {
        compare(IM.parseTaxableCell("maybe"), false)
    }

    function test_taxable_trims_whitespace() {
        compare(IM.parseTaxableCell("  Yes  "), true)
    }

    function test_taxpercent_zero_when_not_taxable() {
        compare(IM.parseTaxPercentCell("18", false), 0)
    }

    function test_taxpercent_parses_number_when_taxable() {
        compare(IM.parseTaxPercentCell("18", true), 18)
    }

    function test_taxpercent_blank_when_taxable_is_zero() {
        compare(IM.parseTaxPercentCell("", true), 0)
    }

    function test_taxpercent_invalid_when_taxable_is_zero() {
        compare(IM.parseTaxPercentCell("not a number", true), 0)
    }
```

- [x] **Step 2: Run tests to verify they fail**

Run: `qmltestrunner -input tests` (or the `qt-development-skills:qt-qml-test-run` skill)
Expected: FAIL — `TypeError: IM.parseTaxableCell is not a function` (and similarly for `parseTaxPercentCell`).

- [x] **Step 3: Write the minimal implementation**

Add to `qml/helper/ImportMath.js`, after `renameSku`:

```js
// Parses a human-typed "Taxable" export/import cell into a boolean. Accepts
// "yes"/"true"/"1" case-insensitively (matches how the app writes the column
// on export: "Yes"/"No"). Blank or unrecognized values default to false —
// there is no "reject the row" behavior for this optional column.
function parseTaxableCell(raw) {
    var s = (raw === undefined || raw === null) ? "" : String(raw).trim().toLowerCase()
    return s === "yes" || s === "true" || s === "1"
}

// Parses the "Tax %" cell. When the row isn't taxable, the rate is always 0
// regardless of what's in the cell (matches AddProductDialog/EditProductDialog's
// own behavior: the Tax % input is disabled and zeroed when "Not taxable" is
// selected). When taxable, an unparseable value also falls back to 0 rather
// than rejecting the row — Taxable/Tax % are optional columns.
function parseTaxPercentCell(raw, taxable) {
    if (!taxable) return 0
    var n = parseFloat(raw)
    return isNaN(n) ? 0 : n
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `qmltestrunner -input tests`
Expected: PASS — all `ImportMath` tests, including the 10 new ones, green.

- [x] **Step 5: Commit**

```bash
git add qml/helper/ImportMath.js tests/tst_ImportMath.qml
git commit -m "feat(import): add pure Taxable/Tax% cell parsers to ImportMath.js"
```

---

### Task 2: `InventoryStore.qml` — `size` schema + tax overwrite-path bug fix

**Files:**
- Modify: `qml/model/InventoryStore.qml`

**Interfaces:**
- Consumes: nothing new.
- Produces: every product object now carries `size: string`. `addProduct(name, sku, category, description, price, unit, stock, minStock, sellingPrice, taxable, taxPercent, party, unitCost, size)` — 14 params. `updateProduct(productId, fields)` accepts an optional `fields.size`. `upsertMany(records)` now correctly overwrites `taxable`/`taxPercent`/`size` on conflict. These are consumed by Task 4 (`AddProductDialog.qml`), Task 5 (`EditProductDialog.qml`), and Task 6 (`ImportPreviewDialog.qml`).

No automated test for this task — it's data-layer plumbing across an existing untested store (no `tst_InventoryStore.qml` exists; page-level/store-level QML can't run headless per the existing project convention — see spec §5). Verified via the on-device test plan (Task 7).

- [x] **Step 1: Fix `_clone()` — the load-bearing fix**

`_clone()` is called by all 8 mutator functions (`addProduct`, `updateProduct`, `upsertMany`, `restock`, etc.). It currently rebuilds each product through an explicit field whitelist that does **not** include `size` — meaning without this fix, `size` would be silently wiped the next time *any* product anywhere is mutated. Find:

```js
    function _clone() {
        var a = [];
        for (var i = 0; i < products.length; ++i) {
            var p = products[i];
            a.push({ productId: p.productId, name: p.name, sku: p.sku, category: p.category,
                      stock: p.stock, minStock: p.minStock,
                      price: p.price, sellingPrice: p.sellingPrice !== undefined ? p.sellingPrice : p.price,
                      taxable: !!p.taxable,
                      taxPercent: typeof p.taxPercent === "number" ? p.taxPercent : 0,
                      unit: p.unit, description: p.description,
                      photoUrl: p.photoUrl || "",
                      photoUpdatedAt: p.photoUpdatedAt || "" });
```

Replace with:

```js
    function _clone() {
        var a = [];
        for (var i = 0; i < products.length; ++i) {
            var p = products[i];
            a.push({ productId: p.productId, name: p.name, sku: p.sku, category: p.category,
                      stock: p.stock, minStock: p.minStock,
                      price: p.price, sellingPrice: p.sellingPrice !== undefined ? p.sellingPrice : p.price,
                      taxable: !!p.taxable,
                      taxPercent: typeof p.taxPercent === "number" ? p.taxPercent : 0,
                      size: p.size || "",
                      unit: p.unit, description: p.description,
                      photoUrl: p.photoUrl || "",
                      photoUpdatedAt: p.photoUpdatedAt || "" });
```

- [x] **Step 2: Default `size` on Firestore-synced docs**

In `_normalizeProducts(arr)`, find:

```js
            if (p.taxable === undefined || p.taxable === null) p.taxable = false;
            if (p.taxPercent === undefined || p.taxPercent === null) p.taxPercent = 0;
            if (!p.photoUrl) p.photoUrl = "";
```

Replace with:

```js
            if (p.taxable === undefined || p.taxable === null) p.taxable = false;
            if (p.taxPercent === undefined || p.taxPercent === null) p.taxPercent = 0;
            if (!p.size) p.size = "";
            if (!p.photoUrl) p.photoUrl = "";
```

- [x] **Step 3: Add `size` to `addProduct()`**

Find:

```js
    function addProduct(name, sku, category, description, price, unit, stock, minStock, sellingPrice, taxable, taxPercent, party, unitCost) {
        var id = nextProductId();
        var arr = _clone();
        var sp = (sellingPrice !== undefined && sellingPrice !== null) ? sellingPrice : price;
        var tx = !!taxable;
        var tp = (typeof taxPercent === "number" && !isNaN(taxPercent)) ? taxPercent : 0;
        var doc = { productId: id, name: name, sku: sku, category: category,
                   stock: stock, minStock: minStock,
                   price: price, sellingPrice: sp,
                   taxable: tx, taxPercent: tp,
                   unit: unit, description: description || "",
                   photoUrl: "", photoUpdatedAt: "" };
```

Replace with:

```js
    function addProduct(name, sku, category, description, price, unit, stock, minStock, sellingPrice, taxable, taxPercent, party, unitCost, size) {
        var id = nextProductId();
        var arr = _clone();
        var sp = (sellingPrice !== undefined && sellingPrice !== null) ? sellingPrice : price;
        var tx = !!taxable;
        var tp = (typeof taxPercent === "number" && !isNaN(taxPercent)) ? taxPercent : 0;
        var sz = size || "";
        var doc = { productId: id, name: name, sku: sku, category: category,
                   stock: stock, minStock: minStock,
                   price: price, sellingPrice: sp,
                   taxable: tx, taxPercent: tp,
                   size: sz,
                   unit: unit, description: description || "",
                   photoUrl: "", photoUpdatedAt: "" };
```

A few lines below in the same function, find the `TransactionStore.recordCreated` snapshot:

```js
        TransactionStore.recordCreated(id, name, stock, batchCost, {
            sku: sku || "",
            category: category || "",
            unit: unit || "",
            sellingPrice: sp,
            taxable: tx,
            taxPercent: tp,
            minStock: minStock || 0,
            description: description || "",
            supplierId: supplierId
        }, supplierId);
```

Replace with:

```js
        TransactionStore.recordCreated(id, name, stock, batchCost, {
            sku: sku || "",
            category: category || "",
            unit: unit || "",
            sellingPrice: sp,
            taxable: tx,
            taxPercent: tp,
            size: sz,
            minStock: minStock || 0,
            description: description || "",
            supplierId: supplierId
        }, supplierId);
```

- [x] **Step 4: Add `size` to `_bookImportedProduct()`'s snapshot**

Find:

```js
    function _bookImportedProduct(doc) {
        var supplierId = doc.supplierId || "";
        var batchCost = (typeof doc.price === "number" && !isNaN(doc.price)) ? doc.price : 0;
        TransactionStore.recordCreated(doc.productId, doc.name, doc.stock, batchCost, {
            sku: doc.sku || "", category: doc.category || "", unit: doc.unit || "",
            sellingPrice: doc.sellingPrice, taxable: doc.taxable, taxPercent: doc.taxPercent,
            minStock: doc.minStock || 0, description: doc.description || "",
            supplierId: supplierId, origin: "imported"
        }, supplierId);
```

Replace with:

```js
    function _bookImportedProduct(doc) {
        var supplierId = doc.supplierId || "";
        var batchCost = (typeof doc.price === "number" && !isNaN(doc.price)) ? doc.price : 0;
        TransactionStore.recordCreated(doc.productId, doc.name, doc.stock, batchCost, {
            sku: doc.sku || "", category: doc.category || "", unit: doc.unit || "",
            sellingPrice: doc.sellingPrice, taxable: doc.taxable, taxPercent: doc.taxPercent,
            size: doc.size || "",
            minStock: doc.minStock || 0, description: doc.description || "",
            supplierId: supplierId, origin: "imported"
        }, supplierId);
```

- [x] **Step 5: Fix the `upsertMany()` overwrite-path bug + add `size`**

Find (the commented-out, buggy block):

```js
                // overwrite
                // For overwrite operation we have to send it through logic and data model layer to update details.
                updatedProducts.push({productId: r.productId, fields: {
                                  name: r.name,
                                  sku: r.sku,
                                  category: r.category,
                                  description: r.description,
                                  unit: r.unit,
                                  price: r.price,
                                  sellingPrice: r.sellingPrice,
                                  // To-Do: There are no tax information getting exported.
                                  // Keeping below lines, for future to uncomment when export of tax information implemented

                                  // taxable: taxable,
                                  // taxPercent: taxable ? taxPercent : 0,
                                  stock: r.stock,
                                  minStock: r.minStock
                              }})
                counts.updated++;
```

Replace with:

```js
                // overwrite
                // For overwrite operation we have to send it through logic and data model layer to update details.
                updatedProducts.push({productId: r.productId, fields: {
                                  name: r.name,
                                  sku: r.sku,
                                  category: r.category,
                                  description: r.description,
                                  unit: r.unit,
                                  price: r.price,
                                  sellingPrice: r.sellingPrice,
                                  taxable: !!r.taxable,
                                  taxPercent: r.taxable
                                      ? (typeof r.taxPercent === "number" ? r.taxPercent : parseCurrency(r.taxPercent))
                                      : 0,
                                  size: r.size || "",
                                  stock: r.stock,
                                  minStock: r.minStock
                              }})
                counts.updated++;
```

- [x] **Step 6: Add `size` to `_normalizeRecord()`**

Find:

```js
    function _normalizeRecord(r) {
        return {
            productId: r.productId,
            name: r.name || "",
            sku: r.sku || "",
            category: r.category || "",
            unit: r.unit || "Units (pcs)",
            description: r.description || "",
            price: typeof r.price === "number" ? r.price : parseCurrency(r.price),
            sellingPrice: typeof r.sellingPrice === "number"
                ? r.sellingPrice
                : (r.sellingPrice ? parseCurrency(r.sellingPrice) : 0),
            taxable: !!r.taxable,
            taxPercent: typeof r.taxPercent === "number"
                ? r.taxPercent
                : (r.taxPercent ? parseCurrency(r.taxPercent) : 0),
            stock: parseInt(r.stock) || 0,
            minStock: parseInt(r.minStock) || 0,
            photoUrl: r.photoUrl || "",
            photoUpdatedAt: r.photoUpdatedAt || "",
            supplierId: r.supplierId || (r.supplier ? _resolveSupplierId(r.supplier) : "")
        };
    }
```

Replace with:

```js
    function _normalizeRecord(r) {
        return {
            productId: r.productId,
            name: r.name || "",
            sku: r.sku || "",
            category: r.category || "",
            unit: r.unit || "Units (pcs)",
            description: r.description || "",
            price: typeof r.price === "number" ? r.price : parseCurrency(r.price),
            sellingPrice: typeof r.sellingPrice === "number"
                ? r.sellingPrice
                : (r.sellingPrice ? parseCurrency(r.sellingPrice) : 0),
            taxable: !!r.taxable,
            taxPercent: typeof r.taxPercent === "number"
                ? r.taxPercent
                : (r.taxPercent ? parseCurrency(r.taxPercent) : 0),
            size: r.size || "",
            stock: parseInt(r.stock) || 0,
            minStock: parseInt(r.minStock) || 0,
            photoUrl: r.photoUrl || "",
            photoUpdatedAt: r.photoUpdatedAt || "",
            supplierId: r.supplierId || (r.supplier ? _resolveSupplierId(r.supplier) : "")
        };
    }
```

- [x] **Step 7: Add `size` to `updateProduct()`'s field whitelist**

Find:

```js
        var prevSnap = {
            name: prev.name, sku: prev.sku, category: prev.category,
            description: prev.description, unit: prev.unit,
            price: prev.price, sellingPrice: prev.sellingPrice,
            taxable: !!prev.taxable, taxPercent: prev.taxPercent || 0,
            stock: prev.stock, minStock: prev.minStock
        }
```

Replace with:

```js
        var prevSnap = {
            name: prev.name, sku: prev.sku, category: prev.category,
            description: prev.description, unit: prev.unit,
            price: prev.price, sellingPrice: prev.sellingPrice,
            taxable: !!prev.taxable, taxPercent: prev.taxPercent || 0,
            size: prev.size || "",
            stock: prev.stock, minStock: prev.minStock
        }
```

Then find:

```js
        if (fields.taxPercent   !== undefined) { _maybe("taxPercent", fields.taxPercent); p.taxPercent = fields.taxPercent }
        if (fields.stock        !== undefined) { _maybe("stock", fields.stock); p.stock = fields.stock }
```

Replace with:

```js
        if (fields.taxPercent   !== undefined) { _maybe("taxPercent", fields.taxPercent); p.taxPercent = fields.taxPercent }
        if (fields.size         !== undefined) { _maybe("size", fields.size); p.size = fields.size }
        if (fields.stock        !== undefined) { _maybe("stock", fields.stock); p.stock = fields.stock }
```

- [x] **Step 8: Commit**

```bash
git add qml/model/InventoryStore.qml
git commit -m "feat(inventory): add size field + fix tax overwrite-path bug in import"
```

---

### Task 3: `src/XlsxService.cpp` — export/import columns + README

**Files:**
- Modify: `src/XlsxService.cpp`

**Interfaces:**
- Consumes: nothing new (products come in as `QVariantList` already carrying `size`/`taxable`/`taxPercent` from Task 2 — no C++-side schema awareness needed beyond reading these keys).
- Produces: `kProductHeaders` now includes `"Size"`, `"Taxable"`, `"Tax %"`. Consumed by Task 6 (`ImportPreviewDialog.qml`, which reads `r["Size"]`/`r["Taxable"]`/`r["Tax %"]`).

No automated test — no existing C++ test harness for `XlsxService` in this project (confirmed: no `tst_*` for it). Verified via the on-device test plan (Task 7).

- [x] **Step 1: Extend `kProductHeaders`**

Find:

```cpp
const QStringList kProductHeaders = {
    "Product ID", "Name", "SKU", "Category", "Unit", "Description",
    "Cost Price", "Selling Price", "Stock", "Min Stock", "Photo URL", "Supplier"
};
```

Replace with:

```cpp
const QStringList kProductHeaders = {
    "Product ID", "Name", "SKU", "Category", "Unit", "Description",
    "Cost Price", "Selling Price", "Stock", "Min Stock", "Photo URL", "Supplier",
    "Size", "Taxable", "Tax %"
};
```

- [x] **Step 2: Write the three new columns in `writeProductsSheet()`**

Find:

```cpp
        doc.write(row, 11, variantToString(p.value("photoUrl")));
        doc.write(row, 12, variantToString(p.value("supplier")));
    }
```

Replace with:

```cpp
        doc.write(row, 11, variantToString(p.value("photoUrl")));
        doc.write(row, 12, variantToString(p.value("supplier")));
        doc.write(row, 13, variantToString(p.value("size")));
        doc.write(row, 14, p.value("taxable").toBool() ? QStringLiteral("Yes") : QStringLiteral("No"));
        doc.write(row, 15, variantToNumber(p.value("taxPercent")));
    }
```

- [x] **Step 3: Widen the three new columns**

Find:

```cpp
    doc.setColumnWidth(11, 32);
    doc.setColumnWidth(12, 20);
}
```

Replace with:

```cpp
    doc.setColumnWidth(11, 32);
    doc.setColumnWidth(12, 20);
    doc.setColumnWidth(13, 14);
    doc.setColumnWidth(14, 10);
    doc.setColumnWidth(15, 10);
}
```

- [x] **Step 4: Add README rows**

Find:

```cpp
            {"Photo URL",     "no",  "text",   "Public image URL. Leave empty to keep the existing photo."},
            {"Supplier",      "no",  "text",   "Supplier name. Creates an opening stock batch so by-supplier reports work."},
        };
```

Replace with:

```cpp
            {"Photo URL",     "no",  "text",   "Public image URL. Leave empty to keep the existing photo."},
            {"Supplier",      "no",  "text",   "Supplier name. Creates an opening stock batch so by-supplier reports work."},
            {"Size",          "no",  "text",   "Optional — e.g. clothing size, volume, dimension."},
            {"Taxable",       "no",  "text",   "Yes/No. Defaults to No if blank or unrecognized."},
            {"Tax %",         "no",  "number", "GST-style rate. Ignored (treated as 0) when Taxable is No."},
        };
```

- [x] **Step 5: Commit**

```bash
git add src/XlsxService.cpp
git commit -m "feat(export): add Size/Taxable/Tax % columns to product export/import"
```

---

### Task 4: `AddProductDialog.qml` — Size field UI

**Files:**
- Modify: `qml/pages/AddProductDialog.qml`

**Interfaces:**
- Consumes: `InventoryStore.addProduct(..., size)` (Task 2, 14th param).
- Produces: nothing consumed elsewhere.

No automated test — QML page-level dialogs can't run under `qmltestrunner` in this project (confirmed by every existing `tst_*.qml` comment about `App context`). Verified via the on-device test plan (Task 7).

Per `qt-development-skills:qt-ui-design`: this is a small edit to an existing design (adding one field to an existing form) — Jakob's Law and Proximity/Similarity favor a standalone full-width field next to the other classification attributes (Category, Unit) rather than cramming a 3rd combobox into the existing 2-column row.

- [x] **Step 1: Reset `sizeField` on open**

Find:

```qml
        taxableCombo.currentIndex = 0
        taxPercentField.text = ""
```

Replace with:

```qml
        taxableCombo.currentIndex = 0
        taxPercentField.text = ""
        sizeField.text = ""
```

- [x] **Step 2: Add the Size field to the form**

Find the Category/Unit row's closing brace, immediately followed by the Stock/Min-stock row:

```qml
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: dp(Constants.space2)
                        AuthTextField {
                            id: stockField
                            Layout.fillWidth: true
                            label: qsTr("Initial stock")
                            placeholderText: "0"
                        }
                        AuthTextField {
                            id: minStockField
                            Layout.fillWidth: true
                            label: qsTr("Reorder at")
                            placeholderText: "2"
                        }
                    }
```

Replace with (adds the new field immediately before this row):

```qml
                    AuthTextField {
                        id: sizeField
                        Layout.fillWidth: true
                        label: qsTr("Size")
                        placeholderText: qsTr("e.g. M, L, XL, 500ml")
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: dp(Constants.space2)
                        AuthTextField {
                            id: stockField
                            Layout.fillWidth: true
                            label: qsTr("Initial stock")
                            placeholderText: "0"
                        }
                        AuthTextField {
                            id: minStockField
                            Layout.fillWidth: true
                            label: qsTr("Reorder at")
                            placeholderText: "2"
                        }
                    }
```

- [x] **Step 3: Pass `size` into `addProduct()`**

Find:

```qml
        var newId = InventoryStore.addProduct(nameField.text, skuField.text,
            categoryCombo.currentText, descField.text, p, unitCombo.currentText, s, ms, sp,
            taxable, taxable ? taxPercent : 0, supplierId, p /* unitCost = cost */)
```

Replace with:

```qml
        var newId = InventoryStore.addProduct(nameField.text, skuField.text,
            categoryCombo.currentText, descField.text, p, unitCombo.currentText, s, ms, sp,
            taxable, taxable ? taxPercent : 0, supplierId, p /* unitCost = cost */,
            sizeField.text.trim())
```

- [x] **Step 4: Commit**

```bash
git add qml/pages/AddProductDialog.qml
git commit -m "feat(product): add optional Size field to Add Product dialog"
```

---

### Task 5: `EditProductDialog.qml` — Size field UI + history label

**Files:**
- Modify: `qml/pages/EditProductDialog.qml`

**Interfaces:**
- Consumes: `p.size` (product field, Task 2). Emits `size` in `productUpdateRequested`'s `fields` object, consumed by `InventoryStore.updateProduct()` (Task 2).

No automated test — same reasoning as Task 4. Verified via the on-device test plan (Task 7).

- [x] **Step 1: Populate `sizeField` in `openFor()`**

Find:

```qml
            taxableCombo.currentIndex = p.taxable ? 1 : 0
            taxPercentField.text = (p.taxPercent !== undefined && p.taxPercent !== null) ? String(p.taxPercent) : "0"
            photoUrl = p.photoUrl || ""
```

Replace with:

```qml
            taxableCombo.currentIndex = p.taxable ? 1 : 0
            taxPercentField.text = (p.taxPercent !== undefined && p.taxPercent !== null) ? String(p.taxPercent) : "0"
            sizeField.text = p.size || ""
            photoUrl = p.photoUrl || ""
```

- [x] **Step 2: Add the Size field to the form**

Find:

```qml
        AuthTextField {
            id: descField
            Layout.fillWidth: true
            label: "Description"
            readOnly: !root.editMode
        }
```

Replace with:

```qml
        AuthTextField {
            id: sizeField
            Layout.fillWidth: true
            label: "Size"
            readOnly: !root.editMode
        }

        AuthTextField {
            id: descField
            Layout.fillWidth: true
            label: "Description"
            readOnly: !root.editMode
        }
```

(This places Size directly after the Category/Unit row and before Description, matching the placement in `AddProductDialog.qml` and the spec's B2 decision.)

- [x] **Step 3: Include `size` in the save handler**

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
            size: sizeField.text.trim(),
            stock: stk,
            minStock: ms
        })
```

- [x] **Step 4: Add `"size"` to the edit-history field-label map**

Find:

```qml
                case "taxPercent":   return qsTr("Tax %")
                case "minStock":     return qsTr("Min stock")
                default:              return field || qsTr("Field")
```

Replace with:

```qml
                case "taxPercent":   return qsTr("Tax %")
                case "size":         return qsTr("Size")
                case "minStock":     return qsTr("Min stock")
                default:              return field || qsTr("Field")
```

(No change needed in `_fieldFormat()` — a size change falls through to the existing default string formatter, same as `category`/`description`.)

- [x] **Step 5: Commit**

```bash
git add qml/pages/EditProductDialog.qml
git commit -m "feat(product): add optional Size field to Edit Product dialog + history label"
```

---

### Task 6: `ImportPreviewDialog.qml` — wire Taxable/Tax %/Size into import

**Files:**
- Modify: `qml/pages/ImportPreviewDialog.qml`

**Interfaces:**
- Consumes: `ImportMath.parseTaxableCell`/`parseTaxPercentCell` (Task 1). Produces `rec.taxable`/`rec.taxPercent`/`rec.size` on the record object passed into `InventoryStore.upsertMany()` (Task 2).

No automated test — the row-validation function lives inline in a page (`ImportPreviewDialog.qml`), which can't run under `qmltestrunner` per the existing project convention; the parsing logic itself already carries a test via Task 1's `ImportMath.js` extraction. Verified via the on-device test plan (Task 7).

- [x] **Step 1: Add the `ImportMath` import**

Verified: `ImportPreviewDialog.qml` does **not** currently import `ImportMath.js` (unlike
`InventoryStore.qml`, which already does) — it's not registered in `qml/helper/qmldir` either
(only `Constants`/`FormValidator`/`SafeArea` are singletons there), so it needs the same explicit
relative import `InventoryStore.qml` uses. Find:

```qml
import "../components"
import "../helper"
import "../model"
```

Replace with:

```qml
import "../components"
import "../helper"
import "../helper/ImportMath.js" as ImportMath
import "../model"
```

- [x] **Step 2: Read the three new columns into `rec`**

Find:

```qml
            // To-Do: There are no tax information getting exported.
            // We need to export tax information as well with the product details.
            var rec = {
                row: row,
                productId: pid,
                name: name,
                sku: sku,
                category: (r["Category"] || "").toString().trim(),
                unit: unit,
                description: (r["Description"] || "").toString(),
                price: cost,
                sellingPrice: sell,
                stock: parseInt(r["Stock"]) || 0,
                minStock: parseInt(r["Min Stock"]) || 0,
                photoUrl: (r["Photo URL"] || "").toString().trim(),
                supplier: (r["Supplier"] || "").toString().trim(),
                _conflictPolicy: "skip"
            }
```

Replace with:

```qml
            var rowTaxable = ImportMath.parseTaxableCell(r["Taxable"])
            var rec = {
                row: row,
                productId: pid,
                name: name,
                sku: sku,
                category: (r["Category"] || "").toString().trim(),
                unit: unit,
                description: (r["Description"] || "").toString(),
                price: cost,
                sellingPrice: sell,
                stock: parseInt(r["Stock"]) || 0,
                minStock: parseInt(r["Min Stock"]) || 0,
                photoUrl: (r["Photo URL"] || "").toString().trim(),
                supplier: (r["Supplier"] || "").toString().trim(),
                size: (r["Size"] || "").toString().trim(),
                taxable: rowTaxable,
                taxPercent: ImportMath.parseTaxPercentCell(r["Tax %"], rowTaxable),
                _conflictPolicy: "skip"
            }
```

- [x] **Step 3: Commit**

```bash
git add qml/pages/ImportPreviewDialog.qml
git commit -m "feat(import): read Size/Taxable/Tax % columns during product import preview"
```

---

### Task 7: On-device test plan doc

**Files:**
- Create: `docs/superpowers/test-plans/2026-07-10-on-device-test-plan-tax-size.md`

**Interfaces:** none — documentation only.

- [x] **Step 1: Write the on-device test plan**

Create `docs/superpowers/test-plans/2026-07-10-on-device-test-plan-tax-size.md` (matching the naming/structure of the existing `2026-06-19-on-device-test-plan-revenue-reconciliation.md` and `2026-06-21-custome-device-test-plan.md`):

```markdown
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
      still present (regression check for the `_clone()` whitelist fix in Task 2, Step 1: without
      it, Size would silently disappear here).

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
```

- [x] **Step 2: Commit**

```bash
git add docs/superpowers/test-plans/2026-07-10-on-device-test-plan-tax-size.md
git commit -m "docs: on-device test plan for tax export/import + Size field"
```

---

## Plan self-review notes

- **Spec coverage:** A1→Task 2 Step 5, A2→Task 2 Step 6 (no-op confirmed), A3→Task 6, A4→Task 3 Steps 1–3, A5→Task 3 Step 4, A6→confirmed no-op (Main.qml's `_exportProducts()` already clones every field generically). B1→Task 2 Steps 1,3,4,7. B2→Tasks 4–5. B3→Task 3 + Task 6. B4→intentionally not built (spec Decision). All spec workstreams have a task.
- **Placeholder scan:** no TBD/TODO/"add appropriate X" phrasing in any step; every step shows exact before/after code.
- **Type consistency:** `size` is a plain JS string everywhere (QML) and a `QString`/`QVariant` in C++ — no cross-task mismatch. `ImportMath.parseTaxableCell`/`parseTaxPercentCell` signatures used identically in Task 1's tests and Task 6's consumption.
- **Gap found and fixed during planning (not in the original spec):** `InventoryStore._clone()`'s field whitelist would have silently dropped `size` on every subsequent mutation. Added as Task 2 Step 1 and called out explicitly in the spec (already amended) and in the on-device test plan (Task 7, §1) as its own regression check.
