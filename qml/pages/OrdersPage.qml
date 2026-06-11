import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Mobile-first orders feed. Glass header with filter/search icons, status
// chip-scroller, swipe-friendly card list, FAB for new order.
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
    signal filtersRequested()

    property string _searchText: ""
    property string _statusFilter: "all"  // "all" | "pending" | "processing" | "completed" | "cancelled"
    // Public — set by Main.qml when the user picks a chip in the FilterSheet.
    // "all" | "today" | "7days" | "30days"
    property string dateRange: "all"

    Rectangle { anchors.fill: parent; color: Constants.appBg }

    GlassHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: "Orders"
        subtitle: "Manage and track customer orders"

        actions: [
            IconActionButton {
                variant: "glass"
                iconName: "import"
                onClicked: root.importRequested()
            },
            IconActionButton {
                variant: "glass"
                iconName: "export"
                onClicked: root.exportRequested()
            },
            IconActionButton {
                variant: "glass"
                iconName: "settings"
                // Dot badge when a date filter is active so the user can spot
                // why the list is shorter than they expected.
                badgeText: root.dateRange !== "all" && root.dateRange.length > 0 ? "•" : ""
                onClicked: root.filtersRequested()
            }
        ]
    }

    QQC.ScrollView {
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

        ColumnLayout {
            id: stack
            width: root.width
            spacing: dp(Constants.space3)

            SearchField {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                Layout.topMargin: dp(Constants.space3)
                placeholder: "Search orders, customers…"
                onTextChanged: root._searchText = text
            }

            // Auto-approve toggle row — labeled, full-width, easy to find.
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                Layout.preferredHeight: dp(48)
                radius: dp(Constants.radius)
                color: Constants.cardBg
                border.color: Constants.borderColor
                border.width: 1

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: dp(Constants.space3)
                    anchors.rightMargin: dp(Constants.space2)
                    spacing: dp(Constants.space3)

                    Icon {
                        name: "quick"
                        size: sp(16)
                    }
                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true
                        Text {
                            text: "Auto-approve new orders"
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBody)
                            font.bold: true
                        }
                        Text {
                            text: OrdersStore.autoApproveEnabled
                                ? "Pending orders complete automatically when stock is available."
                                : "New orders stay pending until you approve them."
                            color: Constants.textSecondary
                            font.pixelSize: sp(Constants.fsCaption)
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                    // QQC.Switch's default style is bulky on iOS/Material —
                    // wrap in an Item to constrain footprint, scale down for
                    // visual parity with the prototype's compact toggle.
                    Item {
                        Layout.preferredWidth: dp(48)
                        Layout.preferredHeight: dp(28)
                        QQC.Switch {
                            anchors.centerIn: parent
                            checked: OrdersStore.autoApproveEnabled
                            scale: 0.75
                            onCheckedChanged: OrdersStore.autoApproveEnabled = checked
                        }
                    }
                }
            }

            ChipScroller {
                Layout.fillWidth: true
                model: [
                    { label: "All", count: (OrdersStore.orders || []).length },
                    { label: "Pending", count: OrdersStore.pendingOrderCount },
                    { label: "Processing", count: _countByStatus("processing") },
                    { label: "Completed", count: OrdersStore.completedOrderCount },
                    { label: "Cancelled", count: _countByStatus("cancelled") }
                ]
                onChipSelected: function(idx, label) {
                    var map = ["all","pending","processing","completed","cancelled"]
                    root._statusFilter = map[idx] || "all"
                }
            }

            // Approve-all banner — only when there's pending work AND user can act.
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root.canApproveAll && OrdersStore.pendingOrderCount > 0
                radius: dp(Constants.radius)
                Layout.preferredHeight: dp(56)
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Constants.brand4 }
                    GradientStop { position: 1.0; color: Constants.brand5 }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: dp(Constants.space4)
                    anchors.rightMargin: dp(Constants.space2)
                    spacing: dp(Constants.space3)

                    Icon {
                        name: "check"
                        color: Constants.textOnBrand
                        size: sp(20)
                    }
                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true
                        Text {
                            text: "Approve all pending"
                            color: Constants.textOnBrand
                            font.pixelSize: sp(Constants.fsBodyLg)
                            font.bold: true
                        }
                        Text {
                            text: OrdersStore.pendingOrderCount + " orders waiting"
                            color: Qt.rgba(1,1,1,0.85)
                            font.pixelSize: sp(Constants.fsCaption)
                        }
                    }
                    QQC.AbstractButton {
                        implicitWidth: dp(80); implicitHeight: dp(32)
                        padding: 0
                        contentItem: Item {
                            Text {
                                anchors.centerIn: parent
                                text: qsTr("Approve")
                                color: Constants.textOnBrand
                                font.pixelSize: sp(Constants.fsSmall)
                                font.bold: true
                            }
                        }
                        background: Rectangle {
                            radius: dp(Constants.radiusPill)
                            color: Qt.rgba(1,1,1,0.22)
                        }
                        onClicked: _approveAllPending()
                    }
                }
            }

            // Order cards
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                Repeater {
                    model: _filteredOrders()
                    delegate: ListCard {
                        Layout.fillWidth: true
                        title: (modelData.orderId || "Order") + " · " + (modelData.customer || "Walk-in")
                        subtitle: (modelData.items || 0) + " items · " + (modelData.date || "")
                        onClicked: root.orderDetailsClicked(modelData.orderId)

                        leading: AvatarBadge {
                            label: ((modelData.customer || "?").charAt(0) || "?").toUpperCase()
                            palette: index % 4 === 0 ? Constants.grad1
                                   : index % 4 === 1 ? Constants.grad2
                                   : index % 4 === 2 ? Constants.grad3
                                   :                   Constants.grad4
                        }

                        ColumnLayout {
                            spacing: dp(4)
                            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                            Text {
                                text: OrdersStore.formatCurrency(modelData.total || 0)
                                color: Constants.textPrimary
                                font.pixelSize: sp(Constants.fsBody)
                                font.bold: true
                                horizontalAlignment: Text.AlignRight
                                Layout.alignment: Qt.AlignRight
                            }
                            StatusPill {
                                Layout.alignment: Qt.AlignRight
                                status: modelData.status || "pending"
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: _filteredOrders().length === 0
                radius: dp(Constants.radius)
                color: Constants.cardBg
                border.color: Constants.borderColor
                border.width: 1
                Layout.preferredHeight: dp(140)

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: dp(6)
                    Icon { name: "empty-inbox"; size: sp(32); color: Constants.textMuted; Layout.alignment: Qt.AlignHCenter }
                    Text {
                        text: root._searchText.length > 0 ? "No matches" : "No orders yet"
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBodyLg)
                        font.bold: true
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Text {
                        text: root._searchText.length > 0
                            ? "Try a different search or filter."
                            : "Tap + to record your first sale."
                        color: Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
            }

            Item { Layout.preferredHeight: dp(Constants.tabbarClearance) + SafeArea.bottom; Layout.fillWidth: true }
        }
    }

    // ── FAB ──
    FloatingActionButton {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: dp(Constants.space5)
        anchors.bottomMargin: dp(96)
        onClicked: root.addOrderClicked()
    }

    // ── Helpers ──
    function _countByStatus(s) {
        var c = 0
        var arr = OrdersStore.orders || []
        for (var i = 0; i < arr.length; ++i)
            if (arr[i].status === s) c++
        return c
    }

    // Resolve the chip key into a [from, to) date window. Returns `null` when
    // the filter is "all" so callers can short-circuit the per-row check.
    function _dateWindow() {
        if (root.dateRange === "all" || !root.dateRange) return null
        var now = new Date()
        var to = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)  // tomorrow 00:00
        var from
        if (root.dateRange === "today")
            from = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        else if (root.dateRange === "7days")
            from = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 6)
        else if (root.dateRange === "30days")
            from = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 29)
        else
            return null
        return { from: from, to: to }
    }

    function _filteredOrders() {
        var orders = (OrdersStore.orders || []).slice()
        orders.sort(function(a, b) {
            var da = new Date(a.date).getTime() || 0
            var db = new Date(b.date).getTime() || 0
            return db - da
        })
        var q = (root._searchText || "").toLowerCase().trim()
        var statusFilter = root._statusFilter
        var win = _dateWindow()
        return orders.filter(function(o) {
            if (statusFilter !== "all" && (o.status || "") !== statusFilter) return false
            if (win) {
                var od = new Date(o.date)
                if (isNaN(od.getTime())) return false
                if (od < win.from || od >= win.to) return false
            }
            if (q.length === 0) return true
            var hay = ((o.orderId || "") + " " + (o.customer || "") + " " + (o.status || "")).toLowerCase()
            return hay.indexOf(q) >= 0
        })
    }

    function _approveAllPending() {
        var allOrders = OrdersStore.orders
        var failed = []
        for (var i = 0; i < allOrders.length; ++i) {
            if (allOrders[i].status === "pending") {
                if (!dataModel.tryCompleteOrder(allOrders[i].orderId))
                    failed.push(allOrders[i].orderId)
            }
        }
        dataModel.syncOrdersModel()
        if (failed.length > 0) {
            dataModel.stockErrorMsg = "Could not approve: " + failed.join(", ") + " (insufficient stock)"
            stockErrorDlg.open()
        }
    }
}
