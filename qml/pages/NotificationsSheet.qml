import QtQuick
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
        // page + opens the right detail dialog.
        Repeater {
            model: ActivityLog.entries
            delegate: ListCard {
                Layout.fillWidth: true
                title: modelData.title || ""
                subtitle: (modelData.subtitle || "") + " · " + ActivityLog.timeAgo(modelData.timestamp)
                onClicked: {
                    root.notificationItemClicked(modelData.kind || "", modelData.entityId || "")
                    root.close()
                }

                leading: AvatarBadge {
                    label: {
                        var k = modelData.kind || ""
                        if (k === "product_added") return "＋"
                        if (k === "product_updated") return "✎"
                        if (k === "product_restocked") return "↻"
                        if (k === "staff_added") return "👤"
                        if (k === "staff_updated") return "✎"
                        if (k === "low_stock") return "!"
                        return "•"
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
                label: "★"
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
                Text { text: "🎉"; font.pixelSize: sp(28); Layout.alignment: Qt.AlignHCenter }
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
