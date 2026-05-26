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

    property var selectedProducts: []
    property var productNames: []

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
                    Text { text: "Subtotal"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsBody); Layout.fillWidth: true }
                    Text { text: InventoryStore.formatCurrency(dlg._subtotal()); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBody) }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Total"; color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBodyLg); font.bold: true; Layout.fillWidth: true }
                    Text { text: InventoryStore.formatCurrency(dlg._subtotal()); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsBodyLg); font.bold: true }
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

        var totalItems = 0; var totalAmount = 0
        var prods = []
        for (var i = 0; i < selectedProducts.length; ++i) {
            totalItems += selectedProducts[i].qty
            totalAmount += selectedProducts[i].qty * selectedProducts[i].price
            prods.push({ productId: selectedProducts[i].productId, name: selectedProducts[i].name,
                         qty: selectedProducts[i].qty, price: selectedProducts[i].price })
        }

        orderCreated({ customer: customerField.text, items: totalItems, total: totalAmount,
                       status: "pending", date: new Date(),
                       email: emailField.text, phone: phoneField.text, products: prods })
        dlg.close()
    }
}
