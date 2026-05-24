pragma Singleton
import QtQuick

QtObject {
    id: root

    // Live cumulative values that update when orders are placed
    property real totalRevenue: 0
    property int totalOrders: 0
    property int activeCustomers: 0

    // Computed
    readonly property real averageOrder: totalOrders > 0 ? totalRevenue / totalOrders : 0

    function _load() {
        _fetchFromFirebase();
    }

    function _save() {
        _pushToFirebase();
    }

    function _fetchFromFirebase() {
        FirebaseService.get("sales", function(ok, data) {
            if (ok) {
                var d = data || {};
                totalRevenue = d.totalRevenue !== undefined ? d.totalRevenue : 0;
                totalOrders = d.totalOrders !== undefined ? d.totalOrders : 0;
                activeCustomers = d.activeCustomers !== undefined ? d.activeCustomers : 0;
                console.log("[SalesStore] Synced from Firestore");
            } else {
                console.warn("[SalesStore] Firestore sync failed", FirebaseService.lastStatusCode, FirebaseService.lastError)
            }
        });
    }

    function _pushToFirebase() {
        FirebaseService.put("sales", { totalRevenue: totalRevenue, totalOrders: totalOrders, activeCustomers: activeCustomers }, function(ok) {
            if (!ok)
                console.warn("[SalesStore] Firestore write failed", FirebaseService.lastStatusCode, FirebaseService.lastError)
            else
                console.log("[SalesStore] Firestore write ok")
        });
    }

    function syncFromFirebase() { _fetchFromFirebase(); }

    function clear() {
        totalRevenue = 0
        totalOrders = 0
        activeCustomers = 0
        revenueData = []
        ordersData = []
        topProducts = []
    }

    function recordSale(amount, itemCount) {
        totalRevenue += amount;
        totalOrders += 1;
        activeCustomers += 1;
        _save();
        _rebuildDerivedData();
    }

    property var revenueData: []
    property var ordersData: []
    property var topProducts: []
    property int ordersRevisionWatcher: OrdersStore.revision
    onOrdersRevisionWatcherChanged: {
        _rebuildDerivedData()
    }

    function _monthLabel(i) {
        var labels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return labels[i]
    }

    function _safeDate(dateStr) {
        var d = new Date(dateStr)
        if (isNaN(d.getTime()))
            return new Date()
        return d
    }

    function _rebuildDerivedData() {
        try {
        var revenueByMonth = []
        var ordersByMonth = []
        for (var i = 0; i < 12; ++i) {
            revenueByMonth.push(0)
            ordersByMonth.push(0)
        }

        var productMap = {}

        if (typeof OrdersStore === "undefined" || !OrdersStore || !OrdersStore.orders) {
            revenueData = []
            ordersData = []
            topProducts = []
            return
        }

        for (var k = 0; k < OrdersStore.orders.length; ++k) {
            var o = OrdersStore.orders[k]
            if (o.status !== "completed")
                continue

            var d = _safeDate(o.date)
            var m = d.getMonth()
            revenueByMonth[m] += (o.total || 0)
            ordersByMonth[m] += 1

            var products = o.products || []
            for (var j = 0; j < products.length; ++j) {
                var p = products[j]
                var name = p.name || "Unknown"
                var qty = p.quantity !== undefined ? p.quantity : (p.qty || 0)
                var price = p.price || 0
                if (!productMap[name])
                    productMap[name] = { name: name, sold: 0, revenue: 0 }
                productMap[name].sold += qty
                productMap[name].revenue += qty * price
            }
        }

        // Recompute KPI totals from completed orders
        var totalRev = 0
        var totalOrd = 0
        var customerSet = {}
        for (var z = 0; z < OrdersStore.orders.length; ++z) {
            var co = OrdersStore.orders[z]
            if (co.status === "completed") {
                totalRev += (co.total || 0)
                totalOrd += 1
                if (co.customer) customerSet[co.customer] = true
            }
        }
        totalRevenue = totalRev
        totalOrders = totalOrd
        activeCustomers = Object.keys(customerSet).length

        var rev = []
        var ord = []
        for (var x = 0; x < 12; ++x) {
            rev.push({ month: _monthLabel(x), value: revenueByMonth[x] })
            ord.push({ month: _monthLabel(x), value: ordersByMonth[x] })
        }
        revenueData = rev
        ordersData = ord

        var prodArr = []
        var keys = Object.keys(productMap)
        for (var y = 0; y < keys.length; ++y)
            prodArr.push(productMap[keys[y]])
        prodArr.sort(function(a, b) { return b.revenue - a.revenue })
        if (prodArr.length > 5)
            prodArr = prodArr.slice(0, 5)
        topProducts = prodArr
        } catch (e) {
            console.warn("[SalesStore] _rebuildDerivedData failed:", e)
            revenueData = []
            ordersData = []
            topProducts = []
        }
    }

    function formatCurrency(val) {
        var n = typeof val === 'number' ? val : parseFloat(String(val).replace(/[^0-9.]/g, ''));
        if (isNaN(n)) n = 0;
        try { return new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(n); }
        catch(e) { return '₹' + Math.round(n).toString(); }
    }

    function formatNumber(val) {
        try { return new Intl.NumberFormat('en-IN').format(val); }
        catch(e) { return String(val); }
    }

    function maxRevenueValue() {
        var m = 0;
        for (var i = 0; i < revenueData.length; ++i)
            if (revenueData[i].value > m) m = revenueData[i].value;
        return m > 0 ? m : 1;
    }

    function maxOrdersValue() {
        var m = 0;
        for (var i = 0; i < ordersData.length; ++i)
            if (ordersData[i].value > m) m = ordersData[i].value;
        return m > 0 ? m : 1;
    }

    Component.onCompleted: {
        _load()
        _rebuildDerivedData()
    }
}
