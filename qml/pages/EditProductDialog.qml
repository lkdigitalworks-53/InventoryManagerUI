import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Product detail / edit — bottom sheet. Public contract preserved:
//   signal productUpdateRequested(productId, fields, reason)
//   function openFor(id, startInEdit)
//   property string productId
//   property bool editMode
//   property string photoUrl
BottomSheet {
    id: root

    sheetTitle: editMode ? "Edit product" : "Product details"
    primaryAction: editMode ? "Save changes" : (AuthStore.canManageInventory ? "Edit" : "")
    secondaryAction: editMode ? "Cancel" : "Close"

    signal productUpdateRequested(string productId, var fields, string reason)
    // The photo-source sheet is hoisted to the App root (Main.qml) — a Popup
    // declared inside this BottomSheet's body opens off-screen. Main opens the
    // shared sheet on request and routes its result back via the functions below.
    signal photoPickRequested(bool hasExistingPhoto)

    property string productId: ""
    property bool editMode: false
    property string photoUrl: ""
    property bool photoBusy: false

    // Supplier banner state — `_currentSupplierId` resolves to the most
    // recent purchase/created event's supplier; the display name is looked
    // up via SupplierStore so a supplier rename reflects everywhere without
    // touching historical batch docs. The binding depends on TransactionStore
    // and SupplierStore revisions so both add-batch and rename refresh it.
    property string _currentSupplierId: {
        var tx = TransactionStore.revision
        return root.productId.length > 0
                ? TransactionStore.lastSupplierFor(root.productId) || ""
                : ""
    }
    property string _currentSupplierName: {
        var sup = SupplierStore.revision
        return root._currentSupplierId
                ? SupplierStore.nameOf(root._currentSupplierId) || qsTr("(removed supplier)")
                : ""
    }
    // Per-batch list (oldest first) for the View-mode batch table.
    property var _productBatches: {
        var bRev = StockBatchStore.revision
        return root.productId.length > 0
                ? StockBatchStore.forProduct(root.productId)
                : []
    }
    property bool _renaming: false

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
            taxableCombo.currentIndex = p.taxable ? 1 : 0
            taxPercentField.text = (p.taxPercent !== undefined && p.taxPercent !== null) ? String(p.taxPercent) : "0"
            sizeField.text = p.size || ""
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
        reasonField.text = ""
        // Supplier picker — refresh the model from SupplierStore and select
        // by id rather than by combobox string (the underlying list sorts
        // alphabetically, so positions shift on every add).
        root._refreshSupplierPicker(TransactionStore.lastSupplierFor(id) || "")
        root._renaming = false
        renameField.text = ""
        open()
    }

    // Mirror of SupplierStore (id ↔ label arrays kept in sync). Used by
    // editPartyCombo for the edit-mode picker.
    property var _supplierIds: [""]
    property var _supplierLabels: [qsTr("Select a supplier")]

    function _refreshSupplierPicker(preferredId) {
        var ids = [""]
        var labels = [qsTr("Select a supplier")]
        var src = SupplierStore.suppliers || []
        for (var i = 0; i < src.length; ++i) {
            ids.push(src[i].supplierId)
            labels.push(src[i].name)
        }
        _supplierIds = ids
        _supplierLabels = labels
        if (typeof editPartyCombo !== "undefined") {
            editPartyCombo.model = labels
            editPartyCombo.currentIndex = preferredId ? Math.max(0, ids.indexOf(preferredId)) : 0
        }
    }

    onPrimaryClicked: {
        if (!editMode) { editMode = true; reasonField.text = "" }
        else _submit()
    }
    onSecondaryClicked: {
        if (editMode) openFor(productId, false)
    }

    // Photo-source result handlers — invoked by Main.qml after the shared,
    // App-root PhotoSourceSheet resolves (see photoPickRequested above).
    function applyPhotoSource(url) {
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
    function clearPhotoSource() {
        StorageService.deleteProductPhoto(root.productId, function(ok, err) {
            if (ok) {
                root.photoUrl = ""
                InventoryStore.setPhoto(root.productId, "")
            }
        })
    }

    function getSellingPrice(sellingPriceText, costPriceText, isMarkupSelected) {
        var v = parseFloat(sellingPriceText)
        if (!isMarkupSelected) return v;

        var c = parseFloat(costPriceText)
        var sp = Math.round(((v * c) / 100) + c)
        return sp
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
                Icon {
                    anchors.centerIn: parent
                    name: "box"
                    size: sp(32)
                    color: Constants.textSecondary
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
                    onClicked: root.photoPickRequested(root.photoUrl.length > 0)
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
            id: sizeField
            Layout.fillWidth: true
            label: "Size"
            readOnly: !root.editMode
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
            id: priceRow
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            property bool isMarkupSelected: false

            AuthTextField {
                id: costField
                Layout.fillWidth: true
                label: "Cost (₹)"
                readOnly: !root.editMode
                inputMethodHints: Qt.ImhFormattedNumbersOnly
            }

            SegmentedPill {
                Layout.preferredWidth: dp(72)
                Layout.alignment: Qt.AlignBottom
                model: ["₹", "%"]
                selected: priceRow.isMarkupSelected ? 1 : 0
                enabled: root.editMode
                onSegmentSelected: function(idx, label) {
                    priceRow.isMarkupSelected = idx === 1 ? true : false
                }
            }

            AuthTextField {
                id: sellField
                Layout.fillWidth: true
                label: priceRow.isMarkupSelected ? "Markup (%)" : "Selling (₹)"
                readOnly: !root.editMode
                inputMethodHints: Qt.ImhFormattedNumbersOnly
            }
        }

        Rectangle {
            id: markupPill
            Layout.fillWidth: true
            Layout.preferredHeight: dp(36)
            radius: dp(12)
            color: Qt.rgba(0.06, 0.72, 0.51, 0.10)
            visible: !priceRow.isMarkupSelected // Show markup information if flat price is selected
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


        Rectangle {
            id: sellPricePill
            Layout.fillWidth: true
            Layout.preferredHeight: dp(36)
            radius: dp(12)
            color: Qt.rgba(0.06, 0.72, 0.51, 0.10)
            visible: priceRow.isMarkupSelected // Show price information if markup % is selected
            Text {
                anchors.centerIn: parent
                color: Constants.success
                font.pixelSize: sp(Constants.fsSmall)
                font.bold: true
                text: {
                    var c = parseFloat(costField.text)
                    var m = parseFloat(sellField.text)
                    if (isNaN(c) || isNaN(m) || c <= 0) return "Selling price —"
                    var sp = Math.round(((m * c) / 100) + c)
                    return "Selling price ₹" + sp + "   ·   profit ₹" + (sp - c).toFixed(2)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AuthTextField {
                id: stockField
                Layout.fillWidth: true
                label: qsTr("Stock")
                readOnly: !root.editMode
                inputMethodHints: Qt.ImhDigitsOnly
            }
            AuthTextField {
                id: minStockField
                Layout.fillWidth: true
                label: qsTr("Min stock")
                readOnly: !root.editMode
                inputMethodHints: Qt.ImhDigitsOnly
            }
        }

        Text {
            text: qsTr("Tax")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            ColumnLayout {
                Layout.fillWidth: true
                spacing: dp(4)
                Text { text: qsTr("Status"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
                AppComboBox {
                    id: taxableCombo
                    Layout.fillWidth: true
                    model: [qsTr("Not taxable"), qsTr("Taxable")]
                    enabled: root.editMode
                    font.pixelSize: sp(Constants.fsBody)
                }
            }
            AuthTextField {
                id: taxPercentField
                Layout.fillWidth: true
                label: qsTr("Tax %")
                readOnly: !root.editMode || taxableCombo.currentIndex === 0
                enabled: taxableCombo.currentIndex === 1
                inputMethodHints: Qt.ImhFormattedNumbersOnly
            }
        }

        // ── Supplier ───────────────────────────────────────────────────────
        // Read-only banner in view mode, picker + inline rename in edit mode.
        // The "supplier" is derived from the most recent purchase event for
        // this product (TransactionStore.lastPartyFor) — rather than living
        // on the product itself, which keeps every restock as the source of
        // truth. Editing here renames the party globally (i.e. across every
        // event that references it).
        Text {
            text: qsTr("Supplier")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        // View mode: banner + per-batch list. The banner shows the most
        // recent supplier (resolved via SupplierStore so a rename takes
        // effect everywhere), and the batch list breaks current stock down
        // by receipt event so the user can see which batch came from whom.
        ColumnLayout {
            Layout.fillWidth: true
            visible: !root.editMode
            spacing: dp(Constants.space2)

            Rectangle {
                Layout.fillWidth: true
                radius: dp(Constants.radius)
                color: Constants.subtleBg
                border.color: Constants.borderColor
                border.width: 1
                Layout.preferredHeight: dp(48)
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: dp(Constants.space3)
                    anchors.rightMargin: dp(Constants.space3)
                    spacing: dp(Constants.space2)
                    Icon {
                        name: "tag"
                        size: sp(16)
                        color: Constants.textSecondary
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root._currentSupplierName.length > 0
                                ? qsTr("Latest from %1").arg(root._currentSupplierName)
                                : qsTr("No supplier on record")
                        color: root._currentSupplierName.length > 0
                                ? Constants.textPrimary
                                : Constants.textMuted
                        font.pixelSize: sp(Constants.fsBody)
                        font.bold: root._currentSupplierName.length > 0
                        elide: Text.ElideRight
                    }
                    Text {
                        text: root._productBatches.length > 0
                                ? qsTr("%1 batches").arg(root._productBatches.length)
                                : ""
                        color: Constants.textMuted
                        font.pixelSize: sp(Constants.fsSmall)
                    }
                }
            }

            // Per-batch list. Compact rows: date · supplier · qty
            // remaining/received · unit cost. Hidden when there are no
            // batches yet (e.g. legacy product whose stock predates FIFO).
            Repeater {
                model: root._productBatches
                delegate: Rectangle {
                    id: batchRow
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(44)
                    radius: dp(Constants.radiusSm)
                    color: Constants.cardBg
                    border.color: Constants.borderColor
                    border.width: 1

                    readonly property string supplierLabel: {
                        var sRev = SupplierStore.revision
                        var sid = batchRow.modelData.supplierId
                        return sid
                                ? (SupplierStore.nameOf(sid) || qsTr("(removed supplier)"))
                                : qsTr("(no supplier)")
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: dp(Constants.space3)
                        anchors.rightMargin: dp(Constants.space3)
                        spacing: dp(Constants.space2)
                        Text {
                            // Date only (chop the timestamp tail).
                            text: (batchRow.modelData.receivedDate || "").substring(0, 10)
                            color: Constants.textSecondary
                            font.pixelSize: sp(Constants.fsCaption)
                            Layout.preferredWidth: dp(80)
                        }
                        Text {
                            Layout.fillWidth: true
                            text: batchRow.supplierLabel
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBody)
                            elide: Text.ElideRight
                        }
                        Text {
                            text: (batchRow.modelData.qtyRemaining || 0)
                                    + " / " + (batchRow.modelData.qtyReceived || 0)
                            color: (batchRow.modelData.qtyRemaining || 0) === 0
                                    ? Constants.textMuted
                                    : Constants.textPrimary
                            font.pixelSize: sp(Constants.fsCaption)
                        }
                        Text {
                            text: InventoryStore.formatCurrency(batchRow.modelData.unitCost || 0)
                            color: Constants.textSecondary
                            font.pixelSize: sp(Constants.fsCaption)
                            Layout.preferredWidth: dp(64)
                            horizontalAlignment: Text.AlignRight
                        }
                    }
                }
            }
        }

        // Edit mode: picker for the *next* restock's default supplier. We
        // intentionally don't rewrite historical batches when the picker
        // changes — that would corrupt FIFO lineage. Renaming a supplier
        // (which propagates to every batch via SupplierStore.updateSupplier)
        // is the correct way to fix a typo.
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.editMode
            spacing: dp(Constants.space2)

            RowLayout {
                Layout.fillWidth: true
                spacing: dp(Constants.space2)
                AppComboBox {
                    id: editPartyCombo
                    Layout.fillWidth: true
                    model: root._supplierLabels
                    font.pixelSize: sp(Constants.fsBody)
                    displayText: currentIndex > 0
                            ? currentText
                            : qsTr("Select a supplier")
                }
                QQC.AbstractButton {
                    id: renamePartyToggle
                    Layout.preferredWidth: dp(44)
                    Layout.preferredHeight: dp(44)
                    implicitWidth: dp(44)
                    implicitHeight: dp(44)
                    padding: 0
                    topPadding: 0; bottomPadding: 0; leftPadding: 0; rightPadding: 0
                    enabled: editPartyCombo.currentIndex > 0
                    background: Rectangle {
                        anchors.fill: parent
                        radius: dp(14)
                        color: renamePartyToggle.pressed ? Constants.borderColor : Constants.subtleBg
                        border.color: Constants.borderColor
                        border.width: 1
                        opacity: renamePartyToggle.enabled ? 1 : 0.5
                        Behavior on color { ColorAnimation { duration: Constants.durFast } }
                    }
                    contentItem: Icon {
                        name: root._renaming ? "close" : "edit"
                        color: Constants.textPrimary
                        size: sp(16)
                    }
                    onClicked: {
                        root._renaming = !root._renaming
                        if (root._renaming) {
                            renameField.text = editPartyCombo.currentText
                            renameField.forceActiveFocus()
                        }
                    }
                }
            }

            // Inline rename — updates the SupplierStore record in-place; all
            // batches/transactions that reference the supplierId follow
            // automatically because they only store the id, never the name.
            RowLayout {
                Layout.fillWidth: true
                spacing: dp(Constants.space2)
                visible: root._renaming

                AuthTextField {
                    id: renameField
                    Layout.fillWidth: true
                    placeholderText: qsTr("New supplier name")
                    onAccepted: renameSaveBtn.clicked()
                }
                PrimaryButton {
                    id: renameSaveBtn
                    text: qsTr("Save")
                    implicitHeight: dp(44)
                    implicitWidth: dp(80)
                    onClicked: {
                        var idx = editPartyCombo.currentIndex
                        if (idx <= 0) { root._renaming = false; return }
                        var sid = root._supplierIds[idx]
                        var newName = (renameField.text || "").trim()
                        if (!sid || !newName) { root._renaming = false; return }
                        var renamed = SupplierStore.updateSupplier(sid, { name: newName })
                        if (!renamed) {
                            errorLabel.text = "A supplier named \"" + newName + "\" already exists"
                            return
                        }
                        // Refresh model + restore selection by id (the new
                        // name reshuffles the alphabetical sort order).
                        root._refreshSupplierPicker(sid)
                        root._renaming = false
                        renameField.text = ""
                    }
                }
            }
        }

        // Reason is transaction metadata, not a persistent product field —
        // unlike every other field above, there's nothing to show back in
        // view mode, so this is visible-only (not readOnly-toggled) and
        // reset to blank at the start of every edit session (see openFor()
        // and onPrimaryClicked above).
        AuthTextField {
            id: reasonField
            Layout.fillWidth: true
            visible: root.editMode
            label: qsTr("Reason for this change (optional)")
            placeholderText: qsTr("e.g. damaged stock, recount, price correction")
        }

        Text {
            id: errorLabel
            Layout.fillWidth: true
            visible: text.length > 0
            color: Constants.danger
            font.pixelSize: sp(Constants.fsSmall)
            wrapMode: Text.Wrap
        }

        // ── History ────────────────────────────────────────────────────────
        // Per-product transaction trail: restocks, sales, edits. Keep this
        // header at the same emphasis as the dialog's other sections
        // ("Product info", "Pricing & stock") so it doesn't blend into the
        // empty-state caption when the product has no transactions yet.
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: dp(Constants.space4)
            visible: !root.editMode
            spacing: dp(Constants.space2)

            Icon {
                name: "history"
                size: sp(16)
                color: Constants.textSecondary
            }
            Text {
                text: qsTr("History")
                color: Constants.textPrimary
                font.pixelSize: sp(Constants.fsBodyLg)
                font.bold: true
                Layout.fillWidth: true
            }
            Text {
                text: historySection._history.length > 0
                        ? qsTr("%1 events").arg(historySection._history.length)
                        : ""
                color: Constants.textMuted
                font.pixelSize: sp(Constants.fsCaption)
            }
        }

        ColumnLayout {
            id: historySection
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            visible: !root.editMode

            // Binding (NOT imperative assignment): re-evaluates when either
            // the active product changes or a new transaction is appended.
            // The previous on_TxWatcherChanged handler stomped this binding
            // and left the list stuck on whichever product was active when
            // the first revision++ fired — causing other products' rows to
            // leak into every subsequent dialog open.
            property var _history: {
                var w = TransactionStore.revision   // dependency for refresh
                return root.productId.length > 0
                    ? TransactionStore.forProduct(root.productId)
                    : []
            }

            Repeater {
                model: historySection._history
                delegate: Rectangle {
                    id: histRow
                    Layout.fillWidth: true
                    radius: dp(Constants.radius)
                    color: Constants.cardBg
                    border.color: Constants.borderColor
                    border.width: 1
                    Layout.preferredHeight: histCol.implicitHeight + dp(Constants.space3 * 2)

                    // Effective kind — collapses two legacy patterns into the
                    // new vocabulary so old Firestore docs still render right.
                    readonly property string _kind: {
                        if (modelData.kind === "purchase"
                            && modelData.note === "Initial stock") return "created"
                        if (modelData.kind === "update") return "legacy_update"
                        return modelData.kind || "field_change"
                    }

                    readonly property string _icon: {
                        switch (_kind) {
                        case "created":          return "created"
                        case "purchase":         return "purchase"
                        case "sale":             return "sale"
                        case "stock_adjustment": return "stock_adjustment"
                        case "field_change":     return "field_change"
                        case "photo_change":     return "photo_change"
                        case "legacy_update":    return "field_change"
                        case "return":          return "sale"
                        case "price_adjust":    return "field_change"
                        default:                  return "field_change"
                        }
                    }

                    readonly property string _title: historySection._titleFor(modelData, _kind)
                    readonly property string _detail: historySection._detailFor(modelData, _kind)

                    ColumnLayout {
                        id: histCol
                        anchors.fill: parent
                        anchors.margins: dp(Constants.space3)
                        spacing: dp(2)

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: dp(Constants.space2)
                            Icon {
                                // Reach the delegate Rectangle directly via id —
                                // `parent.parent` lands on histCol (one level
                                // short) and silently resolves to undefined,
                                // which is why the icon + title row was blank.
                                name: histRow._icon
                                size: sp(16)
                                color: Constants.textSecondary
                            }
                            Text {
                                Layout.fillWidth: true
                                text: histRow._title
                                color: Constants.textPrimary
                                font.pixelSize: sp(Constants.fsBody)
                                font.bold: true
                                elide: Text.ElideRight
                                wrapMode: Text.Wrap
                            }
                            Text {
                                text: ActivityLog.timeAgo(modelData.timestamp)
                                color: Constants.textMuted
                                font.pixelSize: sp(Constants.fsCaption)
                            }
                        }
                        Text {
                            visible: histRow._detail.length > 0
                            text: histRow._detail
                            color: Constants.textSecondary
                            font.pixelSize: sp(Constants.fsCaption)
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }

            Text {
                visible: historySection._history.length === 0
                text: qsTr("No history yet for this product.")
                color: Constants.textMuted
                font.pixelSize: sp(Constants.fsSmall)
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
            }

            // ── Per-kind formatters ────────────────────────────────────────
            // Field-name → user-facing label + value formatter. Kept at the
            // section level so both title and detail can reuse it without
            // duplicating the switch.
            function _fieldLabel(field) {
                switch (field) {
                case "name":         return qsTr("Name")
                case "sku":          return qsTr("SKU")
                case "category":     return qsTr("Category")
                case "description":  return qsTr("Description")
                case "unit":         return qsTr("Unit")
                case "price":        return qsTr("Cost")
                case "sellingPrice": return qsTr("Selling")
                case "taxable":      return qsTr("Taxable")
                case "taxPercent":   return qsTr("Tax %")
                case "size":         return qsTr("Size")
                case "minStock":     return qsTr("Min stock")
                default:              return field || qsTr("Field")
                }
            }

            function _fieldFormat(field, v) {
                if (field === "price" || field === "sellingPrice")
                    return InventoryStore.formatCurrency(v || 0)
                if (field === "taxable") return v ? qsTr("On") : qsTr("Off")
                if (field === "taxPercent") return (v || 0) + "%"
                if (typeof v === "string" && v.length === 0) return qsTr("(empty)")
                return String(v === undefined || v === null ? "" : v)
            }

            // Best-effort party label for created/purchase rows. Stored on
            // the document; legacy purchase docs may keep it inside the
            // (now-deprecated) snapshot field.
            function _partyOf(d) {
                if (d.party) return d.party
                if (d.snapshot && d.snapshot.party) return d.snapshot.party
                return ""
            }

            function _titleFor(d, k) {
                switch (k) {
                case "created":
                    var pCreated = _partyOf(d)
                    var headCreated = d.quantity > 0
                        ? qsTr("Created with %1 in stock").arg(d.quantity)
                        : qsTr("Created")
                    return pCreated ? headCreated + qsTr(" · from %1").arg(pCreated) : headCreated
                case "purchase":
                    var pPurchase = _partyOf(d)
                    var headPurchase = qsTr("Restocked +%1").arg(d.quantity || 0)
                    return pPurchase ? headPurchase + qsTr(" · from %1").arg(pPurchase) : headPurchase
                case "sale":
                    return d.orderId
                        ? qsTr("Sold %1 · #%2").arg(d.quantity || 0).arg(d.orderId)
                        : qsTr("Sold %1").arg(d.quantity || 0)
                case "stock_adjustment":
                    var delta = (d.delta !== undefined) ? d.delta : ((d.after || 0) - (d.before || 0))
                    var sign = delta > 0 ? "+" : ""
                    return qsTr("Stock adjusted: %1 → %2 (Δ %3%4)")
                            .arg(d.before).arg(d.after).arg(sign).arg(delta)
                case "field_change":
                    return _fieldLabel(d.field) + ": "
                            + _fieldFormat(d.field, d.before) + " → "
                            + _fieldFormat(d.field, d.after)
                case "photo_change":
                    var hadBefore = d.before && d.before.length > 0
                    var hasAfter = d.after && d.after.length > 0
                    if (hadBefore && hasAfter) return qsTr("Photo replaced")
                    if (!hadBefore && hasAfter) return qsTr("Photo added")
                    if (hadBefore && !hasAfter) return qsTr("Photo removed")
                    return qsTr("Photo updated")
                case "legacy_update":
                    return qsTr("Updated")
                case "return":
                    var retQty = Math.abs(d.quantity || 0)
                    var retVerb = d.reason === "exchange" ? qsTr("Exchanged")
                                : d.reason === "modify" ? qsTr("Modified")
                                : d.reason === "other" ? qsTr("Adjusted")
                                : qsTr("Returned")
                    var retHead = d.orderId
                            ? retVerb + qsTr(" %1 · #%2").arg(retQty).arg(d.orderId)
                            : retVerb + qsTr(" %1").arg(retQty)
                    if (d.condition === "damaged") retHead += qsTr(" · damaged")
                    return retHead
                case "price_adjust":
                    return d.orderId
                            ? qsTr("Price adjusted · #%1").arg(d.orderId)
                            : qsTr("Price adjusted")
                }
                return qsTr("Activity")
            }

            function _detailFor(d, k) {
                switch (k) {
                case "created":
                    var snap = d.snapshot || {}
                    var bits = []
                    if (snap.sku) bits.push(qsTr("SKU ") + snap.sku)
                    if (snap.category) bits.push(snap.category)
                    if (snap.sellingPrice !== undefined)
                        bits.push(qsTr("Selling ") + InventoryStore.formatCurrency(snap.sellingPrice))
                    if (d.unitCost > 0)
                        bits.push(qsTr("Cost ") + InventoryStore.formatCurrency(d.unitCost) + qsTr(" each"))
                    return bits.join(" · ")
                case "purchase":
                    var purDetail = (d.unitCost > 0)
                            ? qsTr("@ %1 each · total %2")
                                    .arg(InventoryStore.formatCurrency(d.unitCost))
                                    .arg(InventoryStore.formatCurrency(d.total || 0))
                            : ""
                    if (d.reason && d.reason.length > 0)
                        purDetail += (purDetail ? " · " : "") + d.reason
                    return purDetail
                case "sale":
                    if (d.unitPrice > 0)
                        return qsTr("%1 × %2 = %3")
                                .arg(d.quantity || 0)
                                .arg(InventoryStore.formatCurrency(d.unitPrice))
                                .arg(InventoryStore.formatCurrency(d.total || 0))
                    return ""
                case "legacy_update":
                    return d.note || ""
                case "field_change":
                    return d.reason || ""
                case "stock_adjustment":
                    return d.reason || ""
                case "return":
                    var rDetail = qsTr("%1 refunded").arg(InventoryStore.formatCurrency(Math.abs(d.total || 0)))
                    if (d.note && d.note.length > 0) rDetail += " · " + d.note
                    return rDetail
                case "price_adjust":
                    var paDetail = (d.total < 0 ? qsTr("Revenue −%1") : qsTr("Revenue +%1"))
                            .arg(InventoryStore.formatCurrency(Math.abs(d.total || 0)))
                    if (d.note && d.note.length > 0) paDetail += " · " + d.note
                    return paDetail
                }
                return ""
            }
        }
    }

    function _submit() {
        var errs = []
        if (!nameField.text || nameField.text.trim().length < 2) errs.push("Enter a valid name")
        if (!skuField.text || skuField.text.trim().length === 0) errs.push("Enter SKU")
        var cost = parseFloat(costField.text)
        if (isNaN(cost) || cost < 0) errs.push("Enter valid cost price")
        var sell = getSellingPrice(sellField.text, costField.text, priceRow.isMarkupSelected)
        if (isNaN(sell) || sell <= 0) errs.push("Enter valid selling price")
        if (!isNaN(cost) && !isNaN(sell) && sell < cost) errs.push("Selling price must be ≥ cost")
        var stk = parseInt(stockField.text)
        if (isNaN(stk) || stk < 0) errs.push("Enter valid stock")
        var ms = parseInt(minStockField.text)
        if (isNaN(ms) || ms < 0) ms = 0
        var taxable = taxableCombo.currentIndex === 1
        var taxPercent = 0
        if (taxable) {
            taxPercent = parseFloat(taxPercentField.text)
            if (isNaN(taxPercent) || taxPercent < 0 || taxPercent > 100)
                errs.push("Enter a valid tax % (0–100)")
        }
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
            taxable: taxable,
            taxPercent: taxable ? taxPercent : 0,
            size: sizeField.text.trim(),
            stock: stk,
            minStock: ms
        }, reasonField.text.trim())
        errorLabel.text = ""
        editMode = false
        close()
    }
}
