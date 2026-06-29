# Design: Import/Export fidelity, post-import analytics, history & per-item discount

**Date:** 2026-06-21
**Status:** Approved (pending written-spec review)
**Scope:** 17 device-reported defects across data import, export, analysis reports, activity/history, the order-discount model, and bar-chart labels.

---

## 1. Problem statement

After importing products and orders from xlsx, large parts of the app read empty:

- Value, Purchased, Sold, Realised & Potential profit reports all show **0**.
- Current-stock "by party (supplier)" shows **0**; Revenue has no by-supplier breakdown.
- No recent-activity entry for an import; no history rows inside imported products/orders.

Separately: order export omits SKU and staff; product/order README mandatory-column lists are wrong; bar-chart value labels sit at the top of bars; order history hides SKU and some reason notes; the new-order product picker keeps stale "available" counts after cancel; and discount is modelled at the order level rather than per item.

### Root cause (items 1–8)

In-app creation writes **three side-effect stores** that every report and history view reads:

- `InventoryStore.addProduct()` → `TransactionStore.recordCreated()` + `StockBatchStore.addBatch()` + `ActivityLog.record()`.
- `DataModel._tryCompleteOrder()` → FIFO stock consumption (populates `order.products[].consumption[]`) + `TransactionStore.recordSaleFromOrder()`.

The import path (`InventoryStore.upsertMany()`, `OrdersStore.upsertMany()`) writes **only** the `products`/`orders` arrays (via `Gateway.recordMutation`). So imported products have **no stock batches** (→ Value / Potential profit / Current-by-supplier read `StockBatchStore.batches[].unitCost`/`.supplierId` = 0) and **no "created" transaction** (→ Purchased reads `kind:"created"|"purchase"` = 0); imported "completed" orders have **no "sale" transaction and no consumption lineage** (→ Sold / Realised profit / Revenue-by-supplier = 0).

---

## 2. Decisions (locked with product owner, 2026-06-21)

