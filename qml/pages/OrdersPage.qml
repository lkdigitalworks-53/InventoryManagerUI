import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../model"
import "../helper"

Item {
    id: root
    anchors.fill: parent

    property bool compact: false
    property bool canApproveAll: true
    property bool canDeleteOrders: false
    signal addOrderClicked()
    signal orderDetailsClicked(string orderId)
    signal deleteOrderClicked(string orderId)
    signal exportRequested()
    signal importRequested()

    Flickable {
        anchors.fill: parent
        contentHeight: col.height
        clip: true
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
            id: col
            width: root.width
            spacing: 16

            // ── Title + New Order + Auto-Approval ──
            RowLayout {
                width: col.width; spacing: 8
                Column { spacing: 4; Layout.fillWidth: true
                    Label { text: "Order Management"; color: "#111827"; font.bold: true; font.pixelSize: 18 }
                    Label { text: "Manage and track customer orders"; color: "#6b7280"; font.pixelSize: 12 }
                }
                Rectangle {
                    width: 190; height: 36; radius: 8
                    color: "#ffffff"; border.color: "#d1d5db"
                    Row {
                        anchors.fill: parent; anchors.margins: 8; spacing: 6
                        Text {
                            text: "Auto-Approve New Orders"
                            color: "#374151"
                            font.pixelSize: 11
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Switch {
                            checked: OrdersStore.autoApproveEnabled
                            anchors.verticalCenter: parent.verticalCenter
                            onCheckedChanged: OrdersStore.autoApproveEnabled = checked
                        }
                    }
                }
                Button {
                    id: importOrdersBtn; text: "📥  Import"
                    onClicked: root.importRequested()
                    background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                    contentItem: Text { text: importOrdersBtn.text; color: "#374151"; font.bold: true; font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    id: exportOrdersBtn; text: "📤  Export"
                    onClicked: root.exportRequested()
                    background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                    contentItem: Text { text: exportOrdersBtn.text; color: "#374151"; font.bold: true; font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    id: newOrderBtn; text: "+  New Order"
                    onClicked: addOrderClicked()
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
                        Text { text: String(dataModel.ordersModel.count); font.pixelSize: 36; font.bold: true; color: "#ffffff" }
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
                            visible: root.canApproveAll
                            enabled: OrdersStore.pendingOrderCount > 0
                            onClicked: {
                                // Approve all pending one by one, checking stock for each
                                var allOrders = OrdersStore.orders;
                                var failed = [];
                                for (var i = 0; i < allOrders.length; ++i) {
                                    if (allOrders[i].status === "pending") {
                                        if (!dataModel.tryCompleteOrder(allOrders[i].orderId))
                                            failed.push(allOrders[i].orderId);
                                    }
                                }
                                dataModel.syncOrdersModel();
                                if (failed.length > 0) {
                                    dataModel.stockErrorMsg = "Could not approve: " + failed.join(", ") + " (insufficient stock)";
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
                        visible: !root.compact; width: ordersCol.width; height: 32; spacing: 0
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
                                model: dataModel.ordersModel
                                delegate: Rectangle {
                                    id: rowDel
                                    width: tableCol.width; height: rowVisible ? 44 : 0; color: "#ffffff"
                                    property bool rowVisible: search.text === "" || ((model.orderId || "") + (model.customer || "") + (model.status || "")).toLowerCase().indexOf(search.text.toLowerCase()) >= 0
                                    visible: rowVisible

                                    property var ws: [0.14,0.24,0.10,0.14,0.14,0.14,0.10]
                                    function cw(i) { return rowDel.width * rowDel.ws[i]; }

                                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: "#f1f5f9" }

                                    // Order ID
                                    Text { x: 0; width: cw(0); text: model.orderId || ""; color: "#111827"; font.pixelSize: 12
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
                                                    dataModel.tryCompleteOrder(model.orderId);
                                                } else {
                                                    OrdersStore.updateOrder(model.orderId, { status: s });
                                                    dataModel.updateOrderInModel(model.orderId);
                                                }
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
                                                dataModel.tryCompleteOrder(model.orderId);
                                            }
                                            ToolTip.visible: hovered; ToolTip.text: "Approve"
                                        }
                                        Button {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 28; height: 28; padding: 0
                                            background: Rectangle { radius: 6; color: "#f3f4f6"; border.color: "#e5e7eb" }
                                            contentItem: Text { text: "\u270E"; color: "#6b7280"; font.pixelSize: 14
                                                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                            onClicked: orderDetailsClicked(model.orderId)
                                            ToolTip.visible: hovered; ToolTip.text: "Edit"
                                        }
                                        Button {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: root.canDeleteOrders
                                            width: 28; height: 28; padding: 0
                                            background: Rectangle { radius: 6; color: "#fef2f2"; border.color: "#ef4444" }
                                            contentItem: Text { text: "\u2715"; color: "#ef4444"; font.pixelSize: 13; font.bold: true
                                                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                            onClicked: deleteOrderClicked(model.orderId)
                                            ToolTip.visible: hovered; ToolTip.text: "Delete"
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
}
