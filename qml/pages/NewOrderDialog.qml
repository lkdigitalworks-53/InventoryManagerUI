import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"
import "../helper/NewOrderPicker.js" as Picker
import "../helper/OrderFlow.js" as OrderFlow

// Mobile-first New Order sheet — bottom sheet with customer fields and a
// product picker. Public contract preserved: signal `orderCreated(order)`.
BottomSheet {
    id: dlg

    sheetTitle: "New order"
    holdsRefresh: true   // edit form: the background list refresh waits while it is open
    primaryAction: "Place order"
    secondaryAction: "Cancel"
    // The full-sheet busy overlay: BottomSheet shows it while busy AND this is non-empty (see RestockDialog).
    // A constant, not set at the tap, so no early return can leave it stale or empty.
    busyMessage: qsTr("Placing order — this can take a few seconds")

    signal orderCreated(var order)
    signal manageChannelsRequested()

    // In-flight guard — see ASYNC-REENTRANCY-BUGS.md C-2. `orderCreated` is a fire-and-forget signal into Main.qml ->
    // logic.addOrder -> DataModel -> OrdersStore.addOrder, which sends ONE atomic order operation and waits for the server (NO3a).
    // Without this, a double-tap on "Place order" would send two operations and make two orders — and if autoApproveEnabled is
    // on, double-deduct stock via the completion too. There is no DataModel-layer guard for creation the way
    // _completingOrderIds guards completion, so the UI entry point below is the ONLY thing standing between this and a
    // duplicate order — same category the doc calls out.

    property var selectedProducts: []

    // productId -> why the last price typed for that line was refused (NO3b). Kept here, not in the row: every cart change
    // rebuilds the rows, so a message held by a row vanished unread (a quantity tap), and trySubmit must see it. A line that
    // leaves the cart (or a new sheet) forgets its message.
    property var _priceErrors: ({})
    property var _discountErrors: ({})   // the same for the discount field (NO3c)
    onSelectedProductsChanged: {
        _priceErrors = OrderFlow.prunePriceErrors(_priceErrors, selectedProducts)
        _discountErrors = OrderFlow.prunePriceErrors(_discountErrors, selectedProducts)
    }

    // Mirror of StaffStore filtered to active members. Index 0 is the
    // empty "(no staff)" row so the user can leave it unattributed.
    property var _staffIds: [""]
    property var _staffLabels: [qsTr("Sold by (none)")]
    function _refreshStaff(preferredId) {
        var ids = [""]
        var labels = [qsTr("Sold by (none)")]
        var src = StaffStore.staff || []
        for (var i = 0; i < src.length; ++i) {
            var s = src[i]
            if (s.status && s.status !== "active") continue
            ids.push(s.staffId || s.id || "")
            labels.push(s.name || qsTr("(unnamed)"))
        }
        _staffIds = ids
        _staffLabels = labels
        if (typeof staffCombo !== "undefined") {
            staffCombo.model = labels
            staffCombo.currentIndex = preferredId ? Math.max(0, ids.indexOf(preferredId)) : 0
        }
    }

    // Cached totals — recomputes only when inputs change, not on every binding read.
    readonly property var _totalsCache: _totals(selectedProducts)

    // ---- Product picker (picker v2, slice S3) ----
    // The sheet knows no store: everything it reads comes in through these three. What may be added, how much and at
    // what price is decided in NewOrderPicker.js and the sheet's helpers (tested, Skill 83); this file only wires them.
    // The stores own the guards that HIDE a product (design D2): a batch-id mint outstanding, a restock queued, a queued
    // or parked edit. No isDeleting hook: a deleted product leaves the catalog at once (ProductPickability.js header).
    readonly property var _pickerLookup: ({
        productOf: function(id) { return InventoryStore.getById(id) },
        batchesOf: function(id) { return StockBatchStore.forProduct(id) }
    })
    // Scope of ONE sheet build (S5d, plan S5d-D1): beginBuild snapshots the cart and indexes it once, endBuild drops both,
    // and the two hooks below read the index in between instead of walking the cart for every product (N x L). Outside a
    // build, or when beginBuild threw before the index was made, they scan the live cart as before. The index is set LAST
    // and cleared FIRST: it is the gate. Plain properties, not an object mutated in place.
    property var _buildLines: null
    property var _buildIndex: null
    readonly property var _pickerHooks: ({
        hasPendingMint: function(id) { return StockBatchStore.hasPendingMint(id) },
        hasQueuedRestock: function(id) { return InventoryStore.hasQueuedRestock(id) },
        unsyncedState: function(id) { return InventoryStore.syncStateOf(id) },
        hasPrice: function(p) { return Picker.priceOf(p) !== null },
        beginBuild: function() { dlg._buildLines = dlg.selectedProducts; dlg._buildIndex = Picker.qtyIndex(dlg._buildLines, "qty") },
        endBuild: function() { dlg._buildIndex = null; dlg._buildLines = null },
        inOrderQty: function(id) { return dlg._buildIndex ? Picker.cartQty(dlg._buildLines, id, dlg._buildIndex) : Picker.cartQty(dlg.selectedProducts, id) },
        availableFor: function(p) { return dlg._buildIndex ? Picker.availableFor(p, dlg._buildLines, dlg._buildIndex) : Picker.availableFor(p, dlg.selectedProducts) },
        commitCheck: function(plan) { return Picker.opsCheck(dlg.selectedProducts, plan, dlg._pickerLookup) }
    })
    // Every counter the hooks read. Each only grows, so the sum changes whenever any of them does and the open sheet
    // re-reads (Skill 78): stock and catalog, batches, pending mints (own counter, S3) and the outbox (queued restock,
    // queued or parked edit).
    readonly property int _pickerRevision: InventoryStore.revision + StockBatchStore.revision
                                           + StockBatchStore.mintRevision + OutboxStore.revision

    // The plan from the sheet: add N more, never remove (design D4). applyPlan re-reads each product at this moment and
    // clamps or refuses, so the order never holds more than the stock. What it did not add is a toast (Taher, 2026-11-11):
    // the red label sits at the bottom of the scrolling body and may be off screen. The label is cleared, since the
    // person has just added products and an older "Add at least one product" no longer applies.
    function _applyPicked(plan) {
        _settleFieldEdit()   // the new cart rebuilds every row: a price or discount still being typed would die with its row
        const res = Picker.applyPlan(selectedProducts, plan, _pickerLookup)
        selectedProducts = res.lines
        errorLabel.text = ""
        const note = Picker.skippedNote(res.skipped)
        if (note.length > 0) Toast.show(note)
    }

    onOpened: {
        // Defensive reset, matching OrderDetailDialog.openFor()'s idiom — a
        // fresh open should never inherit a stuck busy state from whatever
        // happened (or didn't finish happening) the last time this sheet
        // was used.
        busy = false
        customerField.text = ""
        emailField.text = ""
        phoneField.text = ""
        selectedProducts = []
        // Channel + staff: pre-select user defaults so the common case takes
        // zero taps. Channel uses OrderChannelStore's lastUsed; staff is
        // best-effort matched against the signed-in user's name (if a staff
        // record exists with that name).
        // Don't reassign channelCombo.model here — that would break its
        // declarative `model: OrderChannelStore.channels` binding and freeze
        // the dropdown to a snapshot (so newly-added channels wouldn't appear
        // until the dialog was reopened). Just position on the default.
        channelCombo.currentIndex = OrderChannelStore.indexOfDefault()
        // Staff accounts attribute the sale to themselves automatically and
        // cannot reassign it (the combo is disabled below). Everyone else
        // gets a best-effort match against the signed-in user's own staff
        // record, falling back to a fragile name match for legacy/unlinked
        // accounts.
        var preferredStaffId = AuthStore.currentStaffId
        if (!preferredStaffId && AuthStore.displayName) {
            var roster = StaffStore.staff || []
            for (var si = 0; si < roster.length; ++si) {
                if ((roster[si].name || "").toLowerCase() === AuthStore.displayName.toLowerCase()) {
                    preferredStaffId = roster[si].staffId || ""
                    break
                }
            }
        }
        _refreshStaff(preferredStaffId)
        errorLabel.text = ""
    }

    onClosed: {
        picker.close()   // never leave the picker open over a closed order sheet
        selectedProducts = []
        customerField.text = ""
        emailField.text = ""
        phoneField.text = ""
    }

    onPrimaryClicked: trySubmit()

    // Sheet body — title row + form
    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        AuthTextField {
            id: customerField
            Layout.fillWidth: true
            label: "Customer"
            placeholderText: "Search or add customer"
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AuthTextField {
                id: emailField
                Layout.fillWidth: true
                label: "Email (optional)"
                placeholderText: "customer@example.com"
                inputMethodHints: Qt.ImhEmailCharactersOnly
            }
            AuthTextField {
                id: phoneField
                Layout.fillWidth: true
                label: "Phone (optional)"
                placeholderText: "+91 XXXXX"
            }
        }

        // Order channel + staff (sold-by). Side-by-side row, equal width.
        Text {
            text: qsTr("Channel & sold by")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AppComboBox {
                id: channelCombo
                Layout.fillWidth: true
                model: OrderChannelStore.channels
                font.pixelSize: sp(Constants.fsBody)
            }
            AppComboBox {
                id: staffCombo
                Layout.fillWidth: true
                model: dlg._staffLabels
                font.pixelSize: sp(Constants.fsBody)
                // Staff accounts sell as themselves — the field is pre-set to
                // their own record and locked so they can't attribute a sale
                // to someone else. Owner/admin/manager keep it editable.
                enabled: !AuthStore.isStaffRole
                displayText: currentIndex > 0
                        ? currentText
                        : qsTr("Sold by (none)")
            }
        }
        // Compact "Manage channels" link, mirrors how AddProductDialog
        // exposes the categories editor.
        QQC.AbstractButton {
            id: manageChannelsLink
            Layout.alignment: Qt.AlignRight
            // The button's own `text` is its spoken name (no chevron); the picture adds the chevron.
            text: qsTr("Manage channels")
            implicitHeight: dp(48)
            leftPadding: dp(8); rightPadding: dp(8)
            topPadding: 0; bottomPadding: 0
            background: Rectangle { color: "transparent" }
            contentItem: Text {
                text: manageChannelsLink.text + "  ›"
                color: Constants.brand2
                font.pixelSize: sp(Constants.fsCaption)
                font.bold: true
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
            }
            onClicked: dlg.manageChannelsRequested()
        }

        // Product picker
        Text {
            text: "Items"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        GhostButton {
            Layout.fillWidth: true
            text: dlg.selectedProducts.length > 0 ? qsTr("Add more products") : qsTr("Add products")
            enabled: !dlg.busy
            onClicked: picker.open()
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            Repeater {
                id: cartRepeater
                model: dlg.selectedProducts
                delegate: Rectangle {
                    id: cartRow
                    readonly property string priceError: dlg._priceErrors[modelData.productId] || ""   // "" = none
                    readonly property string discountError: dlg._discountErrors[modelData.productId] || ""
                    // Commits the field of this row the person is still in. -> true when there was one.
                    function settleField() {
                        if (linePriceField.activeFocus) { linePriceField._commitPrice(); return true }
                        if (lineDiscField.activeFocus) { lineDiscField._commitDiscount(); return true }
                        return false
                    }
                    Layout.fillWidth: true
                    Layout.preferredHeight: cartCol.implicitHeight + dp(Constants.space3 * 2)
                    radius: dp(Constants.radius)
                    color: Constants.cardBg
                    border.color: Constants.borderColor
                    border.width: 1

                    ColumnLayout {
                        id: cartCol
                        anchors.fill: parent
                        anchors.margins: dp(Constants.space3)
                        spacing: dp(Constants.space2)

                        // ── Top row: avatar + name/price ────────────────────
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: dp(Constants.space2)

                            AvatarBadge {
                                label: (modelData.name || "?").charAt(0).toUpperCase()
                                palette: Constants.grad2
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: dp(2)
                                Text {
                                    text: modelData.name
                                    color: Constants.textPrimary
                                    font.pixelSize: sp(Constants.fsBodyLg)
                                    font.bold: true
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: InventoryStore.formatCurrency(modelData.price) + " · qty " + modelData.qty
                                    color: Constants.textSecondary
                                    font.pixelSize: sp(Constants.fsSmall)
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }
                        }

                        // ── Quantity row: its own line, so the 48 dp touch targets never squeeze the product name
                        // (picker v2 S5c; the product sheet's row stacks its stepper the same way).
                        RowLayout {
                            Layout.fillWidth: true
                            Item { Layout.fillWidth: true }
                            CartStepper {
                                value: modelData.qty
                                itemName: modelData.name
                                onDecrement: dlg.changeQty(index, -1)
                                onIncrement: dlg.changeQty(index, +1)
                            }
                        }

                        // ── Price + discount row: price field, ₹/% toggle, value ──
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: dp(Constants.space2)

                            // Editable unit price — commits on blur/accept (never
                            // per-keystroke) so modelData.price and this field don't
                            // loop. Plain number while focused, formatted otherwise.
                            Text {
                                text: qsTr("Price")
                                color: Constants.textSecondary
                                font.pixelSize: sp(Constants.fsSmall)
                                font.bold: true
                            }
                            QQC.TextField {
                                id: linePriceField
                                Accessible.name: qsTr("Price of %1").arg(modelData.name || qsTr("item"))
                                Accessible.description: cartRow.priceError
                                Layout.minimumHeight: dp(48)
                                Layout.preferredWidth: dp(72)
                                text: InventoryStore.formatCurrency(modelData.price)
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                font.pixelSize: sp(Constants.fsBody)
                                // S5e-3c: the typed text is pinned (the fill is a fixed light colour; a palette colour would follow the system theme)
                                color: linePriceField.enabled ? Constants.textPrimary : Constants.textMuted
                                horizontalAlignment: Text.AlignRight
                                verticalAlignment: TextInput.AlignVCenter
                                selectByMouse: true
                                padding: 0
                                leftPadding: dp(6); rightPadding: dp(6)
                                topPadding: dp(6); bottomPadding: dp(6)
                                background: Rectangle {
                                    radius: dp(8)
                                    color: linePriceField.enabled ? Constants.cardBg : Constants.subtleBg
                                    border.color: cartRow.priceError.length > 0 ? Constants.danger : (linePriceField.activeFocus ? Constants.primaryBlue : Constants.borderColor)
                                    border.width: (linePriceField.activeFocus || cartRow.priceError.length > 0) ? 2 : 1
                                }
                                // Tapping the field acknowledges a refusal: the person now sees the real price in it.
                                onActiveFocusChanged: {
                                    if (activeFocus) { dlg._setPriceError(modelData.productId, ""); text = String(modelData.price); selectAll() }
                                    // Format only the untouched plain number: if this runs before editingFinished, typed text must survive
                                    else if (text === String(modelData.price)) { text = InventoryStore.formatCurrency(modelData.price) }
                                }
                                onTextEdited: if (activeFocus) dlg._setPriceError(modelData.productId, "")
                                function _commitPrice() {
                                    dlg._setLinePrice(index, text)
                                    var cur = dlg.selectedProducts[index]
                                    var price = cur ? cur.price : modelData.price
                                    // Enter commits with the field still focused: it keeps the plain number, selected, ready to retype
                                    text = activeFocus ? String(price) : InventoryStore.formatCurrency(price)
                                    if (activeFocus) selectAll()
                                }
                                onEditingFinished: _commitPrice()
                                onAccepted: _commitPrice()
                            }

                            Text {
                                text: qsTr("Discount")
                                color: Constants.textSecondary
                                font.pixelSize: sp(Constants.fsSmall)
                                font.bold: true
                            }
                            SegmentedPill {
                                Layout.preferredWidth: dp(72)
                                model: ["₹", "%"]
                                selected: modelData.discountType === "percent" ? 1 : 0
                                onSegmentSelected: function(idx, label) {
                                    dlg._setLineDiscountType(index, idx === 1 ? "percent" : "flat",
                                                             lineDiscField.activeFocus ? lineDiscField.text : null)
                                }
                            }
                            QQC.TextField {
                                id: lineDiscField
                                Accessible.name: modelData.discountType === "percent" ? qsTr("Discount of %1, percent").arg(modelData.name || qsTr("item")) : qsTr("Discount of %1, flat amount").arg(modelData.name || qsTr("item"))
                                Accessible.description: cartRow.discountError
                                Layout.minimumHeight: dp(48)
                                Layout.fillWidth: true
                                text: String(modelData.discountValue || 0)
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                font.pixelSize: sp(Constants.fsBody)
                                // S5e-3c: the typed text is pinned (the fill is a fixed light colour; a palette colour would follow the system theme)
                                color: lineDiscField.enabled ? Constants.textPrimary : Constants.textMuted
                                horizontalAlignment: Text.AlignRight
                                verticalAlignment: TextInput.AlignVCenter
                                selectByMouse: true
                                padding: 0
                                leftPadding: dp(6); rightPadding: dp(6)
                                topPadding: dp(6); bottomPadding: dp(6)
                                background: Rectangle {
                                    radius: dp(8)
                                    color: lineDiscField.enabled ? Constants.cardBg : Constants.subtleBg
                                    border.color: cartRow.discountError.length > 0 ? Constants.danger : (lineDiscField.activeFocus ? Constants.primaryBlue : Constants.borderColor)
                                    border.width: (lineDiscField.activeFocus || cartRow.discountError.length > 0) ? 2 : 1
                                }
                                // Tapping the field acknowledges a refusal: the person now sees the real discount in it.
                                onActiveFocusChanged: if (activeFocus) { dlg._setDiscountError(modelData.productId, ""); selectAll() }
                                onTextEdited: if (activeFocus) dlg._setDiscountError(modelData.productId, "")
                                function _commitDiscount() {
                                    dlg._setLineDiscountValue(index, text)
                                    var cur = dlg.selectedProducts[index]
                                    text = String((cur ? cur.discountValue : modelData.discountValue) || 0)
                                    if (activeFocus) selectAll()
                                }
                                onEditingFinished: _commitDiscount()
                                onAccepted: _commitDiscount()
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: cartRow.priceError.length > 0
                            text: cartRow.priceError
                            color: Constants.danger
                            font.pixelSize: sp(Constants.fsSmall)
                            wrapMode: Text.Wrap
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: cartRow.discountError.length > 0
                            text: cartRow.discountError
                            color: Constants.danger
                            font.pixelSize: sp(Constants.fsSmall)
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }
        }

        // Totals
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: totalsCol.implicitHeight + dp(20)
            Layout.topMargin: dp(Constants.space2)
            radius: dp(Constants.radius)
            color: Constants.subtleBg
            visible: dlg.selectedProducts.length > 0

            ColumnLayout {
                id: totalsCol
                anchors.fill: parent
                anchors.margins: dp(Constants.space3)
                spacing: dp(4)

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: qsTr("Subtotal"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsBody); Layout.fillWidth: true }
                    Text { text: InventoryStore.formatCurrency(dlg._totalsCache.subtotal); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBody) }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: dlg._totalsCache.discount > 0
                    Text { text: qsTr("Discount"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsBody); Layout.fillWidth: true }
                    Text { text: "− " + InventoryStore.formatCurrency(dlg._totalsCache.discount); color: Constants.success; font.pixelSize: sp(Constants.fsBody) }
                }
                Repeater {
                    model: dlg._totalsCache.taxBreakdown
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: qsTr("Tax (%1%)").arg(modelData.rate)
                            color: Constants.textSecondary
                            font.pixelSize: sp(Constants.fsBody)
                            Layout.fillWidth: true
                        }
                        Text {
                            text: InventoryStore.formatCurrency(modelData.amount)
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBody)
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: qsTr("Total"); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBodyLg); font.bold: true; Layout.fillWidth: true }
                    Text { text: InventoryStore.formatCurrency(dlg._totalsCache.total); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBodyLg); font.bold: true }
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

    // ── Helpers ──
    function _subtotal() {
        var s = 0
        for (var i = 0; i < selectedProducts.length; ++i)
            s += selectedProducts[i].qty * selectedProducts[i].price
        return s
    }

    // Build a normalized line-item array (with tax info) and compute totals
    // via OrdersStore. Pure function — safe to drive from the cached property.
    function _totals(items) {
        var lines = []
        for (var i = 0; i < (items || []).length; ++i) {
            var sp = items[i]
            var inv = sp.productId ? InventoryStore.getById(sp.productId) : null
            lines.push({
                productId: sp.productId,
                name: sp.name,
                price: sp.price,
                quantity: sp.qty,
                taxable: inv ? !!inv.taxable : false,
                taxPercent: inv && inv.taxable ? Number(inv.taxPercent || 0) : 0,
                discountType: sp.discountType || "flat",
                discountValue: sp.discountValue || 0
            })
        }
        return OrdersStore.computeOrderTotals(lines)
    }

    // A typed price or discount that is not committed yet. The ₹/% pill takes no focus, and a button is not promised to take it
    // on every platform, so a row tap that rebuilds the rows, and trySubmit, ask first (NO3b, NO3c).
    function _settleFieldEdit() {
        for (var i = 0; i < cartRepeater.count; ++i) {
            var row = cartRepeater.itemAt(i)
            if (row && row.settleField()) return   // one field has the focus, and a commit rebuilds the rows
        }
    }

    function _setPriceError(productId, message) {
        _priceErrors = OrderFlow.withPriceError(_priceErrors, productId, message)
    }

    function _setDiscountError(productId, message) {
        _discountErrors = OrderFlow.withPriceError(_discountErrors, productId, message)
    }

    function _replaceLine(idx, changes) {
        var arr = selectedProducts.slice()
        arr[idx] = Object.assign({}, arr[idx], changes)
        selectedProducts = arr
    }

    // Commit a typed discount (NO3c). Same shape as _setLinePrice: a refusal keeps the old value and records why.
    function _setLineDiscountValue(idx, text) {
        if (!OrderFlow.isRow(idx, selectedProducts.length)) return
        var cur = selectedProducts[idx]
        var gross = cur.price * cur.qty
        var r = OrderFlow.discountEdit(text, cur.discountValue, cur.discountType, gross)
        if (r.kind === "unchanged") return
        _setDiscountError(cur.productId, r.kind === "refused" ? OrderFlow.discountText(r.reason, InventoryStore.formatCurrency(gross)) : "")
        if (r.kind !== "set" || r.value === (cur.discountValue || 0)) return
        _replaceLine(idx, { discountValue: r.value })
    }

    // The ₹/% pill (NO3c). `typed`: this row's discount text when the person is still in that field, else null. It is then read
    // under the NEW type; any other field in use is committed first.
    function _setLineDiscountType(idx, type, typed) {
        if (typed === null) _settleFieldEdit()
        if (!OrderFlow.isRow(idx, selectedProducts.length)) return
        var cur = selectedProducts[idx]
        var next = type === "percent" ? "percent" : "flat"
        if ((cur.discountType === "percent" ? "percent" : "flat") === next) return
        var gross = cur.price * cur.qty
        var r = OrderFlow.discountSwitch(typed, cur.discountValue, next, gross, InventoryStore.formatCurrency(gross))
        _setDiscountError(cur.productId, r.message)
        _replaceLine(idx, { discountType: next, discountValue: r.value })
    }

    // Commit an edited per-line unit price (NO3b). Immutable array replace so _totalsCache recomputes. One reading of the text
    // (OrderFlow.priceEdit: a plain decimal up to the app's price limit). A refusal keeps the old price and records why.
    // "unchanged" touches nothing: Enter fires accepted AND editingFinished, and the second call must not wipe the message.
    function _setLinePrice(idx, value) {
        if (!OrderFlow.isRow(idx, selectedProducts.length)) return   // NaN, undefined, "0", 1.5: no such row
        var cur = selectedProducts[idx]
        var r = OrderFlow.priceEdit(value, cur.price, InventoryStore.formatCurrency(cur.price))
        if (r.kind === "unchanged") return
        _setPriceError(cur.productId, r.kind === "refused" ? OrderFlow.priceText(r.reason) : "")
        if (r.kind !== "set" || r.price === cur.price) return
        _replaceLine(idx, { price: r.price })
    }

    function changeQty(idx, delta) {
        _settleFieldEdit()
        var arr = []
        for (var i = 0; i < selectedProducts.length; ++i) {
            var sp = selectedProducts[i]
            if (i === idx) {
                var inv = InventoryStore.getById(sp.productId)
                // The one stock rule (picker v2, S5b): + never lowers or removes a row, - takes exactly delta off
                var newQ = Picker.stepQty(sp.qty, delta, inv)
                if (newQ === 0) continue   // remove on hitting 0
                arr.push({ name: sp.name, qty: newQ, price: sp.price, productId: sp.productId,
                          discountType: sp.discountType || "flat", discountValue: sp.discountValue || 0 })
            } else {
                arr.push({ name: sp.name, qty: sp.qty, price: sp.price, productId: sp.productId,
                          discountType: sp.discountType || "flat", discountValue: sp.discountValue || 0 })
            }
        }
        selectedProducts = arr
    }

    function trySubmit() {
        // Must be the very first check, before any validation even runs —
        // a second tap arriving while the first request is still in flight
        // must be a hard no-op, not just skip re-validation.
        if (busy) return
        _settleFieldEdit()
        var errs = []
        if (!customerField.text || customerField.text.length < 2) errs.push("Enter a valid customer name")
        if (selectedProducts.length === 0) errs.push("Add at least one product")
        for (var k = 0; k < selectedProducts.length; ++k) {
            var sp = selectedProducts[k]
            var inv = InventoryStore.getById(sp.productId)
            if (inv && sp.qty > inv.stock)
                errs.push(sp.name + ": only " + inv.stock + " in stock")
            // A refused price or discount left another value in the cart, and a discount can stop fitting when the quantity or
            // price drops: never book either unseen
            errs = errs.concat(OrderFlow.lineProblems(
                { productId: sp.productId, name: sp.name, price: sp.price, quantity: sp.qty,
                  discountType: sp.discountType, discountValue: sp.discountValue },
                { price: _priceErrors[sp.productId], discount: _discountErrors[sp.productId] },
                InventoryStore.formatCurrency))
        }
        if (errs.length > 0) { errorLabel.text = errs.join(" · "); return }
        errorLabel.text = ""

        var prods = []
        for (var i = 0; i < selectedProducts.length; ++i) {
            var inv = selectedProducts[i].productId ? InventoryStore.getById(selectedProducts[i].productId) : null
            prods.push({ productId: selectedProducts[i].productId, name: selectedProducts[i].name,
                         qty: selectedProducts[i].qty, price: selectedProducts[i].price,
                         taxable: inv ? !!inv.taxable : false,
                         taxPercent: inv && inv.taxable ? Number(inv.taxPercent || 0) : 0,
                         discountType: selectedProducts[i].discountType || "flat",
                         discountValue: selectedProducts[i].discountValue || 0 })
        }

        // Channel + staff additions to the payload. The channel name itself
        // is what we persist (rather than an id) — channels are a free-text
        // configurable list with no Firestore record.
        var channel = (channelCombo.currentIndex >= 0
                       && channelCombo.currentIndex < OrderChannelStore.channels.length)
                ? OrderChannelStore.channels[channelCombo.currentIndex]
                : ""
        // Note: we intentionally do NOT change the default channel here. The
        // default is an explicit user-pinned choice (Manage channels), not the
        // "last used" — so placing an order on a non-default channel doesn't
        // silently repin the picker for next time.
        var staffId = staffCombo.currentIndex > 0
                ? _staffIds[staffCombo.currentIndex]
                : ""

        // Set synchronously, before the fire-and-forget emit below — closes
        // the exact window the original bug lived in. BottomSheet's primary
        // button already binds `enabled: primaryEnabled && !busy`, so this
        // also disables the button itself the instant this line runs.
        busy = true
        // The totals and the status are not sent: OrdersStore computes every total from the lines (one author) and a new order
        // is always pending.
        orderCreated({ customer: customerField.text, date: new Date(),
                       email: emailField.text, phone: phoneField.text, products: prods,
                       orderChannel: channel, staffId: staffId })
        // No dlg.close() here anymore — closing now waits for a real
        // logic.orderAdded (success), logic.orderCreationDeferred (saved, not confirmed yet) or logic.orderCreationFailed
        // (failure) signal, via the Connections block below. See ASYNC-REENTRANCY-BUGS.md
        // C-2 and SKILLS Skill 65.
    }

    // Searchable product sheet with a quantity stepper per row (picker v2). Declared here, opened by "Add products".
    // The app's Back router (Main.qml, BackRouter.js) asks the open dialog first. With the product sheet up, Back belongs
    // to the sheet (it asks "Discard these items?" when a draft exists); without this the router would close THIS dialog
    // under the sheet and the draft would be lost without a question. false = not ours, the router closes the dialog.
    function consumeBack() { return picker.handleBack() }

    ProductPickerSheet {
        id: picker
        products: InventoryStore.products
        hooks: dlg._pickerHooks
        orderLines: dlg.selectedProducts
        revision: dlg._pickerRevision
        onCommitted: function(plan) { dlg._applyPicked(plan) }
    }

    // Waits for the real result of the addOrder round trip fired above,
    // instead of closing immediately — same shape as OrderDetailDialog's
    // Connections-on-logic block for _save(). `logic` is reachable by id
    // here because this dialog is instantiated inline as a child of Main.qml
    // (same object-tree scope), not through a Component{}/Loader boundary.
    //
    // Unlike orderCompletionFailed (scoped by orderId, since an order
    // already exists by the time completion can fail), orderCreationFailed
    // carries no id — there is no order yet to scope by when minting itself
    // fails. That's fine here: only one NewOrderDialog instance exists
    // app-wide, and BottomSheet's own busy-driven closePolicy/close-button
    // guard (see BottomSheet.qml) makes it impossible for the user to close
    // this sheet and re-open a fresh submission while `busy` is still true,
    // so there is no "wrong request's answer" ambiguity to guard against.
    Connections {
        target: logic
        function onOrderAdded(orderId) {
            if (!dlg.busy) return
            dlg.busy = false
            dlg.close()
        }
        function onOrderCreationFailed(errorMessage) {
            if (!dlg.busy) return
            dlg.busy = false
            errorLabel.text = errorMessage || "Could not create order — try again"
        }
        // Saved, but the server's answer is not in yet (slow link) or could not be read: close with a toast that says so. The
        // order is NOT offered again (a second tap would be a second order); it appears in the list when the server answers.
        function onOrderCreationDeferred(status) {
            if (!dlg.busy) return
            dlg.busy = false
            try { Toast.show(OrdersStore.createDoneMessage(status)) } finally { dlg.close() }
        }
    }
}
