
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
                    if (!o.status) o.status = "pending";
                    if (!o.date) o.date = o.created_at || "";
                    if (!o.notes) o.notes = "";
                    if (!o.email) o.email = "";
                    if (!o.phone) o.phone = "";
                    if (!o.products) o.products = [];
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
    // Returns { added, updated, skipped } counts.
    function upsertMany(records) {
        var counts = { added: 0, updated: 0, skipped: 0 };
        if (!records || records.length === 0) return counts;

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
                    products = arr;  // ensure nextOrderId() sees latest
                    r.orderId = nextOrderId();
                    arr.push(_normalizeOrder(r));
                    byId[r.orderId] = arr.length - 1;
                    counts.added++;
                    continue;
                }
                arr[existingIdx] = _mergeOrder(arr[existingIdx], r);
                FirebaseService.put("orders/" + arr[existingIdx].orderId, arr[existingIdx], function(ok) {
                    if (!ok) console.warn("[OrdersStore] import overwrite failed");
                });
                counts.updated++;
            } else {
                if (!r.orderId || r.orderId.length === 0) {
                    orders = arr;  // align nextOrderId scope
                    r.orderId = nextOrderId();
                }
                var doc = _normalizeOrder(r);
                arr.push(doc);
                byId[doc.orderId] = arr.length - 1;
                FirebaseService.put("orders/" + doc.orderId, doc, function(ok) {
                    if (!ok) console.warn("[OrdersStore] import add failed");
                });
                counts.added++;
            }
        }

        orders = arr;
        revision++;
        _refreshCounts();
        return counts;
    }

    function _normalizeOrder(r) {
        var prods = [];
        var rawProducts = r.products || [];
        for (var i = 0; i < rawProducts.length; ++i) {
            var lp = rawProducts[i];
            prods.push({
                productId: lp.productId || "",
                name: lp.name || "",
                price: typeof lp.price === "number" ? lp.price : parseCurrency(lp.price),
                quantity: parseInt(lp.quantity) || parseInt(lp.qty) || 0
            });
        }
        var totalItems = 0; var totalAmount = 0;
        for (var j = 0; j < prods.length; ++j) {
            totalItems += prods[j].quantity;
            totalAmount += prods[j].quantity * prods[j].price;
        }
        return {
            orderId: r.orderId,
            customer: r.customer || "",
            email: r.email || "",
            phone: r.phone || "",
            items: prods.length > 0 ? totalItems : (parseInt(r.items) || 0),
            total: prods.length > 0 ? totalAmount : parseCurrency(r.total),
            status: r.status || "pending",
            date: r.date || Qt.formatDate(new Date(), "yyyy-MM-dd"),
            notes: r.notes || "",
            products: prods
        };
    }

    function _mergeOrder(existing, incoming) {
        var merged = {};
        var keys = ["orderId", "customer", "email", "phone", "items", "total",
                    "status", "date", "notes", "products"];
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
                    prods.push({ productId: p.productId || "", name: p.name, price: p.price, quantity: p.quantity });
                }
            }
            a.push({ orderId: o.orderId, customer: o.customer, items: o.items,
                      total: o.total, status: o.status, date: o.date,
                      notes: o.notes, email: o.email, phone: o.phone, products: prods });
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
        try { return new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(n); }
        catch(e) { return 'INR ' + Math.round(n).toString(); }
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
        if (fields.status   !== undefined) o.status   = fields.status;
        if (fields.customer !== undefined) o.customer = fields.customer;
        if (fields.email    !== undefined) o.email    = fields.email;
        if (fields.phone    !== undefined) o.phone    = fields.phone;
        if (fields.items    !== undefined) o.items    = fields.items;
        if (fields.total    !== undefined) o.total    = parseCurrency(fields.total);
        if (fields.notes    !== undefined) o.notes    = fields.notes;
        if (fields.products !== undefined) o.products = fields.products;
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

    function addOrder(customer, items, total, status, date, email, phone, orderProducts) {
        var id = nextOrderId();
        var iso = Qt.formatDate(date, 'yyyy-MM-dd');
        var arr = _clone();
        var prods = [];
        if (orderProducts) {
            for (var k = 0; k < orderProducts.length; ++k) {
                var pp = orderProducts[k];
                prods.push({
                    productId: pp.productId || "",
                    name: pp.name,
                    price: pp.price,
                    quantity: pp.qty !== undefined ? pp.qty : (pp.quantity || 0)
                });
            }
        }
        arr.push({ orderId: id, customer: customer, items: items, total: total,
                   status: status, date: iso, notes: "",
                   email: email || "", phone: phone || "",
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
