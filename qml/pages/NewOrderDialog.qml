import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Mobile-first New Order sheet — bottom sheet with customer fields and a
// product picker. Public contract preserved: signal `orderCreated(order)`.
BottomSheet {
    id: dlg

    sheetTitle: "New order"
    primaryAction: "Place order"
    secondaryAction: "Cancel"

    signal orderCreated(var order)
    signal manageChannelsRequested()

    property var selectedProducts: []
    property var productNames: []

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

    // Units of a product already in the cart — so the picker can show what's
    // ACTUALLY still available (stock − in-cart), and refresh as qty changes.
    function _inCartQty(productId, productName) {
        var used = 0
        for (var i = 0; i < selectedProducts.length; ++i) {
            var sp = selectedProducts[i]
            if ((productId && sp.productId === productId) || (!productId && sp.name === productName))
                used += (sp.qty || 0)
        }
        return used
    }

    // Available for a NEW order = on-hand stock minus what's already in this
    // cart (units aren't deducted until the order completes). Mirrors
    // OrderDetailDialog._availableStock for the pending case.
    function _availableStock(p) {
        return Math.max(0, (p.stock || 0) - _inCartQty(p.productId, p.name))
    }

    // (Re)build the picker labels with a live "avail N" that reflects the cart.
    // Called on open AND after every qty change / add — without this the count
    // was built once and stayed static (unlike the edit-order dialog).
    function _rebuildPickerNames() {
        var names = []
        for (var i = 0; i < InventoryStore.products.length; ++i) {
            var p = InventoryStore.products[i]

            // HARD REJECT: Avoid showing products which has 0 stock.
            if (!p.stock || p.stock <= 0) continue

            var sp = p.sellingPrice !== undefined ? p.sellingPrice : p.price
            var sku = p.sku ? "[" + p.sku + "] " : ""
            names.push(sku + p.name + " — " + InventoryStore.formatCurrency(sp)
                       + " · " + _availableStock(p) + " left")
        }
        var savedIdx = (typeof productCombo !== "undefined") ? productCombo.currentIndex : 0
        productNames = names
        if (typeof productCombo !== "undefined")
            productCombo.currentIndex = Math.max(0, Math.min(savedIdx, names.length - 1))
    }

    onOpened: {
        _rebuildPickerNames()
        productCombo.currentIndex = 0
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
        selectedProducts = []
        customerField.text = ""
        emailField.text = ""
        phoneField.text = ""
        productCombo.currentIndex = 0
        _rebuildPickerNames()
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

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            AppComboBox {
                id: productCombo
                Layout.fillWidth: true
                model: dlg.productNames
                font.pixelSize: sp(Constants.fsBody)
            }

            IconActionButton {
                variant: "default"
                iconName: "add"
                onClicked: dlg.addSelectedProduct()
            }
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
        _rebuildPickerNames()   // refresh "avail N" to reflect the new cart qty
    }

    function addSelectedProduct() {
        var idx = productCombo.currentIndex
        if (idx < 0 || idx >= InventoryStore.products.length) return
        var p = InventoryStore.products[idx]
        if (p.stock <= 0) return
        var arr = []
        for (var i = 0; i < selectedProducts.length; ++i)
            arr.push({ name: selectedProducts[i].name, qty: selectedProducts[i].qty,
                       price: selectedProducts[i].price, productId: selectedProducts[i].productId,
                       discountType: selectedProducts[i].discountType || "flat",
                       discountValue: selectedProducts[i].discountValue || 0 })
        for (var j = 0; j < arr.length; ++j) {
            if (arr[j].productId === p.productId) {
                if (arr[j].qty >= p.stock) return
                arr[j].qty++
                selectedProducts = arr
                _rebuildPickerNames()
                return
            }
        }
        var sp = p.sellingPrice !== undefined ? p.sellingPrice : p.price
        arr.push({ name: p.name, qty: 1, price: sp, productId: p.productId,
                   discountType: "flat", discountValue: 0 })
        selectedProducts = arr
        _rebuildPickerNames()
    }

    function trySubmit() {
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

        orderCreated({ customer: customerField.text, items: totalItems, total: t.total,
                       status: "pending", date: new Date(),
                       email: emailField.text, phone: phoneField.text, products: prods,
                       orderChannel: channel, staffId: staffId })
        dlg.close()
    }
}
