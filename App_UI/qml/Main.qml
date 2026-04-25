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
            ordersModel.append({ orderId: o.orderId, customer: o.customer, items: o.items,
                total: o.total, status: o.status, date: o.date });
        }
    }

    function updateOrderInModel(orderId) {
        var o = OrdersStore.getById(orderId);
        if (!o) return;
        for (var i = 0; i < ordersModel.count; ++i) {
            if (ordersModel.get(i).orderId === orderId) {
                ordersModel.set(i, { orderId: o.orderId, customer: o.customer, items: o.items,
                    total: o.total, status: o.status, date: o.date });
                break;
            }
        }
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
        Flickable {
            anchors.fill: parent
            visible: nav.currentIndex === 0
            contentHeight: col.height
            clip: true
            flickableDirection: Flickable.VerticalFlick
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
                id: col
                width: content.width
                spacing: 16

                // ── Title + New Order + Auto-Approval ──
                RowLayout {
                    width: col.width; spacing: 8
                    Column { spacing: 4; Layout.fillWidth: true
                        Label { text: "Order Management"; color: "#111827"; font.bold: true; font.pixelSize: 18 }
                        Label { text: "Manage and track customer orders"; color: "#6b7280"; font.pixelSize: 12 }
                    }
                    Button {
                        id: autoApprovalBtn; text: "⚙ Auto-Approval"
                        background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                        contentItem: Text { text: autoApprovalBtn.text; color: "#374151"; font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        id: newOrderBtn; text: "+  New Order"
                        onClicked: dlg.open()
                        background: Rectangle { radius: 8; color: "#ff7a00" }
                        contentItem: Text { text: newOrderBtn.text; color: "white"; font.bold: true; font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                }

                // ── KPI Cards (gradient) ──
                Row {
                    width: col.width; spacing: 12
                    // Total Orders - orange gradient
                    Rectangle {
                        width: (col.width - 24) / 3; height: 130; radius: 16
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#f97316" }
                            GradientStop { position: 1.0; color: "#fb923c" }
                        }
                        Column { x: 20; y: 16; spacing: 4
                            Row { spacing: 6
                                Text { text: "🛒"; font.pixelSize: 16 }
                                Text { text: "Total Orders"; font.pixelSize: 14; font.bold: true; color: "#ffffff" }
                            }
                            Text { text: "All time"; font.pixelSize: 12; color: "#fed7aa" }
                            Item { width: 1; height: 8 }
                            Text { text: String(ordersModel.count); font.pixelSize: 36; font.bold: true; color: "#ffffff" }
                        }
                    }
                    // Pending - amber gradient
                    Rectangle {
                        width: (col.width - 24) / 3; height: 130; radius: 16
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#eab308" }
                            GradientStop { position: 1.0; color: "#facc15" }
                        }
                        Column { x: 20; y: 16; spacing: 4
                            Row { spacing: 6
                                Text { text: "●"; font.pixelSize: 12; color: "#ffffff" }
                                Text { text: "Pending"; font.pixelSize: 14; font.bold: true; color: "#ffffff" }
                            }
                            Text { text: "Awaiting processing"; font.pixelSize: 12; color: "#fef9c3" }
                            Item { width: 1; height: 8 }
                            Text { text: String(OrdersStore.pendingOrderCount); font.pixelSize: 36; font.bold: true; color: "#ffffff" }
                        }
                    }
                    // Completed - green gradient
                    Rectangle {
                        width: (col.width - 24) / 3; height: 130; radius: 16
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#16a34a" }
                            GradientStop { position: 1.0; color: "#4ade80" }
                        }
                        Column { x: 20; y: 16; spacing: 4
                            Row { spacing: 6
                                Text { text: "✓"; font.pixelSize: 16; color: "#ffffff"; font.bold: true }
                                Text { text: "Completed"; font.pixelSize: 14; font.bold: true; color: "#ffffff" }
                            }
                            Text { text: "This month"; font.pixelSize: 12; color: "#bbf7d0" }
                            Item { width: 1; height: 8 }
                            Text { text: String(OrdersStore.completedOrderCount); font.pixelSize: 36; font.bold: true; color: "#ffffff" }
                        }
                    }
                }

                // ── Orders Table ──
                Rectangle {
                    width: col.width; height: ordersCol.height + 32
                    radius: 12; color: "#ffffff"; border.color: "#e5e7eb"

                    Column {
                        id: ordersCol
                        x: 16; y: 16; width: parent.width - 32; spacing: 12

                        RowLayout {
                            width: ordersCol.width; spacing: 8
                            Column { spacing: 2; Layout.fillWidth: true
                                Label { text: "Recent Orders"; font.pixelSize: 14; font.bold: true; color: "#111827" }
                                Label { text: "Latest customer orders"; font.pixelSize: 11; color: "#6b7280" }
                            }
                            Button {
                                id: approveAllBtn
                                text: "✓ Approve All Pending  " + OrdersStore.pendingOrderCount
                                enabled: OrdersStore.pendingOrderCount > 0
                                onClicked: {
                                    // Approve all pending one by one, checking stock for each
                                    var allOrders = OrdersStore.orders;
                                    var failed = [];
                                    for (var i = 0; i < allOrders.length; ++i) {
                                        if (allOrders[i].status === "pending") {
                                            if (!app.tryCompleteOrder(allOrders[i].orderId))
                                                failed.push(allOrders[i].orderId);
                                        }
                                    }
                                    app.syncOrdersModel();
                                    if (failed.length > 0) {
                                        app.stockErrorMsg = "Could not approve: " + failed.join(", ") + " (insufficient stock)";
                                        stockErrorDlg.open();
                                    }
                                }
                                background: Rectangle { radius: 20; color: approveAllBtn.enabled ? "#22c55e" : "#d1d5db" }
                                contentItem: Row {
                                    spacing: 6
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    Text { text: "✓ Approve All Pending"; color: "white"; font.bold: true; font.pixelSize: 12
                                        verticalAlignment: Text.AlignVCenter; anchors.verticalCenter: parent.verticalCenter }
                                    Rectangle {
                                        width: 22; height: 22; radius: 11; color: "#ffffff30"
                                        anchors.verticalCenter: parent.verticalCenter
                                        Text { text: String(OrdersStore.pendingOrderCount); color: "white"; font.pixelSize: 11; font.bold: true; anchors.centerIn: parent }
                                    }
                                }
                            }
                        }

                        TextField {
                            id: search; width: ordersCol.width
                            placeholderText: "\uD83D\uDD0D  Search orders..."
                            font.pixelSize: 12
                            background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#e5e7eb" }
                        }

                        // Header row
                        Row {
                            id: headerRow
                            visible: !app.compact; width: ordersCol.width; height: 32; spacing: 0
                            property var labels: ["Order ID","Customer","Items","Total","Status","Date","Actions"]
                            property var ws:     [0.14,0.24,0.10,0.14,0.14,0.14,0.10]
                            Repeater {
                                model: headerRow.labels
                                Rectangle {
                                    width: ordersCol.width * headerRow.ws[index]; height: 32; color: "transparent"
                                    Text { text: modelData; color: "#6b7280"; font.pixelSize: 12; font.bold: true
                                        anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                                }
                            }
                        }

                        Rectangle { width: ordersCol.width; height: 1; color: "#e5e7eb" }

                        Flickable {
                            id: tableFlick; width: ordersCol.width; height: 360
                            clip: true; flickableDirection: Flickable.VerticalFlick
                            contentHeight: tableCol.height
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                            Column {
                                id: tableCol; width: tableFlick.width; spacing: 0
                                Repeater {
                                    id: ordersRepeater
                                    model: ordersModel
                                    delegate: Rectangle {
                                        id: rowDel
                                        width: tableCol.width; height: rowVisible ? 44 : 0; color: "#ffffff"
                                        property bool rowVisible: search.text === "" || (model.orderId + model.customer + model.status).toLowerCase().indexOf(search.text.toLowerCase()) >= 0
                                        visible: rowVisible

                                        property var ws: [0.14,0.24,0.10,0.14,0.14,0.14,0.10]
                                        function cw(i) { return rowDel.width * rowDel.ws[i]; }

                                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: "#f1f5f9" }

                                        // Order ID
                                        Text { x: 0; width: cw(0); text: model.orderId; color: "#111827"; font.pixelSize: 12
                                            verticalAlignment: Text.AlignVCenter; height: parent.height; leftPadding: 8 }
                                        // Customer
                                        Text { x: cw(0); width: cw(1); text: model.customer; color: "#111827"; font.pixelSize: 12
                                            verticalAlignment: Text.AlignVCenter; height: parent.height; leftPadding: 4 }
                                        // Items
                                        Text { x: cw(0)+cw(1); width: cw(2); text: String(model.items); color: "#111827"; font.pixelSize: 12
                                            verticalAlignment: Text.AlignVCenter; height: parent.height; leftPadding: 4 }
                                        // Total
                                        Text { x: cw(0)+cw(1)+cw(2); width: cw(3); text: OrdersStore.formatCurrency(model.total); color: "#111827"; font.pixelSize: 12
                                            verticalAlignment: Text.AlignVCenter; height: parent.height; leftPadding: 4 }
                                        // Status badge
                                        Item {
                                            x: cw(0)+cw(1)+cw(2)+cw(3); width: cw(4); height: parent.height
                                            StatusBadge {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: model.status; status: model.status; showDropdown: true
                                                onStatusChangeRequested: function(s) {
                                                    if (s === "completed") {
                                                        app.tryCompleteOrder(model.orderId);
                                                    } else {
                                                        OrdersStore.updateOrder(model.orderId, { status: s });
                                                    }
                                                    app.updateOrderInModel(model.orderId);
                                                }
                                            }
                                        }
                                        // Date
                                        Text { x: cw(0)+cw(1)+cw(2)+cw(3)+cw(4); width: cw(5); text: model.date; color: "#6b7280"; font.pixelSize: 12
                                            verticalAlignment: Text.AlignVCenter; height: parent.height; leftPadding: 4 }
                                        // Actions
                                        Row {
                                            x: cw(0)+cw(1)+cw(2)+cw(3)+cw(4)+cw(5); width: cw(6); height: parent.height; spacing: 4
                                            Button {
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: model.status === "pending" || model.status === "out of stock"
                                                width: 28; height: 28; padding: 0
                                                background: Rectangle { radius: 6; color: "#dcfce7"; border.color: "#22c55e" }
                                                contentItem: Text { text: "\u2713"; color: "#22c55e"; font.pixelSize: 14; font.bold: true
                                                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                                onClicked: {
                                                    app.tryCompleteOrder(model.orderId);
                                                    app.updateOrderInModel(model.orderId);
                                                }
                                                ToolTip.visible: hovered; ToolTip.text: "Approve"
                                            }
                                            Button {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 28; height: 28; padding: 0
                                                background: Rectangle { radius: 6; color: "#f3f4f6"; border.color: "#e5e7eb" }
                                                contentItem: Text { text: "\u270E"; color: "#6b7280"; font.pixelSize: 14
                                                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                                onClicked: detail.openFor(model.orderId)
                                                ToolTip.visible: hovered; ToolTip.text: "Edit"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
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
        id: dlg; parent: app.contentItem
        onOrderCreated: function(order) {
            OrdersStore.addOrder(order.customer, order.items, order.total,
                order.status, order.date, order.email, order.phone, order.products)
            app.syncOrdersModel();
        }
    }
    OrderDetailDialog {
        id: detail; parent: app.contentItem
        onOrderUpdated: function(oid) { app.updateOrderInModel(oid); }
    }
    AddProductDialog { id: addProductDlg; parent: app.contentItem }
    AddStaffDialog { id: addStaffDlg; parent: app.contentItem }
    RestockDialog { id: restockDlg; parent: app.contentItem }
}
