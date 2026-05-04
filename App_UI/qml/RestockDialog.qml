import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

Dialog {
    id: dlg
    title: ""
    modal: true
    width: Math.min(480, parent ? parent.width - 24 : 480)
    height: Math.min(380, parent ? parent.height - 40 : 380)
    anchors.centerIn: parent
    padding: 0
    standardButtons: Dialog.NoButton

    property string productId: ""
    property string productName: ""
    property int currentStock: 0
    property int minStock: 0

    signal restockConfirmed(string productId, int amount)

    function openFor(pid) {
        var p = InventoryStore.getById(pid);
        if (!p) return;
        productId = p.productId;
        productName = p.name;
        currentStock = p.stock;
        minStock = p.minStock;
        qtyField.value = 10;
        dlg.open();
    }

    // Close button (X) top-right
    Button {
        z: 10; width: 32; height: 32; x: dlg.width - 44; y: 8
        background: Rectangle { color: "transparent" }
        contentItem: Text { text: "✕"; font.pixelSize: 18; color: "#6b7280"
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
        onClicked: dlg.close()
    }

    contentItem: Item {
        Column {
            x: 24; y: 16; width: parent.width - 48; spacing: 12

            // Title
            Label { text: "Restock Product"; font.pixelSize: 20; font.bold: true; color: "#111827" }
            Label { text: "Add more stock to " + dlg.productName; font.pixelSize: 13; color: "#16a34a" }

            Item { width: 1; height: 8 }

            // Product info card
            Rectangle {
                width: parent.width; height: 120; radius: 12
                color: "#f0fdf4"; border.color: "#bbf7d0"; border.width: 1.5

                Column {
                    x: 20; y: 16; width: parent.width - 40; spacing: 12

                    Row {
                        width: parent.width
                        Label { text: "Product:"; font.pixelSize: 14; color: "#374151"; width: parent.width * 0.5 }
                        Label { text: dlg.productName; font.pixelSize: 14; font.bold: true; color: "#111827"
                            width: parent.width * 0.5; horizontalAlignment: Text.AlignRight }
                    }
                    Row {
                        width: parent.width
                        Label { text: "Current Stock:"; font.pixelSize: 14; color: "#374151"; width: parent.width * 0.5 }
                        Label { text: String(dlg.currentStock) + " units"; font.pixelSize: 14; font.bold: true; color: "#111827"
                            width: parent.width * 0.5; horizontalAlignment: Text.AlignRight }
                    }
                    Row {
                        width: parent.width
                        Label { text: "Minimum Stock:"; font.pixelSize: 14; color: "#374151"; width: parent.width * 0.5 }
                        Label { text: String(dlg.minStock) + " units"; font.pixelSize: 14; font.bold: true; color: "#111827"
                            width: parent.width * 0.5; horizontalAlignment: Text.AlignRight }
                    }
                }
            }

            Item { width: 1; height: 4 }

            // Quantity input
            Label { text: "Add Stock Quantity *"; font.pixelSize: 13; font.bold: true; color: "#111827" }
            SpinBox {
                id: qtyField
                width: parent.width; height: 44
                from: 1; to: 9999; value: 10
                editable: true
                font.pixelSize: 14
                background: Rectangle { radius: 8; color: "#f9fafb"; border.color: "#d1d5db" }
            }
        }
    }

    footer: Item {
        height: 64
        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: "#e5e7eb" }
        Row {
            anchors.centerIn: parent; spacing: 12
            Button {
                text: "Cancel"; width: 100; height: 40
                onClicked: dlg.close()
                background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                contentItem: Text { text: "Cancel"; color: "#374151"; font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            }
            Button {
                text: "Update Stock"; width: 140; height: 40
                onClicked: {
                    InventoryStore.restock(dlg.productId, qtyField.value);
                    dlg.restockConfirmed(dlg.productId, qtyField.value);
                    dlg.close();
                }
                background: Rectangle { radius: 8; color: "#16a34a" }
                contentItem: Text { text: "Update Stock"; color: "white"; font.bold: true; font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            }
        }
    }
}
