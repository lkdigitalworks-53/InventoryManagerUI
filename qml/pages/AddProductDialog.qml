import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Add Product bottom sheet — preserves photo upload, SKU generation, advanced
// disclosure (stock + reorder). Public contract: signal productCreated(),
// signal manageCategoriesRequested().
BottomSheet {
    id: dlg

    sheetTitle: "Add product"
    primaryAction: "Save"
    secondaryAction: "Cancel"

    signal productCreated()
    signal manageCategoriesRequested()

    property string pendingPhotoSource: ""

    PhotoSourceSheet {
        id: photoSheet
        hasExistingPhoto: dlg.pendingPhotoSource.length > 0
        onPhotoSourceSelected: function(url) { dlg.pendingPhotoSource = url }
        onRemoveRequested: dlg.pendingPhotoSource = ""
    }

    onOpened: {
        var idx = CategoryStore.indexOfDefault()
        if (idx >= 0 && idx < CategoryStore.categories.length)
            categoryCombo.currentIndex = idx
        pendingPhotoSource = ""
        nameField.text = ""
        skuField.text = ""
        descField.text = ""
        priceField.text = "0.00"
        sellingPriceField.text = "0.00"
        stockField.text = "0"
        minStockField.text = "0"
    }

    onPrimaryClicked: trySubmit()

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        // Photo picker
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space3)

            Rectangle {
                width: dp(64); height: dp(64); radius: dp(16)
                color: Qt.rgba(0.39, 0.40, 0.95, 0.10)
                clip: true

                Image {
                    anchors.fill: parent
                    anchors.margins: dp(2)
                    source: dlg.pendingPhotoSource
                    visible: dlg.pendingPhotoSource.length > 0
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 128; sourceSize.height: 128
                }
                Text {
                    anchors.centerIn: parent
                    visible: dlg.pendingPhotoSource.length === 0
                    text: "📷"
                    font.pixelSize: sp(24)
                }
            }

            ColumnLayout {
                spacing: dp(4)
                Layout.fillWidth: true
                Text {
                    text: dlg.pendingPhotoSource.length > 0 ? "Photo ready" : "Add a photo"
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }
                Text {
                    text: dlg.pendingPhotoSource.length > 0
                        ? "It'll save when you tap Save."
                        : "Capture or pick from gallery."
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsCaption)
                }
            }

            GhostButton {
                text: dlg.pendingPhotoSource.length > 0 ? "Change" : "Add photo"
                implicitHeight: dp(36)
                onClicked: photoSheet.open()
            }
        }

        AuthTextField {
            id: nameField
            Layout.fillWidth: true
            label: "Name"
            placeholderText: "e.g. Cappuccino"
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            AuthTextField {
                id: priceField
                Layout.fillWidth: true
                label: "Cost"
                placeholderText: "0.00"
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                text: "0.00"
            }
            AuthTextField {
                id: sellingPriceField
                Layout.fillWidth: true
                label: "Price"
                placeholderText: "0.00"
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                text: "0.00"
            }
        }

        // Markup pill (live)
        Rectangle {
            Layout.fillWidth: true
            radius: dp(12)
            color: Qt.rgba(0.06, 0.72, 0.51, 0.10)
            Layout.preferredHeight: dp(36)
            Text {
                anchors.centerIn: parent
                color: Constants.success
                font.pixelSize: sp(Constants.fsSmall)
                font.bold: true
                text: {
                    var c = parseFloat(priceField.text)
                    var s = parseFloat(sellingPriceField.text)
                    if (isNaN(c) || isNaN(s) || c <= 0) return "Markup —"
                    return "Markup " + Math.round(((s - c) / c) * 100) + "%   ·   profit ₹" + (s - c).toFixed(2)
                }
            }
        }

        // Advanced disclosure (SKU, stock, reorder, category)
        Rectangle {
            Layout.fillWidth: true
            radius: dp(Constants.radius)
            color: Constants.subtleBg
            border.color: Constants.borderColor
            border.width: 1
            Layout.preferredHeight: advCol.implicitHeight + dp(24)
            clip: true

            ColumnLayout {
                id: advCol
                anchors.fill: parent
                anchors.margins: dp(Constants.space3)
                spacing: dp(Constants.space2)

                QQC.AbstractButton {
                    id: advToggle
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(32)
                    property bool open: false
                    contentItem: RowLayout {
                        Text {
                            text: "Advanced"
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBody)
                            font.bold: true
                            Layout.fillWidth: true
                        }
                        Text {
                            text: advToggle.open ? "˅" : "›"
                            color: Constants.textSecondary
                            font.pixelSize: sp(16)
                        }
                    }
                    background: Rectangle { color: "transparent" }
                    onClicked: open = !open
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    visible: advToggle.open
                    spacing: dp(Constants.space2)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: dp(Constants.space2)
                        AuthTextField {
                            id: skuField
                            Layout.fillWidth: true
                            label: "SKU"
                            placeholderText: "Auto-generated"
                        }
                        GhostButton {
                            text: "Gen"
                            implicitHeight: dp(44)
                            onClicked: skuField.text = InventoryStore.generateSku(nameField.text)
                        }
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
                                font.pixelSize: sp(Constants.fsBody)
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: dp(Constants.space2)
                        AuthTextField {
                            id: stockField
                            Layout.fillWidth: true
                            label: "Initial stock"
                            placeholderText: "0"
                            text: "0"
                        }
                        AuthTextField {
                            id: minStockField
                            Layout.fillWidth: true
                            label: "Reorder at"
                            placeholderText: "10"
                            text: "0"
                        }
                    }

                    AuthTextField {
                        id: descField
                        Layout.fillWidth: true
                        label: "Description"
                        placeholderText: "Optional"
                    }

                    GhostButton {
                        Layout.fillWidth: true
                        text: "Manage categories"
                        onClicked: dlg.manageCategoriesRequested()
                    }
                }
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

    function trySubmit() {
        var errs = []
        if (!nameField.text || nameField.text.length < 2) errs.push("Enter a valid product name")
        if (!skuField.text) errs.push("SKU required (tap Gen)")
        if (categoryCombo.currentIndex < 0) errs.push("Select a category")
        var p = parseFloat(priceField.text)
        if (isNaN(p) || p < 0) errs.push("Enter a valid cost")
        var sp = parseFloat(sellingPriceField.text)
        if (isNaN(sp) || sp <= 0) errs.push("Enter a valid price")
        if (!isNaN(p) && !isNaN(sp) && sp < p) errs.push("Price < cost")
        var s = parseInt(stockField.text)
        if (isNaN(s) || s < 0) errs.push("Enter valid stock")
        var ms = parseInt(minStockField.text)
        if (isNaN(ms) || ms < 0) errs.push("Enter valid reorder point")
        if (errs.length > 0) { errorLabel.text = errs.join(" · "); return }
        errorLabel.text = ""

        var newId = InventoryStore.addProduct(nameField.text, skuField.text,
            categoryCombo.currentText, descField.text, p, unitCombo.currentText, s, ms, sp)
        CategoryStore.setLastUsed(categoryCombo.currentText)

        if (pendingPhotoSource && pendingPhotoSource.length > 0 && newId) {
            StorageService.uploadProductPhoto(newId, pendingPhotoSource, function(ok, photoUrl) {
                if (ok) InventoryStore.setPhoto(newId, photoUrl)
            })
        }

        Toast.show("Product added")
        productCreated()
        dlg.close()
    }
}
