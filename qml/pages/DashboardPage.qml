import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Mobile dashboard — first thing users see after sign-in. Mirrors the
// prototype: greeting + avatar + bell, KPI grid, Quick Actions, Recent
// Activity. Bound to existing stores so numbers go live the moment data syncs.
Item {
    id: root

    property bool compact: false

    signal newOrderRequested()
    signal addProductRequested()
    signal inviteStaffRequested()
    signal navigateToOrders()
    signal navigateToInventory()
    signal navigateToSales()
    signal navigateToStaff()
    signal navigateToProfile()
    signal showNotificationsRequested()
    // Activity click — caller routes to the right page + opens the right
    // dialog. kind: "order" | "product_added" | "product_updated"
    // | "product_restocked" | "staff_added" | "staff_updated"
    signal activityItemClicked(string kind, string entityId)
    signal seeAllActivityRequested()

    // ── Greeting helper ──
    function _greeting() {
        var h = new Date().getHours()
        if (h < 12) return "Good morning,"
        if (h < 18) return "Good afternoon,"
        return "Good evening,"
    }

    function _firstName() {
        var name = AuthStore.displayName || AuthStore.email || "there"
        var first = name.split(/[\s@]/)[0]
        return first.charAt(0).toUpperCase() + first.slice(1)
    }

    function _initial() {
        var name = AuthStore.displayName || AuthStore.email || "?"
        return (name.charAt(0) || "?").toUpperCase()
    }

    // ── Today / KPI math ──
    function _todayRevenue() {
        var today = new Date()
        var sum = 0
        var orders = OrdersStore.orders || []
        for (var i = 0; i < orders.length; ++i) {
            var o = orders[i]
            if (o.status !== "completed") continue
            var d = new Date(o.date)
            if (isNaN(d.getTime())) continue
            if (d.getDate() === today.getDate()
                && d.getMonth() === today.getMonth()
                && d.getFullYear() === today.getFullYear()) {
                sum += (o.total || 0)
            }
        }
        return sum
    }

    function _todayOrderCount() {
        var today = new Date()
        var c = 0
        var orders = OrdersStore.orders || []
        for (var i = 0; i < orders.length; ++i) {
            var o = orders[i]
            var d = new Date(o.date)
            if (isNaN(d.getTime())) continue
            if (d.getDate() === today.getDate()
                && d.getMonth() === today.getMonth()
                && d.getFullYear() === today.getFullYear()) {
                c++
            }
        }
        return c
    }

    function _activeStaff() {
        var arr = StaffStore.staff || []
        var c = 0
        for (var i = 0; i < arr.length; ++i)
            if (arr[i].status === "active") c++
        return c
    }

    // Returns the last 7 days' completed-order revenue as a numeric array
    // (oldest first). Used to feed the today's-sales KPI sparkline.
    function _last7DaysRevenue() {
        var bins = [0, 0, 0, 0, 0, 0, 0]
        var orders = OrdersStore.orders || []
        var today = new Date()
        today.setHours(0, 0, 0, 0)
        for (var i = 0; i < orders.length; ++i) {
            var o = orders[i]
            if (o.status !== "completed") continue
            var d = new Date(o.date)
            if (isNaN(d.getTime())) continue
            d.setHours(0, 0, 0, 0)
            var diff = Math.round((today.getTime() - d.getTime()) / 86400000)
            if (diff >= 0 && diff < 7) bins[6 - diff] += (o.total || 0)
        }
        return bins
    }

    function _last7DaysOrderCounts() {
        var bins = [0, 0, 0, 0, 0, 0, 0]
        var orders = OrdersStore.orders || []
        var today = new Date()
        today.setHours(0, 0, 0, 0)
        for (var i = 0; i < orders.length; ++i) {
            var d = new Date(orders[i].date)
            if (isNaN(d.getTime())) continue
            d.setHours(0, 0, 0, 0)
            var diff = Math.round((today.getTime() - d.getTime()) / 86400000)
            if (diff >= 0 && diff < 7) bins[6 - diff] += 1
        }
        return bins
    }

    function _yesterdayRevenue() {
        var sum = 0
        var orders = OrdersStore.orders || []
        var y = new Date()
        y.setDate(y.getDate() - 1)
        for (var i = 0; i < orders.length; ++i) {
            var o = orders[i]
            if (o.status !== "completed") continue
            var d = new Date(o.date)
            if (isNaN(d.getTime())) continue
            if (d.getDate() === y.getDate() && d.getMonth() === y.getMonth() && d.getFullYear() === y.getFullYear())
                sum += (o.total || 0)
        }
        return sum
    }

    function _todaySalesTrend() {
        var t = _todayRevenue()
        var y = _yesterdayRevenue()
        if (y === 0)
            return t > 0 ? "▲ today" : "no sales yet"
        var pct = Math.round(((t - y) / y) * 100)
        if (pct === 0) return "= same as yesterday"
        return (pct > 0 ? "▲ " : "▼ ") + Math.abs(pct) + "% vs yesterday"
    }

    // Recent activity — merges OrdersStore (recent orders) with ActivityLog
    // (product/staff additions, restocks, updates). Newest first, capped at
    // 5 entries. Recomputed whenever either store bumps its revision.
    property var _recent: []
    property int _ordersWatcher: OrdersStore.revision
    property int _inventoryWatcher: InventoryStore.revision
    property int _activityWatcher: ActivityLog.revision
    on_OrdersWatcherChanged: _rebuildRecent()
    on_InventoryWatcherChanged: _rebuildRecent()
    on_ActivityWatcherChanged: _rebuildRecent()
    Component.onCompleted: _rebuildRecent()

    function _rebuildRecent() {
        var merged = []

        // Orders → uniform shape with a timestamp millisecond key for sort.
        var orders = OrdersStore.orders || []
        for (var i = 0; i < orders.length; ++i) {
            var o = orders[i]
            var t = new Date(o.date).getTime() || 0
            merged.push({
                _ts: t,
                kind: "order",
                entityId: o.orderId || "",
                title: (o.orderId || "Order") + " · " + (o.customer || "Walk-in"),
                subtitle: (o.items || 0) + " items · " + (o.date || ""),
                amount: OrdersStore.formatCurrency(o.total || 0),
                status: o.status || "pending"
            })
        }

        // ActivityLog entries → same shape.
        var acts = ActivityLog.entries || []
        for (var j = 0; j < acts.length; ++j) {
            var a = acts[j]
            merged.push({
                _ts: new Date(a.timestamp).getTime() || 0,
                kind: a.kind,
                entityId: a.entityId || "",
                title: a.title,
                subtitle: a.subtitle + " · " + ActivityLog.timeAgo(a.timestamp),
                amount: "",
                status: ""
            })
        }

        merged.sort(function(a, b) { return b._ts - a._ts })
        _recent = merged.slice(0, 5)
    }

    Rectangle { anchors.fill: parent; color: Constants.appBg }

    // Soft brand wash backdrop
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Qt.rgba(0.39, 0.40, 0.95, 0.10) }
            GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0) }
            GradientStop { position: 1.0; color: Qt.rgba(0.93, 0.27, 0.60, 0.06) }
        }
    }

    GlassHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: dp(76)
        greeting: root._greeting()
        title: root._firstName()

        actions: [
            IconActionButton {
                variant: "glass"
                iconName: "bell"
                // Live count = low-stock products + unread activity entries.
                // Cleared on notifications-sheet open via ActivityLog.markAllRead().
                badgeText: {
                    var n = InventoryStore.lowStockCount() + ActivityLog.unreadCount
                    return n > 0 ? String(n) : ""
                }
                onClicked: root.showNotificationsRequested()
            },
            IconActionButton {
                variant: "glass"
                text: root._initial()
                onClicked: root.navigateToProfile()
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
            spacing: dp(Constants.space5)

            // ── KPI grid (2×2) ──
            GridLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                Layout.topMargin: dp(Constants.space4)
                columns: 2
                columnSpacing: dp(Constants.space2 + 2)
                rowSpacing: dp(Constants.space2 + 2)

                GradientKpiCard {
                    label: "Today's sales"
                    value: OrdersStore.formatCurrency(root._todayRevenue())
                    trend: root._todaySalesTrend()
                    spark: root._last7DaysRevenue()
                    palette: Constants.grad1
                }
                GradientKpiCard {
                    label: "Orders"
                    value: String(root._todayOrderCount())
                    trend: {
                        var t = root._todayOrderCount()
                        if (t > 0) return "▲ " + t + " today"
                        if (OrdersStore.pendingOrderCount > 0) return "▲ " + OrdersStore.pendingOrderCount + " pending"
                        return "All caught up"
                    }
                    spark: root._last7DaysOrderCounts()
                    palette: Constants.grad2
                }
                GradientKpiCard {
                    label: "Low stock"
                    value: String(InventoryStore.lowStockCount())
                    trend: "▼ items"
                    trendVariant: "down"
                    palette: Constants.grad3
                }
                GradientKpiCard {
                    label: "Active staff"
                    value: String(root._activeStaff())
                    trend: "on shift"
                    trendVariant: "muted"
                    palette: Constants.grad4
                }
            }

            // ── Quick actions ──
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                Text {
                    text: "Quick actions"
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: dp(Constants.space2)

                    ActionTile {
                        Layout.fillWidth: true
                        iconName: "orders"; caption: "New order"
                        onClicked: root.newOrderRequested()
                    }
                    ActionTile {
                        Layout.fillWidth: true
                        iconName: "products"; caption: "Add product"
                        onClicked: root.addProductRequested()
                    }
                    ActionTile {
                        Layout.fillWidth: true
                        iconName: "team"; caption: "Invite staff"
                        onClicked: root.inviteStaffRequested()
                    }
                    ActionTile {
                        Layout.fillWidth: true
                        iconName: "report"; caption: "View report"
                        onClicked: root.navigateToSales()
                    }
                }
            }

            // ── Recent activity ──
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                // Section heading + "See all" link to a full-page list when
                // the user wants more than the dashboard's 5-row preview.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: dp(Constants.space2)

                    Text {
                        Layout.fillWidth: true
                        text: qsTr("Recent activity")
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBodyLg)
                        font.bold: true
                    }
                    QQC.AbstractButton {
                        implicitHeight: dp(28)
                        leftPadding: dp(8); rightPadding: dp(8)
                        topPadding: 0; bottomPadding: 0
                        background: Rectangle { color: "transparent" }
                        contentItem: Text {
                            text: qsTr("See all  ›")
                            color: Constants.brand2
                            font.pixelSize: sp(Constants.fsCaption)
                            font.bold: true
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                        }
                        onClicked: root.seeAllActivityRequested()
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: dp(Constants.space2)

                    Repeater {
                        model: root._recent
                        delegate: ListCard {
                            Layout.fillWidth: true
                            flat: true
                            title: modelData.title || ""
                            subtitle: modelData.subtitle || ""
                            onClicked: root.activityItemClicked(modelData.kind || "",
                                                                modelData.entityId || "")

                            leading: AvatarBadge {
                                label: {
                                    var k = modelData.kind || "order"
                                    if (k === "order") return ((modelData.title || "?").charAt(0) || "?").toUpperCase()
                                    return ""   // non-order kinds render via iconName
                                }
                                iconName: {
                                    var k = modelData.kind || "order"
                                    if (k === "product_added") return "product-added"
                                    if (k === "product_updated") return "product-updated"
                                    if (k === "product_restocked") return "restocked"
                                    if (k === "staff_added") return "staff-added"
                                    if (k === "staff_updated") return "staff-updated"
                                    if (k === "order") return ""
                                    return "activity"
                                }
                                palette: {
                                    var k = modelData.kind || "order"
                                    if (k === "order") return Constants.grad1
                                    if (k === "product_added") return Constants.grad4
                                    if (k === "product_updated") return Constants.grad2
                                    if (k === "product_restocked") return Constants.grad4
                                    if (k === "staff_added") return Constants.grad3
                                    if (k === "staff_updated") return Constants.grad2
                                    return Constants.grad1
                                }
                            }

                            ColumnLayout {
                                spacing: dp(4)
                                Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                                visible: modelData.amount && modelData.amount.length > 0
                                Text {
                                    visible: modelData.amount && modelData.amount.length > 0
                                    text: modelData.amount || ""
                                    color: Constants.textPrimary
                                    font.pixelSize: sp(Constants.fsBody)
                                    font.bold: true
                                    horizontalAlignment: Text.AlignRight
                                    Layout.alignment: Qt.AlignRight
                                }
                                StatusPill {
                                    visible: modelData.status && modelData.status.length > 0
                                    Layout.alignment: Qt.AlignRight
                                    status: modelData.status || "pending"
                                }
                            }
                        }
                    }

                    // Empty state
                    Rectangle {
                        Layout.fillWidth: true
                        visible: (OrdersStore.orders || []).length === 0
                        radius: dp(Constants.radius)
                        color: Constants.cardBg
                        border.color: Constants.borderColor
                        border.width: 1
                        Layout.preferredHeight: dp(120)

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: dp(6)
                            Icon {
                                name: "clipboard"
                                size: sp(28)
                                color: Constants.textSecondary
                                Layout.alignment: Qt.AlignHCenter
                            }
                            Text {
                                text: "No orders yet"
                                color: Constants.textPrimary
                                font.pixelSize: sp(Constants.fsBodyLg)
                                font.bold: true
                                Layout.alignment: Qt.AlignHCenter
                            }
                            Text {
                                text: "Tap + to record your first sale."
                                color: Constants.textSecondary
                                font.pixelSize: sp(Constants.fsSmall)
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }
                }
            }

            // Bottom spacer so content clears the tabbar.
            Item { Layout.preferredHeight: dp(Constants.tabbarClearance); Layout.fillWidth: true }
        }
    }
}
