
import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

Dialog {
    id: dlg
    title: "Create New Order"
    modal: true
    width: Math.min(520, parent ? parent.width - 24 : 520)
    height: Math.min(580, parent ? parent.height - 40 : 580)
    anchors.centerIn: parent
    padding: 0
    standardButtons: Dialog.NoButton

    signal orderCreated(var order)

    property var selectedProducts: []
    property var productNames: []

    onOpened: {
        // Rebuild product list from InventoryStore each time dialog opens
        var names = [];
        for (var i = 0; i < InventoryStore.products.length; ++i) {
            var p = InventoryStore.products[i];
            names.push(p.name + " - " + InventoryStore.formatCurrency(p.price) + " (Stock: " + p.stock + ")");
        }
        productNames = names;
        productCombo.currentIndex = 0;
    }

    function trySubmit() {
        var errs = [];
        if (!customerField.text || customerField.text.length < 2) errs.push("Enter a valid customer name");
        if (selectedProducts.length === 0) errs.push("Add at least one product");
        // Validate stock availability
        for (var k = 0; k < selectedProducts.length; ++k) {
            var sp = selectedProducts[k];
            var inv = InventoryStore.getById(sp.productId);
            if (inv && sp.qty > inv.stock) {
                errs.push(sp.name + ": only " + inv.stock + " in stock, ordered " + sp.qty);
            }
        }
        if (errs.length > 0) { errorLabel.text = errs.join(" · "); errorLabel.visible = true; return; }
        errorLabel.visible = false;

        var totalItems = 0; var totalAmount = 0;
        var prods = [];
        for (var i = 0; i < selectedProducts.length; ++i) {
            totalItems += selectedProducts[i].qty;
            totalAmount += selectedProducts[i].qty * selectedProducts[i].price;
            prods.push({ productId: selectedProducts[i].productId, name: selectedProducts[i].name,
                         qty: selectedProducts[i].qty, price: selectedProducts[i].price });
        }

        orderCreated({ customer: customerField.text, items: totalItems, total: totalAmount, status: "pending", date: new Date(),
            email: emailField.text, phone: phoneField.text, products: prods });
        customerField.text = ""; emailField.text = ""; phoneField.text = "";
        selectedProducts = []; productCombo.currentIndex = 0;
        dlg.close();
    }

    function addSelectedProduct() {
        var idx = productCombo.currentIndex;
        if (idx < 0 || idx >= InventoryStore.products.length) return;
        var p = InventoryStore.products[idx];
        if (p.stock <= 0) return; // out of stock
        var arr = [];
        for (var i = 0; i < selectedProducts.length; ++i)
            arr.push({ name: selectedProducts[i].name, qty: selectedProducts[i].qty, price: selectedProducts[i].price, productId: selectedProducts[i].productId });
        // check duplicate — cap at available stock
        for (var j = 0; j < arr.length; ++j) {
            if (arr[j].productId === p.productId) {
                if (arr[j].qty >= p.stock) return; // already at max
                arr[j].qty++;
                selectedProducts = arr;
                return;
            }
        }
        arr.push({ name: p.name, qty: 1, price: p.price, productId: p.productId });
        selectedProducts = arr;
    }

    function removeProduct(idx) {
        var arr = [];
        for (var i = 0; i < selectedProducts.length; ++i)
            if (i !== idx) arr.push({ name: selectedProducts[i].name, qty: selectedProducts[i].qty, price: selectedProducts[i].price, productId: selectedProducts[i].productId });
        selectedProducts = arr;
    }

    contentItem: Flickable {
        clip: true
        contentHeight: formCol.height + 32
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
            id: formCol
            x: 24; y: 16; width: parent.width - 48; spacing: 8

            Label { text: "Create New Order"; font.pixelSize: 18; font.bold: true; color: "#111827" }
            Label { text: "Add customer details and select products to create a new order"; font.pixelSize: 12; color: "#6b7280" }
            Item { width: 1; height: 8 }

            // Section: Customer Information
            Label { text: "Customer Information"; font.pixelSize: 14; font.bold: true; color: "#b45309" }
            Rectangle { width: formCol.width; height: 2; color: "#fdba74" }
            Item { width: 1; height: 4 }

            Row { spacing: 12; width: formCol.width
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Customer Name *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    TextField { id: customerField; width: parent.width; placeholderText: "Enter customer name"; font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                }
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Email"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    TextField { id: emailField; width: parent.width; placeholderText: "customer@example.com"; font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                }
            }

            Column { spacing: 4
                Label { text: "Phone Number"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                TextField { id: phoneField; width: (formCol.width - 12) / 2; placeholderText: "+91 XXXXX XXXXX"; font.pixelSize: 13
                    background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
            }

            Item { width: 1; height: 8 }

            // Section: Add Products
            Label { text: "Add Products"; font.pixelSize: 14; font.bold: true; color: "#b45309" }
            Rectangle { width: formCol.width; height: 2; color: "#fdba74" }
            Item { width: 1; height: 4 }

            Row { spacing: 8; width: formCol.width
                ComboBox {
                    id: productCombo; width: parent.width - 52
                    model: dlg.productNames
                    font.pixelSize: 13
                    background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" }
                }
                Button {
                    width: 44; height: 36
                    onClicked: dlg.addSelectedProduct()
                    background: Rectangle { radius: 22; color: "#f97316" }
                    contentItem: Text { text: "+"; font.pixelSize: 20; font.bold: true; color: "white"
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
            }

            // Selected products list
            Repeater {
                model: dlg.selectedProducts
                Rectangle {
                    width: formCol.width; height: 36; radius: 6; color: "#fff7ed"; border.color: "#fdba74"
                    Row { x: 8; anchors.verticalCenter: parent.verticalCenter; spacing: 8; width: parent.width - 16
                        Label { text: modelData.name; font.pixelSize: 12; color: "#374151"; width: parent.width - 180; elide: Text.ElideRight }
                        Label { text: "x" + modelData.qty + "/" + (InventoryStore.getById(modelData.productId) ? InventoryStore.getById(modelData.productId).stock : "?"); font.pixelSize: 12; font.bold: true; color: modelData.qty > (InventoryStore.getById(modelData.productId) ? InventoryStore.getById(modelData.productId).stock : 999) ? "#ef4444" : "#b45309" }
                        Label { text: InventoryStore.formatCurrency(modelData.qty * modelData.price); font.pixelSize: 12; color: "#374151" }
                        Text {
                            text: "✕"; font.pixelSize: 14; color: "#ef4444"
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: dlg.removeProduct(index) }
                        }
                    }
                }
            }

            Label { id: errorLabel; visible: false; color: "#ef4444"; text: ""; wrapMode: Text.Wrap; width: formCol.width }
            Item { width: 1; height: 8 }
        }
    }

    footer: Item {
        implicitHeight: 52
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 2; color: "#fdba74"
        }
        Row {
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
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
                background: Rectangle { radius: 8; color: "#f97316" }
                contentItem: Text { text: "Create Order"; font.pixelSize: 13; font.bold: true; color: "#ffffff"
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                onClicked: dlg.trySubmit()
            }
        }
    }
}
