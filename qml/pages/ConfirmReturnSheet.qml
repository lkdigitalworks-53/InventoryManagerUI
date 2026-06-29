import QtQuick
import QtQuick.Layouts
import "../components"
import "../helper"
import "../helper/OrderAdjust.js" as OrderAdjust
import "../model"

// Confirm-on-save sheet for completed-order returns/exchanges. Declared at the
// App root (a BottomSheet nested inside another BottomSheet opens off-screen).
// Triggered via openFor() from Main.qml when OrderDetailDialog.adjustRequested
// fires. Emits confirmed(...) which Main routes to logic.adjustOrder.
BottomSheet {
    id: root
    sheetTitle: qsTr("Confirm changes")
    primaryAction: qsTr("Confirm & save")
    secondaryAction: qsTr("Cancel")

    signal confirmed(string orderId, var newLines, string reason, string condition, string note)

    property string orderId: ""
    property var newLines: []
    property var deltas: []
    property string reason: "return"
    property string condition: "restock"
    property string note: ""
    readonly property bool hasReturn: {
        for (var i = 0; i < deltas.length; ++i) if (deltas[i].returnedQty > 0) return true
        return false
    }
    // True when the user chose Exchange but added no replacement line in the edit.
    readonly property bool _exchangeNeedsReplacement: {
        if (reason !== "exchange") return false
        for (var i = 0; i < deltas.length; ++i) if (deltas[i].addedQty > 0) return false
        return true
    }
    // Aggregate stock + revenue impact across all deltas, for the preview line.
    readonly property var _impact: {
        var stockBack = 0, revenueDelta = 0
        for (var i = 0; i < deltas.length; ++i) {
            var d = deltas[i]
            if (d.returnedQty > 0) {
                if (condition !== "damaged") stockBack += d.returnedQty
                var unitTax = (d.taxable && d.taxPercent > 0) ? d.oldPrice * (d.taxPercent/100) : 0
                revenueDelta -= d.returnedQty * (d.oldPrice + unitTax)
            }
            if (d.addedQty > 0) revenueDelta += d.addedQty * d.newPrice
            if (d.returnedQty === 0 && d.addedQty === 0 && d.oldPrice !== d.newPrice)
                revenueDelta -= Math.min(d.oldQty, d.newQty) * (d.oldPrice - d.newPrice)
        }
        return { stockBack: stockBack, revenueDelta: revenueDelta }
    }

    function openFor(oid, newL, originalL) {
        orderId = oid
        newLines = newL
        deltas = OrderAdjust.diffLines(originalL || [], newL || [])
        // Auto-preselect the most likely reason from WHAT changed (bug 16):
        //   • units removed AND added  → exchange
        //   • units removed only       → return
        //   • only price/discount      → modify
        // The user can still override via the combo. All four reasons expose a
        // note field (bug 19) so any change can carry an explanation.
        var sawReturn = false, sawAdd = false, sawPriceOnly = false
        for (var i = 0; i < deltas.length; ++i) {
            var d = deltas[i]
            if (d.returnedQty > 0) sawReturn = true
            if (d.addedQty > 0) sawAdd = true
            if (d.returnedQty === 0 && d.addedQty === 0 && d.oldPrice !== d.newPrice) sawPriceOnly = true
        }
        var guess = (sawReturn && sawAdd) ? "exchange"
                  : sawReturn ? "return"
                  : sawPriceOnly ? "modify"
                  : "modify"   // discount-only / other line tweaks default to modify
        var idx = ["return","exchange","modify","other"].indexOf(guess)
        reason = guess; condition = "restock"; note = ""
        reasonCombo.currentIndex = idx >= 0 ? idx : 0
        // condition is set above; conditionPill.selected is bound to it.
        noteField.text = ""
        open()
    }

    onPrimaryClicked: {
        confirmed(orderId, newLines, reason, condition, note)
        close()
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        Repeater {
            model: root.deltas
            delegate: Text {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: Constants.textPrimary
                font.pixelSize: sp(Constants.fsBody)
                text: modelData.returnedQty > 0
                        ? qsTr("Returning %1 × %2").arg(modelData.returnedQty).arg(modelData.name)
                      : modelData.addedQty > 0
                        ? qsTr("Adding %1 × %2").arg(modelData.addedQty).arg(modelData.name)
                      : qsTr("Price change on %1 (₹%2 → ₹%3)").arg(modelData.name).arg(modelData.oldPrice).arg(modelData.newPrice)
            }
        }

        Text {
            text: qsTr("Reason")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall); font.bold: true
        }
        AppComboBox {
            id: reasonCombo
            Layout.fillWidth: true
            model: [qsTr("Return"), qsTr("Exchange"), qsTr("Modify"), qsTr("Other")]
            onCurrentIndexChanged: {
                root.reason = ["return","exchange","modify","other"][currentIndex]
            }
        }
        // Reason note for EVERY option (bug 19) — return/exchange/modify/other
        // all let the user record why; the note is carried into the ledger event
        // and shown in the order history.
        AuthTextField {
            id: noteField
            Layout.fillWidth: true
            label: qsTr("Reason note")
            placeholderText: root.reason === "return"   ? qsTr("e.g. customer changed mind, defective…")
                           : root.reason === "exchange" ? qsTr("e.g. swapped for a different size…")
                           : root.reason === "modify"   ? qsTr("e.g. price match, agreed discount…")
                           :                              qsTr("Add a note…")
            onTextChanged: root.note = text
        }

        Text {
            Layout.fillWidth: true
            visible: root._exchangeNeedsReplacement
            wrapMode: Text.Wrap
            color: Constants.warn
            font.pixelSize: sp(Constants.fsSmall)
            text: qsTr("No replacement item added. Close this, use the “+ add item” picker to add the exchanged-for product, then save again — or pick a different reason.")
        }

        Text {
            visible: root.hasReturn
            text: qsTr("Condition")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall); font.bold: true
        }
        SegmentedPill {
            id: conditionPill
            visible: root.hasReturn
            Layout.fillWidth: true
            model: [qsTr("Restock"), qsTr("Damaged")]
            selected: root.condition === "damaged" ? 1 : 0
            onSegmentSelected: function(idx, label) { root.condition = idx === 1 ? "damaged" : "restock" }
        }

        Text {
            Layout.fillWidth: true
            Layout.topMargin: dp(Constants.space2)
            wrapMode: Text.Wrap
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            text: {
                var imp = root._impact
                var parts = []
                if (imp.stockBack > 0) parts.push(qsTr("↩ +%1 to stock").arg(imp.stockBack))
                if (imp.revenueDelta !== 0)
                    parts.push((imp.revenueDelta < 0 ? "−₹" : "+₹")
                               + (Math.round(Math.abs(imp.revenueDelta) * 10) / 10))
                return parts.length > 0 ? parts.join("  ·  ") : qsTr("No stock or revenue impact")
            }
        }
    }
}
