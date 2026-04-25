
import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

Dialog {
    id: dlg
    modal: true
    title: ""
    width: Math.min(560, parent ? parent.width - 32 : 560)
    height: Math.min(parent ? parent.height - 32 : 780, 780)
    anchors.centerIn: parent
    padding: 0
    standardButtons: Dialog.NoButton

    signal orderUpdated(string orderId)

    property string orderId: ""
    property int orderIndex: -1

    // Built dynamically from InventoryStore each time the dialog opens
    property var catalog: []
    property var catalogNames: []

    ListModel { id: products }

    property real _subtotal: 0
    property real _gst: Math.round(_subtotal * 0.18)
    property real _total: _subtotal + _gst

    function recomputeSubtotal() {
        var s = 0;
        for (var i = 0; i < products.count; ++i)
            s += products.get(i).price * products.get(i).quantity;
        _subtotal = s;
    }

    function _rebuildCatalog() {
        var cat = [];
        var names = [];
        for (var i = 0; i < InventoryStore.products.length; ++i) {
            var p = InventoryStore.products[i];
            cat.push({ name: p.name, price: p.price, productId: p.productId });
            names.push(p.name + " - " + InventoryStore.formatCurrency(p.price));
        }
        catalog = cat;
        catalogNames = names;
    }

    function openFor(id) {
        _rebuildCatalog();
        orderId = id;

        // Read orders array directly for AOT safety
        var allOrders = OrdersStore.orders;
        var o = null;
        for (var i = 0; i < allOrders.length; ++i) {
            if (allOrders[i].orderId === id) { o = allOrders[i]; break; }
        }
        if (!o) return;

        customerField.text = o.customer;
        emailField.text = o.email || "";
        phoneField.text = o.phone || "";
        statusCombo.currentIndex = ["pending","processing","completed"].indexOf(String(o.status));

        products.clear();
        // Restore saved products if available, otherwise synthesize from item count
        if (o.products && o.products.length > 0) {
            for (var j = 0; j < o.products.length; ++j) {
                products.append({ name: o.products[j].name, price: o.products[j].price, quantity: o.products[j].quantity });
            }
        } else {
            var itemCount = o.items;
            if (catalog.length >= 2 && itemCount >= 2) {
                var qty1 = Math.ceil(itemCount / 2);
                var qty2 = itemCount - qty1;
                products.append({ name: catalog[0].name, price: catalog[0].price, quantity: qty1 });
                if (qty2 > 0) products.append({ name: catalog[1].name, price: catalog[1].price, quantity: qty2 });
            } else if (catalog.length > 0) {
                products.append({ name: catalog[0].name, price: catalog[0].price, quantity: Math.max(1, itemCount) });
            }
        }
        recomputeSubtotal();
        productCombo.currentIndex = 0;
        flick.contentY = 0;
        dlg.open();
    }

    background: Rectangle { radius: 12; color: "#ffffff"; border.color: "#e5e7eb" }

    header: Item {
        implicitHeight: 64
        Column {
            anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter }
            spacing: 2
            Text { text: "Edit Order " + dlg.orderId; font.bold: true; font.pixelSize: 18; color: "#111827" }
            Text { text: "Update customer details and modify order items"; font.pixelSize: 12; color: "#6b7280" }
        }
        Button {
            anchors { right: parent.right; rightMargin: 12; top: parent.top; topMargin: 8 }
            width: 28; height: 28; padding: 0; flat: true
            contentItem: Text { text: "\u2715"; font.pixelSize: 16; color: "#6b7280"
                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            onClicked: dlg.close()
        }
    }

    contentItem: Flickable {
        id: flick
        clip: true
        contentHeight: mainCol.height + 20
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
            id: mainCol
            x: 20; y: 10
            width: flick.width - 40
            spacing: 16

            // ── Customer Information ──
            Column {
                width: mainCol.width; spacing: 4
                Text { text: "Customer Information"; color: "#c17817"; font.pixelSize: 15; font.bold: true }
                Rectangle { width: parent.width; height: 2; color: "#e8a050" }
            }

            Row {
                width: mainCol.width; spacing: 16
                Column {
                    width: (parent.width - 16) / 2; spacing: 4
                    Text { text: "Customer Name *"; color: "#111827"; font.pixelSize: 12; font.bold: true }
                    TextField {
                        id: customerField; width: parent.width; font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                    }
                }
                Column {
                    width: (parent.width - 16) / 2; spacing: 4
                    Text { text: "Email"; color: "#111827"; font.pixelSize: 12; font.bold: true }
                    TextField {
                        id: emailField; width: parent.width; font.pixelSize: 13
                        placeholderText: "john@example.com"
                        background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                    }
                }
            }

            Column {
                width: (mainCol.width - 16) / 2; spacing: 4
                Text { text: "Phone Number"; color: "#111827"; font.pixelSize: 12; font.bold: true }
                TextField {
                    id: phoneField; width: parent.width; font.pixelSize: 13
                    placeholderText: "+91 98765 43210"
                    background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                }
            }

            Row {
                width: mainCol.width; spacing: 16
                Column {
                    width: (parent.width - 16) / 2; spacing: 4
                    Text { text: "Order Status"; color: "#111827"; font.pixelSize: 12; font.bold: true }
                    ComboBox {
                        id: statusCombo; width: parent.width; height: 40
                        model: ["pending", "processing", "completed"]
                        font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                    }
                }
            }

            // ── Modify Products ──
            Column {
                width: mainCol.width; spacing: 4
                Text { text: "Modify Products"; color: "#c17817"; font.pixelSize: 15; font.bold: true }
                Rectangle { width: parent.width; height: 2; color: "#e8a050" }
            }

            Row {
                width: mainCol.width; spacing: 8
                ComboBox {
                    id: productCombo
                    width: parent.width - 48; height: 40
                    model: dlg.catalogNames
                    font.pixelSize: 13
                    background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                }
                Button {
                    width: 40; height: 40; padding: 0
                    background: Rectangle { radius: 20; color: "#e06c00" }
                    contentItem: Text { text: "+"; color: "white"; font.pixelSize: 20; font.bold: true
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    onClicked: {
                        var idx = productCombo.currentIndex;
                        if (idx < 0 || idx >= dlg.catalog.length) return;
                        var p = dlg.catalog[idx];
                        for (var i = 0; i < products.count; ++i) {
                            if (products.get(i).name === p.name) {
                                products.setProperty(i, "quantity", products.get(i).quantity + 1);
                                dlg.recomputeSubtotal();
                                return;
                            }
                        }
                        products.append({ name: p.name, price: p.price, quantity: 1 });
                        dlg.recomputeSubtotal();
                    }
                }
            }

            // Product table
            Rectangle {
                width: mainCol.width
                height: prodTableHeader.height + prodRows.height + 2
                radius: 8; border.color: "#e8a050"; color: "#ffffff"
                clip: true

                Column {
                    width: parent.width

                    Rectangle {
                        id: prodTableHeader
                        width: parent.width; height: 36; color: "#fff3e0"
                        radius: 8
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 8; color: "#fff3e0" }
                        Row {
                            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                            Text { width: parent.width * 0.30; text: "Product"; color: "#c17817"; font.pixelSize: 12; font.bold: true; verticalAlignment: Text.AlignVCenter; height: parent.height }
                            Text { width: parent.width * 0.18; text: "Price"; color: "#c17817"; font.pixelSize: 12; font.bold: true; verticalAlignment: Text.AlignVCenter; height: parent.height }
                            Text { width: parent.width * 0.18; text: "Quantity"; color: "#c17817"; font.pixelSize: 12; font.bold: true; verticalAlignment: Text.AlignVCenter; height: parent.height }
                            Text { width: parent.width * 0.20; text: "Total"; color: "#c17817"; font.pixelSize: 12; font.bold: true; verticalAlignment: Text.AlignVCenter; height: parent.height }
                            Text { width: parent.width * 0.14; text: "Action"; color: "#c17817"; font.pixelSize: 12; font.bold: true; verticalAlignment: Text.AlignVCenter; height: parent.height }
                        }
                    }

                    Column {
                        id: prodRows
                        width: parent.width
                        Repeater {
                            model: products
                            Rectangle {
                                id: prodRow
                                property int rowIdx: index
                                width: prodRows.width; height: 52
                                color: index % 2 === 0 ? "#ffffff" : "#fafafa"
                                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: "#f1f5f9" }
                                Row {
                                    anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                    Text { width: parent.width * 0.30; text: model.name; color: "#111827"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; height: parent.height; elide: Text.ElideRight }
                                    Text { width: parent.width * 0.18; text: OrdersStore.formatCurrency(model.price); color: "#111827"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; height: parent.height }
                                    Item {
                                        width: parent.width * 0.18; height: parent.height
                                        TextField {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 56; height: 28; font.pixelSize: 12
                                            horizontalAlignment: Text.AlignHCenter
                                            text: String(model.quantity)
                                            validator: IntValidator { bottom: 1; top: 999 }
                                            background: Rectangle { radius: 4; color: "#f3f4f6"; border.color: "#d1d5db" }
                                            onEditingFinished: {
                                                var val = parseInt(text);
                                                if (!isNaN(val) && val > 0) {
                                                    products.setProperty(prodRow.rowIdx, "quantity", val);
                                                    dlg.recomputeSubtotal();
                                                }
                                            }
                                        }
                                    }
                                    Text { width: parent.width * 0.20; text: OrdersStore.formatCurrency(model.price * model.quantity); color: "#111827"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; height: parent.height }
                                    Item {
                                        width: parent.width * 0.14; height: parent.height
                                        Button {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 28; height: 28; padding: 0; flat: true
                                            contentItem: Text { text: "\uD83D\uDDD1\uFE0F"; font.pixelSize: 14
                                                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                            onClicked: { products.remove(prodRow.rowIdx); dlg.recomputeSubtotal(); }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── Order Summary ──
            Column {
                width: mainCol.width; spacing: 4
                Text { text: "Order Summary"; color: "#c17817"; font.pixelSize: 15; font.bold: true }
                Rectangle { width: parent.width; height: 2; color: "#e8a050" }
            }

            Rectangle {
                width: mainCol.width; height: summaryCol.height + 24
                radius: 8; color: "#fff8f0"; border.color: "#e8a050"
                Column {
                    id: summaryCol
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                    spacing: 8
                    Row {
                        width: parent.width
                        Text { text: "Subtotal:"; color: "#111827"; font.pixelSize: 13; width: parent.width * 0.6 }
                        Text { text: OrdersStore.formatCurrency(dlg._subtotal); color: "#111827"; font.pixelSize: 13; font.bold: true; width: parent.width * 0.4; horizontalAlignment: Text.AlignRight }
                    }
                    Row {
                        width: parent.width
                        Text { text: "GST (18%):"; color: "#111827"; font.pixelSize: 13; width: parent.width * 0.6 }
                        Text { text: OrdersStore.formatCurrency(dlg._gst); color: "#111827"; font.pixelSize: 13; font.bold: true; width: parent.width * 0.4; horizontalAlignment: Text.AlignRight }
                    }
                    Rectangle { width: parent.width; height: 1; color: "#e8a050" }
                    Row {
                        width: parent.width
                        Text { text: "Total:"; color: "#c17817"; font.pixelSize: 14; font.bold: true; width: parent.width * 0.6 }
                        Text { text: OrdersStore.formatCurrency(dlg._total); color: "#c17817"; font.pixelSize: 14; font.bold: true; width: parent.width * 0.4; horizontalAlignment: Text.AlignRight }
                    }
                }
            }
        }
    }

    footer: Item {
        implicitHeight: 56
        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: "#e5e7eb" }
        Row {
            anchors { right: parent.right; rightMargin: 20; verticalCenter: parent.verticalCenter }
            spacing: 12
            Button {
                height: 36; padding: 12
                background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                contentItem: Text { text: "Cancel"; font.pixelSize: 13; color: "#374151"
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                onClicked: dlg.close()
            }
            Button {
                height: 36; padding: 12
                background: Rectangle { radius: 8; color: "#d35400" }
                contentItem: Text { text: "Update Order"; font.pixelSize: 13; font.bold: true; color: "#ffffff"
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                onClicked: {
                    var itemCount = 0;
                    var prods = [];
                    for (var i = 0; i < products.count; ++i) {
                        var p = products.get(i);
                        itemCount += p.quantity;
                        prods.push({ name: p.name, price: p.price, quantity: p.quantity });
                    }
                    OrdersStore.updateOrder(dlg.orderId, {
                        customer: customerField.text,
                        email: emailField.text,
                        phone: phoneField.text,
                        status: "pending",
                        items: itemCount,
                        total: dlg._total,
                        products: prods
                    });
                    dlg.orderUpdated(dlg.orderId);
                    dlg.close();
                }
            }
        }
    }
}
