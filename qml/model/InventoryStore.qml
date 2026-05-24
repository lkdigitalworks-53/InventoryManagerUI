pragma Singleton
import QtQuick

QtObject {
    id: root

    property var products: []

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

    function totalValue() {
        var v = 0;
        for (var i = 0; i < products.length; ++i)
            v += products[i].stock * products[i].price;
        return v;
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

    function addProduct(name, sku, category, description, price, unit, stock, minStock, sellingPrice) {
        var id = nextProductId();
        var arr = _clone();
        var sp = (sellingPrice !== undefined && sellingPrice !== null) ? sellingPrice : price;
        arr.push({ productId: id, name: name, sku: sku, category: category,
                   stock: stock, minStock: minStock,
                   price: price, sellingPrice: sp,
                   unit: unit, description: description || "",
                   photoUrl: "", photoUpdatedAt: "" });
        _commit(arr);
        return id;
    }

    // Persist a photo URL on a product. Per-doc PATCH bypasses the bulk-PUT
    // path so the write is always atomic.
    function setPhoto(productId, photoUrl) {
        var idx = findIndexById(productId);
        if (idx < 0) return;
        var arr = _clone();
        arr[idx].photoUrl = photoUrl || "";
        arr[idx].photoUpdatedAt = new Date().toISOString();
        products = arr;
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
            stock: parseInt(r.stock) || 0,
            minStock: parseInt(r.minStock) || 0,
            photoUrl: r.photoUrl || "",
            photoUpdatedAt: r.photoUpdatedAt || ""
        };
    }

    function _mergeRecord(existing, incoming) {
        var merged = {};
        var keys = ["productId", "name", "sku", "category", "unit", "description",
                    "price", "sellingPrice", "stock", "minStock", "photoUrl", "photoUpdatedAt"];
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

    function restock(productId, amount) {
        var arr = _clone();
        var changed = null;
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === productId) {
                arr[i].stock += (amount || 10);
                changed = arr[i];
                break;
            }
        }
        products = arr;
        if (!changed) return
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
        var p = arr[idx]
        if (fields.name         !== undefined) p.name = fields.name
        if (fields.sku          !== undefined) p.sku = fields.sku
        if (fields.category     !== undefined) p.category = fields.category
        if (fields.description  !== undefined) p.description = fields.description
        if (fields.unit         !== undefined) p.unit = fields.unit
        if (fields.price        !== undefined) p.price = fields.price
        if (fields.sellingPrice !== undefined) p.sellingPrice = fields.sellingPrice
        if (fields.stock        !== undefined) p.stock = fields.stock
        if (fields.minStock     !== undefined) p.minStock = fields.minStock
        products = arr
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
