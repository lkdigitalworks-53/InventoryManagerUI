import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Product detail / edit — bottom sheet. Public contract preserved:
//   signal productUpdateRequested(productId, fields)
//   function openFor(id, startInEdit)
//   property string productId
//   property bool editMode
//   property string photoUrl
BottomSheet {
    id: root

    sheetTitle: editMode ? "Edit product" : "Product details"
    primaryAction: editMode ? "Save changes" : (AuthStore.canManageInventory ? "Edit" : "")
    secondaryAction: editMode ? "Cancel" : "Close"

    signal productUpdateRequested(string productId, var fields)

    property string productId: ""
    property bool editMode: false
    property string photoUrl: ""
    property bool photoBusy: false

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

    onPrimaryClicked: {
        if (!editMode) editMode = true
        else _submit()
    }
    onSecondaryClicked: {
        if (editMode) openFor(productId, false)
    }

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

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        // Header card with name + ID + SKU
        Rectangle {
            Layout.fillWidth: true
            radius: dp(Constants.radius)
            color: Qt.rgba(0.39, 0.40, 0.95, 0.06)
            border.color: Constants.borderColor
            border.width: 1
            Layout.preferredHeight: hdrCol.implicitHeight + dp(Constants.space4 * 2)

            ColumnLayout {
                id: hdrCol
                anchors.fill: parent
                anchors.margins: dp(Constants.space3)
                spacing: dp(2)
                Text {
                    text: nameField.text || "(unnamed product)"
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }
                Text {
                    text: "ID: " + root.productId + (skuField.text ? "   ·   SKU: " + skuField.text : "")
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsCaption)
                }
            }
        }

        // Photo block
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space3)

            Rectangle {
                Layout.preferredWidth: dp(80)
                Layout.preferredHeight: dp(80)
                radius: dp(Constants.radius)
                color: Constants.subtleBg
                border.color: Constants.borderColor
                border.width: 1
                clip: true

                Image {
                    anchors.fill: parent
                    anchors.margins: dp(2)
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
                    font.pixelSize: sp(32)
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
                spacing: dp(4)

                Text {
                    text: "Product photo"
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }
                Text {
                    text: root.photoUrl.length > 0
                        ? "Tap “Change photo” to replace the current image."
                        : "Add a photo so customers recognise the product."
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsCaption)
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                }
                GhostButton {
                    Layout.preferredWidth: dp(160)
                    implicitHeight: dp(36)
                    text: root.photoUrl.length > 0 ? "Change photo" : "Add photo"
                    enabled: root.editMode && !root.photoBusy
                    onClicked: photoSheet.open()
                }
            }
        }

        Text {
            text: "Product info"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        AuthTextField {
            id: nameField
            Layout.fillWidth: true
            label: "Name"
            readOnly: !root.editMode
        }
        AuthTextField {
            id: skuField
            Layout.fillWidth: true
            label: "SKU"
            readOnly: !root.editMode
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            ColumnLayout {
                Layout.fillWidth: true
                spacing: dp(4)
                Text { text: "Category"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
                AppComboBox {
                    id: categoryCombo
                    Layout.fillWidth: true
                    model: CategoryStore.categories
                    enabled: root.editMode
                    font.pixelSize: sp(Constants.fsBody)
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: dp(4)
                Text { text: "Unit"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
                AppComboBox {
                    id: unitCombo
                    Layout.fillWidth: true
                    model: ["Units (pcs)", "Kg", "Litres", "Metres"]
                    enabled: root.editMode
                    font.pixelSize: sp(Constants.fsBody)
                }
            }
        }

        AuthTextField {
            id: descField
            Layout.fillWidth: true
            label: "Description"
            readOnly: !root.editMode
        }

        Text {
            text: "Pricing & stock"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AuthTextField {
                id: costField
                Layout.fillWidth: true
                label: "Cost (₹)"
                readOnly: !root.editMode
                inputMethodHints: Qt.ImhFormattedNumbersOnly
            }
            AuthTextField {
                id: sellField
                Layout.fillWidth: true
                label: "Selling (₹)"
                readOnly: !root.editMode
                inputMethodHints: Qt.ImhFormattedNumbersOnly
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: dp(36)
            radius: dp(12)
            color: Qt.rgba(0.06, 0.72, 0.51, 0.10)
            Text {
                anchors.centerIn: parent
                color: Constants.success
                font.pixelSize: sp(Constants.fsSmall)
                font.bold: true
                text: {
                    var c = parseFloat(costField.text)
                    var s = parseFloat(sellField.text)
                    if (isNaN(c) || isNaN(s) || c <= 0) return "Markup —"
                    return "Markup " + Math.round(((s - c) / c) * 100) + "%   ·   profit ₹" + (s - c).toFixed(2)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AuthTextField {
                id: stockField
                Layout.fillWidth: true
                label: "Stock"
                readOnly: !root.editMode
                inputMethodHints: Qt.ImhDigitsOnly
            }
            AuthTextField {
                id: minStockField
                Layout.fillWidth: true
                label: "Min stock"
                readOnly: !root.editMode
                inputMethodHints: Qt.ImhDigitsOnly
            }
        }

        Text {
            id: errorLabel
            Layout.fillWidth: true
            visible: text.length > 0
            color: Constants.danger
            font.pixelSize: sp(Constants.fsSmall)
            wrapMode: Text.Wrap
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
        editMode = false
        close()
    }
}
