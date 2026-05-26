import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Restock bottom sheet. Public contract preserved: openFor(productId).
BottomSheet {
    id: dlg

    sheetTitle: "Restock"
    primaryAction: "Confirm"
    secondaryAction: "Cancel"
    primaryPalette: ({ start: Constants.brand4, end: Constants.brand5 })

    property string productId: ""
    property string productName: ""
    property int currentStock: 0
    property int minStock: 0

    signal restockConfirmed(string productId, int amount)

    function openFor(pid) {
        var p = InventoryStore.getById(pid)
        if (!p) return
        productId = p.productId
        productName = p.name
        currentStock = p.stock
        minStock = p.minStock
        qtyField.value = 10
        dlg.open()
    }

    onPrimaryClicked: {
        InventoryStore.restock(productId, qtyField.value)
        restockConfirmed(productId, qtyField.value)
        Toast.show("Restocked +" + qtyField.value + " units")
        dlg.close()
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        // Product card summary
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: dp(80)
            radius: dp(Constants.radius)
            color: Qt.rgba(0.39, 0.40, 0.95, 0.06)
            border.color: Constants.borderColor
            border.width: 1

            RowLayout {
                anchors.fill: parent
                anchors.margins: dp(Constants.space3)
                spacing: dp(Constants.space3)

                AvatarBadge {
                    size: "lg"
                    label: (dlg.productName || "?").charAt(0).toUpperCase()
                    palette: Constants.grad4
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: dp(2)
                    Text {
                        text: dlg.productName
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBodyLg)
                        font.bold: true
                    }
                    Text {
                        text: "Current " + dlg.currentStock + " · reorder at " + dlg.minStock
                        color: Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
                    }
                }
            }
        }

        Text {
            text: "Add quantity"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
        }

        QQC.SpinBox {
            id: qtyField
            Layout.fillWidth: true
            Layout.preferredHeight: dp(48)
            from: 1; to: 9999; value: 10
            editable: true
            font.pixelSize: sp(Constants.fsBodyLg)
            background: Rectangle {
                radius: dp(14)
                color: Constants.cardBg
                border.color: Constants.borderColor
                border.width: 1
            }
        }

        Text {
            text: "After this, stock will be " + (dlg.currentStock + qtyField.value) + " units."
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
        }
    }
}
