pragma Singleton
import QtQuick

QtObject {
    id: root

    property var products: []

    // Bumped whenever `products` is reassigned. Consumers (DashboardPage,
    // InventoryPage) bind a watcher property to this to trigger their own
    // recomputation — Repeater/ColumnLayout sometimes lags on a bare
    // products-change signal, but a numeric revision flips reliably.
    property int revision: 0
    onProductsChanged: revision++

    Component.onCompleted: _load()

    function _load() {
        products = [];
        _fetchFromFirebase();
    }

    function _fetchFromFirebase() {
        FirebaseService.get("inventory", function(ok, data) {
            if (ok) {
                var arr = FirebaseService.toArray(data);
                // Normalize backend field names to local schema
                for (var i = 0; i < arr.length; ++i) {
                    var p = arr[i];
                    if (p.product_id && !p.productId) p.productId = p.product_id;
                    if (p.currentStock !== undefined && p.stock === undefined) p.stock = p.currentStock;
                    if (p.minimumStock !== undefined && p.minStock === undefined) p.minStock = p.minimumStock;
                    if (!p.sku) p.sku = "";
                    if (!p.category) p.category = "";
                    if (!p.unit) p.unit = "pcs";
                    if (!p.description) p.description = "";
                    // `price` is COST. `sellingPrice` is what customers pay.
                    // Default sellingPrice to cost for legacy docs that pre-date this field.
                    if (p.sellingPrice === undefined || p.sellingPrice === null) p.sellingPrice = p.price || 0;
                    if (p.taxable === undefined || p.taxable === null) p.taxable = false;
                    if (p.taxPercent === undefined || p.taxPercent === null) p.taxPercent = 0;
                    if (!p.photoUrl) p.photoUrl = "";
                    if (!p.photoUpdatedAt) p.photoUpdatedAt = "";
                }
                products = arr;
                console.log("[InventoryStore] Synced", arr.length, "products from Firestore");
            } else {
                console.warn("[InventoryStore] Firestore sync failed", FirebaseService.lastStatusCode, FirebaseService.lastError)
            }
        });
    }

    function _pushAllToFirebase() {
        var obj = {};
        for (var i = 0; i < products.length; ++i)
            obj[products[i].productId] = products[i];
        FirebaseService.put("inventory", obj, function(ok) {
            if (!ok)
                console.warn("[InventoryStore] Firestore bulk write failed", FirebaseService.lastStatusCode, FirebaseService.lastError)
            else
                console.log("[InventoryStore] Firestore bulk write ok, documents:", products.length)
        });
    }

    function syncFromFirebase() { _fetchFromFirebase(); }

    function clear() {
        products = []
    }

    function _commit(arr) {
        products = arr;
        _pushAllToFirebase();
    }

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
        }
        return a;
    }

    function totalProducts() { return products.length; }

    function lowStockCount() {
        var c = 0;
        for (var i = 0; i < products.length; ++i)
            if (products[i].stock <= products[i].minStock) c++;
        return c;
    }

    function totalItems() {
        var c = 0;
        for (var i = 0; i < products.length; ++i)
            c += products[i].stock;
        return c;
    }

    // FIFO inventory value. Walks open batches (qtyRemaining > 0) and
    // multiplies each by its captured unit cost — survives multi-supplier
    // restocking + price-change scenarios correctly. Falls back to the
    // legacy `stock × price` formula when no batches exist yet (e.g. at
    // the moment of first launch before the FIFO migration completes).
    function totalValue() {
        var bs = (typeof StockBatchStore !== "undefined" && StockBatchStore)
                ? (StockBatchStore.batches || [])
                : []
        if (bs.length === 0) {
            var legacy = 0
            for (var i = 0; i < products.length; ++i)
                legacy += (products[i].stock || 0) * (products[i].price || 0)
            return legacy
        }
        var v = 0
        for (var bi = 0; bi < bs.length; ++bi) {
            var b = bs[bi]
            v += (b.qtyRemaining || 0) * (b.unitCost || 0)
        }
        return v
    }

    // ── Value & profit aggregator helpers ────────────────────────────────
    // All of these return a `{ key → value }` map. They walk the batch
    // ledger or the transaction log without any allocation churn — fine to
    // call from a binding because the result map is recreated each call;
    // the page consumes it through a `_invWatcher` revision trigger.

    // Inventory value by productId (current snapshot).
    function valueByProduct() {
        var out = {}
        var bs = (typeof StockBatchStore !== "undefined" && StockBatchStore)
                ? (StockBatchStore.batches || []) : []
        for (var i = 0; i < bs.length; ++i) {
            var b = bs[i]
            var v = (b.qtyRemaining || 0) * (b.unitCost || 0)
            if (v <= 0) continue
            out[b.productId] = (out[b.productId] || 0) + v
        }
        return out
    }

    // Inventory value by supplierId. Empty key "" rolls up batches with no
    // recorded supplier so the report still balances against totalValue().
    function valueBySupplier() {
        var out = {}
        var bs = (typeof StockBatchStore !== "undefined" && StockBatchStore)
                ? (StockBatchStore.batches || []) : []
        for (var i = 0; i < bs.length; ++i) {
            var b = bs[i]
            var v = (b.qtyRemaining || 0) * (b.unitCost || 0)
            if (v <= 0) continue
            out[b.supplierId || ""] = (out[b.supplierId || ""] || 0) + v
        }
        return out
    }

    // Inventory value by category — joins batches → product → category.
    function valueByCategory() {
        var out = {}
        var bs = (typeof StockBatchStore !== "undefined" && StockBatchStore)
                ? (StockBatchStore.batches || []) : []
        for (var i = 0; i < bs.length; ++i) {
            var b = bs[i]
            var v = (b.qtyRemaining || 0) * (b.unitCost || 0)
            if (v <= 0) continue
            var p = getById(b.productId)
            var cat = (p && p.category) ? p.category : "(uncategorised)"
            out[cat] = (out[cat] || 0) + v
        }
        return out
    }

    // Realised profit over completed sales, grouped on the requested
    // dimension. Returns `{ key → { revenue, cogs, profit, margin } }`.
    // `field` ∈ "productId" | "supplierId" | "category" | "channel" | "staffId".
    //
    // Revenue uses the sale's per-line `unitPrice`; COGS uses each
    // consumption[]'s captured `unitCost` (which is FIFO-correct because
    // batches snapshot cost at receipt time). Margin = profit / revenue.
    function realisedProfitByDimension(field) {
        var out = {}
        var entries = (typeof TransactionStore !== "undefined" && TransactionStore)
                ? (TransactionStore.entries || []) : []
        for (var i = 0; i < entries.length; ++i) {
            var e = entries[i]
            if (e.kind !== "sale") continue
            var unitPrice = e.unitPrice || 0
            var c = e.consumption || []
            // For category, look up the product's category once per row.
            var rowCategory = null
            if (field === "category") {
                var pp = getById(e.productId)
                rowCategory = (pp && pp.category) ? pp.category : "(uncategorised)"
            }
            for (var ci = 0; ci < c.length; ++ci) {
                var cc = c[ci]
                var qty = cc.qtyConsumed || 0
                if (qty <= 0) continue
                var revenue = qty * unitPrice
                var cogs = qty * (cc.unitCost || 0)
                var key
                if (field === "productId")      key = e.productId || ""
                else if (field === "supplierId") key = cc.supplierId || ""
                else if (field === "channel")    key = e.orderChannel || ""
                else if (field === "staffId")    key = e.staffId || ""
                else                              key = rowCategory
                if (!out[key]) out[key] = { revenue: 0, cogs: 0, profit: 0, margin: 0 }
                out[key].revenue += revenue
                out[key].cogs    += cogs
                out[key].profit  += (revenue - cogs)
            }
        }
        // Compute margin% in a second pass — avoids divide-by-zero on rows
        // whose revenue is 0 (consumption-only legacy events).
        var keys = Object.keys(out)
        for (var k = 0; k < keys.length; ++k) {
            var row = out[keys[k]]
            row.margin = row.revenue > 0 ? (row.profit / row.revenue) * 100 : 0
        }
        return out
    }

    // Potential profit on open stock — for each open batch, value at the
    // product's current sellingPrice minus the batch's captured unitCost.
    // Same return shape as realisedProfitByDimension. `field` ∈
    // "productId" | "supplierId" | "category".
    function potentialProfitByDimension(field) {
        var out = {}
        var bs = (typeof StockBatchStore !== "undefined" && StockBatchStore)
                ? (StockBatchStore.batches || []) : []
        for (var i = 0; i < bs.length; ++i) {
            var b = bs[i]
            var qty = b.qtyRemaining || 0
            if (qty <= 0) continue
            var p = getById(b.productId)
            var sell = p ? (p.sellingPrice !== undefined ? p.sellingPrice : (p.price || 0)) : 0
            var cost = b.unitCost || 0
            var revenue = qty * sell
            var cogs = qty * cost
            var key
            if (field === "productId")      key = b.productId || ""
            else if (field === "supplierId") key = b.supplierId || ""
            else if (field === "category")   key = (p && p.category) ? p.category : "(uncategorised)"
            else                              key = ""
            if (!out[key]) out[key] = { revenue: 0, cogs: 0, profit: 0, margin: 0 }
            out[key].revenue += revenue
            out[key].cogs    += cogs
            out[key].profit  += (revenue - cogs)
        }
        var keys = Object.keys(out)
        for (var k = 0; k < keys.length; ++k) {
            var row = out[keys[k]]
            row.margin = row.revenue > 0 ? (row.profit / row.revenue) * 100 : 0
        }
        return out
    }

    function formatCurrency(val) {
        var n = typeof val === 'number' ? val : parseFloat(String(val).replace(/[^0-9.]/g, ''));
        if (isNaN(n)) n = 0;
        try { return new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(n); }
        catch(e) { return '₹' + Math.round(n).toString(); }
    }

    function nextProductId() {
        var max = 0;
        for (var i = 0; i < products.length; ++i) {
            var num = parseInt(String(products[i].productId).split('-')[1]);
            if (!isNaN(num) && num > max) max = num;
        }
        return 'PRD-' + String(max + 1).padStart(3, '0');
    }

    function generateSku(name) {
        if (!name || name.length < 2) return "";
        var words = name.trim().split(/\s+/);
        var prefix = "";
        for (var i = 0; i < Math.min(words.length, 2); ++i)
            prefix += words[i].charAt(0).toUpperCase();
        var year = new Date().getFullYear();
        var num = String(products.length + 1).padStart(3, '0');
        return prefix + "-" + year + "-" + num;
    }

    // The `party` legacy argument is now treated as a SUPPLIER ID for new
    // callers; old callers that still pass a name string are routed via
    // SupplierStore.findByName/addSupplier so legacy code paths keep working.
    // `unitCost` is the cost-per-unit of the initial-stock batch (defaults
    // to product cost `price` when not supplied — matches the previous
    // implicit assumption).
    function addProduct(name, sku, category, description, price, unit, stock, minStock, sellingPrice, taxable, taxPercent, party, unitCost) {
        var id = nextProductId();
        var arr = _clone();
        var sp = (sellingPrice !== undefined && sellingPrice !== null) ? sellingPrice : price;
        var tx = !!taxable;
        var tp = (typeof taxPercent === "number" && !isNaN(taxPercent)) ? taxPercent : 0;
        arr.push({ productId: id, name: name, sku: sku, category: category,
                   stock: stock, minStock: minStock,
                   price: price, sellingPrice: sp,
                   taxable: tx, taxPercent: tp,
                   unit: unit, description: description || "",
                   photoUrl: "", photoUpdatedAt: "" });
        _commit(arr);
        ActivityLog.record("product_added",
                           "Product added: " + name,
                           (sku ? sku + " · " : "") + "stock " + stock,
                           id);
        // Resolve the `party` arg into a stable supplierId. Accepts either
        // an existing supplierId, a known name, or a brand-new name (which
        // we promote to a SupplierStore record on the fly).
        var supplierId = _resolveSupplierId(party);
        var batchCost = (typeof unitCost === "number" && !isNaN(unitCost)) ? unitCost : (price || 0);

        // Always record creation (even with 0 initial stock) so the product
        // details "History" section opens with a true creation row instead of
        // looking like the product was restocked.
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

        // Initial stock is treated as the first FIFO batch. Skip when stock
        // is 0 — there's nothing to consume from a zero-quantity batch.
        if (stock > 0) {
            StockBatchStore.addBatch(id, supplierId, stock, batchCost, "Initial stock");
        }
        return id;
    }

    // Internal: turn a free-text "party" argument into a stable supplierId.
    // Empty input returns "". A name that already maps to a supplier returns
    // that id. A new name promotes the supplier on the fly so legacy call
    // sites (which haven't been updated to pass an id) still produce
    // first-class supplier records.
    function _resolveSupplierId(party) {
        if (!party) return "";
        var raw = String(party);
        // Already an id?
        if (raw.indexOf("SUP-") === 0) {
            var byId = SupplierStore.getById(raw);
            return byId ? byId.supplierId : raw;
        }
        var byName = SupplierStore.findByName(raw);
        if (byName) return byName.supplierId;
        var created = SupplierStore.addSupplier({ name: raw });
        return created ? created.supplierId : "";
    }

    // Persist a photo URL on a product. Per-doc PATCH bypasses the bulk-PUT
    // path so the write is always atomic.
    function setPhoto(productId, photoUrl) {
        var idx = findIndexById(productId);
        if (idx < 0) return;
        var arr = _clone();
        var prevUrl = arr[idx].photoUrl || "";
        var newUrl = photoUrl || "";
        arr[idx].photoUrl = newUrl;
        arr[idx].photoUpdatedAt = new Date().toISOString();
        products = arr;
        if (prevUrl !== newUrl)
            TransactionStore.recordPhotoChange(productId, arr[idx].name, prevUrl, newUrl);
        FirebaseService.put("inventory/" + productId, arr[idx], function(ok) {
            if (!ok) console.warn("[InventoryStore] Firestore photo write failed for", productId);
        });
    }

    // Bulk import / upsert. Records carry the same shape as products plus an
    // optional `_conflictPolicy` string ("skip" | "overwrite" | "rename").
    // Returns { added, updated, skipped } counts.
    function upsertMany(records) {
        var counts = { added: 0, updated: 0, skipped: 0 };
        if (!records || records.length === 0) return counts;

        var arr = _clone();
        var byId = {};
        var bySku = {};
        for (var i = 0; i < arr.length; ++i) {
            byId[arr[i].productId] = i;
            if (arr[i].sku) bySku[arr[i].sku.toLowerCase()] = i;
        }

        for (var k = 0; k < records.length; ++k) {
            var r = records[k];
            var policy = r._conflictPolicy || "skip";

            // Resolve conflict by id first, then by SKU
            var existingIdx = -1;
            if (r.productId && byId[r.productId] !== undefined)
                existingIdx = byId[r.productId];
            else if (r.sku && bySku[r.sku.toLowerCase()] !== undefined)
                existingIdx = bySku[r.sku.toLowerCase()];

            if (existingIdx >= 0) {
                if (policy === "skip") { counts.skipped++; continue; }
                if (policy === "rename") {
                    // Treat as new: assign fresh id and unique SKU
                    r.productId = nextProductId();
                    if (r.sku) r.sku = r.sku + "-" + counts.added + 1;
                    arr.push(_normalizeRecord(r));
                    byId[r.productId] = arr.length - 1;
                    if (r.sku) bySku[r.sku.toLowerCase()] = arr.length - 1;
                    counts.added++;
                    continue;
                }
                // overwrite
                var existing = arr[existingIdx];
                arr[existingIdx] = _mergeRecord(existing, r);
                FirebaseService.put("inventory/" + existing.productId, arr[existingIdx], function(ok) {
                    if (!ok) console.warn("[InventoryStore] import overwrite write failed");
                });
                counts.updated++;
            } else {
                // New row
                if (!r.productId || r.productId.length === 0) {
                    // Reserve next id without recursing into nextProductId on the
                    // mutated arr (safe — nextProductId reads `products` only).
                    products = arr;
                    r.productId = nextProductId();
                }
                var doc = _normalizeRecord(r);
                arr.push(doc);
                byId[doc.productId] = arr.length - 1;
                if (doc.sku) bySku[doc.sku.toLowerCase()] = arr.length - 1;
                FirebaseService.put("inventory/" + doc.productId, doc, function(ok) {
                    if (!ok) console.warn("[InventoryStore] import add write failed");
                });
                counts.added++;
            }
        }

        products = arr;
        return counts;
    }

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
            photoUpdatedAt: r.photoUpdatedAt || ""
        };
    }

    function _mergeRecord(existing, incoming) {
        var merged = {};
        var keys = ["productId", "name", "sku", "category", "unit", "description",
                    "price", "sellingPrice", "taxable", "taxPercent",
                    "stock", "minStock", "photoUrl", "photoUpdatedAt"];
        for (var i = 0; i < keys.length; ++i) {
            var k = keys[i];
            // Empty incoming values fall back to existing — empty cells in the
            // import sheet shouldn't blow away data.
            var v = incoming[k];
            var isEmpty = v === undefined || v === null
                       || (typeof v === "string" && v.length === 0);
            merged[k] = isEmpty ? existing[k] : v;
        }
        // Recompute numeric fields safely
        merged.price = typeof merged.price === "number" ? merged.price : parseCurrency(merged.price);
        merged.sellingPrice = typeof merged.sellingPrice === "number"
            ? merged.sellingPrice
            : parseCurrency(merged.sellingPrice);
        merged.taxable = !!merged.taxable;
        merged.taxPercent = typeof merged.taxPercent === "number"
            ? merged.taxPercent
            : parseCurrency(merged.taxPercent);
        merged.stock = parseInt(merged.stock) || 0;
        merged.minStock = parseInt(merged.minStock) || 0;
        return merged;
    }

    function parseCurrency(val) {
        if (typeof val === "number") return val;
        if (!val) return 0;
        var n = parseFloat(String(val).replace(/[^0-9.\-]/g, ""));
        return isNaN(n) ? 0 : n;
    }

    // Markup % = (selling - cost) / cost — the retailer's "I price 30% above
    // what I paid" framing. Returns 0 when cost is 0 (can't divide).
    function averageMarkupPercent() {
        var sum = 0; var n = 0;
        for (var i = 0; i < products.length; ++i) {
            var p = products[i];
            var cost = p.price || 0;
            var sp = p.sellingPrice !== undefined ? p.sellingPrice : cost;
            if (!cost || cost <= 0) continue;
            sum += (sp - cost) / cost;
            n++;
        }
        return n > 0 ? Math.round((sum / n) * 100) : 0;
    }

    function markupPercentFor(p) {
        var cost = p.price || 0;
        var sp = p.sellingPrice !== undefined ? p.sellingPrice : cost;
        if (!cost || cost <= 0) return 0;
        return Math.round(((sp - cost) / cost) * 100);
    }

    function deleteProduct(productId) {
        var arr = _clone();
        var found = false
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === productId) { arr.splice(i, 1); found = true; break; }
        }
        products = arr
        if (!found) return

        FirebaseService.remove("inventory/" + productId, function(ok) {
            if (!ok) console.warn("[InventoryStore] Firestore delete failed for", productId)
        })
    }

    // `party` may be a supplierId, an existing supplier name, or a brand-new
    // name we'll auto-promote. `unitCost` is cost-per-unit at receipt time
    // and defaults to the product's cost field (`changed.price`) when the
    // caller didn't capture it (e.g. legacy restock paths).
    function restock(productId, amount, party, unitCost) {
        var arr = _clone();
        var changed = null;
        var addedQty = amount || 10;
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === productId) {
                arr[i].stock += addedQty;
                changed = arr[i];
                break;
            }
        }
        products = arr;
        if (!changed) return

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
        FirebaseService.put("inventory/" + productId, changed, function(ok) {
            if (!ok)
                console.warn("[InventoryStore] Firestore restock failed for", productId,
                             FirebaseService.lastStatusCode, FirebaseService.lastError)
        });
    }

    function stockStatus(p) {
        return p.stock <= p.minStock ? "Low Stock" : "In Stock";
    }

    function stockPercent(p) {
        var maxStock = Math.max(p.minStock * 3, 100);
        return Math.min(1.0, p.stock / maxStock);
    }

    function deductStock(productId, qty) {
        var arr = _clone();
        var changed = null;
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === productId) {
                arr[i].stock = Math.max(0, arr[i].stock - qty);
                changed = arr[i];
                break;
            }
        }
        products = arr;
        if (!changed) {
            console.warn("[InventoryStore] deductStock: no product with id", productId)
            return
        }
        // Per-doc PATCH so the write definitely lands in Firestore. The bulk
        // _pushAllToFirebase path used to be racy when several deductions ran
        // back-to-back from order completion.
        FirebaseService.put("inventory/" + productId, changed, function(ok) {
            if (!ok)
                console.warn("[InventoryStore] Firestore deduct failed for", productId,
                             FirebaseService.lastStatusCode, FirebaseService.lastError)
            else
                console.log("[InventoryStore] Deducted stock for", productId, "→", changed.stock)
        });
    }

    function findIndexById(productId) {
        for (var i = 0; i < products.length; ++i)
            if (products[i].productId === productId) return i
        return -1
    }

    function updateProduct(productId, fields) {
        var idx = findIndexById(productId)
        if (idx < 0) return
        var arr = _clone()
        var prev = arr[idx]
        var p = arr[idx]
        // Snapshot prev values BEFORE we mutate `p`, since some fields below
        // assign through to the same object reference.
        var prevSnap = {
            name: prev.name, sku: prev.sku, category: prev.category,
            description: prev.description, unit: prev.unit,
            price: prev.price, sellingPrice: prev.sellingPrice,
            taxable: !!prev.taxable, taxPercent: prev.taxPercent || 0,
            stock: prev.stock, minStock: prev.minStock
        }
        // Per-field events recorded after the local mutation succeeds. The
        // stock field uses recordStockAdjustment to distinguish a manual
        // edit from a Restock-dialog flow (which calls recordPurchase).
        var fieldChanges = []   // { field, before, after }
        var stockChange = null  // { before, after }
        function _maybe(field, after) {
            if (after === undefined) return
            var before = prevSnap[field]
            if (before === after) return
            if (field === "stock") { stockChange = { before: before, after: after }; return }
            fieldChanges.push({ field: field, before: before, after: after })
        }
        if (fields.name         !== undefined) { _maybe("name", fields.name); p.name = fields.name }
        if (fields.sku          !== undefined) { _maybe("sku", fields.sku); p.sku = fields.sku }
        if (fields.category     !== undefined) { _maybe("category", fields.category); p.category = fields.category }
        if (fields.description  !== undefined) { _maybe("description", fields.description); p.description = fields.description }
        if (fields.unit         !== undefined) { _maybe("unit", fields.unit); p.unit = fields.unit }
        if (fields.price        !== undefined) { _maybe("price", fields.price); p.price = fields.price }
        if (fields.sellingPrice !== undefined) { _maybe("sellingPrice", fields.sellingPrice); p.sellingPrice = fields.sellingPrice }
        if (fields.taxable      !== undefined) { _maybe("taxable", !!fields.taxable); p.taxable = !!fields.taxable }
        if (fields.taxPercent   !== undefined) { _maybe("taxPercent", fields.taxPercent); p.taxPercent = fields.taxPercent }
        if (fields.stock        !== undefined) { _maybe("stock", fields.stock); p.stock = fields.stock }
        if (fields.minStock     !== undefined) { _maybe("minStock", fields.minStock); p.minStock = fields.minStock }
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
        // Per-doc PATCH bypasses the broken bulk-PUT path used by _commit.
        FirebaseService.put("inventory/" + productId, p, function(ok) {
            if (!ok) console.warn("[InventoryStore] Firestore update failed for", productId)
        })
    }

    function findByName(name) {
        for (var i = 0; i < products.length; ++i)
            if (products[i].name === name) return products[i];
        return null;
    }

    function getById(productId) {
        for (var i = 0; i < products.length; ++i)
            if (products[i].productId === productId) return products[i];
        return null;
    }
}
