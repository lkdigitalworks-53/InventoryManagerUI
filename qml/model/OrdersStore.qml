
pragma Singleton
import QtQuick
import QtCore

QtObject {
    id: root

    property var orders: []
    property bool autoApproveEnabled: false

    property Settings _settings: Settings {
        category: "OrdersStore"
        property bool autoApprove: false
    }

    Component.onCompleted: {
        autoApproveEnabled = _settings.autoApprove
        _load()
    }

    onAutoApproveEnabledChanged: {
        _settings.autoApprove = autoApproveEnabled
    }

    function _load() {
        orders = []
        _refreshCounts();
        _fetchFromFirebase();
    }

    function _fetchFromFirebase() {
        FirebaseService.get("orders", function(ok, data) {
            if (ok) {
                var arr = FirebaseService.toArray(data);
                // Normalize backend field names to local schema
                for (var i = 0; i < arr.length; ++i) {
                    var o = arr[i];
                    if (o.order_id && !o.orderId) o.orderId = o.order_id;
                    if (!o.customer) o.customer = "";
                    if (o.items === undefined) o.items = 0;
                    if (o.total === undefined) o.total = 0;
                    if (!o.status) { console.error(" ======== status is not present"); o.status = "pending";}
                    if (!o.date) o.date = o.created_at || "";
                    if (!o.notes) o.notes = "";
                    if (!o.email) o.email = "";
                    if (!o.phone) o.phone = "";
                    if (!o.products) o.products = [];
                    if (o.subtotal === undefined || o.subtotal === null) o.subtotal = 0;
                    if (o.tax === undefined || o.tax === null) o.tax = 0;
                    if (o.discount === undefined || o.discount === null) o.discount = 0;
                    if (!o.taxBreakdown) o.taxBreakdown = [];
                    // Channel + staff are added by the new build going
                    // forward; legacy docs default to empty so analytics
                    // surface them under "(unspecified)".
                    if (!o.orderChannel) o.orderChannel = "";
                    if (!o.staffId) o.staffId = "";
                    if (!Array.isArray(o.adjustments)) o.adjustments = [];
                }
                orders = arr;
                revision++;
                _refreshCounts();
                console.log("[OrdersStore] Synced", arr.length, "orders from Firestore");
            } else {
                console.warn("[OrdersStore] Firestore sync failed", FirebaseService.lastStatusCode, FirebaseService.lastError)
            }
        });
    }

    function _pushToFirebase(order) {
        FirebaseService.put("orders/" + order.orderId, order, function(ok) {
            if (!ok)
                console.warn("[OrdersStore] Firestore write failed for", order.orderId, FirebaseService.lastStatusCode, FirebaseService.lastError)
            else
                console.log("[OrdersStore] Firestore write ok for", order.orderId)
        });
    }

    function _pushAllToFirebase() {
        var obj = {};
        for (var i = 0; i < orders.length; ++i)
            obj[orders[i].orderId] = orders[i];
        FirebaseService.put("orders", obj, function(ok) {
            if (!ok)
                console.warn("[OrdersStore] Firestore bulk write failed", FirebaseService.lastStatusCode, FirebaseService.lastError)
            else
                console.log("[OrdersStore] Firestore bulk write ok, documents:", orders.length)
        });
    }

    function syncFromFirebase() { _fetchFromFirebase(); }

    function clear() {
        orders = []
        revision++
        _refreshCounts()
    }

    // Bulk import / upsert. Records carry the same shape as orders plus an
    // optional `_conflictPolicy` ("skip" | "overwrite" | "rename").
    // `inventoryByName` and `inventoryBySku` are caller-supplied lookup tables
    // so we can resolve order-line products to a stable productId.
    // Returns { added, updated, skipped, addedIds } counts.
    function upsertMany(records) {
        var counts = { added: 0, updated: 0, skipped: 0 };
        var addedIds = [];
        var updatedOrders = [];
        if (!records || records.length === 0) {
            counts.addedIds = addedIds;
            return counts;
        }

        var arr = _clone();
        var byId = {};
        for (var i = 0; i < arr.length; ++i)
            byId[arr[i].orderId] = i;

        for (var k = 0; k < records.length; ++k) {
            var r = records[k];
            var policy = r._conflictPolicy || "skip";
            var existingIdx = (r.orderId && byId[r.orderId] !== undefined) ? byId[r.orderId] : -1;

            if (existingIdx >= 0) {
                if (policy === "skip") { counts.skipped++; continue; }
                if (policy === "rename") {
                    orders = arr;  // ensure nextOrderId() sees latest
                    r.orderId = nextOrderId();
                    arr.push(_normalizeOrder(r));
                    byId[r.orderId] = arr.length - 1;
                    addedIds.push(r.orderId);
                    counts.added++;
                    continue;
                }
                if (policy === "overwrite") {
                    // For overwrite policy, we need to adjust the order data and calculate the inventory, discount, price, and sales matrics
                    // Hence we will give back the updated orders and try to adjust the order.
                    var order = OrdersStore.getById(r.orderId)
                    if (!order || order.status !== "completed") continue;
                    updatedOrders.push({orderId: r.orderId, products: r.products})
                    counts.updated++;
                }
            } else {
                if (!r.orderId || r.orderId.length === 0) {
                    orders = arr;  // align nextOrderId scope
                    r.orderId = nextOrderId();
                }
                var doc = _normalizeOrder(r);
                arr.push(doc);
                byId[doc.orderId] = arr.length - 1;
                addedIds.push(doc.orderId);
                FirebaseService.put("orders/" + doc.orderId, doc, function(ok) {
                    if (!ok) console.warn("[OrdersStore] import add failed");
                });
                counts.added++;
            }
        }

        orders = arr;
        revision++;
        _refreshCounts();
        counts.addedIds = addedIds;
        counts.updatedOrders = updatedOrders
        return counts;
    }

    function _normalizeOrder(r) {
        var prods = [];
        var rawProducts = r.products || [];
        for (var i = 0; i < rawProducts.length; ++i) {
            var lp = rawProducts[i];
            // Resolve tax info from inventory if not carried on the line.
            var inv = lp.productId ? InventoryStore.getById(lp.productId) : null;
            var taxable = lp.taxable !== undefined ? !!lp.taxable : (inv ? !!inv.taxable : false);
            var taxPercent = lp.taxPercent !== undefined && lp.taxPercent !== null
                ? Number(lp.taxPercent)
                : (inv && taxable ? Number(inv.taxPercent || 0) : 0);
            var lnType = lp.discountType === "percent" ? "percent" : "flat";
            var lnVal = parseCurrency(lp.discountValue);
            prods.push({
                productId: lp.productId || "",
                name: lp.name || "",
                price: typeof lp.price === "number" ? lp.price : parseCurrency(lp.price),
                quantity: parseInt(lp.quantity) || parseInt(lp.qty) || 0,
                taxable: taxable,
                taxPercent: isNaN(taxPercent) ? 0 : taxPercent,
                discountType: lnType,
                discountValue: lnVal,
                // FIFO batch lineage stamped by DataModel on order completion
                consumption: Array.isArray(lp.consumption) ? lp.consumption.slice() : []
            });
        }

        var totals = computeOrderTotals(prods);

        return {
            orderId: r.orderId,
            customer: r.customer || "",
            email: r.email || "",
            phone: r.phone || "",
            items: prods.length > 0 ? totals.itemCount : (parseInt(r.items) || 0),
            subtotal: totals.subtotal,
            discount: totals.discount,
            tax: totals.tax,
            taxBreakdown: totals.taxBreakdown,
            total: prods.length > 0 ? totals.total : parseCurrency(r.total),
            status: r.status || "pending",
            date: r.date || Qt.formatDate(new Date(), "yyyy-MM-dd"),
            updatedAt: r.updatedAt || new Date().toISOString(),
            notes: r.notes || "",
            orderChannel: r.orderChannel || "",
            staffId: r.staffId || "",
            products: prods
        };
    }

    // Compute subtotal, summed per-line discount, per-rate tax breakdown, and
    // grand total. Each line carries its own discountType/discountValue; tax is
    // taken on the discounted line net and is a pass-through (excluded from net).
    function computeOrderTotals(prods) {
        if (!prods) prods = [];
        var subtotal = 0; var itemCount = 0; var totalDiscount = 0;
        var taxByRate = {}; var totalTax = 0;
        for (var i = 0; i < prods.length; ++i) {
            var p = prods[i];
            var lineGross = p.quantity * p.price;
            subtotal += lineGross;
            itemCount += p.quantity;
            var lnType = p.discountType === "percent" ? "percent" : "flat";
            var lineDisc;
            if (lnType === "percent") {
                var pct = parseFloat(p.discountValue) || 0;
                if (pct < 0) pct = 0;
                if (pct > 100) pct = 100;
                lineDisc = lineGross * (pct / 100);
            } else {
                lineDisc = parseFloat(p.discountValue) || 0;
                if (lineDisc < 0) lineDisc = 0;
                if (lineDisc > lineGross) lineDisc = lineGross;
            }
            totalDiscount += lineDisc;
            var lineNet = lineGross - lineDisc;
            if (p.taxable && p.taxPercent && p.taxPercent > 0) {
                var lineTax = lineNet * (p.taxPercent / 100);
                taxByRate[p.taxPercent] = (taxByRate[p.taxPercent] || 0) + lineTax;
                totalTax += lineTax;
            }
        }
        var taxBreakdown = [];
        var keys = Object.keys(taxByRate).sort(function(a, b) { return parseFloat(a) - parseFloat(b); });
        for (var k = 0; k < keys.length; ++k)
            taxBreakdown.push({ rate: parseFloat(keys[k]), amount: taxByRate[keys[k]] });

        var roundedDiscount = Math.round(totalDiscount * 100) / 100;
        var roundedTax = Math.round(totalTax * 100) / 100;
        var roundedSubtotal = Math.round(subtotal * 100) / 100;
        var roundedNet = Math.round((roundedSubtotal - roundedDiscount) * 100) / 100;
        var total = Math.round((roundedNet + roundedTax) * 100) / 100;

        return {
            subtotal: roundedSubtotal,
            discount: roundedDiscount,
            tax: roundedTax,
            taxBreakdown: taxBreakdown,
            total: total,
            itemCount: itemCount
        };
    }

    function _mergeOrder(existing, incoming) {
        var merged = {};
        var keys = ["orderId", "customer", "email", "phone", "items", "total",
                    "status", "date", "notes", "products",
                    "subtotal", "discount", "tax", "taxBreakdown",
                    "orderChannel", "staffId"];
        for (var i = 0; i < keys.length; ++i) {
            var k = keys[i];
            var v = incoming[k];
            var isEmpty = v === undefined || v === null
                       || (typeof v === "string" && v.length === 0)
                       || (Array.isArray(v) && v.length === 0);
            merged[k] = isEmpty ? existing[k] : v;
        }
        return _normalizeOrder(merged);
    }

    // Reactive properties – UI binds directly to these
    property int revision: 0
    property int pendingOrderCount: 2
    property int completedOrderCount: 0
    property int outOfStockCount: 0
    readonly property int count: orders.length

    function _refreshCounts() {
        var p = 0; var c = 0; var oos = 0;
        for (var i = 0; i < orders.length; ++i) {
            if (orders[i].status === "pending") p++;
            if (orders[i].status === "completed") c++;
            if (orders[i].status === "out of stock") oos++;
        }
        pendingOrderCount = p;
        completedOrderCount = c;
        outOfStockCount = oos;
    }

    function _commit(arr) {
        orders = arr;
        revision++;
        _refreshCounts();
        _pushAllToFirebase();
    }

    function _clone() {
        var a = [];
        for (var i = 0; i < orders.length; ++i) {
            var o = orders[i];
            var prods = [];
            if (o.products) {
                for (var j = 0; j < o.products.length; ++j) {
                    var p = o.products[j];
                    // Keep productId on every line item — _tryCompleteOrder
                    // uses it to deduct stock against the right inventory row.
                    // Deep-copy consumption[] so consumers can mutate their
                    // own clones without bleeding into the live store array.
                    var consClone = [];
                    if (Array.isArray(p.consumption)) {
                        for (var ci = 0; ci < p.consumption.length; ++ci) {
                            var c = p.consumption[ci];
                            consClone.push({
                                batchId: c.batchId || "",
                                supplierId: c.supplierId || "",
                                qtyConsumed: c.qtyConsumed || 0,
                                unitCost: c.unitCost || 0
                            });
                        }
                    }
                    prods.push({ productId: p.productId || "", name: p.name, price: p.price, quantity: p.quantity,
                                 taxable: !!p.taxable,
                                 taxPercent: typeof p.taxPercent === "number" ? p.taxPercent : 0,
                                 discountType: p.discountType === "percent" ? "percent" : "flat",
                                 discountValue: typeof p.discountValue === "number" ? p.discountValue : parseCurrency(p.discountValue),
                                 consumption: consClone });
                }
            }
            var bd = [];
            if (o.taxBreakdown) {
                for (var k = 0; k < o.taxBreakdown.length; ++k)
                    bd.push({ rate: o.taxBreakdown[k].rate, amount: o.taxBreakdown[k].amount });
            }
            a.push({ orderId: o.orderId, customer: o.customer, items: o.items,
                      subtotal: o.subtotal || 0,
                      discount: o.discount || 0,
                      tax: o.tax || 0,
                      taxBreakdown: bd,
                      total: o.total, status: o.status, date: o.date,
                      notes: o.notes, email: o.email, phone: o.phone,
                      orderChannel: o.orderChannel || "",
                      staffId: o.staffId || "",
                      adjustments: Array.isArray(o.adjustments) ? o.adjustments.slice() : [],
                      products: prods });
        }
        return a;
    }

    function pendingCount() { return pendingOrderCount; }
    function completedThisMonth() { return completedOrderCount; }

    function nextOrderId() {
        var max = 0;
        for (var i = 0; i < orders.length; ++i) {
            var num = parseInt(String(orders[i].orderId).split('-')[1]);
            if (!isNaN(num) && num > max) max = num;
        }
        return 'ORD-' + String(max + 1).padStart(3, '0');
    }

    function parseCurrency(str) {
        if (typeof str === 'number') return str;
        if (!str) return 0;
        var s = String(str).replace(/[^0-9.]/g, '');
        var n = parseFloat(s);
        return isNaN(n) ? 0 : n;
    }

    function formatCurrency(val) {
        var n = parseCurrency(val);
        // Up to 1 decimal so a fractional discount/total displays exactly
        // (₹10.5), integers stay clean (₹15) — display now matches the math.
        try { return new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 0, maximumFractionDigits: 1 }).format(n); }
        catch(e) { return 'INR ' + (Math.round(n * 10) / 10).toString(); }
    }

    function findIndexById(orderId) {
        for (var i = 0; i < orders.length; ++i)
            if (orders[i].orderId === orderId) return i;
        return -1;
    }

    function get(idx) { return idx >= 0 && idx < orders.length ? orders[idx] : null; }
    function getById(orderId) { var idx = findIndexById(orderId); return idx >= 0 ? orders[idx] : null; }

    // Count of open orders (pending/processing/out of stock) that reference
    // the given productId in their line items. Used to block product delete.
    function openOrdersForProduct(productId) {
        var open = ["pending", "processing", "out of stock"]
        var refs = []
        for (var i = 0; i < orders.length; ++i) {
            var o = orders[i]
            if (open.indexOf(o.status) < 0) continue
            var prods = o.products || []
            for (var j = 0; j < prods.length; ++j) {
                if (prods[j].productId === productId) {
                    refs.push(o.orderId)
                    break
                }
            }
        }
        return refs
    }

    function updateOrder(orderId, fields) {
        var idx = findIndexById(orderId);
        if (idx < 0) return;
        var arr = _clone();
        var o = arr[idx];
        if (fields.status        !== undefined) o.status        = fields.status;
        if (fields.customer      !== undefined) o.customer      = fields.customer;
        if (fields.email         !== undefined) o.email         = fields.email;
        if (fields.phone         !== undefined) o.phone         = fields.phone;
        if (fields.items         !== undefined) o.items         = fields.items;
        if (fields.notes         !== undefined) o.notes         = fields.notes;
        if (fields.products      !== undefined) o.products      = fields.products;
        if (fields.orderChannel  !== undefined) o.orderChannel  = fields.orderChannel;
        if (fields.staffId       !== undefined) o.staffId       = fields.staffId;

        if (fields.products !== undefined) {
            var t = computeOrderTotals(o.products || []);
            o.subtotal = t.subtotal;
            o.discount = t.discount;
            o.tax = t.tax;
            o.taxBreakdown = t.taxBreakdown;
            o.total = t.total;
            o.items = t.itemCount;
        }
        if (fields.total !== undefined) o.total = parseCurrency(fields.total);
        o.updatedAt = new Date().toISOString();
        _commit(arr);
    }

    // Apply a return/exchange/modify adjustment: set the order's lines to the
    // post-adjustment state, recompute totals, and append one immutable entry to
    // the order's adjustments[] audit log. Used by DataModel._tryAdjustOrder
    // AFTER it has already written the stock + ledger reversals. Distinct from
    // updateOrder so the normal edit path is untouched.
    //   adjustmentRecord: { date, reason, condition, lineDeltas, refundAmount, note, actorUid }
    function applyAdjustment(orderId, newLines, adjustmentRecord) {
        var idx = findIndexById(orderId);
        if (idx < 0) return;
        var arr = _clone();
        var o = arr[idx];
        o.products = newLines || [];
        var t = computeOrderTotals(o.products);
        o.subtotal = t.subtotal;
        o.discount = t.discount;
        o.taxBreakdown = t.taxBreakdown;
        o.items = t.itemCount;
        // A COMPLETED order's lines (one tax rate each) can't represent
        // mixed-vintage tax (originals at the booked rate + units added after a
        // tax change at the current rate). _tryAdjustOrder has already booked the
        // added units' sale events, so take the authoritative tax/net/total from
        // the immutable ledger — reconciles with the Analysis reports by
        // construction. Pending orders have no ledger yet → keep the line totals.
        if (o.status === "completed") {
            var led = (typeof TransactionStore !== "undefined" && TransactionStore)
                    ? TransactionStore.totalsForOrder(orderId) : null;
            if (led) {
                o.tax = led.tax;
                o.total = led.total;
            } else {
                o.tax = t.tax; o.total = t.total;
            }
        } else {
            o.tax = t.tax;
            o.total = t.total;
        }
        if (!Array.isArray(o.adjustments)) o.adjustments = [];
        o.adjustments.push(adjustmentRecord);
        o.updatedAt = new Date().toISOString();
        _commit(arr);
    }

    function approveAllPending() {
        var arr = _clone();
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].status === "pending")
                arr[i].status = "completed";
        }
        _commit(arr);
    }

    // `orderChannel` (e.g. "Online" / "In-store" / "Direct") and `staffId`
    // (the salesperson) are optional — empty strings are persisted when the
    // caller doesn't supply them, so the Analysis page can detect
    // "(unspecified)" rows and bucket them out of per-channel/per-staff
    // breakdowns.
    function addOrder(customer, items, total, status, date, email, phone, orderProducts, orderChannel, staffId) {
        var id = nextOrderId();
        var iso = Qt.formatDate(date, 'yyyy-MM-dd');
        var arr = _clone();
        var prods = [];
        if (orderProducts) {
            for (var k = 0; k < orderProducts.length; ++k) {
                var pp = orderProducts[k];
                var inv = pp.productId ? InventoryStore.getById(pp.productId) : null;
                var taxable = pp.taxable !== undefined ? !!pp.taxable : (inv ? !!inv.taxable : false);
                var taxPercent = pp.taxPercent !== undefined && pp.taxPercent !== null
                    ? Number(pp.taxPercent)
                    : (inv && taxable ? Number(inv.taxPercent || 0) : 0);
                prods.push({
                    productId: pp.productId || "",
                    name: pp.name,
                    price: pp.price,
                    quantity: pp.qty !== undefined ? pp.qty : (pp.quantity || 0),
                    taxable: taxable,
                    taxPercent: isNaN(taxPercent) ? 0 : taxPercent,
                    discountType: pp.discountType === "percent" ? "percent" : "flat",
                    discountValue: parseCurrency(pp.discountValue)
                });
            }
        }
        var totals = computeOrderTotals(prods);
        arr.push({ orderId: id, customer: customer,
                   items: prods.length > 0 ? totals.itemCount : items,
                   subtotal: totals.subtotal,
                   discount: totals.discount,
                   tax: totals.tax,
                   taxBreakdown: totals.taxBreakdown,
                   total: prods.length > 0 ? totals.total : total,
                   status: status, date: iso, notes: "",
                   email: email || "", phone: phone || "",
                   orderChannel: orderChannel || "",
                   staffId: staffId || "",
                   updatedAt: new Date().toISOString(),
                   products: prods });
        _commit(arr);
    }

    function deleteOrder(orderId) {
        var arr = _clone();
        var found = false
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].orderId === orderId) { arr.splice(i, 1); found = true; break; }
        }
        // Update local state without re-uploading the whole collection
        // (bulk PUT cannot delete documents — it only upserts).
        orders = arr
        revision++
        _refreshCounts()
        if (!found) return

        FirebaseService.remove("orders/" + orderId, function(ok) {
            if (!ok) console.warn("[OrdersStore] Firestore delete failed for", orderId)
        })
    }

    function totalRevenue() {
        var t = 0;
        for (var i = 0; i < orders.length; ++i)
            if (orders[i].status === "completed")
                t += orders[i].total;
        return t;
    }

    function processingCount() {
        var c = 0;
        for (var i = 0; i < orders.length; ++i)
            if (orders[i].status === "processing") c++;
        return c;
    }
}
