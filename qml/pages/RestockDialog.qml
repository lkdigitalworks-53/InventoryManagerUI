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
    // Inline "Add new party" expansion state — declared on `dlg` (root) so
    // descendant references via `dlg._addPartyOpen` resolve correctly. Was
    // briefly declared on the inner ColumnLayout, which silently broke the
    // dialog by making `dlg._addPartyOpen` undefined and throwing in bindings.
    property bool _addPartyOpen: false

    signal restockConfirmed(string productId, int amount)

    // Cached supplier ids that mirror the picker rows. Index 0 is "" (no
    // supplier), then SupplierStore.suppliers in display order — the picker
    // model is built from `_supplierLabels`.
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
        // Restore selection by id rather than by index — the underlying list
        // is sorted alphabetically so positions shift on every add.
        var target = preferredId || ""
        var idx = Math.max(0, ids.indexOf(target))
        partyCombo.currentIndex = idx
    }

    function openFor(pid) {
        var p = InventoryStore.getById(pid)
        if (!p) return
        productId = p.productId
        productName = p.name
        currentStock = p.stock
        minStock = p.minStock
        qtyField.value = 10
        // Default the cost field to the product's recorded cost — the user
        // can override per-batch (price renegotiated, FX shift, etc.).
        unitCostField.text = (p.price !== undefined && p.price !== null) ? String(p.price) : "0"

        // Default the supplier picker to the most recent supplier we used.
        _refreshSuppliers(TransactionStore.lastSupplierFor(pid))

        addPartyField.text = ""
        dlg._addPartyOpen = false
        reasonField.text = ""
        dlg.open()
    }

    onPrimaryClicked: {
        var supplierId = partyCombo.currentIndex > 0
                ? dlg._supplierIds[partyCombo.currentIndex]
                : ""
        var unitCost = parseFloat(unitCostField.text)
        if (isNaN(unitCost) || unitCost < 0) unitCost = 0
        InventoryStore.restock(productId, qtyField.value, supplierId, unitCost, reasonField.text.trim())
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

        // Cost-per-unit at receipt time. Drives FIFO margin reports — every
        // sale that consumes from this batch will use this number as cost-of-
        // goods. Pre-filled with the product's recorded cost; user can adjust.
        Text {
            text: qsTr("Unit cost (₹)")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }
        AuthTextField {
            id: unitCostField
            Layout.fillWidth: true
            placeholderText: "0.00"
            inputMethodHints: Qt.ImhFormattedNumbersOnly
        }

        // Supplier picker — optional. The first row is the empty placeholder
        // so the user can intentionally leave it blank (legacy stock).
        Text {
            text: qsTr("Supplier")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AppComboBox {
                id: partyCombo
                Layout.fillWidth: true
                // Display labels live in `_supplierLabels`; selection maps
                // back to a supplierId via `_supplierIds[currentIndex]`.
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
                    color: addPartyToggle.pressed ? Constants.borderColor : Constants.subtleBg
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
        // Inline "Add new party" row — appears when the user taps + above.
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
                    // SupplierStore.addSupplier returns the existing record
                    // when the name already exists, so we always have an id.
                    var s = SupplierStore.addSupplier({ name: n })
                    dlg._refreshSuppliers(s ? s.supplierId : "")
                    addPartyField.text = ""
                    dlg._addPartyOpen = false
                }
            }
        }

        Text {
            text: qsTr("Reason (optional)")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }
        AuthTextField {
            id: reasonField
            Layout.fillWidth: true
            placeholderText: qsTr("e.g. delayed shipment, emergency restock")
        }
    }
}
