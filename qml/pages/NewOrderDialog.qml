import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"
import "../helper/NewOrderPicker.js" as Picker

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

    // In-flight guard — see ASYNC-REENTRANCY-BUGS.md C-2. `orderCreated` is a
    // fire-and-forget signal into Main.qml -> logic.addOrder -> DataModel's
    // OrdersStore.nextOrderId mint (a real, server-coordinated network round
    // trip). Without this, a double-tap on "Place order" mints two separate
    // orders — and if autoApproveEnabled is on, double-deducts stock via
    // _tryCompleteOrder too. There is no DataModel-layer guard for creation
    // the way _completingOrderIds guards completion (no second call path
    // into OrdersStore.addOrder the way _approveAllPending gives completion),
    // so the UI entry point below is the ONLY thing standing between this and
    // a duplicate order — same category the doc calls out.

    property var selectedProducts: []

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
    readonly property var _pickerHooks: ({
        hasPendingMint: function(id) { return StockBatchStore.hasPendingMint(id) },
        hasQueuedRestock: function(id) { return InventoryStore.hasQueuedRestock(id) },
        unsyncedState: function(id) { return InventoryStore.syncStateOf(id) },
        inOrderQty: function(id) { return Picker.cartQty(dlg.selectedProducts, id) },
        availableFor: function(p) { return Picker.availableFor(p, dlg.selectedProducts) },
        commitCheck: function(plan) { return Picker.opsCheck(dlg.selectedProducts, plan, dlg._pickerLookup) }
    })
    // Every counter the hooks read. Each only grows, so the sum changes whenever any of them does and the open sheet
    // re-reads (Skill 78): stock and catalog, batches, pending mints (own counter, S3) and the outbox (queued restock,
    // queued or parked edit).
    readonly property int _pickerRevision: InventoryStore.revision + StockBatchStore.revision
                                           + StockBatchStore.mintRevision + OutboxStore.revision

    // The plan from the sheet: add N more, never remove (design D4). applyPlan re-reads each product at this moment and
    // clamps or refuses, so the order never holds more than the stock, and says what it did not add.
    function _applyPicked(plan) {
        var res = Picker.applyPlan(selectedProducts, plan, _pickerLookup)
        selectedProducts = res.lines
        errorLabel.text = Picker.skippedNote(res.skipped)
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
            Layout.alignment: Qt.AlignRight
            implicitHeight: dp(28)
            leftPadding: dp(8); rightPadding: dp(8)
            topPadding: 0; bottomPadding: 0
            background: Rectangle { color: "transparent" }
            contentItem: Text {
                text: qsTr("Manage channels  ›")
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
                model: dlg.selectedProducts
                delegate: Rectangle {
                    id: cartRow
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

                        // ── Top row: avatar + name/price + qty stepper ──────
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
                            QQC.AbstractButton {
                                implicitWidth: dp(28); implicitHeight: dp(28)
                                padding: 0
                                background: Rectangle { radius: dp(8); border.color: Constants.borderColor; border.width: 1; color: "transparent" }
                                contentItem: Item {
                                    Icon { anchors.centerIn: parent; name: "remove"; size: sp(16); color: Constants.textPrimary }
                                }
                                onClicked: dlg.changeQty(index, -1)
                            }
                            Text {
                                text: String(modelData.qty)
                                color: Constants.textPrimary
                                font.pixelSize: sp(Constants.fsBody)
                                font.bold: true
                                Layout.preferredWidth: dp(22)
                                horizontalAlignment: Text.AlignHCenter
                            }
                            QQC.AbstractButton {
                                implicitWidth: dp(28); implicitHeight: dp(28)
                                padding: 0
                                background: Rectangle { radius: dp(8); border.color: Constants.borderColor; border.width: 1; color: "transparent" }
                                contentItem: Item {
                                    Icon { anchors.centerIn: parent; name: "add"; size: sp(16); color: Constants.textPrimary }
                                }
                                onClicked: dlg.changeQty(index, +1)
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
                                Layout.preferredWidth: dp(72)
                                text: InventoryStore.formatCurrency(modelData.price)
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                font.pixelSize: sp(Constants.fsBody)
                                horizontalAlignment: Text.AlignRight
                                selectByMouse: true
                                padding: 0
                                leftPadding: dp(6); rightPadding: dp(6)
                                topPadding: dp(6); bottomPadding: dp(6)
                                background: Rectangle {
                                    radius: dp(8)
                                    color: linePriceField.enabled ? Constants.cardBg : Constants.subtleBg
                                    border.color: linePriceField.activeFocus ? Constants.primaryBlue : Constants.borderColor
                                    border.width: linePriceField.activeFocus ? 2 : 1
                                }
                                onActiveFocusChanged: {
                                    if (activeFocus) { text = String(modelData.price); selectAll() }
                                    else { text = InventoryStore.formatCurrency(modelData.price) }
                                }
                                function _commitPrice() {
                                    dlg._setLinePrice(index, text)
                                    var cur = dlg.selectedProducts[index]
                                    text = InventoryStore.formatCurrency(cur ? cur.price : modelData.price)
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
                                    dlg._setLineDiscount(index, idx === 1 ? "percent" : "flat", modelData.discountValue)
                                }
                            }
                            QQC.TextField {
                                id: lineDiscField
                                Layout.fillWidth: true
                                text: String(modelData.discountValue || 0)
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                font.pixelSize: sp(Constants.fsBody)
                                horizontalAlignment: Text.AlignRight
                                selectByMouse: true
                                padding: 0
                                leftPadding: dp(6); rightPadding: dp(6)
                                topPadding: dp(6); bottomPadding: dp(6)
                                background: Rectangle {
                                    radius: dp(8)
                                    color: lineDiscField.enabled ? Constants.cardBg : Constants.subtleBg
                                    border.color: lineDiscField.activeFocus ? Constants.primaryBlue : Constants.borderColor
                                    border.width: lineDiscField.activeFocus ? 2 : 1
                                }
                                function _commitDiscount() {
                                    var v = parseFloat(String(text).replace(/[^0-9.]/g, ""))
                                    if (isNaN(v) || v < 0) v = 0
                                    dlg._setLineDiscount(index, modelData.discountType, v)
                                }
                                onEditingFinished: _commitDiscount()
                                onAccepted: _commitDiscount()
                            }
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

    function _setLineDiscount(idx, type, value) {
        if (idx < 0 || idx >= selectedProducts.length) return
        var arr = selectedProducts.slice()
        arr[idx] = Object.assign({}, arr[idx], {
            discountType: type === "percent" ? "percent" : "flat",
            discountValue: isNaN(value) ? 0 : value
        })
        selectedProducts = arr
    }

    // Commit an edited per-line unit price. Mirrors _setLineDiscount: immutable
    // array replace so _totalsCache (and the orderCreated payload) recompute.
    // Rejects empty / NaN / negative by keeping the existing price.
    function _setLinePrice(idx, value) {
        if (idx < 0 || idx >= selectedProducts.length) return
        var v = parseFloat(String(value).replace(/[^0-9.]/g, ""))
        if (isNaN(v) || v < 0) return
        var arr = selectedProducts.slice()
        arr[idx] = Object.assign({}, arr[idx], { price: v })
        selectedProducts = arr
    }

    function changeQty(idx, delta) {
        var arr = []
        for (var i = 0; i < selectedProducts.length; ++i) {
            var sp = selectedProducts[i]
            if (i === idx) {
                var inv = InventoryStore.getById(sp.productId)
                var maxQ = inv ? inv.stock : sp.qty
                var newQ = Math.max(0, Math.min(maxQ, sp.qty + delta))
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
        var errs = []
        if (!customerField.text || customerField.text.length < 2) errs.push("Enter a valid customer name")
        if (selectedProducts.length === 0) errs.push("Add at least one product")
        for (var k = 0; k < selectedProducts.length; ++k) {
            var sp = selectedProducts[k]
            var inv = InventoryStore.getById(sp.productId)
            if (inv && sp.qty > inv.stock)
                errs.push(sp.name + ": only " + inv.stock + " in stock")
        }
        if (errs.length > 0) { errorLabel.text = errs.join(" · "); return }
        errorLabel.text = ""

        var totalItems = 0
        var prods = []
        for (var i = 0; i < selectedProducts.length; ++i) {
            totalItems += selectedProducts[i].qty
            var inv = selectedProducts[i].productId ? InventoryStore.getById(selectedProducts[i].productId) : null
            prods.push({ productId: selectedProducts[i].productId, name: selectedProducts[i].name,
                         qty: selectedProducts[i].qty, price: selectedProducts[i].price,
                         taxable: inv ? !!inv.taxable : false,
                         taxPercent: inv && inv.taxable ? Number(inv.taxPercent || 0) : 0,
                         discountType: selectedProducts[i].discountType || "flat",
                         discountValue: selectedProducts[i].discountValue || 0 })
        }
        var t = _totalsCache

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
        orderCreated({ customer: customerField.text, items: totalItems, total: t.total,
                       status: "pending", date: new Date(),
                       email: emailField.text, phone: phoneField.text, products: prods,
                       orderChannel: channel, staffId: staffId })
        // No dlg.close() here anymore — closing now waits for a real
        // logic.orderAdded (success) or logic.orderCreationFailed (failure)
        // signal, via the Connections block below. See ASYNC-REENTRANCY-BUGS.md
        // C-2 and SKILLS Skill 65.
    }

    // Searchable product sheet with a quantity stepper per row (picker v2). Declared here, opened by "Add products".
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
    }
}