| # | Decision |
|---|---|
| Tax in revenue (16) | **Keep net.** Revenue stays net (subtotal − discount, tax excluded) everywhere — no chart values change. Add an explicit **"Tax collected"** figure as a separate export column (and where gross is shown). |
| Discount model (17) | **Per-line only.** Add per-line discount; **remove** the order-level discount field entirely. No legacy/back-compat — app is in MVP fresh-data phase (Firestore wiped & re-tested). |
| Supplier/batch (3) | **Supplier column + opening batch.** Add a "Supplier" column to product export/import. On import create **one opening stock batch** per product (qty=Stock, unitCost=Cost Price, supplierId from Supplier column) + a "created" txn. **No** per-batch export sheet. |
| Import history (7, 8) | **Full events, tagged `imported`.** Import generates the same `created`/opening-stock and `sale`+consumption events as in-app creation, plus one Recent-Activity summary entry. |
| Import understock | **Complete + report shortfall.** An imported "completed" order with insufficient stock completes anyway (consume what's available; remainder consumed at zero/unknown cost) and is counted in the import result summary as "X completed with insufficient stock". |

---

## 3. Workstreams

### A. Import writes full lineage — items 1, 2, 5, 6, 7, 8 (+ data half of 3, 4)

**A1. Products — `InventoryStore.upsertMany()` (`qml/model/InventoryStore.qml`).**
For every record that results in an **add** (new row or `rename` policy), after pushing the doc, mirror `addProduct()`'s side-effects:
- Resolve `supplierId` from the record's `supplier` (name) via the existing `_resolveSupplierId()` (creates the supplier if the name is new).
- `TransactionStore.recordCreated(id, name, stock, batchCost, {snapshot…, supplierId}, supplierId)` with `reason`/origin tag `"imported"`.
- If `stock > 0`: `StockBatchStore.addBatch(id, supplierId, stock, batchCost, "Imported opening stock")`, where `batchCost = price` (Cost Price).
- For **overwrite** of an existing product, do **not** synthesize a new opening batch (would double-count stock). Overwrite stays a field merge only. (If stock changed on overwrite, that is out of scope for this pass — documented limitation; opening batches are an add-time concept.)
- `_normalizeRecord()` / `_mergeRecord()` gain a `supplierId` field so it round-trips.

To avoid N Firebase round-trips and N revision bumps, the per-product `addBatch`/`recordCreated` calls follow the **same batching the stores already use** (accumulate in-memory, commit/push once). Verify `StockBatchStore.addBatch` and `TransactionStore.recordCreated` either already coalesce or add a bulk variant used by the import loop. **One** `products =` assignment at the end (already the case).

**A2. Orders — `OrdersStore.upsertMany()` + a completion hook.**
Imported orders with `status === "completed"` must run the same completion math as the UI. Because `upsertMany` lives in the store and the orchestration lives in `DataModel._tryCompleteOrder()`, the import flow (`ImportPreviewDialog._apply()` in `qml/pages/ImportPreviewDialog.qml`) will, after `OrdersStore.upsertMany()` returns, iterate the newly-added completed orders and route each through a `DataModel.completeImportedOrder(orderId)` method that:
- runs FIFO consumption against current batches (reusing the existing consumption routine), populating `order.products[].consumption[]`;
- on shortfall, consumes what's available and records the remainder at zero/unknown unit cost (so `sale` events still stamp `net`), and increments an `understocked` counter returned to the dialog;
- calls `TransactionStore.recordSaleFromOrder(order)`;
- leaves non-completed imported orders untouched.

**A3. Activity summary (item 7).** After a successful import, emit one `ActivityLog.record("import", "Imported N products · M orders", subtitle, "")` entry. Add `kind:"import"` to the icon/palette maps in `DashboardPage.qml` and `ActivityPage.qml`.

**A4. Supplier column in import (item 3 data half).** `ImportPreviewDialog._validateProductRows()` reads a new `"Supplier"` column into `record.supplier`; passed through `upsertMany` → `_resolveSupplierId`.

**Reports fixed for free** once A1–A2 land: Value, Purchased, Sold, Realised profit, Potential profit, Current-stock-by-supplier, Revenue-by-supplier — they already read the three side-effect stores correctly; they were starved of data, not miscomputing.

### B. Export fidelity + README — items 3, 9, 10, 11, 12 (`src/XlsxService.cpp`)

**B1. Orders SKU (10).** `writeOrdersSheet()` line ~150 hardcodes `const QString sku;` (empty). Populate the SKU column from each line. Source: have the QML caller (`Main.qml::_exportOrders`) attach `sku` per line by looking up `InventoryStore.getById(line.productId).sku`, OR pass the products array to `writeOrders` and resolve in C++. **Chosen:** resolve in QML (keeps C++ dumb), add `sku` to each line object before calling `XlsxService.writeOrders`.

**B2. Order staff (9).** Add a **"Staff"** column to `kOrderHeaders` and `writeOrdersSheet()`. QML attaches a `staffName` (resolved from `staffId` via `StaffStore`) to the order before export; C++ writes it. README documents it as optional.

**B3. Product Supplier (3).** Add a **"Supplier"** column to `kProductHeaders` + `writeProductsSheet()`. QML attaches `supplierName` (from `supplierId` via `SupplierStore`) per product. Import reads it back (A4).

**B4. Tax collected (16).** Orders export already has per-line `Line Tax` and order `Order Tax`. Confirm a clear total "Tax collected" is present in the analysis export (`buildAnalysisExport`/`buildAnalysisWorkbook` in `SalesPage.qml`); add a column if missing. No revenue redefinition.

**B5. README mandatory columns (11, 12).** In `writeReadmeSheet()`, the README documents the owner's mandatory-column lists (header marked `*`):
- **Products:** Name, SKU, Unit, Cost Price, Selling Price, Min Stock.
- **Orders:** Customer, Status, Date, SKU, Quantity, Unit Price.

**B6. Import validation contract (finalized 2026-06-22).** `ImportPreviewDialog` validation distinguishes *hard-reject* fields (block the row, surface in preview errors) from *defaulted-with-warning* fields. Decisions:

| Field | Rule |
| --- | --- |
| **Product: identifier** | **Hard-reject** the row if BOTH SKU and Product ID are empty. (Either one suffices.) |
| **Product: Cost Price** | **Hard-reject** the row if empty/non-numeric. (Needed for Value/Purchased/Profit + opening-batch unitCost.) |
| **Product: Name** | Hard-reject if empty / <2 chars (already enforced). |
| **Product: Selling Price** | Hard-reject if ≤0 or < Cost Price (already enforced). |
| **Product: Unit** | **Default + warn** → `"Units (pcs)"`. |
| **Product: SKU (when PRD ID present)** | **Default + warn** → auto-generate SKU. |
| **Order: Customer** | Hard-reject the order if empty (already enforced). |
| **Order line: identifier** | **Hard-reject** the line if BOTH Product ID and SKU empty. |
| **Order line: Quantity** | **Reject that LINE + warn** (keep the rest of the order). Never fabricate qty. |
| **Order line: Unit Price** | **Default + warn** → fall back to the product's CURRENT Selling Price. Report that historical price may differ. |
| **Order: Date** | **Default + warn** → import day (today). Report that the order lands in today's time-bucket. |
| **Order/Product: SKU (other id present)** | **Default + warn** → resolve/auto-generate. |

The import preview must **convey to the user** that defaulted/rejected fields are missing and that this *degrades analysis accuracy* (wrong time-bucket for defaulted dates; current-vs-historical price for defaulted unit price; dropped lines reduce Sold/Revenue). Warnings are aggregated per category in the preview summary, not one dialog per row.

### C. Per-item discount + tax line — items 16, 17

**C1. Data shape.** Order line item gains `discountType` ("flat"|"percent") and `discountValue` (number). The **order-level** `discountType`/`discountValue` fields are **removed** from the order shape, `NewOrderDialog`, `OrderDetailDialog`, `OrdersStore._normalizeOrder`, and `computeOrderTotals`.

**C2. `OrderMath.allocate()` (`qml/helper/OrderMath.js`).** Replace the order-level discount block (lines 20–31) and per-line `discShare` (line 42) with per-line computation:
- For each line: `lineDiscount = discountType==="percent" ? gross*clamp(value,0,100)/100 : clamp(value,0,gross)`.
- `discShare` for the line = its own `lineDiscount` (no pro-rata across the order).
- Order `discount` total = Σ line discounts. `net`, `tax`, `total`, per-consumption split: unchanged formulas (the per-consumption proportional split by `qtyConsumed/qty` still applies to the line's own net/tax/discount).
- Reconciliation invariant preserved: Σ line net + Σ line discount = subtotal; total = net + tax.

**C3. `spreadOrderDelta` / `spreadLineDeltaBySupplier`.** A discount change is now inherently per-line, so a discount edit on a completed order emits a **per-line** `price_adjust` (real `productId`, `reason:"discount"`) → routed through `spreadLineDeltaBySupplier` (the existing per-line path). The order-wide-discount branch of `spreadOrderDelta` (productId "") becomes unused for discounts; keep the function (still used for any order-wide delta) but the discount-edit caller in `DataModel` switches to the per-line event.

**C4. History event (17).** Editing a line's discount on a completed order appends a `price_adjust` event carrying that line's `productId` + `reason:"discount"` + note (`"discount X→Y on <product>"`), so it appears in **both** the product's history (`TransactionStore.forProduct`) and the order's history (`TransactionStore.forOrder`).

**C5. UI.** `NewOrderDialog` and `OrderDetailDialog`: remove the order-level discount input; add a per-line discount entry (type toggle + value) in the line editor. Picker line label may show the post-discount line total.

**C6. Export (17).** Orders sheet replaces order-level "Discount Type"/"Discount Value" columns with **per-line** "Discount Type"/"Discount Value" columns; "Order Discount" stays as the computed sum.

**C7. Tax (16).** No revenue change. Ensure a "Tax collected" total surfaces in exports (B4).

### D. Order history & picker — items 14, 15

**D1. SKU in order history (14).** In `OrderDetailDialog.qml` history rows, resolve `InventoryStore.getById(e.productId)?.sku` and render it on each line (where `e.productId` is non-empty).

**D2. Reason note always shown (14).** `_detailFor(e)` currently suppresses the reason label for `reason === "reopened"`. Change so the **note text** is always shown for any reason category that carries one (reopened/exchange/modify/discount/other). Keep the reason label logic but never drop a present note.

**D3. Picker reset on close (15).** `NewOrderDialog` resets state in `onOpened` but has no `onClosed`, so a cancelled dialog leaves `selectedProducts`/discount/customer fields populated; the available-count (`stock − _inCartQty`) is computed off that stale cart on the next interaction before `onOpened` fully rebuilds. Add an explicit reset (clear `selectedProducts`, discount fields, customer/email/phone, `currentIndex=0`, `_rebuildPickerNames()`) wired to the dialog's close lifecycle so cancel→reopen always starts clean. Verify the picker "avail N" recomputes from fresh state.

### E. Bar-chart label position — item 13 (`qml/components/BreakdownBarCard.qml`)

The value label (lines ~141–154) is anchored `bottom: parent.bottom` but for tall bars (`_labelInside` when `_barH > dp(22)`) uses `bottomMargin = _barH − dp(16)`, placing it near the **top** interior. Change so the number renders **at the bottom of the bar** (just above the x-axis baseline, inside the bar) for tall bars; keep short-bar labels readable (float above, unchanged). Adjust the `_labelInside` margin to a small bottom offset (e.g. `dp(2)`–`dp(4)`).

---

## 4. Files touched

| File | Workstream |
|---|---|
| `qml/model/InventoryStore.qml` | A1, A4 (upsert side-effects, supplierId field) |
| `qml/model/OrdersStore.qml` | A2, C1 (completed-import hook surface, drop order discount) |
| `qml/model/DataModel.qml` | A2 (`completeImportedOrder`), C3/C4 (per-line discount event) |
| `qml/pages/ImportPreviewDialog.qml` | A2, A3, A4 (supplier col, completion loop, activity summary) |
| `qml/model/ActivityLog.qml` | A3 (`import` kind, if any enum guard) |
| `qml/pages/DashboardPage.qml`, `qml/pages/ActivityPage.qml` | A3 (icon/palette for `import`) |
| `src/XlsxService.cpp` / `.h` | B1–B5 (SKU, Staff, Supplier cols, README) |
| `qml/Main.qml` | B1–B3 (attach sku/staffName/supplierName before export) |
| `qml/helper/OrderMath.js` | C2 (per-line discount allocation) |
| `qml/pages/NewOrderDialog.qml` | C5, D3 (per-line discount UI, picker reset) |
| `qml/pages/OrderDetailDialog.qml` | C5, D1, D2 (per-line discount UI, SKU + note in history) |
| `qml/components/BreakdownBarCard.qml` | E (label position) |
| `tests/tst_OrderMath.qml` (new) | C2 reconciliation tests |

---

## 5. Testing

- **Unit (headless, qmltestrunner):** new `tests/tst_OrderMath.qml` over `OrderMath.allocate()` — per-line flat & percent discount; mixed taxable lines; reconciliation (Σ line net + Σ discount = subtotal; total = net + tax); per-consumption split still sums to line net.
- **Manual on-device plan** (page-level QML can't run headless): a `docs/.../on-device test plan` covering: import products+orders → verify Value/Purchased/Sold/Profit/Current-by-supplier/Revenue-by-supplier all populate; recent-activity shows the import entry; product & order detail show imported history; export products & orders → verify SKU, Staff, Supplier columns populated and README mandatory lists correct; per-line discount create + edit → history shows discount event in product and order; understocked completed import → reported in summary; bar labels at bottom.

## 6. Regression guardrails

- Revenue/profit math unchanged (net convention locked) — only the discount *source* moves from order-level to per-line; allocation output shape is the same.
- Import overwrite path does **not** create duplicate opening batches (add-only).
- Import side-effects batch their writes (no N× Firebase pushes / revision storms).
- `eventProfit` and `spreadLineDeltaBySupplier` are reused as-is; no re-allocation of mutated orders.
- MVP fresh-data: no migration code; old order-level-discount documents are not supported by design.
