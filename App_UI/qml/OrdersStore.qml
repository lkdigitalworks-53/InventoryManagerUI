
pragma Singleton
import QtQuick 6.5
import QtCore

QtObject {
    id: root

    readonly property var _seedOrders: [
        { orderId: "ORD-001", customer: "John Smith",      items: 5, total: 20495, status: "pending",    date: "2025-11-28", notes: "", email: "john@example.com",      phone: "+91 98765 43210", products: [] },
        { orderId: "ORD-002", customer: "Sarah Johnson",   items: 3, total: 15791, status: "completed",  date: "2025-11-28", notes: "", email: "sarah@example.com",     phone: "+91 99887 76543", products: [] },
        { orderId: "ORD-003", customer: "Michael Brown",   items: 7, total: 47303, status: "processing", date: "2025-11-29", notes: "", email: "michael@example.com",   phone: "+91 98123 45678", products: [] },
        { orderId: "ORD-004", customer: "Emily Davis",     items: 2, total: 8332,  status: "completed",  date: "2025-11-29", notes: "", email: "emily@example.com",     phone: "+91 97654 32109", products: [] },
        { orderId: "ORD-005", customer: "David Wilson",    items: 4, total: 26067, status: "pending",    date: "2025-11-30", notes: "", email: "david@example.com",     phone: "+91 96543 21098", products: [] },
        { orderId: "ORD-006", customer: "Lisa Anderson",   items: 6, total: 37147, status: "processing", date: "2025-11-30", notes: "", email: "lisa@example.com",      phone: "+91 95432 10987", products: [] }
    ]

    property var orders: []

    property Settings _settings: Settings {
        category: "OrdersStore"
        property string ordersJson: ""
    }

    Component.onCompleted: _load()

    function _load() {
        if (_settings.ordersJson && _settings.ordersJson.length > 2) {
            try { orders = JSON.parse(_settings.ordersJson); } catch(e) { orders = _seedOrders.slice(); }
        } else {
            orders = _seedOrders.slice();
        }
        _refreshCounts();
    }

    function _save() {
        _settings.ordersJson = JSON.stringify(orders);
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
        _save();
    }

    function _clone() {
        var a = [];
        for (var i = 0; i < orders.length; ++i) {
            var o = orders[i];
            var prods = [];
            if (o.products) {
                for (var j = 0; j < o.products.length; ++j) {
                    var p = o.products[j];
                    prods.push({ name: p.name, price: p.price, quantity: p.quantity });
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
                prods.push({ name: pp.name, price: pp.price, quantity: pp.qty !== undefined ? pp.qty : (pp.quantity || 0) });
            }
        }
        arr.push({ orderId: id, customer: customer, items: items, total: total,
                   status: status, date: iso, notes: "",
                   email: email || "", phone: phone || "",
                   products: prods });
        _commit(arr);
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
