import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../model"
import "../helper"

Item {
    id: root
    property bool compact: false
    property bool canManageInventory: true

    signal addProductClicked()
    signal restockClicked(string productId)
    signal viewProductClicked(string productId)
    signal editProductClicked(string productId)
    signal deleteProductClicked(string productId)
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

            // ── Title + Add Product ──
            RowLayout {
                width: col.width; spacing: 8
                Column { spacing: 4; Layout.fillWidth: true
                    Label { text: "Inventory Management"; color: "#111827"; font.bold: true; font.pixelSize: 18 }
                    Label { text: "Track and manage product inventory"; color: "#6b7280"; font.pixelSize: 12 }
                }
                Button {
                    id: importBtn; text: "📥  Import"
                    onClicked: root.importRequested()
                    background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                    contentItem: Text { text: importBtn.text; color: "#374151"; font.bold: true; font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    id: exportBtn; text: "📤  Export"
                    onClicked: root.exportRequested()
                    background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                    contentItem: Text { text: exportBtn.text; color: "#374151"; font.bold: true; font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    id: addBtn; text: "+  Add Product"
                    visible: root.canManageInventory
                    onClicked: root.addProductClicked()
                    background: Rectangle { radius: 8; color: "#3158ff" }
                    contentItem: Text { text: addBtn.text; color: "white"; font.bold: true; font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
            }

            // ── KPI Cards ──
            Row {
                width: col.width; spacing: 12
                Rectangle {
                    width: (col.width - 36) / 4; height: 110; radius: 12
                    border.color: "#f97316"; border.width: 2; color: "#fff7ed"
                    Column { x: 16; y: 14; spacing: 4
                        Label { text: "Total Products"; font.pixelSize: 13; font.bold: true; color: "#f97316" }
                        Label { text: "In inventory"; font.pixelSize: 11; color: "#6b7280" }
                        Item { width: 1; height: 8 }
                        Label { text: String(InventoryStore.totalProducts()); font.pixelSize: 22; font.bold: true; color: "#111827" }
                    }
                }
                Rectangle {
                    width: (col.width - 36) / 4; height: 110; radius: 12
                    border.color: "#ef4444"; border.width: 2; color: "#fef2f2"
                    Column { x: 16; y: 14; spacing: 4
                        Label { text: "Low Stock"; font.pixelSize: 13; font.bold: true; color: "#ef4444" }
                        Label { text: "Needs reorder"; font.pixelSize: 11; color: "#6b7280" }
                        Item { width: 1; height: 8 }
                        Row { spacing: 6
                            Label { text: "⚠"; font.pixelSize: 18; color: "#ef4444" }
                            Label { text: String(InventoryStore.lowStockCount()); font.pixelSize: 22; font.bold: true; color: "#ef4444" }
                        }
                    }
                }
                Rectangle {
                    width: (col.width - 36) / 4; height: 110; radius: 12
                    border.color: "#22c55e"; border.width: 2; color: "#f0fdf4"
                    Column { x: 16; y: 14; spacing: 4
                        Label { text: "Total Items"; font.pixelSize: 13; font.bold: true; color: "#22c55e" }
                        Label { text: "In stock"; font.pixelSize: 11; color: "#6b7280" }
                        Item { width: 1; height: 8 }
                        Label { text: String(InventoryStore.totalItems()); font.pixelSize: 22; font.bold: true; color: "#111827" }
                    }
                }
                Rectangle {
                    width: (col.width - 36) / 4; height: 110; radius: 12
                    border.color: "#8b5cf6"; border.width: 2; color: "#f5f3ff"
                    Column { x: 16; y: 14; spacing: 4
                        Label { text: "Avg Markup"; font.pixelSize: 13; font.bold: true; color: "#8b5cf6" }
                        Label { text: "Above cost"; font.pixelSize: 11; color: "#6b7280" }
                        Item { width: 1; height: 8 }
                        Label { text: InventoryStore.averageMarkupPercent() + "%"; font.pixelSize: 22; font.bold: true; color: "#8b5cf6" }
                    }
                }
            }

            // ── Product Table ──
            Rectangle {
                width: col.width; height: tableCol.height + 32
                radius: 12; color: "#ffffff"; border.color: "#e5e7eb"

                Column {
                    id: tableCol
                    x: 16; y: 16; width: parent.width - 32; spacing: 12

                    Column { spacing: 2
                        Label { text: "Product Inventory"; font.pixelSize: 14; font.bold: true; color: "#111827" }
                        Label { text: "All products and stock levels"; font.pixelSize: 11; color: "#6b7280" }
                    }

                    TextField {
                        id: search; width: tableCol.width
                        placeholderText: "🔍  Search products..."
                        font.pixelSize: 12
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#e5e7eb" }
                    }

                    // Header
                    Row {
                        visible: !root.compact; width: tableCol.width; height: 32; spacing: 0
                        property var labels: ["Photo","Product ID","Name","SKU","Category","Stock","Status","Cost","Sell","Markup","Actions"]
                        property var ws: [0.05,0.08,0.13,0.10,0.09,0.09,0.08,0.07,0.07,0.07,0.17]
                        Repeater {
                            model: parent.labels
                            Rectangle {
                                width: tableCol.width * parent.ws[index]; height: 32; color: "transparent"
                                Text { text: modelData; color: "#6b7280"; font.pixelSize: 12; font.bold: true
                                    anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                            }
                        }
                    }
                    Rectangle { width: tableCol.width; height: 1; color: "#e5e7eb" }

                    // Rows
                    Flickable {
                        width: tableCol.width; height: 320
                        clip: true; flickableDirection: Flickable.VerticalFlick
                        contentHeight: rowsCol.height
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                        Column {
                            id: rowsCol; width: parent.width; spacing: 0
                            Repeater {
                                model: InventoryStore.products
                                Rectangle {
                                    id: prodRow
                                    width: rowsCol.width
                                    color: index % 2 === 0 ? "#ffffff" : "#f9fafb"
                                    visible: search.text === "" || ((modelData.productId || "") + (modelData.name || "") + (modelData.sku || "") + (modelData.category || "")).toLowerCase().indexOf(search.text.toLowerCase()) >= 0
                                    height: visible ? 56 : 0

                                    property var ws: [0.05,0.08,0.13,0.10,0.09,0.09,0.08,0.07,0.07,0.07,0.17]
                                    Row {
                                        anchors.verticalCenter: parent.verticalCenter; width: parent.width; spacing: 0
                                        // Photo
                                        Item { width: prodRow.width * prodRow.ws[0]; height: 48
                                            Rectangle {
                                                anchors.centerIn: parent
                                                width: 36; height: 36; radius: 6
                                                color: "#f3f4f6"; border.color: "#e5e7eb"
                                                clip: true
                                                Image {
                                                    anchors.fill: parent; anchors.margins: 1
                                                    source: modelData.photoUrl || ""
                                                    sourceSize.width: 72
                                                    sourceSize.height: 72
                                                    fillMode: Image.PreserveAspectCrop
                                                    cache: true
                                                    visible: source != ""
                                                }
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: "📦"; font.pixelSize: 16
                                                    visible: !modelData.photoUrl || modelData.photoUrl.length === 0
                                                }
                                            }
                                        }
                                        // Product ID
                                        Item { width: prodRow.width * prodRow.ws[1]; height: 40
                                            Text { text: modelData.productId; color: "#374151"; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                                        }
                                        // Name
                                        Item { width: prodRow.width * prodRow.ws[2]; height: 40
                                            Text { text: modelData.name; color: "#111827"; font.pixelSize: 12; font.bold: true; anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                                        }
                                        // SKU
                                        Item { width: prodRow.width * prodRow.ws[3]; height: 40
                                            Text { text: modelData.sku || ""; color: "#6b7280"; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                                        }
                                        // Category
                                        Item { width: prodRow.width * prodRow.ws[4]; height: 40
                                            Text { text: modelData.category; color: "#374151"; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                                        }
                                        // Stock (number + progress bar)
                                        Item { width: prodRow.width * prodRow.ws[5]; height: 40
                                            Column { anchors.verticalCenter: parent.verticalCenter; leftPadding: 8; spacing: 4
                                                Text { text: String(modelData.stock); color: modelData.stock <= modelData.minStock ? "#ef4444" : "#22c55e"; font.pixelSize: 13; font.bold: true }
                                                Rectangle {
                                                    width: prodRow.width * prodRow.ws[5] - 20; height: 4; radius: 2; color: "#e5e7eb"
                                                    Rectangle {
                                                        width: parent.width * InventoryStore.stockPercent(modelData); height: 4; radius: 2
                                                        color: modelData.stock <= modelData.minStock ? "#ef4444" : "#3b82f6"
                                                    }
                                                }
                                            }
                                        }
                                        // Status
                                        Item { width: prodRow.width * prodRow.ws[6]; height: 40
                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter; x: 8
                                                width: statusTxt.implicitWidth + 16; height: 24; radius: 12
                                                color: InventoryStore.stockStatus(modelData) === "In Stock" ? "#dcfce7" : "#fef2f2"
                                                border.color: InventoryStore.stockStatus(modelData) === "In Stock" ? "#22c55e" : "#ef4444"
                                                Text { id: statusTxt; text: InventoryStore.stockStatus(modelData); color: InventoryStore.stockStatus(modelData) === "In Stock" ? "#16a34a" : "#dc2626"
                                                    font.pixelSize: 11; font.bold: true; anchors.centerIn: parent }
                                            }
                                        }
                                        // Cost price
                                        Item { width: prodRow.width * prodRow.ws[7]; height: 40
                                            Text { text: InventoryStore.formatCurrency(modelData.price); color: "#6b7280"; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                                        }
                                        // Selling price
                                        Item { width: prodRow.width * prodRow.ws[8]; height: 40
                                            Text { text: InventoryStore.formatCurrency(modelData.sellingPrice !== undefined ? modelData.sellingPrice : modelData.price); color: "#111827"; font.pixelSize: 12; font.bold: true; anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                                        }
                                        // Margin %
                                        Item { width: prodRow.width * prodRow.ws[9]; height: 40
                                            Text {
                                                text: InventoryStore.markupPercentFor(modelData) + "%"
                                                color: InventoryStore.markupPercentFor(modelData) > 0 ? "#16a34a" : "#9ca3af"
                                                font.pixelSize: 12; font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter; leftPadding: 8
                                            }
                                        }
                                        Item { width: prodRow.width * prodRow.ws[10]; height: 40
                                            Row {
                                                anchors.verticalCenter: parent.verticalCenter; x: 8; spacing: 4
                                                Button {
                                                    width: 28; height: 28; padding: 0
                                                    background: Rectangle { radius: 6; color: "#ffffff"; border.color: "#d1d5db" }
                                                    contentItem: Text { text: "✎"; color: "#374151"; font.pixelSize: 13
                                                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                                    onClicked: root.viewProductClicked(modelData.productId)
                                                    ToolTip.visible: hovered; ToolTip.text: "View / Edit"
                                                }
                                                Button {
                                                    text: "⟲"
                                                    visible: root.canManageInventory
                                                    width: 28; height: 28; padding: 0
                                                    onClicked: root.restockClicked(modelData.productId)
                                                    background: Rectangle { radius: 6; color: "#f3f4f6"; border.color: "#d1d5db" }
                                                    contentItem: Text { text: "⟲"; color: "#374151"; font.pixelSize: 14
                                                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                                    ToolTip.visible: hovered; ToolTip.text: "Restock"
                                                }
                                                Button {
                                                    visible: root.canManageInventory
                                                    width: 28; height: 28; padding: 0
                                                    background: Rectangle { radius: 6; color: "#fef2f2"; border.color: "#ef4444" }
                                                    contentItem: Text { text: "\u2715"; color: "#ef4444"; font.pixelSize: 13; font.bold: true
                                                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                                    onClicked: root.deleteProductClicked(modelData.productId)
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
    }
}
