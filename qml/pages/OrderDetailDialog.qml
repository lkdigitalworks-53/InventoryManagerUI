import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Order detail / edit — bottom sheet. Live product table with qty editing,
// totals (subtotal / GST 18% / total), product picker. Public contract:
//   signal orderUpdated(orderId)
//   function openFor(id)
//   property string orderId, int orderIndex
BottomSheet {
    id: dlg

    sheetTitle: "Edit order " + (orderId.length > 0 ? "#" + orderId : "")
    primaryAction: "Save changes"
    secondaryAction: "Close"

    signal orderUpdated(string orderId)

    property string orderId: ""
    property int orderIndex: -1

    property var catalog: []
    property var catalogNames: []

    ListModel { id: products }

    property string _discountType: "flat"
    property real _discountValue: 0

    // Mirror of StaffStore for the picker (filtered to active members).
    // Index 0 is the empty "(no staff)" row.
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

    property real _subtotal: 0
    property real _discount: 0
    property real _tax: 0
    property var _taxBreakdown: []
    property real _total: 0

    function _lineItemArray() {
        var arr = []
        for (var i = 0; i < products.count; ++i) {
            var pr = products.get(i)
            arr.push({ productId: pr.productId, name: pr.name, price: pr.price,
                       quantity: pr.quantity,
                       taxable: !!pr.taxable, taxPercent: pr.taxPercent || 0 })
        }
        return arr
    }

    function recomputeSubtotal() {
        var lineArr = _lineItemArray()
        var t = OrdersStore.computeOrderTotals(lineArr, _discountType, _discountValue)
        _subtotal = t.subtotal
        _discount = t.discount
        _tax = t.tax
        // Force reference change so the Repeater rebuilds even when
        // computeOrderTotals returns a structurally-equal array.
        _taxBreakdown = []
        _taxBreakdown = t.taxBreakdown.slice()
        _total = t.total
        var savedIdx = productCombo.currentIndex
        _rebuildCatalog()
        productCombo.currentIndex = savedIdx
    }

    function _rebuildCatalog() {
        var cat = []
        var names = []
        for (var i = 0; i < InventoryStore.products.length; ++i) {
            var p = InventoryStore.products[i]
            var avail = _availableStock(p.name)
            var sellPrice = p.sellingPrice !== undefined ? p.sellingPrice : p.price
            cat.push({ name: p.name, price: sellPrice, productId: p.productId,
                       taxable: !!p.taxable, taxPercent: p.taxPercent || 0 })
            names.push(p.name + " — " + InventoryStore.formatCurrency(sellPrice) + "  ·  avail " + avail)
        }
        catalog = cat
        catalogNames = names
    }

    function _availableStock(productName) {
        var inv = InventoryStore.findByName(productName)
        if (!inv) return 0
        var used = 0
        for (var i = 0; i < products.count; ++i)
            if (products.get(i).name === productName)
                used = products.get(i).quantity
        return Math.max(0, inv.stock - used)
    }

    function openFor(id) {
        _rebuildCatalog()
        orderId = id

        var allOrders = OrdersStore.orders
        var o = null
        for (var i = 0; i < allOrders.length; ++i)
            if (allOrders[i].orderId === id) { o = allOrders[i]; break }
        if (!o) return

        customerField.text = o.customer
        emailField.text = o.email || ""
        phoneField.text = o.phone || ""
        statusCombo.currentIndex = ["pending","processing","completed"].indexOf(String(o.status))
        if (statusCombo.currentIndex < 0) statusCombo.currentIndex = 0

        _discountType = o.discountType === "percent" ? "percent" : "flat"
        _discountValue = parseFloat(o.discountValue) || 0
        discountTypeToggle.selected = _discountType === "percent" ? 1 : 0
        discountField.text = String(_discountValue)

        // Channel + staff: pre-fill from the existing order. The channel
        // string is matched against the configured list — when the order
        // referenced a channel that's since been removed, the picker falls
        // back to the default index so save doesn't accidentally clear the
        // value.
        channelCombo.model = OrderChannelStore.channels
        var chIdx = OrderChannelStore.channels.indexOf(o.orderChannel || "")
        channelCombo.currentIndex = chIdx >= 0 ? chIdx : OrderChannelStore.indexOfDefault()
        dlg._refreshStaff(o.staffId || "")

        products.clear()
        if (o.products && o.products.length > 0) {
            for (var j = 0; j < o.products.length; ++j) {
                var lp = o.products[j]
                var inv = lp.productId ? InventoryStore.getById(lp.productId) : null
                var taxable = lp.taxable !== undefined ? !!lp.taxable : (inv ? !!inv.taxable : false)
                var taxPercent = lp.taxPercent !== undefined && lp.taxPercent !== null
                    ? Number(lp.taxPercent)
                    : (inv && taxable ? Number(inv.taxPercent || 0) : 0)
                products.append({
                    productId: lp.productId || "",
                    name: lp.name,
                    price: lp.price,
                    quantity: lp.quantity,
                    taxable: taxable,
                    taxPercent: isNaN(taxPercent) ? 0 : taxPercent
                })
            }
        } else {
            var itemCount = o.items
            if (catalog.length >= 2 && itemCount >= 2) {
                var qty1 = Math.ceil(itemCount / 2)
                var qty2 = itemCount - qty1
                products.append({ productId: catalog[0].productId, name: catalog[0].name, price: catalog[0].price, quantity: qty1,
                                   taxable: catalog[0].taxable, taxPercent: catalog[0].taxPercent })
                if (qty2 > 0) products.append({ productId: catalog[1].productId, name: catalog[1].name, price: catalog[1].price, quantity: qty2,
                                                 taxable: catalog[1].taxable, taxPercent: catalog[1].taxPercent })
            } else if (catalog.length > 0) {
                products.append({ productId: catalog[0].productId, name: catalog[0].name, price: catalog[0].price, quantity: Math.max(1, itemCount),
                                   taxable: catalog[0].taxable, taxPercent: catalog[0].taxPercent })
            }
        }
        recomputeSubtotal()
        productCombo.currentIndex = 0
        stockErrorLabel.text = ""
        open()
    }

    onPrimaryClicked: _save()

    function _save() {
        var itemCount = 0
        var prods = []
        var stockErrors = []
        for (var i = 0; i < products.count; ++i) {
            var p = products.get(i)
            itemCount += p.quantity
            prods.push({ productId: p.productId || "", name: p.name, price: p.price,
                         quantity: p.quantity,
                         taxable: !!p.taxable,
                         taxPercent: p.taxPercent || 0 })
            var inv = InventoryStore.findByName(p.name)
            if (inv && p.quantity > inv.stock)
                stockErrors.push(p.name + ": only " + inv.stock + " in stock, ordered " + p.quantity)
        }
        if (stockErrors.length > 0) {
            stockErrorLabel.text = stockErrors.join("\n")
            return
        }
        stockErrorLabel.text = ""

        var statuses = ["pending","processing","completed"]
        var chIdx = channelCombo.currentIndex
        var channel = (chIdx >= 0 && chIdx < OrderChannelStore.channels.length)
                ? OrderChannelStore.channels[chIdx]
                : ""
        var staffId = staffCombo.currentIndex > 0
                ? dlg._staffIds[staffCombo.currentIndex]
                : ""
        logic.updateOrder(dlg.orderId, {
            customer: customerField.text,
            email: emailField.text,
            phone: phoneField.text,
            status: statuses[Math.max(0, statusCombo.currentIndex)] || "pending",
            items: itemCount,
            products: prods,
            discountType: dlg._discountType,
            discountValue: dlg._discountValue,
            orderChannel: channel,
            staffId: staffId
        })
        dlg.orderUpdated(dlg.orderId)
        dlg.close()
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        // Customer block
        Text {
            text: "Customer"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
        }

        AuthTextField {
            id: customerField
            Layout.fillWidth: true
            label: "Name"
            placeholderText: "Customer name"
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AuthTextField {
                id: emailField
                Layout.fillWidth: true
                label: "Email"
                placeholderText: "name@example.com"
                inputMethodHints: Qt.ImhEmailCharactersOnly
            }
            AuthTextField {
                id: phoneField
                Layout.fillWidth: true
                label: "Phone"
                placeholderText: "+91 98765 43210"
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: dp(4)
            Text {
                text: "Status"
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsSmall)
                font.bold: true
            }
            AppComboBox {
                id: statusCombo
                Layout.fillWidth: true
                model: ["pending", "processing", "completed"]
                font.pixelSize: sp(Constants.fsBody)
            }
        }

        // Order channel + staff (sold-by). Read-only fields would normally
        // sit in a banner, but the dialog is a single edit form so the
        // pickers live alongside Status. A `dlg.staffId` getter feeds _save.
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

        // Products block
        Text {
            text: "Items"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        // Picker
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            AppComboBox {
                id: productCombo
                Layout.fillWidth: true
                model: dlg.catalogNames
                font.pixelSize: sp(Constants.fsBody)
            }
            IconActionButton {
                variant: "default"
                iconName: "add"
                onClicked: {
                    var idx = productCombo.currentIndex
                    if (idx < 0 || idx >= dlg.catalog.length) return
                    var p = dlg.catalog[idx]
                    var avail = dlg._availableStock(p.name)
                    if (avail <= 0) return
                    for (var i = 0; i < products.count; ++i) {
                        if (products.get(i).name === p.name) {
                            products.setProperty(i, "quantity", products.get(i).quantity + 1)
                            dlg.recomputeSubtotal()
                            return
                        }
                    }
                    products.append({ productId: p.productId, name: p.name, price: p.price, quantity: 1,
                                       taxable: !!p.taxable, taxPercent: p.taxPercent || 0 })
                    dlg.recomputeSubtotal()
                }
            }
        }

        // Line items as cards (Repeater, not ListView, to avoid nested-scroll
        // conflicts with the BottomSheet's outer ScrollView).
        ColumnLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            Repeater {
                model: products
                delegate: ListCard {
                    id: row
                    property int rowIdx: index
                    Layout.fillWidth: true
                    title: model.name
                    subtitle: {
                        var inv = null
                        if (model.productId) inv = InventoryStore.getById(model.productId)
                        if (!inv && model.name) inv = InventoryStore.findByName(model.name)
                        var sku = inv && inv.sku ? inv.sku + " · " : ""
                        return sku + OrdersStore.formatCurrency(model.price) + " × " + model.quantity
                            + "  =  " + OrdersStore.formatCurrency(model.price * model.quantity)
                    }

                    leading: AvatarBadge {
                        label: (model.name || "?").charAt(0).toUpperCase()
                        palette: index % 4 === 0 ? Constants.grad1
                               : index % 4 === 1 ? Constants.grad2
                               : index % 4 === 2 ? Constants.grad3
                               :                   Constants.grad4
                    }

                    RowLayout {
                        spacing: dp(4)
                        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight

                        QQC.AbstractButton {
                            Layout.preferredWidth: dp(28); Layout.preferredHeight: dp(28)
                            implicitWidth: dp(28); implicitHeight: dp(28)
                            padding: 0
                            background: Rectangle { radius: dp(8); border.color: Constants.borderColor; border.width: 1; color: "transparent" }
                            contentItem: Item {
                                Icon { anchors.centerIn: parent; name: "remove"; size: sp(16); color: Constants.textPrimary }
                            }
                            onClicked: {
                                var q = model.quantity - 1
                                if (q <= 0) {
                                    products.remove(row.rowIdx)
                                } else {
                                    products.setProperty(row.rowIdx, "quantity", q)
                                }
                                dlg.recomputeSubtotal()
                            }
                        }
                        Text {
                            text: String(model.quantity)
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBody)
                            font.bold: true
                            Layout.preferredWidth: dp(22)
                            horizontalAlignment: Text.AlignHCenter
                        }
                        QQC.AbstractButton {
                            Layout.preferredWidth: dp(28); Layout.preferredHeight: dp(28)
                            implicitWidth: dp(28); implicitHeight: dp(28)
                            padding: 0
                            background: Rectangle { radius: dp(8); border.color: Constants.borderColor; border.width: 1; color: "transparent" }
                            contentItem: Item {
                                Icon { anchors.centerIn: parent; name: "add"; size: sp(16); color: Constants.textPrimary }
                            }
                            onClicked: {
                                var inv = InventoryStore.findByName(model.name)
                                var maxQ = inv ? inv.stock : model.quantity + 1
                                var q = Math.min(maxQ, model.quantity + 1)
                                products.setProperty(row.rowIdx, "quantity", q)
                                dlg.recomputeSubtotal()
                            }
                        }
                        QQC.AbstractButton {
                            Layout.preferredWidth: dp(28); Layout.preferredHeight: dp(28)
                            implicitWidth: dp(28); implicitHeight: dp(28)
                            padding: 0
                            background: Rectangle { radius: dp(8); color: "transparent" }
                            contentItem: Item {
                                Icon { anchors.centerIn: parent; name: "close"; size: sp(14); color: Constants.danger }
                            }
                            onClicked: { products.remove(row.rowIdx); dlg.recomputeSubtotal() }
                        }
                    }
                }
            }
        }

        // Stock errors
        Text {
            id: stockErrorLabel
            Layout.fillWidth: true
            visible: text.length > 0
            text: ""
            color: Constants.danger
            font.pixelSize: sp(Constants.fsSmall)
            wrapMode: Text.Wrap
        }

        // Discount block
        Text {
            text: qsTr("Discount")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            Layout.alignment: Qt.AlignBottom

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
                        dlg.recomputeSubtotal()
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
                    dlg.recomputeSubtotal()
                }
            }
        }

        // Totals strip
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: totalsCol.implicitHeight + dp(Constants.space4 * 2)
            radius: dp(Constants.radius)
            color: Constants.subtleBg
            border.color: Constants.borderColor
            border.width: 1

            ColumnLayout {
                id: totalsCol
                anchors.fill: parent
                anchors.margins: dp(Constants.space4)
                spacing: dp(4)

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: qsTr("Subtotal"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsBody); Layout.fillWidth: true }
                    Text { text: OrdersStore.formatCurrency(dlg._subtotal); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBody) }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: dlg._discount > 0
                    Text { text: qsTr("Discount"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsBody); Layout.fillWidth: true }
                    Text { text: "− " + OrdersStore.formatCurrency(dlg._discount); color: Constants.success; font.pixelSize: sp(Constants.fsBody) }
                }
                Repeater {
                    model: dlg._taxBreakdown
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: qsTr("Tax (%1%)").arg(modelData.rate)
                            color: Constants.textSecondary
                            font.pixelSize: sp(Constants.fsBody)
                            Layout.fillWidth: true
                        }
                        Text {
                            text: OrdersStore.formatCurrency(modelData.amount)
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBody)
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: Constants.borderColor }
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: qsTr("Total"); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBodyLg); font.bold: true; Layout.fillWidth: true }
                    Text { text: OrdersStore.formatCurrency(dlg._total); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBodyLg); font.bold: true }
                }
            }
        }
    }
}
