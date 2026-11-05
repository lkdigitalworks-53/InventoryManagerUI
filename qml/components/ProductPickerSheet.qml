import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"
import "../model"
import "../helper/PickerDraft.js" as Draft
import "../helper/PickerSheetModel.js" as Model

// Searchable product sheet with a quantity stepper per row (picker v2, slice S2, design
// docs/superpowers/specs/2026-11-03-product-picker-v2-design.md). DORMANT in S2: nothing instantiates it until S3 (New
// Order) and S4 (Edit Order) wire it in.
//
// This file holds STATE and PAINTS; every decision is in the tested pure helpers (Skill 83): PickerSheetModel.build
// (rows, hidden count, draft reconcile, totals, commit gate), PickerDraft, ProductPickability, ProductSearch and
// PickerRowGeometry. The Felgo view layer cannot be loaded by qmltestrunner, so this file is pinned by
// functions/test/pickerSheetWiring.test.js and by the on-device plan.
//
// The sheet never touches an order. It hands the dialog a plan and the dialog applies it with its own add-line code:
//   committed({ adds: [{productId, qty}], bumps: [{productId, qty}] })   (add N more, never remove: design D4)
//
// What the dialog supplies (all plain values, so the sheet knows no store):
//   products    the catalog array (e.g. InventoryStore.products)
//   hooks       { hasPendingMint(id), hasQueuedRestock(id), unsyncedState(id), isDeleting(id), inOrderQty(id),
//                 availableFor(product) }  closures; see ProductPickability.js for the contract
//   orderLines  the order's current lines (for the line cap and for adds versus bumps)
//   revision    an int the dialog bumps when anything the hooks read may have changed, e.g. the sum of the store
//               revisions. The sheet re-reads on every change (Skill 78). See the S3 note on pending mints below.
BottomSheet {
    id: root

    property var products: []
    property var hooks: ({})
    property var orderLines: []
    property int revision: 0

    signal committed(var plan)

    sheetTitle: qsTr("Add products")
    primaryAction: qsTr("Add to order")
    secondaryAction: qsTr("Cancel")
    scrollBody: false      // the ListView below owns scrolling and the footer stays pinned (D5)
    guardClose: true       // X, Cancel, tap outside and Back ask first when a draft exists (D1)
    focus: true            // so the Back key reaches BottomSheet's Keys handler
    primaryEnabled: _view !== null && _view.canCommit.ok

    // ---- State ----
    property var _draft: ({})
    property string _query: ""
    property string _category: "All"
    property bool _inStockOnly: false
    property var _view: null
    property var _ids: []
    property var _chips: ["All"]

    // ---- Re-reads (Skill 78): every external change schedules ONE rebuild; the person's own taps rebuild at once ----
    onProductsChanged: _later()
    onHooksChanged: _later()
    onOrderLinesChanged: _later()
    onRevisionChanged: _later()
    function _later() { if (opened) Qt.callLater(rebuild, false) }

    onOpened: rebuild(true)
    // Reset on close so the next open starts clean and shows no stale frame.
    onClosed: {
        _draft = ({})
        _query = ""
        _category = "All"
        _inStockOnly = false
        searchField.text = ""
        chips.selected = 0
        stockToggle.checked = false
        listModel.clear()
        _ids = []
        _view = null
    }

    // resetScroll: true when the person changed the search, a chip or the toggle (the list starts at the top);
    // false for refreshes and stepper taps, where the scroll position is kept.
    function rebuild(resetScroll) {
        _chips = Model.categories(products)
        if (_chips.indexOf(_category) < 0) { _category = "All"; resetScroll = true }
        chips.selected = Math.max(0, _chips.indexOf(_category))
        var v = Model.build({
            products: products, hooks: hooks, orderLines: orderLines, draft: _draft,
            query: _query, category: _category, inStockOnly: _inStockOnly
        })
        if (v.draftChanged) _draft = v.draft
        _view = v
        _syncList(v.rows, resetScroll === true)
    }

    // Update the rows in place when the same products are listed in the same order, so a stepper tap or a refresh never
    // resets the scroll position (replacing a JS-array model would). ListModel.set only notifies for roles that changed.
    function _syncList(rows, resetScroll) {
        if (Model.sameOrder(_ids, rows)) {
            for (var i = 0; i < rows.length; ++i) listModel.set(i, rows[i])
            return
        }
        var y = list.contentY
        listModel.clear()
        var ids = []
        for (var r = 0; r < rows.length; ++r) { listModel.append(rows[r]); ids.push(rows[r].productId) }
        _ids = ids
        if (resetScroll) list.positionViewAtBeginning()
        else Qt.callLater(function() { list.contentY = Math.max(0, Math.min(y, list.contentHeight - list.height)) })
    }

    // ---- The person's actions ----
    function _step(productId, delta, maxQty) { _draft = Draft.step(_draft, productId, delta, maxQty); rebuild(false) }
    function _typed(productId, text, maxQty) { _draft = Draft.setQty(_draft, productId, text, maxQty); rebuild(false) }

    // Commit: re-read first, so the plan is made from the stock of THIS moment and a drift since the last tap is
    // clamped or refused (fail closed), then hand the plan over and close WITHOUT the discard question.
    onPrimaryClicked: {
        rebuild(false)
        if (!_view || !_view.canCommit.ok) return
        var plan = Draft.commitPlan(_draft, orderLines)
        root.committed(plan)
        root.close()
    }

    // X, Cancel, a tap outside and Back all land here (BottomSheet.guardClose).
    onCloseRequested: {
        var n = _view ? _view.totals.items : 0
        if (n <= 0) { root.close(); return }
        discardConfirm.ask({
            title: qsTr("Discard these items?"),
            message: n === 1 ? qsTr("The 1 item you picked will not be added.") : qsTr("The %1 items you picked will not be added.").arg(n),
            confirmLabel: qsTr("Discard"),
            cancelLabel: qsTr("Keep picking"),
            onConfirm: function() { root.close() }
        })
    }

    ConfirmDialog { id: discardConfirm }

    ListModel { id: listModel }

    ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: dp(Constants.space2)

        SearchField {
            id: searchField
            Layout.fillWidth: true
            placeholder: qsTr("Search name, ID, SKU or category")
            onTextChanged: { root._query = text; if (root.opened) root.rebuild(true) }
        }

        ChipScroller {
            id: chips
            Layout.fillWidth: true
            Layout.leftMargin: -dp(Constants.space4)
            Layout.rightMargin: -dp(Constants.space4)
            model: root._chips
            onChipSelected: function(index, label) { root._category = label; root.rebuild(true) }
        }

        // In-stock-only toggle. The whole row is the touch target (48 dp), not just the small switch.
        Rectangle {
            id: stockToggle
            property bool checked: false
            Layout.fillWidth: true
            Layout.preferredHeight: dp(48)
            color: "transparent"
            Accessible.role: Accessible.CheckBox
            Accessible.name: qsTr("In stock only")
            Accessible.checked: checked
            RowLayout {
                anchors.fill: parent
                spacing: dp(Constants.space2)
                Text {
                    Layout.fillWidth: true
                    text: qsTr("In stock only")
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBody)
                }
                Item {
                    Layout.preferredWidth: dp(48)
                    Layout.preferredHeight: dp(28)
                    QQC.Switch {
                        anchors.centerIn: parent
                        checked: stockToggle.checked
                        scale: 0.75      // the MouseArea below covers the row and takes every tap; this only paints the state
                    }
                }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: { stockToggle.checked = !stockToggle.checked; root._inStockOnly = stockToggle.checked; root.rebuild(true) }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
                id: list
                anchors.fill: parent
                model: listModel
                spacing: dp(Constants.space2)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                keyNavigationEnabled: false
                // A tap on a stepper must not be swallowed by the list's own flick on a slightly moving finger.
                flickableDirection: Flickable.VerticalFlick
                QQC.ScrollBar.vertical: QQC.ScrollBar {}

                delegate: ProductPickerRow {
                    onStepRequested: function(productId, delta, maxQty) { root._step(productId, delta, maxQty) }
                    onQtyTyped: function(productId, text, maxQty) { root._typed(productId, text, maxQty) }
                }
            }

            // Empty list: say why, with a way out (never a blank sheet).
            ColumnLayout {
                anchors.centerIn: parent
                width: parent.width - 2 * dp(Constants.space4)
                spacing: dp(Constants.space2)
                visible: root._view !== null && root._view.empty.kind !== ""
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: root._view ? root._view.empty.text : ""
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsBody)
                }
                GhostButton {
                    Layout.alignment: Qt.AlignHCenter
                    visible: root._view !== null && root._view.empty.kind === "no-match" && root._query.trim().length > 0
                    text: qsTr("Clear search")
                    onClicked: searchField.text = ""
                }
            }
        }

        // Quiet footer lines: what is hidden while it syncs (D7), why Add is off, then the running total.
        Text {
            Layout.fillWidth: true
            visible: text.length > 0
            text: root._view ? root._view.hiddenNote : ""
            color: Constants.textMuted
            font.pixelSize: sp(Constants.fsCaption)
            wrapMode: Text.Wrap
        }
        Text {
            Layout.fillWidth: true
            visible: text.length > 0
            text: root._view ? root._view.commitNote : ""
            color: Constants.danger
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            wrapMode: Text.Wrap
        }
        Text {
            Layout.fillWidth: true
            Layout.bottomMargin: dp(Constants.space1)
            text: root._view
                ? (root._view.totals.items === 1 ? qsTr("1 item") : qsTr("%1 items").arg(root._view.totals.items))
                  + "  ·  " + InventoryStore.formatCurrency(root._view.totals.amount)
                : ""
            color: Constants.textPrimary
            font.pixelSize: sp(Constants.fsBody)
            font.bold: true
        }
    }
}
