pragma Singleton
import QtQuick 6.5
import QtCore

QtObject {
    id: root

    // Live cumulative values that update when orders are placed
    property real totalRevenue: 2408425
    property int totalOrders: 321
    property int activeCustomers: 1847

    // Computed
    readonly property real averageOrder: totalOrders > 0 ? totalRevenue / totalOrders : 0

    property Settings _settings: Settings {
        category: "SalesStore"
        property string salesJson: ""
    }

    Component.onCompleted: _load()

    function _load() {
        if (_settings.salesJson && _settings.salesJson.length > 2) {
            try {
                var d = JSON.parse(_settings.salesJson);
                totalRevenue = d.totalRevenue;
                totalOrders = d.totalOrders;
                activeCustomers = d.activeCustomers;
            } catch(e) {}
        }
    }

    function _save() {
        _settings.salesJson = JSON.stringify({ totalRevenue: totalRevenue, totalOrders: totalOrders, activeCustomers: activeCustomers });
    }

    function recordSale(amount, itemCount) {
        totalRevenue += amount;
        totalOrders += 1;
        activeCustomers += 1;
        _save();
    }

    property var revenueData: [
        { month: "Jan", value: 180000 },
        { month: "Feb", value: 220000 },
        { month: "Mar", value: 350000 },
        { month: "Apr", value: 390000 },
        { month: "May", value: 420000 },
        { month: "Jun", value: 400000 },
        { month: "Jul", value: 480000 },
        { month: "Aug", value: 510000 },
        { month: "Sep", value: 490000 },
        { month: "Oct", value: 460000 },
        { month: "Nov", value: 550000 }
    ]

    property var ordersData: [
        { month: "Jan", value: 120 },
        { month: "Feb", value: 150 },
        { month: "Mar", value: 170 },
        { month: "Apr", value: 180 },
        { month: "May", value: 200 },
        { month: "Jun", value: 190 },
        { month: "Jul", value: 250 },
        { month: "Aug", value: 270 },
        { month: "Sep", value: 260 },
        { month: "Oct", value: 290 },
        { month: "Nov", value: 310 }
    ]

    property var topProducts: [
        { name: "Wireless Mouse",      sold: 145, revenue: 362355 },
        { name: "Mechanical Keyboard", sold: 89,  revenue: 667411 },
        { name: "Monitor",             sold: 67,  revenue: 1674933 },
        { name: "USB-C Cable",         sold: 234, revenue: 292266 },
        { name: "Laptop Stand",        sold: 112, revenue: 466592 }
    ]

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
        return m;
    }

    function maxOrdersValue() {
        var m = 0;
        for (var i = 0; i < ordersData.length; ++i)
            if (ordersData[i].value > m) m = ordersData[i].value;
        return m;
    }
}
