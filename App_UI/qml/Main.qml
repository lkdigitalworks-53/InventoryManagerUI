import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

ApplicationWindow {
    id: app
    width: 1024; height: 640; visible: true
    title: "Business Management"
    color: "#f0f2f5"

    property bool compact: width < 520

    // ── Orders ListModel for guaranteed reactivity ──
    ListModel { id: ordersModel }

    // ── Stock error popup ──
    property string stockErrorMsg: ""
    Dialog {
        id: stockErrorDlg; modal: true; title: "Insufficient Inventory"
        anchors.centerIn: parent; width: 420; height: stockErrCol.height + 120
        standardButtons: Dialog.Ok
        Column {
            id: stockErrCol; width: parent.width; spacing: 8
            Text { text: "Cannot complete order — insufficient stock:"; font.pixelSize: 13; font.bold: true; color: "#991b1b"; wrapMode: Text.Wrap; width: parent.width }
            Text { text: app.stockErrorMsg; font.pixelSize: 12; color: "#ef4444"; wrapMode: Text.Wrap; width: parent.width }
        }
    }

    // Check stock and complete a single order; returns true if success
    function tryCompleteOrder(orderId) {
        var o = OrdersStore.getById(orderId);
        if (!o) return false;
        if (o.status === "completed") return true; // already done
        var errs = [];
        if (o.products && o.products.length > 0) {
            for (var i = 0; i < o.products.length; ++i) {
                var p = o.products[i];
                var qty = p.quantity !== undefined ? p.quantity : (p.qty || 0);
                var inv = InventoryStore.findByName(p.name);
                if (!inv) { errs.push(p.name + ": not found in inventory"); continue; }
                if (qty > inv.stock) errs.push(p.name + ": need " + qty + ", only " + inv.stock + " in stock");
            }
        }
        if (errs.length > 0) {
            // Mark order as "out of stock"
            OrdersStore.updateOrder(orderId, { status: "out of stock" });
            app.stockErrorMsg = errs.join("\n");
            stockErrorDlg.open();
            return false;
        }
        // Deduct stock
        if (o.products && o.products.length > 0) {
            for (var j = 0; j < o.products.length; ++j) {
                var pp = o.products[j];
                var qqty = pp.quantity !== undefined ? pp.quantity : (pp.qty || 0);
                var invP = InventoryStore.findByName(pp.name);
                if (invP) InventoryStore.deductStock(invP.productId, qqty);
            }
        }
        // Mark completed
        OrdersStore.updateOrder(orderId, { status: "completed" });
        SalesStore.recordSale(o.total, o.items);
        return true;
    }

    function syncOrdersModel() {
        ordersModel.clear();
        for (var i = 0; i < OrdersStore.orders.length; ++i) {
            var o = OrdersStore.orders[i];
            ordersModel.append({ orderId: o.orderId || "", customer: o.customer || "", items: o.items || 0,
                total: o.total || 0, status: o.status || "", date: o.date || "" });
        }
    }

    function updateOrderInModel(orderId) {
        var o = OrdersStore.getById(orderId);
        if (!o) return;
        for (var i = 0; i < ordersModel.count; ++i) {
            if (ordersModel.get(i).orderId === orderId) {
                ordersModel.set(i, { orderId: o.orderId || "", customer: o.customer || "", items: o.items || 0,
                    total: o.total || 0, status: o.status || "", date: o.date || "" });
                break;
            }
        }
    }

    // Auto-resync ordersModel when OrdersStore revision changes (e.g. Firebase fetch)
    Connections {
        target: OrdersStore
        function onRevisionChanged() { app.syncOrdersModel(); }
    }

    Component.onCompleted: syncOrdersModel()

    // ── Header ──
    Rectangle {
        id: header
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 80
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#3158ff" }
            GradientStop { position: 1.0; color: "#6b41ff" }
        }
        Column {
            anchors.centerIn: parent; spacing: 4
            Label { text: "Business Management"; color: "#ffffff"; font.bold: true; font.pixelSize: 18; anchors.horizontalCenter: parent.horizontalCenter }
            Label { text: "Manage your business operations efficiently"; color: "#dbeafe"; font.pixelSize: 12; anchors.horizontalCenter: parent.horizontalCenter }
        }
        Row {
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
            spacing: 8
            Button {
                id: syncBtn; width: 36; height: 36; padding: 0
                background: Rectangle { radius: 18; color: syncBtn.hovered ? "#ffffff30" : "transparent" }
                contentItem: Text { text: FirebaseService.syncing ? "⏳" : "🔄"; font.pixelSize: 16
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                onClicked: {
                    OrdersStore.syncFromFirebase();
                    InventoryStore.syncFromFirebase();
                    SalesStore.syncFromFirebase();
                    StaffStore.syncFromFirebase();
                    syncOrdersModel();
                }
                ToolTip.visible: hovered; ToolTip.text: FirebaseService.syncing ? "Syncing..." : "Sync with server"
            }
        }
    }

    // ── Segmented Nav ──
    SegmentedNav {
        id: nav
        anchors { top: header.bottom; topMargin: 12; horizontalCenter: parent.horizontalCenter }
        width: Math.min(800, app.width - 32)
        model: [
            { label: "Orders",    icon: "🛒", activeColor: "#ea580c" },
            { label: "Inventory", icon: "📦", activeColor: "#16a34a" },
            { label: "Sales",     icon: "$",  activeColor: "#2563eb" },
            { label: "Staff",     icon: "👥", activeColor: "#2563eb" }
        ]
        currentIndex: 0
    }

    // ── Content ──
    Item {
        id: content
        anchors { top: nav.bottom; topMargin: 12; left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 16; rightMargin: 16 }

        // ── Orders View (index 0) ──
        OrdersPage {
            anchors.fill: parent
            visible: nav.currentIndex === 0
            compact: app.compact
            onAddOrderClicked: newOrderDlg.open()
            onOrderDetailsClicked: function(orderId) { orderDetail.openFor(orderId) }
        }

        // ── Inventory View (index 1) ──
        InventoryPage {
            anchors.fill: parent
            visible: nav.currentIndex === 1
            compact: app.compact
            onAddProductClicked: addProductDlg.open()
            onRestockClicked: function(pid) { restockDlg.openFor(pid) }
        }

        // ── Sales View (index 2) ──
        SalesPage {
            anchors.fill: parent
            visible: nav.currentIndex === 2
            compact: app.compact
        }

        // ── Staff View (index 3) ──
        StaffPage {
            anchors.fill: parent
            visible: nav.currentIndex === 3
            compact: app.compact
            onAddStaffClicked: addStaffDlg.open()
        }
    }

    NewOrderDialog {
        id: newOrderDlg; parent: app.contentItem
        onOrderCreated: function(order) {
            OrdersStore.addOrder(order.customer, order.items, order.total,
                order.status, order.date, order.email, order.phone, order.products)
            app.syncOrdersModel();
        }
    }
    OrderDetailDialog {
        id: orderDetail; parent: app.contentItem
        onOrderUpdated: function(oid) { app.updateOrderInModel(oid); }
    }
    AddProductDialog { id: addProductDlg; parent: app.contentItem }
    AddStaffDialog { id: addStaffDlg; parent: app.contentItem }
    RestockDialog { id: restockDlg; parent: app.contentItem }
}
