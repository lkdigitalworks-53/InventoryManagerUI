pragma Singleton
import QtQuick
import "../helper/OrderMath.js" as OrderMath

QtObject {
    id: root

    // Live cumulative values that update when orders are placed
    property real totalRevenue: 0
    property int totalOrders: 0
    property int activeCustomers: 0

    // Computed
    readonly property real averageOrder: totalOrders > 0 ? totalRevenue / totalOrders : 0

    // OrdersStore is the SINGLE source of truth for these KPIs. They are
    // derived (_rebuildDerivedData sums allocate().totals.net over completed
    // orders and counts them), never an independently-persisted running tally.
    //
    // The old design ALSO kept an incrementing "sales/summary" doc that
    // recordSale bumped (by tax-inclusive o.total) and _fetchFromFirebase loaded
    // back. That summary was never decremented, so reopening + re-completing an
    // order double-counted it; and its tax-inclusive revenue disagreed with the
    // net-based Analysis/Dashboard. On load it clobbered the correct recompute.
    // We no longer read or write that doc — recompute from OrdersStore instead.
    function _load() {
        _rebuildDerivedData();
    }

    function _fetchFromFirebase() {
        // Orders may not have synced yet on first call; OrdersStore.revision
        // bumps (onOrdersRevisionWatcherChanged) trigger a fresh recompute once
        // they land, so this is safe to call eagerly.
        _rebuildDerivedData();
    }

    function syncFromFirebase() { _rebuildDerivedData(); }

    function clear() {
        totalRevenue = 0
        totalOrders = 0
        activeCustomers = 0
        revenueData = []
        ordersData = []
        topProducts = []
    }

    // Kept for the Logic.recordSale signal path, but it no longer maintains an
    // independent running tally (that double-counted on re-completion and used
    // tax-inclusive amounts). The KPIs are recomputed from OrdersStore, which is
    // the source of truth — the order it represents is already persisted there.
    // (Most callers reach completion via DataModel._tryCompleteOrder, which bumps
    // OrdersStore.revision → onOrdersRevisionWatcherChanged → recompute anyway.)
    function recordSale(amount, itemCount) {
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
            var a = OrderMath.allocate(o)
            revenueByMonth[m] += a.totals.net
            ordersByMonth[m] += 1

            var allocByPid = {}
            for (var ai = 0; ai < a.perLine.length; ++ai) {
                var pl = a.perLine[ai]
                allocByPid[pl.productId] = pl
            }

            var products = o.products || []
            for (var j = 0; j < products.length; ++j) {
                var p = products[j]
                var name = p.name || "Unknown"
                var qty = p.quantity !== undefined ? p.quantity : (p.qty || 0)
                var lineNet = allocByPid[p.productId] ? allocByPid[p.productId].net : (qty * (p.price || 0))
                if (!productMap[name])
                    productMap[name] = { name: name, sold: 0, revenue: 0 }
                productMap[name].sold += qty
                productMap[name].revenue += lineNet
            }
        }

        // Recompute KPI totals from completed orders
        var totalRev = 0
        var totalOrd = 0
        var customerSet = {}
        for (var z = 0; z < OrdersStore.orders.length; ++z) {
            var co = OrdersStore.orders[z]
            if (co.status === "completed") {
                totalRev += OrderMath.allocate(co).totals.net
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
        // Up to 1 decimal so fractional values display exactly; integers clean.
        try { return new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 0, maximumFractionDigits: 1 }).format(n); }
        catch(e) { return '₹' + (Math.round(n * 10) / 10).toString(); }
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
