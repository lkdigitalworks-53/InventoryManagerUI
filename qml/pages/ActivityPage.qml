import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Full activity log — accessed from the Dashboard's "See all" link.
// Shows the merged ActivityLog + recent orders feed without the 5-row cap.
Item {
    id: root

    signal backRequested()
    signal activityItemClicked(string kind, string entityId)

    property var _all: []
    property int _ordersWatcher: OrdersStore.revision
    property int _activityWatcher: ActivityLog.revision
    on_OrdersWatcherChanged: _rebuild()
    on_ActivityWatcherChanged: _rebuild()
    Component.onCompleted: _rebuild()

    function _rebuild() {
        var merged = []
        var orders = OrdersStore.orders || []
        for (var i = 0; i < orders.length; ++i) {
            var o = orders[i]
            merged.push({
                _ts: new Date(o.date).getTime() || 0,
                kind: "order",
                entityId: o.orderId || "",
                title: (o.orderId || "Order") + " · " + (o.customer || "Walk-in"),
                subtitle: (o.items || 0) + " items · " + (o.date || ""),
                amount: OrdersStore.formatCurrency(o.total || 0)
            })
        }
        var acts = ActivityLog.entries || []
        for (var j = 0; j < acts.length; ++j) {
            var a = acts[j]
            merged.push({
                _ts: new Date(a.timestamp).getTime() || 0,
                kind: a.kind,
                entityId: a.entityId || "",
                title: a.title,
                subtitle: a.subtitle + " · " + ActivityLog.timeAgo(a.timestamp),
                amount: ""
            })
        }
        merged.sort(function(a, b) { return b._ts - a._ts })
        _all = merged
    }

    Rectangle { anchors.fill: parent; color: Constants.appBg }

    GlassHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("All activity")
        subtitle: qsTr("Orders, restocks, and edits")

        leading: QQC.AbstractButton {
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: dp(40); implicitHeight: dp(40)
            padding: 0
            background: Rectangle { color: parent.pressed ? Qt.rgba(0,0,0,0.04) : "transparent"; radius: dp(12) }
            contentItem: Item {
                Icon { anchors.centerIn: parent; name: "back"; color: Constants.textPrimary; size: sp(22) }
            }
            onClicked: root.backRequested()
        }
    }

    QQC.ScrollView {
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

        ColumnLayout {
            width: root.width
            spacing: dp(Constants.space2)

            Item { Layout.preferredHeight: dp(Constants.space3); Layout.fillWidth: true }

            Repeater {
                model: root._all
                delegate: ListCard {
                    Layout.fillWidth: true
                    Layout.leftMargin: dp(Constants.space4)
                    Layout.rightMargin: dp(Constants.space4)
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

                    Text {
                        visible: modelData.amount && modelData.amount.length > 0
                        text: modelData.amount || ""
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBody)
                        font.bold: true
                        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root._all.length === 0
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
                        text: qsTr("No activity yet")
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBodyLg)
                        font.bold: true
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
            }

            Item { Layout.preferredHeight: dp(Constants.tabbarClearance); Layout.fillWidth: true }
        }
    }
}
