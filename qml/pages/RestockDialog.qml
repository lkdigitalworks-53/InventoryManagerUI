import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../helper/RestockFlow.js" as RestockFlow
import "../model"

// Restock bottom sheet. Public contract preserved: openFor(productId).
BottomSheet {
    id: dlg

    sheetTitle: "Restock"
    holdsRefresh: true   // edit form: the background list refresh waits while it is open
    primaryAction: "Confirm"
    secondaryAction: "Cancel"
    primaryPalette: ({ start: Constants.brand4, end: Constants.brand5 })
    // The full-sheet busy overlay: BottomSheet shows it while busy AND this is non-empty. A restock waits for the
    // server, so the small spinner on the Confirm button alone is not enough. A constant, not set at the tap, so it
    // cannot be left stale or empty by a path that returns early.
    busyMessage: qsTr("Restocking — this can take a few seconds")

    property string productId: ""
    property string productName: ""
    property int currentStock: 0
    property int minStock: 0
    // Inline "Add new party" expansion state — declared on `dlg` (root) so
    // descendant references via `dlg._addPartyOpen` resolve correctly. Was
    // briefly declared on the inner ColumnLayout, which silently broke the
    // dialog by making `dlg._addPartyOpen` undefined and throwing in bindings.
    property bool _addPartyOpen: false
    // A typed NEW supplier name (R5a). Nothing is created when the person taps "Use": the name travels inside the
    // restock operation and the server creates the supplier in the same transaction as the batch, so a restock that
    // fails leaves no orphan supplier and burns no number. "" = none. Picking a row in the combo clears it.
    property string _newSupplierName: ""

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
        // PR #191 sweep: the SpinBox shows typed text until Enter or focus loss; assigning the SAME value (10) does not
        // refresh it, so text typed and abandoned last time stayed in the field and Confirm (which reads the text)
        // booked it. Moving the value first forces the text to be rewritten.
        qtyField.value = qtyField.from
        qtyField.value = 10
        // Default the cost field to the product's recorded cost — the user
        // can override per-batch (price renegotiated, FX shift, etc.).
        unitCostField.text = (p.price !== undefined && p.price !== null) ? String(p.price) : "0"

        // Default the supplier picker to the most recent supplier we used.
        _refreshSuppliers(TransactionStore.lastSupplierFor(pid))

        addPartyField.text = ""
        dlg._addPartyOpen = false
        dlg._newSupplierName = ""
        reasonField.text = ""
        dlg.open()
    }

    onPrimaryClicked: dlg._confirm()

    // The Confirm tap. A named function, not an inline handler, so functions/test/restockDialogConfirm.test.js
    // runs this exact body against fake stores. Three rules, all from the PR #183 device test (a missing import
    // made this handler throw before anything showed, so Confirm looked dead):
    //  - everything the tap needs is read once, up front: the answer can arrive later on a slow link,
    //    when the fields may have changed;
    //  - an exception is shown to the person and logged, never swallowed;
    //  - if it was thrown after busy was set and before the answer, busy is cleared so the sheet cannot stick.
    function _confirm() {
        if (busy) return
        // Defense in depth: the Restock button itself is already hidden
        // from non-owner/admin users (InventoryPage's canManage, bound to
        // AuthStore.canManageInventory — same role set as onRestockProduct's
        // gate), so this isn't reachable via the normal UI today. But this
        // dialog calls InventoryStore.restock directly, bypassing the
        // logic.restockProduct signal (and its RBAC check) entirely — if
        // this dialog is ever opened from anywhere else, or the button's
        // visibility binding is ever forgotten in a future refactor,
        // nothing else stands in the way. Mirrors onRestockProduct's exact
        // check rather than relying solely on the button being hidden.
        if (!AuthStore.canManageInventory) {
            Toast.show("Only owner/admin can restock products")
            return
        }
        var settled = false
        try {
            var pid = productId
            // PR #191 sweep: a name typed in the new-supplier row but never sent with "Use" is refused, not dropped.
            var unused = RestockFlow.unusedPartyText(addPartyField.text)
            if (unused !== "") { Toast.show(unused); return }
            // Review D-C: the typed text, not the last committed value (see RestockFlow.qtyFromField).
            var typed = RestockFlow.qtyFromField(qtyField)
            if (!typed.ok) { Toast.show(typed.message); return }
            var qty = typed.qty
            if (qtyField.value !== qty) qtyField.value = qty
            // A typed new supplier name (created inside the operation) or the picked id, decided in the helper.
            var party = RestockFlow.partyFor(dlg._newSupplierName, partyCombo.currentIndex, dlg._supplierIds)
            // Blank = the product's recorded cost; a typo or a negative is refused by the plan, not booked as 0 (review D-2).
            var unitCost = RestockFlow.costFromText(unitCostField.text)
            busy = true
            InventoryStore.restock(pid, qty, party, unitCost, reasonField.text.trim(), function(ok, queued, refusal) {
                settled = true
                busy = false
                if (!ok) { Toast.show(refusal || "Could not restock — try again"); return }
                restockConfirmed(pid, qty)
                // Queued = saved, but stock changes only once the server confirms (offline or slow link).
                Toast.show(queued
                    ? "Restock saved. Stock updates when it syncs"
                    : "Restocked +" + qty + " units")
                dlg.close()
            })
        } catch (e) {
            console.warn("[RestockDialog] confirm failed:", e)
            // Already answered: the callback has shown its own message, nothing more to say.
            // Not answered: the restock may or may not have been queued, so do not claim either.
            if (!settled) {
                busy = false
                Toast.show("Something went wrong. Check the stock before trying again")
            }
        }
    }

    // The "Use" button of the inline new-supplier row. Creates NOTHING (see _newSupplierName). A name that matches a
    // known supplier (case-insensitive) selects that row instead, so retyping "acme" never makes a second supplier.
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

        // PR #191 sweep: shows what Confirm will book (the typed text), not the last committed `value`, and says so when
        // the text cannot be booked.
        Text {
            readonly property var _typed: RestockFlow.qtyFromField(qtyField)
            text: _typed.ok ? "After this, stock will be " + (dlg.currentStock + _typed.qty) + " units." : _typed.message
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
                displayText: dlg._newSupplierName.length > 0
                        ? qsTr("New: ") + dlg._newSupplierName
                        : (currentIndex > 0 ? currentText : qsTr("Select or add a supplier"))
                // A user pick replaces a typed new name (one supplier per restock). Programmatic currentIndex
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
                maxLength: RestockFlow.MAX_SUPPLIER_NAME
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
        // Says what "Use" did: the supplier does not exist yet, it is created with the restock.
        Text {
            Layout.fillWidth: true
            visible: dlg._newSupplierName.length > 0
            text: qsTr("“%1” will be added as a new supplier when you confirm this restock.").arg(dlg._newSupplierName)
            wrapMode: Text.WordWrap
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
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
            maxLength: RestockFlow.MAX_REASON
        }
    }
}
