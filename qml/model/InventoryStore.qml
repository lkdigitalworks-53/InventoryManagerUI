pragma Singleton
import QtQuick
import "../components"
import "../helper/OrderMath.js" as OrderMath
import "../helper/RealisedMath.js" as RealisedMath
import "../helper/ImportMath.js" as ImportMath

QtObject {
    id: root

    property var products: []

    // Bounded collection (capped by realistic business size) — the UI needs
    // the full set for search/dropdowns, so we page to exhaustion rather than
    // exposing a partial list. Fetches happen in <=_pageSize chunks via
    // FirebaseService.query() instead of one unbounded FirebaseService.get(),
    // which is what silently truncated past Firestore's internal
    // response-size threshold (confirmed: 250 products -> 170 fetched).
    readonly property int _pageSize: 50
    property bool hasMore: true
    property bool loadingMore: false

    // Set instead of the reset being silently dropped when _resetAndFetch()
    // arrives while a fetch is already in flight (see the guard below) --
    // e.g. a genuine account switch mid-sync. Consumed by _fetchFromFirebase's
    // callback the moment loadingMore goes back to false: that in-flight
    // fetch chain is abandoned (its result is for the stale tenant/account)
    // and a fresh _resetAndFetch() runs immediately instead. Design: SKILLS.md
    // Skill 39's "residual trade-off" note.
    property bool _resetPending: false
    property var _cursor: null

    // Bumped whenever `products` is reassigned. Consumers (DashboardPage,
    // InventoryPage) bind a watcher property to this to trigger their own
    // recomputation — Repeater/ColumnLayout sometimes lags on a bare
    // products-change signal, but a numeric revision flips reliably.
    property int revision: 0
    onProductsChanged: revision++

    // Only fetch here if tenant context is ALREADY known (lazy/warm
    // creation). On cold start with a persisted session this singleton can
    // be created (via DashboardPage's eager InventoryStore.revision binding)
    // before AuthStore.loadSession() has run, which would hit Firestore with
    // an unscoped path and 403. Main.qml's onTenantContextReady already
    // re-syncs every store once tenant context resolves — defer to that.
    Component.onCompleted: {
        if (AuthStore.tenantId.length > 0)
            _load()
        Gateway.mutationConflicted.connect(_onMutationConflicted)
        Gateway.batchMutationFailedPermanently.connect(_onBatchMutationFailedPermanently)
    }

    // Bulk-import chunking fix: every item Gateway.recordMutations("inventory", ...)
    // ever sends is a brand-new row (action "create" — see upsertMany, overwrites
    // of existing products route through the single-item updateProduct path
    // instead), so a permanent rejection always means "this row was added to
    // `products` optimistically and never actually reached Firestore" — safe to
    // just remove it, never a "revert someone else's edit" case.
    function _onBatchMutationFailedPermanently(entity, items, error) {
        if (entity !== "inventory" || !items || items.length === 0) return
        var failedIds = {}
        for (var i = 0; i < items.length; ++i) failedIds[items[i].entityId] = true
        var arr = products.filter(function(p) { return !failedIds[p.productId] })
        products = arr
        Toast.show(qsTr("%1 imported row(s) couldn't be saved and were removed. Please re-check and re-import them.").arg(items.length))
        ActivityLog.record("import_error",
            qsTr("Product import failed"),
            qsTr("%1 row(s) were rejected (%2) and removed from your device.").arg(items.length).arg(error),
            "")
    }

    // Component 3's client-side half (review finding C3, 2026-08-06) — see
    // OrdersStore._onMutationConflicted for the full explanation. Only
    // applies to plain recordMutation edits (name/price/category/etc via
    // updateProduct); deductStock/restock/creditStockNoBatch already go
    // through recordDelta, which doesn't use CAS and can't conflict this way.
    function _onMutationConflicted(entity, entityId, current) {
        if (entity !== "inventory") return
        var arr = products.slice()
        var idx = -1
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === entityId) { idx = i; break }
        }
        if (current) {
            var normalized = _normalizeProducts([current])[0]
            if (idx >= 0) arr[idx] = normalized
            else arr.push(normalized)
        } else if (idx >= 0) {
            arr.splice(idx, 1)
        }
        products = arr
        Toast.show(qsTr("This product was updated elsewhere — your change didn't save. Refreshed to the latest version."))
    }

    function _load() {
        _resetAndFetch();
    }

    function _resetAndFetch() {
        if (loadingMore) { _resetPending = true; return }
        products = [];
        hasMore = true;
        _cursor = null;
        _fetchFromFirebase();
    }

    function _normalizeProducts(arr) {
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
            if (!p.size) p.size = "";
            if (!p.photoUrl) p.photoUrl = "";
            if (!p.photoUpdatedAt) p.photoUpdatedAt = "";
            if (!p.supplierId) p.supplierId = "";
        }
        return arr;
    }

    function _fetchFromFirebase() {
        if (loadingMore) return;
        loadingMore = true;
        FirebaseService.query("inventory", { limit: _pageSize, startAfter: _cursor }, function(ok, result) {
            loadingMore = false;
            if (_resetPending) {
                _resetPending = false;
                _resetAndFetch();
                return;
            }
            if (!ok || !result) {
                console.warn("[InventoryStore] Firestore sync failed", FirebaseService.lastStatusCode, FirebaseService.lastError)
                return;
            }
            products = products.concat(_normalizeProducts(result.items));
            hasMore = result.hasMore;
            _cursor = result.nextCursor;
            if (hasMore) {
                // Bounded collection: keep paging until Firestore reports no
                // more pages, so `products` ends up complete either way —
                // just fetched in bounded chunks instead of one unbounded
                // request.
                _fetchFromFirebase();
            } else {
                console.log("[InventoryStore] Synced", products.length, "products from Firestore (all pages)");
            }
        });
    }

    function syncFromFirebase() { _resetAndFetch(); }

    function clear() {
        products = []
    }

    // INVARIANT (added 2026-07-30, after a real bug found in OrdersStore's
    // equivalent function): this field list must exactly match every field
    // addProduct's `doc` sends at creation — no more, no less. If they ever
    // drift (a field this whitelist defaults that creation doesn't send, or
    // vice versa), the very next clone silently reshapes the local cache
    // away from what's actually in Firestore, and the CAS backstop in
    // applyMutation (Component 3, async-write-sequencing design) will
    // reject a completely ordinary single-user edit as a false conflict —
    // not a rare race, a near-certainty on the second touch of any record.
    // Verified consistent as of this date; re-check both functions together
    // whenever either one changes.
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
                      photoUpdatedAt: p.photoUpdatedAt || "",
                      supplierId: p.supplierId || ""});
        }
        return a;
    }

    // The other half of the _clone() invariant above: the exact shape
    // addProduct() sends on create. Pulled out to a standalone pure
    // function (no async args — id/supplierId are already-resolved values
    // by the time addProduct calls this) so tst_InventoryStore_cloneSymmetry.qml
    // can assert the two field lists match without needing the emulator
    // that addProduct's own async id/supplier minting requires end to end.
    // This is a narrower fix than OrdersStore's _normalizeOrder (which also
    // folds in the update/bulk-import paths) — see review notes on
    // pr_taher_bug_fixes for the trade-off; _normalizeRecord (bulk import)
    // still builds its own doc shape independently and must be checked by
    // hand against this one and _clone() if either changes.
    function _newProductDoc(id, name, sku, category, stock, minStock,
                             price, sellingPrice, taxable, taxPercent,
                             size, unit, description, supplierId) {
        return { productId: id, name: name, sku: sku, category: category,
                 stock: stock, minStock: minStock,
                 price: price, sellingPrice: sellingPrice,
                 taxable: taxable, taxPercent: taxPercent,
                 size: size,
                 unit: unit, description: description || "",
                 photoUrl: "", photoUpdatedAt: "",
                 supplierId: supplierId };
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
    // dimension. Returns `{ key → { revenue, cogs, profit, tax, discount, margin } }`.
    // `field` ∈ "productId" | "supplierId" | "category" | "channel" | "staffId".
    //
    // Thin adapter over RealisedMath.byDimension (the single source of truth for
    // realised money aggregation). Reads STAMPED event net/tax/discount only — a
    // missing net fails closed to 0, never re-allocates the live order (SITE 4).
    // Multi-batch FIFO splits are remainder-reconciled (C). Margin is the markup
    // over cost: `profit / cogs`.
    //
    // `opts` (optional) carries the active filter scope so the by-dimension
    // sections honour the page's filters (A):
    //   { window:{from,to}|null, channel, staffId, category, supplierId }
    // Omitting opts (or passing nothing) sums the whole ledger — byte-for-byte
    // the legacy behaviour, so existing callers are unaffected.
    function realisedProfitByDimension(field, opts) {
        var entries = (typeof TransactionStore !== "undefined" && TransactionStore)
                ? (TransactionStore.entries || []) : []
        var lookups = {
            categoryOf: function(pid) { var p = getById(pid); return (p && p.category) ? p.category : "" },
            orderLookup: function(oid) {
                return (typeof OrdersStore !== "undefined" && oid) ? OrdersStore.getById(oid) : null
            }
        }
        return RealisedMath.byDimension(field, entries, opts || null, lookups)
    }

    // Filtered realised totals block (gross/discount/net/tax/cogs/profit) over the
    // event log — the single reconciling source for the Revenue/Profit hero and
    // the export Totals block (SITE 5, D). `opts` is the same scope shape as
    // realisedProfitByDimension; omitting it sums the whole ledger.
    function realisedTotals(opts) {
        var entries = (typeof TransactionStore !== "undefined" && TransactionStore)
                ? (TransactionStore.entries || []) : []
        var lookups = {
            categoryOf: function(pid) { var p = getById(pid); return (p && p.category) ? p.category : "" },
            orderLookup: function(oid) {
                return (typeof OrdersStore !== "undefined" && oid) ? OrdersStore.getById(oid) : null
            }
        }
        return RealisedMath.totals(entries, opts || null, lookups)
    }

    // Period-bucketed realised event walk for the on-screen chart / export
    // period tables. metric ∈ "net" | "profit". Both Revenue and Profit bins
    // now walk the SAME event log (SITE 5), so they reconcile to realisedTotals.
    // `opts` is the filter scope (date/channel/staff/category/supplier).
    function realisedBucketWalk(metric, periodIdx, opts) {
        var entries = (typeof TransactionStore !== "undefined" && TransactionStore)
                ? (TransactionStore.entries || []) : []
        var lookups = {
            categoryOf: function(pid) { var p = getById(pid); return (p && p.category) ? p.category : "" }
        }
        return RealisedMath.bucketWalk(metric, periodIdx, entries, opts || null, new Date(), lookups)
    }

    // Potential profit on open stock — for each open batch, value at the
    // product's current sellingPrice minus the batch's captured unitCost.
    // Same return shape as realisedProfitByDimension. `field` ∈
    // "productId" | "supplierId" | "category".
    //
    // `opts` (optional) gates the batch walk by the active filter scope so the
    // export matches the on-screen Potential view. Only supplier + category
    // apply — Potential is a batch snapshot with no date/channel/staff lineage.
    //   { supplierId: "", category: "" }   ("" = all)
    function potentialProfitByDimension(field, opts) {
        var out = {}
        var filterSup = (opts && opts.supplierId) ? opts.supplierId : ""
        var filterCat = (opts && opts.category) ? opts.category : ""
        var bs = (typeof StockBatchStore !== "undefined" && StockBatchStore)
                ? (StockBatchStore.batches || []) : []
        for (var i = 0; i < bs.length; ++i) {
            var b = bs[i]
            var qty = b.qtyRemaining || 0
            if (qty <= 0) continue
            if (filterSup && (b.supplierId || "") !== filterSup) continue
            var p = getById(b.productId)
            if (filterCat) {
                var pcat = (p && p.category) ? p.category : "(uncategorised)"
                if (pcat !== filterCat) continue
            }
            var sell = p ? (p.sellingPrice !== undefined ? p.sellingPrice : (p.price || 0)) : 0
            var cost = b.unitCost || 0
            var revenue = qty * sell
            var cogs = qty * cost
            var key
            if (field === "productId")      key = b.productId || ""
            else if (field === "supplierId") key = b.supplierId || ""
            else if (field === "category")   key = (p && p.category) ? p.category : "(uncategorised)"
            else                              key = ""
            if (!out[key]) out[key] = { revenue: 0, cogs: 0, profit: 0, tax: 0, discount: 0, margin: 0 }
            out[key].revenue += revenue
            out[key].cogs    += cogs
            out[key].profit  += (revenue - cogs)
        }
        var keys = Object.keys(out)
        for (var k = 0; k < keys.length; ++k) {
            var row = out[keys[k]]
            row.margin = row.cogs > 0 ? (row.profit / row.cogs) * 100 : 0
        }
        return out
    }

    function formatCurrency(val) {
        var n = typeof val === 'number' ? val : parseFloat(String(val).replace(/[^0-9.]/g, ''));
        if (isNaN(n)) n = 0;
        // Up to 1 decimal so fractional discounts/taxes display exactly (₹4.5),
        // integers stay clean (₹15). Avoids "rounded display ≠ stored value".
        try { return new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 0, maximumFractionDigits: 1 }).format(n); }
        catch(e) { return '₹' + (Math.round(n * 10) / 10).toString(); }
    }

    // Async — see FirebaseService.mintCounterValue for why max(existing)+1
    // isn't safe (id reuse after delete, concurrent-add collisions).
    function nextProductId(callback) {
        var seedMax = 0;
        for (var i = 0; i < products.length; ++i) {
            var num = parseInt(String(products[i].productId).split('-')[1]);
            if (!isNaN(num) && num > seedMax) seedMax = num;
        }
        FirebaseService.mintCounterValue("counters/products", seedMax, function(ok, value) {
            callback(ok ? ('PRD-' + String(value).padStart(3, '0')) : "")
        })
    }

    function generateSku(name, numOfProducts = 0) {
        if (!name || name.length < 2) return "";
        var words = name.trim().split(/\s+/);
        var prefix = "";
        for (var i = 0; i < Math.min(words.length, 2); ++i)
            prefix += words[i].charAt(0).toUpperCase();
        var year = new Date().getFullYear();
        // numOfProducts always has a value (default param above), so the
        // only thing that decides the fallback is whether it's > 0.
        var num = numOfProducts > 0 ? numOfProducts : products.length + 1;
        var numStr = String(num).padStart(3, '0');
        return prefix + "-" + year + "-" + numStr;
    }

    // Shared by every _upsertManySync branch that needs a per-row-unique
    // SKU suffix during bulk import: the numeric tail of a "PRD-###"
    // productId. Using each row's own (already-unique) productId instead
    // of `products.length` is what fixes the original bug this branch was
    // built for — `products.length` is read from the *outer* `products`
    // property, which stays frozen at its pre-import value for the whole
    // loop (it's only reassigned once, after the loop, via `products =
    // arr`), so every row lacking a SKU in a batch used to collide on the
    // exact same generated suffix.
    function _idSuffixNumber(productId) {
        return parseInt(String(productId).split('-')[1]);
    }

    // The `party` legacy argument is now treated as a SUPPLIER ID for new
    // callers; old callers that still pass a name string are routed via
    // SupplierStore.findByName/addSupplier so legacy code paths keep working.
    // `unitCost` is the cost-per-unit of the initial-stock batch (defaults
    // to product cost `price` when not supplied — matches the previous
    // implicit assumption).
    function addProduct(name, sku, category, description, price, unit, stock, minStock, sellingPrice, taxable, taxPercent, party, unitCost, size, callback) {
        // Resolve supplier first (only actually async when `party` is a
        // brand-new name that needs a fresh supplierId minted — an existing
        // id/name resolves synchronously-fast via the callback), then mint
        // the productId, then build+persist the product. Both mints go
        // through FirebaseService.mintCounterValue (see its comment for why).
        _resolveSupplierId(party, function(supplierId, supplierFailed) {
            if (supplierFailed) {
                console.warn("[InventoryStore] could not create the requested supplier — add aborted")
                if (callback) callback(false, "")
                return
            }
            nextProductId(function(id) {
                if (!id) {
                    console.warn("[InventoryStore] could not mint a productId — add aborted")
                    if (callback) callback(false, "")
                    return
                }
                var arr = _clone();
                var sp = (sellingPrice !== undefined && sellingPrice !== null) ? sellingPrice : price;
                var tx = !!taxable;
                var tp = (typeof taxPercent === "number" && !isNaN(taxPercent)) ? taxPercent : 0;
                var sz = size || "";
                var doc = _newProductDoc(id, name, sku, category, stock, minStock,
                                         price, sp, tx, tp, sz, unit, description, supplierId);
                arr.push(doc);
                // Optimistic local update; persist this one product via the gateway
                // (a per-doc create, not the legacy bulk PUT of the whole collection).
                products = arr;
                Gateway.recordMutation("inventory", id, "create", null, doc);
                ActivityLog.record("product_added",
                                   "Product added: " + name,
                                   (sku ? sku + " · " : "") + "stock " + stock,
                                   id);
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
                    size: sz,
                    minStock: minStock || 0,
                    description: description || "",
                    supplierId: supplierId
                }, supplierId);

                // Initial stock is treated as the first FIFO batch. Skip when stock
                // is 0 — there's nothing to consume from a zero-quantity batch.
                // addBatch is async (mints its own batchId) — fire-and-forget here,
                // same as before this call site's return value was ever used.
                if (stock > 0) {
                    StockBatchStore.addBatch(id, supplierId, stock, batchCost, "Initial stock");
                }
                if (callback) callback(true, id)
            })
        })
    }

    // Internal: turn a free-text "party" argument into a stable supplierId.
    // Empty input calls back with "". A name that already maps to a supplier
    // calls back with that id. A new name promotes the supplier on the fly
    // (async — see SupplierStore.addSupplier) so legacy call sites (which
    // haven't been updated to pass an id) still produce first-class supplier
    // records. Always calls back via the callback, even on the fast/already-
    // resolved paths, so callers don't have to special-case sync vs async.
    function _resolveSupplierId(party, callback) {
        if (!party) { callback("", false); return }
        var raw = String(party);
        // Already an id?
        if (raw.indexOf("SUP-") === 0) {
            var byId = SupplierStore.getById(raw);
            callback(byId ? byId.supplierId : raw, false);
            return;
        }
        var byName = SupplierStore.findByName(raw);
        if (byName) { callback(byName.supplierId, false); return; }
        SupplierStore.addSupplier({ name: raw }, function(created) {
            // `failed` is true only when the caller asked for a genuinely
            // new supplier and creation didn't happen (network drop etc) —
            // distinct from an empty party, which is a legitimate "no
            // supplier requested" and never a failure.
            callback(created ? created.supplierId : "", !created);
        });
    }

    // Book the ledger side-effects for an imported product so analytics
    // (Value / Purchased / Profit / by-supplier) populate exactly as if the
    // product had been created in-app. Opening batch only when stock > 0.
    // transactionItems/stockBatchItems: caller-provided arrays this pushes
    // the built (but not-yet-written) docs into, instead of each call firing
    // its own individual Gateway write — see addBatchMany/recordCreatedMany.
    // pullBatchId: caller-supplied closure pulling from a pre-reserved
    // batch-id range (see upsertMany) — StockBatchStore.addBatch can't be
    // used here any more since it's async (mints its own id); this loop is
    // synchronous, same reason pullProductId/nameToSupplierId exist.
    function _bookImportedProduct(doc, transactionItems, stockBatchItems, pullBatchId) {
        var supplierId = doc.supplierId || "";
        var batchCost = (typeof doc.price === "number" && !isNaN(doc.price)) ? doc.price : 0;
        var txDoc = TransactionStore.recordCreated(doc.productId, doc.name, doc.stock, batchCost, {
            sku: doc.sku || "", category: doc.category || "", unit: doc.unit || "",
            sellingPrice: doc.sellingPrice, taxable: doc.taxable, taxPercent: doc.taxPercent,
            size: doc.size || "",
            minStock: doc.minStock || 0, description: doc.description || "",
            supplierId: supplierId, origin: "imported"
        }, supplierId, true);
        if (txDoc) transactionItems.push(txDoc);
        if (doc.stock > 0) {
            var batchDoc = StockBatchStore.addBatchWithId(pullBatchId(), doc.productId, supplierId, doc.stock, batchCost, "Imported opening stock", true);
            if (batchDoc) stockBatchItems.push(batchDoc);
        }
    }

    // Persist a photo URL on a product. Per-doc PATCH bypasses the bulk-PUT
    // path so the write is always atomic.
    function setPhoto(productId, photoUrl) {
        var idx = findIndexById(productId);
        if (idx < 0) return;
        var arr = _clone();
        var before = Object.assign({}, arr[idx]);
        var prevUrl = arr[idx].photoUrl || "";
        var newUrl = photoUrl || "";
        arr[idx].photoUrl = newUrl;
        arr[idx].photoUpdatedAt = new Date().toISOString();
        products = arr;
        if (prevUrl !== newUrl)
            TransactionStore.recordPhotoChange(productId, arr[idx].name, prevUrl, newUrl);
        Gateway.recordMutation("inventory", productId, "update", before, arr[idx]);
    }

    // Bulk import / upsert. Records carry the same shape as products plus an
    // optional `_conflictPolicy` string ("skip" | "overwrite" | "rename").
    // Returns { added, updated, skipped } counts.
    // Bulk import / upsert. Records carry the same shape as products plus an
    // optional `_conflictPolicy` string ("skip" | "overwrite" | "rename").
    // Async — callback({ added, updated, skipped, updatedProducts }).
    //
    // A synchronous per-row loop can't call the (now-async) id minters
    // mid-iteration, and minting one id per row over the network would be
    // slow for a big import anyway — so this pre-scans the batch for how
    // many fresh productIds and NEW supplier names it needs, reserves both
    // in ONE round-trip each via FirebaseService.mintCounterBatch, then runs
    // the original loop synchronously again against those pre-reserved
    // pools. All new/renamed rows are collected into a single
    // Gateway.recordMutations() call at the end instead of one
    // recordMutation() per row, matching SupplierStore.upsertMany's pattern.
    // Pure — no FirebaseService/network calls, and no reliance on the
    // singletons directly (existingProductIds/supplierNameExists are
    // passed in) — extracted specifically so this counting logic is
    // unit-testable without a live emulator. This is the correctness-
    // critical piece of the reservation scheme: an undercount here means
    // the loop below runs out of pre-reserved ids mid-way; an overcount
    // just wastes a few counter values, harmlessly.
    //
    // neededBatchIds mirrors neededProductIds' exact branching (a row
    // creates a new product doc iff it doesn't match an existing one, OR
    // it does and the conflict policy is "rename") — a companion FIFO
    // batch only exists for those same rows, and only when incoming stock
    // is positive (see _bookImportedProduct).
    function _scanUpsertManyNeeds(records, existingProductIds, supplierNameExists) {
        var neededProductIds = 0;
        var neededBatchIds = 0;
        var newSupplierNames = []; // unique, first-seen order
        var seenNames = {};
        for (var qi = 0; qi < records.length; ++qi) {
            var rr = records[qi];
            var pol = rr._conflictPolicy || "skip";
            var existsAlready = !!(rr.productId && existingProductIds[rr.productId]);
            var willCreateNewRow;
            if (existsAlready) {
                willCreateNewRow = (pol === "rename");
                if (willCreateNewRow) neededProductIds++;
            } else {
                // A row that doesn't match an existing product is a new
                // product, full stop — always needs a freshly minted id,
                // whether the productId column was left blank (the normal
                // case) or happened to have something typed in it that
                // doesn't match anything yet. Trusting a typed-but-unknown
                // id here is how two different rows can end up minting/
                // keeping the exact same number.
                willCreateNewRow = true;
                neededProductIds++;
            }
            if (willCreateNewRow && (parseInt(rr.stock) || 0) > 0) neededBatchIds++;

            if (!rr.supplierId && rr.supplier) {
                var key = String(rr.supplier).trim().toLowerCase();
                if (key.length > 0 && !seenNames[key] && !supplierNameExists(rr.supplier)) {
                    seenNames[key] = true;
                    newSupplierNames.push(String(rr.supplier).trim());
                }
            }
        }
        return { neededProductIds: neededProductIds, neededBatchIds: neededBatchIds, newSupplierNames: newSupplierNames };
    }

    function upsertMany(records, callback) {
        var counts = { added: 0, updated: 0, skipped: 0, updatedProducts: [] };
        if (!records || records.length === 0) { if (callback) callback(counts); return; }

        var byIdPre = {};
        for (var pi = 0; pi < products.length; ++pi) byIdPre[products[pi].productId] = true;

        var scan = _scanUpsertManyNeeds(records, byIdPre, function(name) { return !!SupplierStore.findByName(name); });
        var neededProductIds = scan.neededProductIds;
        var neededBatchIds = scan.neededBatchIds;
        var newSupplierNames = scan.newSupplierNames;

        var seedProductMax = 0;
        for (var si = 0; si < products.length; ++si) {
            var n1 = parseInt(String(products[si].productId).split('-')[1]);
            if (!isNaN(n1) && n1 > seedProductMax) seedProductMax = n1;
        }
        var seedSupplierMax = 0;
        for (var sj = 0; sj < SupplierStore.suppliers.length; ++sj) {
            var n2 = parseInt(String(SupplierStore.suppliers[sj].supplierId).split('-')[1]);
            if (!isNaN(n2) && n2 > seedSupplierMax) seedSupplierMax = n2;
        }
        // Batch ids are year-scoped (BAT-<year>-NNN resets every year — see
        // StockBatchStore.nextBatchId) so both the seed scan and the
        // counter path itself are keyed off the current year, captured
        // once here (see the design doc's note on the accepted midnight-
        // rollover edge case).
        var currentYear = new Date().getFullYear();
        var batchPrefix = "BAT-" + currentYear + "-";
        var seedBatchMax = 0;
        for (var bk = 0; bk < StockBatchStore.batches.length; ++bk) {
            var bid = String(StockBatchStore.batches[bk].batchId || "");
            if (bid.indexOf(batchPrefix) !== 0) continue;
            var n3 = parseInt(bid.substring(batchPrefix.length));
            if (!isNaN(n3) && n3 > seedBatchMax) seedBatchMax = n3;
        }

        FirebaseService.mintCounterBatch("counters/products", seedProductMax, neededProductIds,
            function(prodOk, prodStart) {
            if (!prodOk) {
                console.warn("[InventoryStore] could not reserve product ids — import aborted");
                if (callback) callback(counts);
                return;
            }
            FirebaseService.mintCounterBatch("counters/suppliers", seedSupplierMax, newSupplierNames.length,
                function(supOk, supStart) {
                if (!supOk) {
                    console.warn("[InventoryStore] could not reserve supplier ids — import aborted");
                    if (callback) callback(counts);
                    return;
                }
                FirebaseService.mintCounterBatch("counters/stockBatches-" + currentYear, seedBatchMax, neededBatchIds,
                    function(batchOk, batchStart) {
                    if (!batchOk) {
                        console.warn("[InventoryStore] could not reserve stock batch ids — import aborted");
                        if (callback) callback(counts);
                        return;
                    }

                    var nameToSupplierId = {};
                    var supplierItems = [];
                    for (var ni = 0; ni < newSupplierNames.length; ++ni) {
                        var newSupId = 'SUP-' + String(supStart + ni + 1).padStart(3, '0');
                        var supDoc = SupplierStore.addSupplierWithId(newSupId, newSupplierNames[ni], true);
                        if (supDoc) supplierItems.push(supDoc);
                        nameToSupplierId[newSupplierNames[ni].toLowerCase()] = newSupId;
                    }
                    if (supplierItems.length > 0) SupplierStore.addSupplierWithIdMany(supplierItems);

                    var mintedProductIdx = 0;
                    function pullProductId() {
                        mintedProductIdx++;
                        return 'PRD-' + String(prodStart + mintedProductIdx).padStart(3, '0');
                    }
                    var mintedBatchIdx = 0;
                    function pullBatchId() {
                        mintedBatchIdx++;
                        return batchPrefix + String(batchStart + mintedBatchIdx).padStart(3, '0');
                    }
                    function resolveSupplierForRecord(r) {
                        if (r.supplierId) return r.supplierId;
                        if (!r.supplier) return "";
                        var byId = _resolveSupplierIdSyncKnown(r.supplier);
                        if (byId) return byId;
                        return nameToSupplierId[String(r.supplier).trim().toLowerCase()] || "";
                    }

                    _upsertManySync(records, pullProductId, resolveSupplierForRecord, pullBatchId, counts);
                    if (callback) callback(counts);
                });
            });
        });
    }

    // Resolves `party` synchronously using ONLY already-known suppliers (an
    // existing SUP- id, or a name that already matches an existing
    // supplier) — never mints. Used by the upsertMany batch path, where
    // brand-new names are resolved from the pre-minted nameToSupplierId map
    // instead (see resolveSupplierForRecord above).
    function _resolveSupplierIdSyncKnown(party) {
        if (!party) return "";
        var raw = String(party);
        if (raw.indexOf("SUP-") === 0) {
            var byId = SupplierStore.getById(raw);
            return byId ? byId.supplierId : raw;
        }
        var byName = SupplierStore.findByName(raw);
        return byName ? byName.supplierId : "";
    }

    // The original synchronous upsert loop, pulling ids from the pools
    // upsertMany already reserved instead of minting inline. Collects every
    // new/renamed row into `mutationItems` and fires ONE
    // Gateway.recordMutations() call at the end instead of one
    // recordMutation() per row.
    function _upsertManySync(records, pullProductId, resolveSupplierForRecord, pullBatchId, counts) {
        var arr = _clone();
        var byId = {};
        var updatedProducts = counts.updatedProducts;
        var mutationItems = [];
        var transactionItems = [];
        var stockBatchItems = [];
        for (var i = 0; i < arr.length; ++i) {
            byId[arr[i].productId] = i;
        }

        for (var k = 0; k < records.length; ++k) {
            var r = records[k];
            var policy = r._conflictPolicy || "skip";
            r.supplierId = resolveSupplierForRecord(r);

            // Match an existing product by productId only — never by name
            // or SKU (both can legitimately duplicate across products).
            var existingIdx = -1;
            if (r.productId && byId[r.productId] !== undefined)
                existingIdx = byId[r.productId];

            if (existingIdx >= 0) {
                if (policy === "skip") { counts.skipped++; continue; }
                if (policy === "rename") {
                    // Treat as new: assign fresh id (pre-reserved) and unique SKU
                    r.productId = pullProductId();

                    if (r.sku) { r.sku = ImportMath.renameSku(r.sku, counts.added); }
                    else {
                        r.sku = generateSku(r.name, _idSuffixNumber(r.productId));
                    }

                    var renamedDoc = _normalizeRecord(r);
                    arr.push(renamedDoc);
                    byId[r.productId] = arr.length - 1;
                    mutationItems.push({ entityId: renamedDoc.productId, action: "create", before: null, after: renamedDoc });
                    _bookImportedProduct(renamedDoc, transactionItems, stockBatchItems, pullBatchId);
                    counts.added++;
                    continue;
                }

                // overwrite — this is an EXISTING product (matched by
                // productId), not a new one. A blank sku on the incoming
                // row almost always just means "the CSV export/edit round
                // trip didn't carry the sku column" — it does not mean the
                // product itself has no SKU. Falling straight to
                // generateSku() here (as new-row/rename correctly do,
                // since those really are new products with nothing to
                // preserve) would silently replace the product's real,
                // already-correct SKU with a synthetic one on every bulk
                // edit that happens to omit that column. Preserve the
                // existing value first; only synthesize one if the stored
                // product itself somehow also has none (legacy data).
                if (!r.sku || r.sku.length === 0) {
                    r.sku = arr[existingIdx].sku || generateSku(r.name, _idSuffixNumber(r.productId));
                }
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
                                  minStock: r.minStock,
                                  supplierId: r.supplierId
                              }})
                counts.updated++;
            } else {
                // New row — always mint a fresh id (see the pre-scan above
                // for why a typed-but-unmatched value in this column can't
                // be trusted as authoritative).
                r.productId = pullProductId();
                if (!r.sku || r.sku.length === 0) {
                    // Generate SKU if empty, for a new row
                    r.sku = generateSku(r.name, _idSuffixNumber(r.productId));
                }

                var doc = _normalizeRecord(r);
                arr.push(doc);
                byId[doc.productId] = arr.length - 1;
                mutationItems.push({ entityId: doc.productId, action: "create", before: null, after: doc });
                _bookImportedProduct(doc, transactionItems, stockBatchItems, pullBatchId);
                counts.added++;
            }
        }

        products = arr;
        // >maxBatchSize rows means recordMutations() below splits into
        // multiple background sends (see Gateway._chunkItems) — the caller's
        // completion message should say so rather than imply everything is
        // already durably saved server-side the instant this function returns.
        counts.chunked = mutationItems.length > Gateway.maxBatchSize;
        if (mutationItems.length > 0) Gateway.recordMutations("inventory", mutationItems);
        if (transactionItems.length > 0) TransactionStore.recordCreatedMany(transactionItems);
        if (stockBatchItems.length > 0) StockBatchStore.addBatchMany(stockBatchItems);
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
            size: r.size || "",
            stock: parseInt(r.stock) || 0,
            minStock: parseInt(r.minStock) || 0,
            photoUrl: r.photoUrl || "",
            photoUpdatedAt: r.photoUpdatedAt || "",
            // Already resolved (existing id/name, or pre-minted-for-this-batch
            // name) by _upsertManySync before _normalizeRecord is called.
            supplierId: r.supplierId || ""
        };
    }

    function _mergeRecord(existing, incoming) {
        var merged = {};
        var keys = ["productId", "name", "sku", "category", "unit", "description",
                    "price", "sellingPrice", "taxable", "taxPercent",
                    "stock", "minStock", "photoUrl", "photoUpdatedAt", "supplierId"];
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
        var before = null
        var found = false
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === productId) { before = arr[i]; arr.splice(i, 1); found = true; break; }
        }
        products = arr
        if (!found) return

        Gateway.recordMutation("inventory", productId, "delete", before, null)
    }

    // `party` may be a supplierId, an existing supplier name, or a brand-new
    // name we'll auto-promote. `unitCost` is cost-per-unit at receipt time
    // and defaults to the product's cost field (`changed.price`) when the
    // caller didn't capture it (e.g. legacy restock paths).
    function restock(productId, amount, party, unitCost, reason, callback) {
        var arr = _clone();
        var current = null;
        var addedQty = amount || 10;
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === productId) { current = arr[i]; break; }
        }
        if (!current) { if (callback) callback(false); return }

        _resolveSupplierId(party, function(supplierId, supplierFailed) {
            var supplierName = supplierId ? SupplierStore.nameOf(supplierId) : "";
            var batchCost = (typeof unitCost === "number" && !isNaN(unitCost)) ? unitCost : (current.price || 0);
            var reasonText = (reason || "").trim();

            // Atomic server-side delta (Component 4) instead of the old
            // optimistic-local-then-whole-record-CAS-mutation pattern —
            // same fix and reasoning as deductStock above. review finding
            // C4 (2026-08-06): restock() was the one Component-4 caller
            // the design doc called for that was never actually converted
            // — two staff restocking the same product close together used
            // to compute the new stock value from a stale local snapshot,
            // which (combined with the now-fixed C3/C1 gaps) could get
            // silently stuck retrying forever on the resulting conflict.
            // Local products[] is now updated only once the server confirms
            // (result.after.stock), not optimistically — so the ActivityLog/
            // TransactionStore/StockBatchStore side effects below also wait
            // for that confirmation, rather than firing for a write that
            // might not have actually landed.
            Gateway.recordDelta("inventory", productId, { stock: addedQty }, {}, {}, function(result) {
                if (!result || !result.ok || !result.after || result.after.stock === undefined) {
                    console.warn("[InventoryStore] restock: recordDelta failed for", productId, result && result.error)
                    if (callback) callback(false, supplierFailed)
                    return
                }
                var arr2 = _clone();
                for (var j = 0; j < arr2.length; ++j) {
                    if (arr2[j].productId === productId) { arr2[j].stock = result.after.stock; break }
                }
                products = arr2;

                ActivityLog.record("product_restocked",
                                   "Restocked: " + current.name,
                                   "+" + addedQty + " · now " + result.after.stock + " in stock"
                                       + (supplierName ? " · from " + supplierName : "")
                                       + (reasonText ? " · " + reasonText : ""),
                                   productId);
                TransactionStore.recordPurchase(productId, addedQty, batchCost, current.name, supplierId, reasonText);
                // The receipt also lands as a FIFO batch — this is what every
                // subsequent sale will draw from in date order. The reason
                // rides along in the batch's existing (currently unrendered)
                // note field. addBatch creates a brand-new document (no
                // shared mutable value to race on), so it's out of C4's
                // scope — only consumeFifo/topUpOldest/restoreFifo (which
                // mutate an EXISTING batch's qtyRemaining) are the still-open
                // part of that gap, tracked separately. addBatch is async
                // (mints its own batchId) — fire-and-forget here, same as
                // before this call site's return value was ever used.
                StockBatchStore.addBatch(productId, supplierId, addedQty, batchCost, reasonText);

                if (callback) callback(true, supplierFailed)
            })
        })
    }

    function stockStatus(p) {
        return p.stock <= p.minStock ? "Low Stock" : "In Stock";
    }

    function stockPercent(p) {
        var maxStock = Math.max(p.minStock * 3, 100);
        return Math.min(1.0, p.stock / maxStock);
    }

    // Deducts qty from product.stock via an atomic server-side delta
    // (Component 4, async-write-sequencing design) — NOT the old optimistic-
    // local-then-fire-and-forget pattern. Local `products[]` is updated only
    // once the callback confirms the real, server-computed outcome, using
    // the server's authoritative new value (result.after.stock) rather than
    // recomputing locally — avoids drifting from whatever else may have
    // touched this product concurrently.
    //
    // `clampInsteadOfReject` (default false — reject): order completion
    // wants insufficient stock to FAIL the deduction (Taher's round-4
    // decision: reject the order, don't silently under-sell). Pass true for
    // completeImportedOrder's deliberately different "complete + report
    // shortfall" business rule, which must keep succeeding the way it
    // always has — same atomicity/race-safety either way, only the
    // floor-crossing behavior differs.
    function deductStock(productId, qty, callback, clampInsteadOfReject) {
        var arr = _clone();
        var exists = false;
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === productId) { exists = true; break; }
        }
        if (!exists) {
            console.warn("[InventoryStore] deductStock: no product with id", productId)
            if (callback) callback({ ok: false, error: "not-found" })
            return
        }
        var floors = clampInsteadOfReject ? {} : { stock: 0 }
        var clamps = clampInsteadOfReject ? { stock: 0 } : {}
        Gateway.recordDelta("inventory", productId, { stock: -qty }, floors, clamps, function(result) {
            if (result && result.ok && result.after && result.after.stock !== undefined) {
                var arr2 = _clone()
                for (var j = 0; j < arr2.length; ++j) {
                    if (arr2[j].productId === productId) {
                        arr2[j].stock = result.after.stock
                        break
                    }
                }
                products = arr2
            }
            if (callback) callback(result)
        })
    }

    // Increment product.stock WITHOUT creating a batch or purchase event. Used by
    // the returns flow, where StockBatchStore.restoreFifo has ALREADY credited the
    // batch ledger — this just keeps product.stock in lockstep. (Distinct from
    // restock(), which is a supplier receipt that DOES create a batch.)
    function creditStockNoBatch(productId, qty) {
        if (!qty || qty <= 0) return
        var arr = _clone()
        var exists = false
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === productId) { exists = true; break }
        }
        if (!exists) {
            console.warn("[InventoryStore] creditStockNoBatch: no product with id", productId)
            return
        }
        // Atomic server-side delta (Component 4) instead of a whole-record
        // CAS mutation computed from a possibly-stale local snapshot — same
        // fix and reasoning as restock() above (review finding C4,
        // 2026-08-06, folded in alongside restock's fix since it's the
        // identical bug). Stays fire-and-forget from the caller's
        // perspective (no callback param, matching restoreFifo/consumeFifo's
        // existing convention in the returns flow this feeds) — local
        // products[] is just patched from result.after.stock once the
        // server confirms, instead of being mutated optimistically.
        Gateway.recordDelta("inventory", productId, { stock: qty }, {}, {}, function(result) {
            if (!result || !result.ok || !result.after || result.after.stock === undefined) {
                console.warn("[InventoryStore] creditStockNoBatch: recordDelta failed for", productId, result && result.error)
                return
            }
            var arr2 = _clone()
            for (var j = 0; j < arr2.length; ++j) {
                if (arr2[j].productId === productId) { arr2[j].stock = result.after.stock; break }
            }
            products = arr2
        })
    }

    function findIndexById(productId) {
        for (var i = 0; i < products.length; ++i)
            if (products[i].productId === productId) return i
        return -1
    }

    function updateProduct(productId, fields, reason) {
        var idx = findIndexById(productId)
        if (idx < 0) return
        var arr = _clone()
        var prev = arr[idx]
        var p = arr[idx]
        // Full pre-mutation snapshot for the audit_log `before` (taken before
        // any field is reassigned through the shared `p` reference).
        var auditBefore = Object.assign({}, prev)
        // Snapshot prev values BEFORE we mutate `p`, since some fields below
        // assign through to the same object reference.
        var prevSnap = {
            name: prev.name, sku: prev.sku, category: prev.category,
            description: prev.description, unit: prev.unit,
            price: prev.price, sellingPrice: prev.sellingPrice,
            taxable: !!prev.taxable, taxPercent: prev.taxPercent || 0,
            size: prev.size || "",
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
        if (fields.size         !== undefined) { _maybe("size", fields.size); p.size = fields.size }
        if (fields.stock        !== undefined) { _maybe("stock", fields.stock); p.stock = fields.stock }
        if (fields.minStock     !== undefined) { _maybe("minStock", fields.minStock); p.minStock = fields.minStock }
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

    function getById(productId) {
        for (var i = 0; i < products.length; ++i)
            if (products[i].productId === productId) return products[i];
        return null;
    }
}
