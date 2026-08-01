import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"
import "../helper/StaffScope.js" as StaffScope

// Mobile-first orders feed. Glass header with filter/search icons, status
// chip-scroller, swipe-friendly card list, FAB for new order.
Item {
    id: root
    anchors.fill: parent

    property bool compact: false
    property bool canApproveAll: true
    // Whether the current role may approve pending orders at all. Staff are
    // allowed, but the approve action below operates on _scopedOrders(), so a
    // staff member only ever clears their OWN pending backlog.
    property bool canApprovePending: true
    property bool canDeleteOrders: false
    property bool canViewAllSales: true
    property string currentStaffId: ""

    signal addOrderClicked()
    signal orderDetailsClicked(string orderId)
    signal deleteOrderClicked(string orderId)
    signal exportRequested()
    signal importRequested()
    signal filtersRequested()

    property string _searchText: ""
    property string _statusFilter: "all"  // "all" | "pending" | "processing" | "completed" | "cancelled"
    // Public — set by Main.qml when the user picks a chip in the FilterSheet.
    // "all" | "today" | "7days" | "30days" | "custom"
    property string dateRange: "all"
    // Only consulted when dateRange === "custom". "yyyy-MM-dd" each.
    property string customFrom: ""
    property string customTo: ""

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

    AppScrollView {
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

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
                    { label: "All", count: _scopedOrders().length },
                    { label: "Pending", count: _countByStatus("pending") },
                    { label: "Processing", count: _countByStatus("processing") },
                    { label: "Completed", count: _countByStatus("completed") },
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
                visible: root.canApprovePending && root._scopedPendingCount() > 0
                radius: dp(Constants.radius)
                Layout.preferredHeight: dp(56)
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Constants.brand4 }
                    GradientStop { position: 1.0; color: Constants.brand5 }
                }

                // Anchors (not a RowLayout) so the Approve button pins flush to
                // the banner's right edge. A RowLayout left a large gap here
                // because Layout.fillWidth on the text column didn't claim the
                // trailing space; the banner is a plain Rectangle, so anchoring
                // its children directly is both correct and warning-free.
                Icon {
                    id: bannerIcon
                    anchors.left: parent.left
                    anchors.leftMargin: dp(Constants.space4)
                    anchors.verticalCenter: parent.verticalCenter
                    name: "check"
                    color: Constants.textOnBrand
                    size: sp(20)
                }
                QQC.AbstractButton {
                    id: approveBtn
                    anchors.right: parent.right
                    anchors.rightMargin: dp(Constants.space3)
                    anchors.verticalCenter: parent.verticalCenter
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
                Column {
                    spacing: 0
                    anchors.left: bannerIcon.right
                    anchors.leftMargin: dp(Constants.space3)
                    anchors.right: approveBtn.left
                    anchors.rightMargin: dp(Constants.space2)
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        width: parent.width
                        text: "Approve all pending"
                        color: Constants.textOnBrand
                        font.pixelSize: sp(Constants.fsBodyLg)
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        text: root._scopedPendingCount() + " orders waiting"
                        color: Qt.rgba(1,1,1,0.85)
                        font.pixelSize: sp(Constants.fsCaption)
                        elide: Text.ElideRight
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
        anchors.bottomMargin: dp(Constants.tabbarClearance) + SafeArea.bottom
        onClicked: root.addOrderClicked()
    }

    // ── Helpers ──
    // Base order set, narrowed to the current staff member when they may not
    // view all sales (everyone else gets the full tenant set). The revision
    // read ties this to OrdersStore changes so chips/list refresh.
    function _scopedOrders() {
        var _r = OrdersStore.revision   // reactivity tie
        var all = OrdersStore.orders || []
        if (canViewAllSales) return all
        return StaffScope.ownOrders(all, currentStaffId)
    }

    function _countByStatus(s) {
        var c = 0
        var arr = _scopedOrders()
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
        else if (root.dateRange === "custom") {
            // Only honour the window when both ends parse — otherwise treat the
            // filter as inactive so we don't show an empty list. Mirrors
            // SalesPage._dateWindow's custom branch (local midnight, inclusive to).
            var f = new Date(root.customFrom + "T00:00:00")
            var t = new Date(root.customTo + "T00:00:00")
            if (isNaN(f.getTime()) || isNaN(t.getTime())) return null
            from = f
            to = new Date(t.getFullYear(), t.getMonth(), t.getDate() + 1)
        } else
            return null
        return { from: from, to: to }
    }

    function _filteredOrders() {
        var orders = _scopedOrders().slice()
        orders.sort(function(a, b) {
            //Note: changed the sorting to id based instead of time updated time based.
            // Kept the code for future references.
            // var ta = new Date(a.updatedAt || a.date).getTime() || 0
            // var tb = new Date(b.updatedAt || b.date).getTime() || 0
            // return tb - ta
            var aId = parseInt(String(a.orderId).split('-')[1])
            var bId = parseInt(String(b.orderId).split('-')[1])
            return bId - aId

        })
        var q = (root._searchText || "").toLowerCase().trim()
        var statusFilter = root._statusFilter
        var win = _dateWindow()
        return orders.filter(function(o) {
            if (statusFilter !== "all" && (o.status || "") !== statusFilter) return false
            if (win) {
                // o.date is "yyyy-MM-dd"; append time so it parses as LOCAL
                // midnight to match win.from/to (which are local). Bare
                // "yyyy-MM-dd" parses as UTC, shifting the whole window by the
                // tz offset — "Today" then shows nothing in negative-offset zones.
                var od = new Date(o.date + "T00:00:00")
                if (isNaN(od.getTime())) return false
                if (od < win.from || od >= win.to) return false
            }
            if (q.length === 0) return true
            var hay = ((o.orderId || "") + " " + (o.customer || "") + " " + (o.status || "")).toLowerCase()
            return hay.indexOf(q) >= 0
        })
    }

    // Pending orders the current user is allowed to see — tenant-wide for
    // owner/admin/manager, own-only for staff. The banner count and the
    // approve action both read this so staff never see or act on others' work.
    function _scopedPendingCount() {
        return _countByStatus("pending")
    }

    // Sequential, not parallel, on purpose: these orders can share products,
    // and tryCompleteOrder is no longer synchronous (round 4 of the
    // async-write-sequencing design) — processing one at a time means each
    // order's stock deduction is fully resolved before the next one even
    // starts, rather than firing N concurrent completions that could race
    // each other over the same inventory within this SAME bulk action.
    function _approveAllPending() {
        var scoped = _scopedOrders()
        var toApprove = []
        for (var i = 0; i < scoped.length; ++i) {
            if (scoped[i].status === "pending" || scoped[i].status === "processing")
                toApprove.push(scoped[i].orderId)
        }
        var failed = []
        var idx = 0

        function _next() {
            if (idx >= toApprove.length) {
                dataModel.syncOrdersModel()
                if (failed.length > 0) {
                    var errorMsg = qsTr("Could not approve orders: %1\n\nInsufficient stock available.").arg(failed.join(", "))
                    stockErrorDlg.show({
                        title: qsTr("Insufficient Inventory"),
                        message: errorMsg,
                        variant: "error"
                    })
                }
                return
            }
            var orderId = toApprove[idx]
            idx++
            dataModel.tryCompleteOrder(orderId, function(success) {
                if (!success) failed.push(orderId)
                _next()
            })
        }
        _next()
    }
}
