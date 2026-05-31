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

    property string _discountType: "flat"
    property real _discountValue: 0

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
    readonly property var _totalsCache: _totals(selectedProducts, _discountType, _discountValue)

    onOpened: {
        var names = []
        for (var i = 0; i < InventoryStore.products.length; ++i) {
            var p = InventoryStore.products[i]
            var sp = p.sellingPrice !== undefined ? p.sellingPrice : p.price
            var sku = p.sku ? "[" + p.sku + "] " : ""
            names.push(sku + p.name + " — " + InventoryStore.formatCurrency(sp) + " · " + p.stock + " left")
        }
        productNames = names
        productCombo.currentIndex = 0
        customerField.text = ""
        emailField.text = ""
        phoneField.text = ""
        selectedProducts = []
        _discountType = "flat"
        _discountValue = 0
        if (typeof discountField !== "undefined") discountField.text = "0"
        if (typeof discountTypeToggle !== "undefined") discountTypeToggle.selected = 0
        // Channel + staff: pre-select user defaults so the common case takes
        // zero taps. Channel uses OrderChannelStore's lastUsed; staff is
        // best-effort matched against the signed-in user's name (if a staff
        // record exists with that name).
        channelCombo.model = OrderChannelStore.channels
        channelCombo.currentIndex = OrderChannelStore.indexOfDefault()
        var preferredStaffId = ""
        if (AuthStore.displayName) {
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
                text: "＋"
                onClicked: dlg.addSelectedProduct()
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            Repeater {
                model: dlg.selectedProducts
                delegate: ListCard {
                    Layout.fillWidth: true
                    title: modelData.name
                    subtitle: InventoryStore.formatCurrency(modelData.price) + " · qty " + modelData.qty

                    leading: AvatarBadge {
                        label: (modelData.name || "?").charAt(0).toUpperCase()
                        palette: Constants.grad2
                    }

                    RowLayout {
                        spacing: dp(4)
                        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight

                        QQC.AbstractButton {
                            implicitWidth: dp(28); implicitHeight: dp(28)
                            padding: 0
                            background: Rectangle { radius: dp(8); border.color: Constants.borderColor; border.width: 1; color: "transparent" }
                            contentItem: Item {
                                Text {
                                    anchors.centerIn: parent
                                    text: "−"
                                    font.pixelSize: sp(16)
                                    font.bold: true
                                    color: Constants.textPrimary
                                }
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
                                Text {
                                    anchors.centerIn: parent
                                    text: "+"
                                    font.pixelSize: sp(16)
                                    font.bold: true
                                    color: Constants.textPrimary
                                }
                            }
                            onClicked: dlg.changeQty(index, +1)
                        }
                    }
                }
            }
        }

        // Discount
        Text {
            text: qsTr("Discount")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            visible: dlg.selectedProducts.length > 0
            Layout.topMargin: dp(Constants.space2)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            Layout.alignment: Qt.AlignBottom
            visible: dlg.selectedProducts.length > 0

            ColumnLayout {
                Layout.preferredWidth: dp(140)
                spacing: dp(4)
                Text {
                    text: qsTr("Type")
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsSmall)
                    font.bold: true
                }
                SegmentedPill {
                    id: discountTypeToggle
                    Layout.fillWidth: true
                    model: ["₹", "%"]
                    selected: 0
                    onSegmentSelected: function(idx, label) {
                        dlg._discountType = idx === 1 ? "percent" : "flat"
                    }
                }
            }
            AuthTextField {
                id: discountField
                Layout.fillWidth: true
                label: qsTr("Amount")
                placeholderText: "0"
                text: "0"
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                onTextChanged: {
                    var v = parseFloat(text)
                    dlg._discountValue = isNaN(v) ? 0 : v
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
    function _totals(items, dType, dValue) {
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
                taxPercent: inv && inv.taxable ? Number(inv.taxPercent || 0) : 0
            })
        }
        return OrdersStore.computeOrderTotals(lines, dType, dValue)
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
                arr.push({ name: sp.name, qty: newQ, price: sp.price, productId: sp.productId })
            } else {
                arr.push({ name: sp.name, qty: sp.qty, price: sp.price, productId: sp.productId })
            }
        }
        selectedProducts = arr
    }

    function addSelectedProduct() {
        var idx = productCombo.currentIndex
        if (idx < 0 || idx >= InventoryStore.products.length) return
        var p = InventoryStore.products[idx]
        if (p.stock <= 0) return
        var arr = []
        for (var i = 0; i < selectedProducts.length; ++i)
            arr.push({ name: selectedProducts[i].name, qty: selectedProducts[i].qty,
                       price: selectedProducts[i].price, productId: selectedProducts[i].productId })
        for (var j = 0; j < arr.length; ++j) {
            if (arr[j].productId === p.productId) {
                if (arr[j].qty >= p.stock) return
                arr[j].qty++
                selectedProducts = arr
                return
            }
        }
        var sp = p.sellingPrice !== undefined ? p.sellingPrice : p.price
        arr.push({ name: p.name, qty: 1, price: sp, productId: p.productId })
        selectedProducts = arr
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
                         taxPercent: inv && inv.taxable ? Number(inv.taxPercent || 0) : 0 })
        }
        var t = _totalsCache

        // Channel + staff additions to the payload. The channel name itself
        // is what we persist (rather than an id) — channels are a free-text
        // configurable list with no Firestore record.
        var channel = (channelCombo.currentIndex >= 0
                       && channelCombo.currentIndex < OrderChannelStore.channels.length)
                ? OrderChannelStore.channels[channelCombo.currentIndex]
                : ""
        if (channel) OrderChannelStore.setLastUsed(channel)
        var staffId = staffCombo.currentIndex > 0
                ? _staffIds[staffCombo.currentIndex]
                : ""

        orderCreated({ customer: customerField.text, items: totalItems, total: t.total,
                       status: "pending", date: new Date(),
                       email: emailField.text, phone: phoneField.text, products: prods,
                       discountType: _discountType, discountValue: _discountValue,
                       orderChannel: channel, staffId: staffId })
        dlg.close()
    }
}
