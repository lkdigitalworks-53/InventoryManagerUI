import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../model"
import "../helper"
import "../components"

QQC.Dialog {
    id: root

    signal productUpdateRequested(string productId, var fields)

    modal: true
    title: editMode ? "Edit Product" : "Product Details"
    anchors.centerIn: parent
    padding: 20
    width: Math.min(parent ? parent.width - 40 : 540, 540)
    height: Math.min(parent ? parent.height - 40 : 600, 600)

    property string productId: ""
    property bool editMode: false

    property string photoUrl: ""

    function openFor(id, startInEdit) {
        productId = id
        editMode = !!startInEdit
        var p = InventoryStore.getById(id)
        if (p) {
            nameField.text = p.name || ""
            skuField.text = p.sku || ""
            descField.text = p.description || ""
            costField.text = (p.price !== undefined && p.price !== null) ? String(p.price) : "0"
            sellField.text = (p.sellingPrice !== undefined && p.sellingPrice !== null)
                ? String(p.sellingPrice)
                : (p.price !== undefined ? String(p.price) : "0")
            stockField.text = (p.stock !== undefined) ? String(p.stock) : "0"
            minStockField.text = (p.minStock !== undefined) ? String(p.minStock) : "0"
            photoUrl = p.photoUrl || ""

            // Match category against CategoryStore list, fall back to first option
            var cats = CategoryStore.categories
            var idx = 0
            for (var i = 0; i < cats.length; ++i)
                if (cats[i] === p.category) { idx = i; break }
            categoryCombo.currentIndex = idx

            var units = ["Units (pcs)", "Kg", "Litres", "Metres"]
            var ui = 0
            for (var j = 0; j < units.length; ++j)
                if (units[j] === p.unit) { ui = j; break }
            unitCombo.currentIndex = ui
        }
        errorLabel.text = ""
        photoBusy = false
        open()
    }

    property bool photoBusy: false

    PhotoSourceSheet {
        id: photoSheet
        hasExistingPhoto: root.photoUrl.length > 0
        onPhotoSourceSelected: function(url) {
            root.photoBusy = true
            StorageService.uploadProductPhoto(root.productId, url, function(ok, photoUrlOut, err) {
                root.photoBusy = false
                if (ok) {
                    root.photoUrl = photoUrlOut
                    InventoryStore.setPhoto(root.productId, photoUrlOut)
                } else {
                    errorLabel.text = "Photo: " + err
                }
            })
        }
        onRemoveRequested: {
            StorageService.deleteProductPhoto(root.productId, function(ok, err) {
                if (ok) {
                    root.photoUrl = ""
                    InventoryStore.setPhoto(root.productId, "")
                }
            })
        }
    }

    background: Rectangle {
        radius: 12
        color: "#ffffff"
        border.color: Constants.borderColor
    }

    contentItem: QQC.ScrollView {
        clip: true
        ColumnLayout {
            width: root.width - 40
            spacing: 12

            // Header strip
            Rectangle {
                Layout.fillWidth: true
                radius: 10
                color: "#f9fafb"
                border.color: "#e5e7eb"
                implicitHeight: hdrCol.implicitHeight + 16

                ColumnLayout {
                    id: hdrCol
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 2

                    QQC.Label {
                        text: nameField.text || "(unnamed product)"
                        font.bold: true
                        font.pixelSize: 14
                        color: "#111827"
                    }
                    QQC.Label {
                        text: "ID: " + root.productId + (skuField.text ? "    SKU: " + skuField.text : "")
                        font.pixelSize: 11
                        color: "#6b7280"
                    }
                }
            }

            // ── Photo panel ──
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 12

                Rectangle {
                    Layout.preferredWidth: 80
                    Layout.preferredHeight: 80
                    radius: 10
                    color: "#f3f4f6"
                    border.color: Constants.borderColor

                    Image {
                        anchors.fill: parent
                        anchors.margins: 2
                        source: root.photoUrl
                        sourceSize.width: 160
                        sourceSize.height: 160
                        fillMode: Image.PreserveAspectCrop
                        cache: true
                        visible: root.photoUrl.length > 0
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "📦"
                        font.pixelSize: 32
                        visible: root.photoUrl.length === 0
                    }
                    QQC.BusyIndicator {
                        anchors.centerIn: parent
                        running: root.photoBusy
                        visible: root.photoBusy
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    QQC.Label {
                        text: "Product photo"
                        font.bold: true
                        font.pixelSize: 13
                        color: "#374151"
                    }
                    QQC.Label {
                        text: root.photoUrl.length > 0
                            ? "Tap “Change photo” to replace the current image."
                            : "Add a photo so customers can recognise the product faster."
                        font.pixelSize: 11
                        color: "#6b7280"
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                    }
                    QQC.Button {
                        Layout.preferredWidth: 160
                        text: root.photoUrl.length > 0 ? "Change photo" : "Add photo"
                        enabled: root.editMode && !root.photoBusy
                        onClicked: photoSheet.open()
                    }
                }
            }

            // Product info
            QQC.Label { text: "Product Information"; font.bold: true; font.pixelSize: 13; color: "#374151"; Layout.topMargin: 4 }

            RowLayout {
                Layout.fillWidth: true
                QQC.Label { text: "Name"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
                QQC.TextField { id: nameField; Layout.fillWidth: true; readOnly: !root.editMode }
            }
            RowLayout {
                Layout.fillWidth: true
                QQC.Label { text: "SKU"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
                QQC.TextField { id: skuField; Layout.fillWidth: true; readOnly: !root.editMode }
            }
            RowLayout {
                Layout.fillWidth: true
                QQC.Label { text: "Category"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
                QQC.ComboBox {
                    id: categoryCombo
                    Layout.fillWidth: true
                    model: CategoryStore.categories
                    enabled: root.editMode
                }
            }
            RowLayout {
                Layout.fillWidth: true
                QQC.Label { text: "Unit"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
                QQC.ComboBox {
                    id: unitCombo
                    Layout.fillWidth: true
                    model: ["Units (pcs)", "Kg", "Litres", "Metres"]
                    enabled: root.editMode
                }
            }
            RowLayout {
                Layout.fillWidth: true
                QQC.Label { text: "Description"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
                QQC.TextField { id: descField; Layout.fillWidth: true; readOnly: !root.editMode }
            }

            // Pricing & stock
            QQC.Label { text: "Pricing & Stock"; font.bold: true; font.pixelSize: 13; color: "#374151"; Layout.topMargin: 8 }

            RowLayout {
                Layout.fillWidth: true
                QQC.Label { text: "Cost (₹)"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
                QQC.TextField {
                    id: costField; Layout.fillWidth: true; readOnly: !root.editMode
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                }
            }
            RowLayout {
                Layout.fillWidth: true
                QQC.Label { text: "Selling (₹)"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
                QQC.TextField {
                    id: sellField; Layout.fillWidth: true; readOnly: !root.editMode
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                }
            }
            RowLayout {
                Layout.fillWidth: true
                QQC.Label { text: "Markup"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: 6
                    color: "#f0fdf4"; border.color: "#86efac"
                    Text {
                        anchors.centerIn: parent
                        font.pixelSize: 12; font.bold: true; color: "#16a34a"
                        text: {
                            var c = parseFloat(costField.text)
                            var s = parseFloat(sellField.text)
                            if (isNaN(c) || isNaN(s) || c <= 0) return "—"
                            return Math.round(((s - c) / c) * 100) + "%   (₹" + (s - c).toFixed(2) + " profit/unit)"
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                QQC.Label { text: "Stock"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
                QQC.TextField { id: stockField; Layout.fillWidth: true; readOnly: !root.editMode; inputMethodHints: Qt.ImhDigitsOnly }
            }
            RowLayout {
                Layout.fillWidth: true
                QQC.Label { text: "Min Stock"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
                QQC.TextField { id: minStockField; Layout.fillWidth: true; readOnly: !root.editMode; inputMethodHints: Qt.ImhDigitsOnly }
            }

            QQC.Label {
                id: errorLabel
                Layout.fillWidth: true
                visible: text.length > 0
                color: "#b91c1c"
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 8

                QQC.Button {
                    text: "Close"
                    visible: !root.editMode
                    Layout.fillWidth: true
                    onClicked: root.close()
                }
                QQC.Button {
                    text: "Edit"
                    visible: !root.editMode && AuthStore.canManageInventory
                    Layout.fillWidth: true
                    background: Rectangle { radius: 8; color: Constants.primaryBlue }
                    contentItem: Text { text: "Edit"; color: "#ffffff"; font.bold: true; font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    onClicked: root.editMode = true
                }
                QQC.Button {
                    text: "Cancel"
                    visible: root.editMode
                    Layout.fillWidth: true
                    onClicked: root.openFor(root.productId, false)
                }
                QQC.Button {
                    text: "Save"
                    visible: root.editMode
                    Layout.fillWidth: true
                    background: Rectangle { radius: 8; color: Constants.primaryBlue }
                    contentItem: Text { text: "Save"; color: "#ffffff"; font.bold: true; font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    onClicked: root._submit()
                }
            }
        }
    }

    function _submit() {
        var errs = []
        if (!nameField.text || nameField.text.trim().length < 2) errs.push("Enter a valid name")
        if (!skuField.text || skuField.text.trim().length === 0) errs.push("Enter SKU")
        var cost = parseFloat(costField.text)
        if (isNaN(cost) || cost < 0) errs.push("Enter valid cost price")
        var sell = parseFloat(sellField.text)
        if (isNaN(sell) || sell <= 0) errs.push("Enter valid selling price")
        if (!isNaN(cost) && !isNaN(sell) && sell < cost) errs.push("Selling price must be ≥ cost")
        var stk = parseInt(stockField.text)
        if (isNaN(stk) || stk < 0) errs.push("Enter valid stock")
        var ms = parseInt(minStockField.text)
        if (isNaN(ms) || ms < 0) errs.push("Enter valid minimum stock")
        if (errs.length > 0) {
            errorLabel.text = errs.join(" · ")
            return
        }
        productUpdateRequested(root.productId, {
            name: nameField.text.trim(),
            sku: skuField.text.trim(),
            category: categoryCombo.currentText,
            description: descField.text.trim(),
            unit: unitCombo.currentText,
            price: cost,
            sellingPrice: sell,
            stock: stk,
            minStock: ms
        })
        errorLabel.text = ""
        root.editMode = false
        root.close()
    }
}
