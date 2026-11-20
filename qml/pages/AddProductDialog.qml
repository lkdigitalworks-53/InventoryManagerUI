import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../helper/AddProductFlow.js" as AddProductFlow
import "../helper/RestockFlow.js" as RestockFlow
import "../model"

// Add Product bottom sheet — preserves photo upload, SKU generation, advanced
// disclosure (stock + reorder). Public contract: signal manageCategoriesRequested().
// AP3b: every decision before the store call (strict number parsing, limits, the supplier) is AddProductFlow.fromForm.
BottomSheet {
    id: dlg

    sheetTitle: "Add product"
    holdsRefresh: true   // edit form: the background list refresh waits while it is open
    primaryAction: "Save"
    secondaryAction: "Cancel"
    // The full-sheet busy overlay: BottomSheet shows it while busy AND this is non-empty (see RestockDialog).
    // A constant, not set at the tap, so no early return can leave it stale or empty.
    busyMessage: qsTr("Adding product — this can take a few seconds")

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
        sizeField.text = ""
        // Build the supplier picker from SupplierStore. Index 0 stays empty
        // ("Select or add a supplier") so the user can leave it blank.
        dlg._refreshSuppliers("")
        addPartyField.text = ""
        dlg._addPartyOpen = false
        dlg._newSupplierName = ""
        advToggle.open = true   // advanced section visible every time the sheet opens
    }

    // Local toggle for the inline "Add new party" row — see RestockDialog
    // for why we don't drive this off the field's own `visible`.
    property bool _addPartyOpen: false
    // A typed NEW supplier name (AP3b, the R5a pattern). Nothing is created when the person taps "Use": the name travels inside
    // the add operation and the server creates the supplier in the same transaction as the product, so an add that fails leaves
    // no orphan supplier and burns no number. "" = none. Picking a row in the combo clears it.
    property string _newSupplierName: ""

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

    // The "Use" button of the inline new-supplier row. Creates NOTHING (see _newSupplierName). A name that matches a known
    // supplier (case-insensitive) selects that row instead, so retyping "acme" never makes a second supplier.
    function _useTypedParty() {
        var c = RestockFlow.newPartyChoice(addPartyField.text, SupplierStore.suppliers)
        if (c.kind === "none") return
        if (c.kind === "invalid") { Toast.show(c.message); return }
        if (c.kind === "existing") {
            dlg._newSupplierName = ""
            dlg._refreshSuppliers(c.id)
        } else {
            dlg._newSupplierName = c.name
            partyCombo.currentIndex = 0
        }
        addPartyField.text = ""
        dlg._addPartyOpen = false
    }

    onPrimaryClicked: { if (!busy) trySubmit() }

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
            maximumLength: AddProductFlow.MAX_NAME
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
                text: AddProductFlow.priceSummary(priceField.text, sellingPriceField.text, false)
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
                text: AddProductFlow.priceSummary(priceField.text, sellingPriceField.text, true)
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
                            maximumLength: AddProductFlow.MAX_SKU
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

                    AuthTextField {
                        id: sizeField
                        Layout.fillWidth: true
                        label: qsTr("Size")
                        placeholderText: qsTr("e.g. M, L, XL, 500ml")
                        maximumLength: AddProductFlow.MAX_SIZE
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: dp(Constants.space2)
                        AuthTextField {
                            id: stockField
                            Layout.fillWidth: true
                            label: qsTr("Initial stock")
                            placeholderText: "0"
                            maximumLength: String(AddProductFlow.MAX_STOCK).length
                            inputMethodHints: Qt.ImhDigitsOnly
                        }
                        AuthTextField {
                            id: minStockField
                            Layout.fillWidth: true
                            label: qsTr("Reorder at")
                            placeholderText: "0"
                            maximumLength: String(AddProductFlow.MAX_STOCK).length
                            inputMethodHints: Qt.ImhDigitsOnly
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
                        maximumLength: AddProductFlow.MAX_DESCRIPTION
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
                            displayText: dlg._newSupplierName.length > 0
                                    ? qsTr("New: %1").arg(dlg._newSupplierName)
                                    : (currentIndex > 0 ? currentText : qsTr("Select or add a supplier"))
                            // A user pick replaces a typed new name (one supplier per product). Programmatic currentIndex
                            // changes do not emit `activated`, so _useTypedParty / _refreshSuppliers never clear it by accident.
                            onActivated: dlg._newSupplierName = ""
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
                            maximumLength: RestockFlow.MAX_SUPPLIER_NAME
                            onAccepted: addPartyBtn.clicked()
                        }
                        PrimaryButton {
                            id: addPartyBtn
                            text: qsTr("Use")
                            implicitHeight: dp(44)
                            implicitWidth: dp(80)
                            onClicked: dlg._useTypedParty()
                        }
                    }
                    // Says what "Use" did: the supplier does not exist yet, it is created with the product.
                    Text {
                        Layout.fillWidth: true
                        visible: dlg._newSupplierName.length > 0
                        text: qsTr("“%1” will be added as a new supplier when you save this product.").arg(dlg._newSupplierName)
                        wrapMode: Text.WordWrap
                        color: Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
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
        // Same shape as RestockDialog._confirm (PR #183): a throw before the answer must not leave the full-sheet busy overlay on.
        var settled = false
        try {
            var form = AddProductFlow.fromForm({
                name: nameField.text, sku: skuField.text, size: sizeField.text, description: descField.text,
                category: categoryCombo.currentText, categoryIndex: categoryCombo.currentIndex, unit: unitCombo.currentText,
                costText: priceField.text, priceText: sellingPriceField.text, markup: priceRow.isMarkupSelected,
                stockText: stockField.text, minStockText: minStockField.text,
                taxable: taxableCombo.currentIndex === 1, taxPercentText: taxPercentField.text,
                pendingPartyText: addPartyField.text, newSupplierName: dlg._newSupplierName,
                partyIndex: partyCombo.currentIndex, supplierIds: dlg._supplierIds })
            if (!form.ok) { errorLabel.text = form.errors.join(" · "); return }
            errorLabel.text = ""
            var a = form.args
            // Initial-batch unit cost is the product cost (same convention as RestockDialog's default).
            busy = true
            InventoryStore.addProduct(a.name, a.sku, a.category, a.description, a.price, a.unit, a.stock, a.minStock,
                a.sellingPrice, a.taxable, a.taxPercent, a.party, a.unitCost, a.size, function(ok, newId, refusal, status) {
                    settled = true
                    busy = false
                    if (!ok) {
                        errorLabel.text = refusal ? refusal : "Could not add product — try again"
                        return
                    }
                    // Review sweep 1 of PR 207: the product exists from here on. This part runs from the Gateway's callback, NOT inside
                    // the try/catch around the call, so a throw in a side effect (last-used category, photo queue) or in the toast must not
                    // skip the toast and the close: the sheet would stay open with the form filled and a second tap would add a SECOND product.
                    try { CategoryStore.setLastUsed(a.category) } catch (e1) { console.warn("[AddProductDialog] setLastUsed failed:", e1) }

                    // AP3a: the photo is attached from the LIVE answer only (design D-AP-8). A queued answer (slow link) has no id
                    // yet, so the photo is not attached and the toast says where to add it; an unconfirmed answer (the server
                    // may have saved it) has none either, and the person is told to check the list before adding again.
                    var photoSkipped = false
                    if (pendingPhotoSource && pendingPhotoSource.length > 0) {
                        if (status === "applied" && newId) {
                            // addProductPhoto queues the upload and returns immediately (design spec) --
                            // no callback needed. PhotoQueue.photoUploaded (wired in EditProductDialog's
                            // gallery, Main.qml) reports the outcome once the upload itself completes.
                            try {
                                var addResult = StorageService.addProductPhoto(newId, pendingPhotoSource)
                                if (!addResult.ok) {
                                    console.warn("[AddProductDialog] addProductPhoto failed for", newId, addResult.error)
                                    photoSkipped = true
                                }
                            } catch (e2) {
                                console.warn("[AddProductDialog] addProductPhoto threw for", newId, e2)
                                photoSkipped = true
                            }
                        } else {
                            photoSkipped = true
                        }
                    }

                    try { Toast.show(InventoryStore.addDoneMessage(status, photoSkipped)) } finally { dlg.close() }
                })
        } catch (e) {
            console.warn("[AddProductDialog] submit failed:", e)
            // Already answered: the callback has shown its own message. Not answered: the add may or may not have been
            // queued, so do not claim either.
            if (!settled) {
                busy = false
                Toast.show("Something went wrong. Check the product list before adding again")
            }
        }
    }
}
