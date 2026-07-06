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
    // The photo-source sheet is hoisted to the App root (Main.qml) — a Popup
    // declared inside this BottomSheet's body opens off-screen. Main opens the
    // shared sheet on request and routes its result back via these functions.
    signal photoPickRequested(bool hasExistingPhoto)

    property string pendingPhotoSource: ""

    function applyPhotoSource(url) { dlg.pendingPhotoSource = url }
    function clearPhotoSource() { dlg.pendingPhotoSource = "" }

    onOpened: {
        var idx = CategoryStore.indexOfDefault()
        if (idx >= 0 && idx < CategoryStore.categories.length)
            categoryCombo.currentIndex = idx
        pendingPhotoSource = ""
        nameField.text = ""
        skuField.text = ""
        descField.text = ""
        priceField.text = ""
        sellingPriceField.text = ""
        stockField.text = ""
        minStockField.text = ""
        taxableCombo.currentIndex = 0
        taxPercentField.text = ""
        // Build the supplier picker from SupplierStore. Index 0 stays empty
        // ("Select or add a supplier") so the user can leave it blank.
        dlg._refreshSuppliers("")
        addPartyField.text = ""
        dlg._addPartyOpen = false
        advToggle.open = true   // advanced section visible every time the sheet opens
    }

    // Local toggle for the inline "Add new party" row — see RestockDialog
    // for why we don't drive this off the field's own `visible`.
    property bool _addPartyOpen: false

    // Mirror of SupplierStore for the picker: ids and labels move together.
    property var _supplierIds: [""]
    property var _supplierLabels: [qsTr("Select or add a supplier")]

    function _refreshSuppliers(preferredId) {
        var ids = [""]
        var labels = [qsTr("Select or add a supplier")]
        var src = SupplierStore.suppliers || []
        for (var i = 0; i < src.length; ++i) {
            ids.push(src[i].supplierId)
            labels.push(src[i].name)
        }
        _supplierIds = ids
        _supplierLabels = labels
        partyCombo.model = labels
        var idx = preferredId ? Math.max(0, ids.indexOf(preferredId)) : 0
        partyCombo.currentIndex = idx
    }

    function getSellingPrice(sellingPriceText, costPriceText, isMarkupSelected) {
        var v = parseFloat(sellingPriceText)
        if (!isMarkupSelected) return v;

        var c = parseFloat(costPriceText)
        var sp = Math.round(((v * c) / 100) + c)
        return sp
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
                Icon {
                    anchors.centerIn: parent
                    visible: dlg.pendingPhotoSource.length === 0
                    name: "camera"
                    size: sp(24)
                    color: Constants.textSecondary
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
                onClicked: dlg.photoPickRequested(dlg.pendingPhotoSource.length > 0)
            }
        }

        AuthTextField {
            id: nameField
            Layout.fillWidth: true
            label: "Name"
            placeholderText: "e.g. Cappuccino"
        }

        RowLayout {
            id: priceRow
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            property bool isMarkupSelected: false

            AuthTextField {
                id: priceField
                Layout.fillWidth: true
                label: "Cost"
                placeholderText: "0.00"
                inputMethodHints: Qt.ImhFormattedNumbersOnly
            }

            SegmentedPill {
                Layout.preferredWidth: dp(72)
                Layout.alignment: Qt.AlignBottom
                model: ["₹", "%"]
                selected: priceRow.isMarkupSelected ? 1 : 0
                onSegmentSelected: function(idx, label) {
                    priceRow.isMarkupSelected = idx === 1 ? true : false
                }
            }

            AuthTextField {
                id: sellingPriceField
                Layout.fillWidth: true
                label: priceRow.isMarkupSelected ? "Markup %" : "₹ Price"
                placeholderText: "0.00"
                inputMethodHints: Qt.ImhFormattedNumbersOnly
            }
        }

        // Markup pill (live)
        Rectangle {
            id: markupPill
            Layout.fillWidth: true
            radius: dp(12)
            color: Qt.rgba(0.06, 0.72, 0.51, 0.10)
            Layout.preferredHeight: dp(36)
            visible: !priceRow.isMarkupSelected // Show markup information if flat price is selected
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

        // Selling price pill (live)
        Rectangle {
            id: sellingPricePill
            Layout.fillWidth: true
            radius: dp(12)
            color: Qt.rgba(0.06, 0.72, 0.51, 0.10)
            Layout.preferredHeight: dp(36)
            visible: priceRow.isMarkupSelected // Show price information if markup % is selected
            Text {
                anchors.centerIn: parent
                color: Constants.success
                font.pixelSize: sp(Constants.fsSmall)
                font.bold: true
                text: {
                    var c = parseFloat(priceField.text)
                    var m = parseFloat(sellingPriceField.text)
                    if (isNaN(c) || isNaN(m) || c <= 0) return "Selling price —"
                    var sp = Math.round(((m * c) / 100) + c)
                    return "Selling price ₹" + sp + "   ·   profit ₹" + (sp - c).toFixed(2)
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
                    property bool open: true   // advanced section starts expanded
                    contentItem: RowLayout {
                        Text {
                            text: qsTr("Advanced")
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBody)
                            font.bold: true
                            Layout.fillWidth: true
                        }
                        Icon {
                            // Match the AppComboBox dropdown caret so the
                            // disclosure looks like the rest of the app's
                            // selectable controls. Flip on open.
                            name: "dropdown"
                            color: Constants.textSecondary
                            size: sp(14)
                            rotation: advToggle.open ? 180 : 0
                            Behavior on rotation { NumberAnimation { duration: Constants.durFast } }
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
                            // Bottom-align so the button sits level with the SKU
                            // INPUT field, not vertically centred across the
                            // field's label + input (which floated it up to the
                            // label row). The AuthTextField sibling carries the
                            // label on top, so AlignBottom matches the input box.
                            Layout.alignment: Qt.AlignBottom
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
                            label: qsTr("Initial stock")
                            placeholderText: "0"
                        }
                        AuthTextField {
                            id: minStockField
                            Layout.fillWidth: true
                            label: qsTr("Reorder at")
                            placeholderText: "2"
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: dp(Constants.space2)

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: dp(4)
                            Text { text: qsTr("Tax"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
                            AppComboBox {
                                id: taxableCombo
                                Layout.fillWidth: true
                                model: [qsTr("Not taxable"), qsTr("Taxable")]
                                font.pixelSize: sp(Constants.fsBody)
                            }
                        }
                        AuthTextField {
                            id: taxPercentField
                            Layout.fillWidth: true
                            label: qsTr("Tax %")
                            placeholderText: "0"
                            text: "0"
                            enabled: taxableCombo.currentIndex === 1
                            inputMethodHints: Qt.ImhFormattedNumbersOnly
                        }
                    }

                    AuthTextField {
                        id: descField
                        Layout.fillWidth: true
                        label: qsTr("Description")
                        placeholderText: qsTr("Optional")
                    }

                    // Supplier / party picker — optional. Tracking the source
                    // of initial stock turns the "Created" history row into a
                    // first purchase event for the Analysis page.
                    Text {
                        text: qsTr("Supplier (party)")
                        color: Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
                        font.bold: true
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: dp(Constants.space2)
                        AppComboBox {
                            id: partyCombo
                            Layout.fillWidth: true
                            // Labels come from `_supplierLabels`; selected
                            // supplierId resolved via `_supplierIds[idx]`.
                            model: dlg._supplierLabels
                            font.pixelSize: sp(Constants.fsBody)
                            displayText: currentIndex > 0
                                    ? currentText
                                    : qsTr("Select or add a supplier")
                        }
                        QQC.AbstractButton {
                            id: addPartyToggle
                            Layout.preferredWidth: dp(44)
                            Layout.preferredHeight: dp(44)
                            implicitWidth: dp(44)
                            implicitHeight: dp(44)
                            padding: 0
                            topPadding: 0; bottomPadding: 0; leftPadding: 0; rightPadding: 0
                            background: Rectangle {
                                anchors.fill: parent
                                radius: dp(14)
                                color: addPartyToggle.pressed ? Constants.borderColor : Constants.cardBg
                                border.color: Constants.borderColor
                                border.width: 1
                                Behavior on color { ColorAnimation { duration: Constants.durFast } }
                            }
                            contentItem: Icon {
                                name: dlg._addPartyOpen ? "close" : "add"
                                color: Constants.textPrimary
                                size: sp(18)
                            }
                            onClicked: {
                                dlg._addPartyOpen = !dlg._addPartyOpen
                                if (dlg._addPartyOpen) addPartyField.forceActiveFocus()
                                else addPartyField.text = ""
                            }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: dp(Constants.space2)
                        visible: dlg._addPartyOpen
                        AuthTextField {
                            id: addPartyField
                            Layout.fillWidth: true
                            placeholderText: qsTr("New supplier name")
                            onAccepted: addPartyBtn.clicked()
                        }
                        PrimaryButton {
                            id: addPartyBtn
                            text: qsTr("Save")
                            implicitHeight: dp(44)
                            implicitWidth: dp(80)
                            onClicked: {
                                var n = (addPartyField.text || "").trim()
                                if (n.length === 0) return
                                var s = SupplierStore.addSupplier({ name: n })
                                dlg._refreshSuppliers(s ? s.supplierId : "")
                                addPartyField.text = ""
                                dlg._addPartyOpen = false
                            }
                        }
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
        var sp = getSellingPrice(sellingPriceField.text, priceField.text,  priceRow.isMarkupSelected)
        if (isNaN(sp) || sp <= 0) errs.push("Enter a valid price")
        if (!isNaN(p) && !isNaN(sp) && sp < p) errs.push("Price < cost")
        var s = parseInt(stockField.text)
        if (isNaN(s) || s < 0) errs.push("Enter valid stock")
        var ms = parseInt(minStockField.text)
        if (isNaN(ms) || ms < 0) errs.push("Enter valid reorder point")
        var taxable = taxableCombo.currentIndex === 1
        var taxPercent = 0
        if (taxable) {
            taxPercent = parseFloat(taxPercentField.text)
            if (isNaN(taxPercent) || taxPercent < 0 || taxPercent > 100)
                errs.push("Enter a valid tax % (0–100)")
        }
        if (errs.length > 0) { errorLabel.text = errs.join(" · "); return }
        errorLabel.text = ""

        // Resolve picker selection to a stable supplierId; index 0 means
        // "no supplier", which leaves the initial-stock batch unattributed.
        var supplierId = partyCombo.currentIndex > 0 ? dlg._supplierIds[partyCombo.currentIndex] : ""
        // Initial-batch unit cost defaults to product cost — same convention
        // as RestockDialog. Future "advanced" UI could expose this separately.
        var newId = InventoryStore.addProduct(nameField.text, skuField.text,
            categoryCombo.currentText, descField.text, p, unitCombo.currentText, s, ms, sp,
            taxable, taxable ? taxPercent : 0, supplierId, p /* unitCost = cost */)
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
