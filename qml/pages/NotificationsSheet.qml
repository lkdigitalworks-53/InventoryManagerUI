import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Notifications drawer — surfaces low-stock alerts + ActivityLog entries.
// Marks all activity entries as read when the sheet opens, so the bell
// badge clears.
BottomSheet {
    id: root

    sheetTitle: "Notifications"
    primaryAction: ""
    secondaryAction: "Close"

    // Emitted when a notification row is tapped. Caller routes to the right
    // page + opens the right detail dialog.
    signal notificationItemClicked(string kind, string entityId)

    onOpened: ActivityLog.markAllRead()

    property int _activityWatcher: ActivityLog.revision
    property int _inventoryWatcher: InventoryStore.revision

    function _lowStockProducts() {
        var arr = InventoryStore.products || []
        return arr.filter(function(p) { return p.stock <= p.minStock })
    }

    function _isEmpty() {
        return _lowStockProducts().length === 0
            && (ActivityLog.entries || []).length === 0
            && SalesStore.totalRevenue === 0
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space2)

        // Header row: count + "Clear all" affordance. Hidden when empty so
        // the empty-state card below stands alone.
        RowLayout {
            Layout.fillWidth: true
            visible: !root._isEmpty()
            spacing: dp(Constants.space2)

            Text {
                Layout.fillWidth: true
                text: {
                    var n = (ActivityLog.entries || []).length + root._lowStockProducts().length
                    return n === 1 ? qsTr("1 notification") : qsTr("%1 notifications").arg(n)
                }
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsCaption)
            }
            QQC.AbstractButton {
                visible: (ActivityLog.entries || []).length > 0
                implicitHeight: dp(28)
                leftPadding: dp(10); rightPadding: dp(10)
                topPadding: 0; bottomPadding: 0
                background: Rectangle {
                    radius: dp(Constants.radiusPill)
                    color: Qt.rgba(0.93, 0.27, 0.27, 0.10)
                    border.color: Qt.rgba(0.93, 0.27, 0.27, 0.25)
                    border.width: 1
                }
                contentItem: Text {
                    text: qsTr("Clear all")
                    color: Constants.danger
                    font.pixelSize: sp(Constants.fsCaption)
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: ActivityLog.clear()
            }
        }

        // Low-stock alerts — include SKU so the user can identify the product
        // by code, not just name. Click routes to Stock + opens the product.
        Repeater {
            model: root._lowStockProducts()
            delegate: ListCard {
                Layout.fillWidth: true
                title: "Low stock: " + modelData.name
                subtitle: (modelData.sku ? "SKU " + modelData.sku + " · " : "")
                          + "only " + modelData.stock + " left · reorder at " + modelData.minStock
                onClicked: {
                    root.notificationItemClicked("low_stock", modelData.productId || "")
                    root.close()
                }

                leading: AvatarBadge {
                    label: "!"
                    palette: Constants.grad3
                }
            }
        }

        // Activity feed entries (newest first). Click routes to the right
        // page + opens the right detail dialog AND dismisses the entry.
        // Horizontal swipe also dismisses without navigating.
        Repeater {
            model: ActivityLog.entries
            delegate: Item {
                id: rowItem
                Layout.fillWidth: true
                Layout.preferredHeight: dp(72)

                // Tracks horizontal drag offset; when past threshold and released, removes.
                property real _swipeX: 0
                readonly property real _threshold: width * 0.35

                // Swipe affordance underneath — red surface with a "Remove" hint.
                Rectangle {
                    anchors.fill: parent
                    radius: dp(Constants.radius)
                    color: Qt.rgba(0.93, 0.27, 0.27, 0.10)
                    visible: Math.abs(rowItem._swipeX) > 1
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: dp(Constants.space4)
                        visible: rowItem._swipeX > 1
                        text: qsTr("Remove")
                        color: Constants.danger
                        font.bold: true
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        anchors.rightMargin: dp(Constants.space4)
                        visible: rowItem._swipeX < -1
                        text: qsTr("Remove")
                        color: Constants.danger
                        font.bold: true
                    }
                }

                Item {
                    id: cardWrap
                    width: parent.width
                    height: parent.height
                    x: rowItem._swipeX
                    Behavior on x { NumberAnimation { duration: Constants.durFast; easing.type: Easing.OutCubic } }

                    Rectangle {
                        id: card
                        anchors.fill: parent
                        radius: dp(Constants.radius)
                        color: dragArea.pressed ? Constants.subtleBg : Constants.cardBg
                        border.color: Constants.borderColor
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: Constants.durFast } }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: dp(14)
                            anchors.rightMargin: dp(14)
                            spacing: dp(Constants.space3)

                            AvatarBadge {
                                Layout.alignment: Qt.AlignVCenter
                                label: ""   // notification kinds render via iconName
                                iconName: {
                                    var k = modelData.kind || ""
                                    if (k === "product_added") return "product-added"
                                    if (k === "product_updated") return "product-updated"
                                    if (k === "product_restocked") return "restocked"
                                    if (k === "staff_added") return "staff-added"
                                    if (k === "staff_updated") return "staff-updated"
                                    if (k === "low_stock") return "warn"
                                    return "activity"
                                }
                                palette: {
                                    var k = modelData.kind || ""
                                    if (k === "product_added") return Constants.grad4
                                    if (k === "product_updated") return Constants.grad2
                                    if (k === "product_restocked") return Constants.grad4
                                    if (k === "staff_added") return Constants.grad3
                                    if (k === "staff_updated") return Constants.grad2
                                    if (k === "low_stock") return Constants.grad3
                                    return Constants.grad1
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: dp(2)
                                Text {
                                    text: modelData.title || ""
                                    color: Constants.textPrimary
                                    font.pixelSize: sp(Constants.fsBodyLg)
                                    font.bold: true
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: (modelData.subtitle || "") + " · " + ActivityLog.timeAgo(modelData.timestamp)
                                    color: Constants.textSecondary
                                    font.pixelSize: sp(Constants.fsSmall)
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }
                        }
                    }

                    MouseArea {
                        id: dragArea
                        anchors.fill: parent
                        // Swipe-to-dismiss: drag horizontally past threshold.
                        // Below threshold, snap back. Tap with no drag = open + dismiss.
                        property real _startX: 0
                        property bool _dragging: false
                        onPressed: { _startX = mouse.x; _dragging = false }
                        onPositionChanged: {
                            var dx = mouse.x - _startX
                            if (Math.abs(dx) > 6) _dragging = true
                            if (_dragging) rowItem._swipeX = dx
                        }
                        onReleased: {
                            if (_dragging && Math.abs(rowItem._swipeX) > rowItem._threshold) {
                                rowItem._swipeX = rowItem._swipeX > 0 ? rowItem.width : -rowItem.width
                                ActivityLog.remove(modelData.id || "")
                            } else {
                                rowItem._swipeX = 0
                            }
                            _dragging = false
                        }
                        onCanceled: { rowItem._swipeX = 0; _dragging = false }
                        onClicked: {
                            if (!_dragging) {
                                var entryId = modelData.id || ""
                                root.notificationItemClicked(modelData.kind || "", modelData.entityId || "")
                                ActivityLog.remove(entryId)
                                root.close()
                            }
                        }
                    }
                }
            }
        }

        // Sales summary card — purely informational, kept for parity with
        // earlier behaviour.
        ListCard {
            visible: SalesStore.totalRevenue > 0
            Layout.fillWidth: true
            title: "Revenue update"
            subtitle: SalesStore.formatCurrency(SalesStore.totalRevenue) + " · " + SalesStore.totalOrders + " orders"

            leading: AvatarBadge {
                iconName: "star"
                palette: Constants.grad2
            }
        }

        // Empty state
        Rectangle {
            Layout.fillWidth: true
            visible: root._isEmpty()
            radius: dp(Constants.radius)
            color: Constants.subtleBg
            border.color: Constants.borderColor
            border.width: 1
            Layout.preferredHeight: dp(100)

            ColumnLayout {
                anchors.centerIn: parent
                spacing: dp(4)
                Icon { name: "celebrate"; size: sp(28); color: Constants.textMuted; Layout.alignment: Qt.AlignHCenter }
                Text {
                    text: "All caught up"
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                    Layout.alignment: Qt.AlignHCenter
                }
                Text {
                    text: "We'll let you know when anything needs attention."
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsSmall)
                    Layout.alignment: Qt.AlignHCenter
                }
            }
        }
    }
}
