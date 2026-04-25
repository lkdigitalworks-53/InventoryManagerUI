import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

Dialog {
    id: dlg
    title: "Add New Product"
    modal: true
    width: Math.min(520, parent ? parent.width - 24 : 520)
    height: Math.min(600, parent ? parent.height - 40 : 600)
    anchors.centerIn: parent
    padding: 0
    standardButtons: Dialog.NoButton

    signal productCreated()

    function trySubmit() {
        var errs = [];
        if (!nameField.text || nameField.text.length < 2) errs.push("Enter a valid product name");
        if (!skuField.text) errs.push("Enter or generate a SKU");
        if (categoryCombo.currentIndex < 0) errs.push("Select a category");
        var p = parseFloat(priceField.text);
        if (isNaN(p) || p <= 0) errs.push("Enter a valid price");
        var s = parseInt(stockField.text);
        if (isNaN(s) || s < 0) errs.push("Enter valid stock");
        var ms = parseInt(minStockField.text);
        if (isNaN(ms) || ms < 0) errs.push("Enter valid minimum stock");
        if (errs.length > 0) { errorLabel.text = errs.join(" · "); errorLabel.visible = true; return; }
        errorLabel.visible = false;

        InventoryStore.addProduct(nameField.text, skuField.text, categoryCombo.currentText,
            descField.text, p, unitCombo.currentText, s, ms);
        nameField.text = ""; skuField.text = ""; descField.text = "";
        priceField.text = "0.00"; stockField.text = "0"; minStockField.text = "0";
        categoryCombo.currentIndex = 0; unitCombo.currentIndex = 0;
        productCreated();
        dlg.close();
    }

    contentItem: Flickable {
        clip: true
        contentHeight: formCol.height + 32
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
            id: formCol
            x: 24; y: 16; width: parent.width - 48; spacing: 8

            Label { text: "Add New Product"; font.pixelSize: 18; font.bold: true; color: "#111827" }
            Label { text: "Add a new product to your inventory with details and stock information"; font.pixelSize: 12; color: "#6b7280" }
            Item { width: 1; height: 8 }

            // Section: Product Information
            Label { text: "Product Information"; font.pixelSize: 14; font.bold: true; color: "#16a34a" }
            Rectangle { width: formCol.width; height: 2; color: "#86efac" }
            Item { width: 1; height: 4 }

            Label { text: "Product Name *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
            TextField { id: nameField; width: formCol.width; placeholderText: "Enter product name"; font.pixelSize: 13
                background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }

            Row { spacing: 12; width: formCol.width
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "SKU *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    Row { spacing: 8; width: parent.width
                        TextField { id: skuField; width: parent.width - 88; placeholderText: "Product SKU"; font.pixelSize: 13
                            background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                        Button {
                            text: "Generate"; width: 80; height: 36
                            onClicked: skuField.text = InventoryStore.generateSku(nameField.text)
                            background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                            contentItem: Text { text: "Generate"; color: "#374151"; font.pixelSize: 12
                                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        }
                    }
                }
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Category *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    ComboBox { id: categoryCombo; width: parent.width; model: ["Electronics", "Accessories", "Office", "Furniture", "Other"]
                        font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                }
            }

            Label { text: "Description"; font.pixelSize: 12; font.bold: true; color: "#374151" }
            ScrollView {
                width: formCol.width; height: 80
                TextArea { id: descField; placeholderText: "Enter product description"; font.pixelSize: 13; wrapMode: TextEdit.Wrap
                    background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
            }

            Item { width: 1; height: 8 }

            // Section: Pricing & Stock
            Label { text: "Pricing & Stock"; font.pixelSize: 14; font.bold: true; color: "#16a34a" }
            Rectangle { width: formCol.width; height: 2; color: "#86efac" }
            Item { width: 1; height: 4 }

            Row { spacing: 12; width: formCol.width
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Price (₹) *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    TextField { id: priceField; width: parent.width; text: "0.00"; font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                }
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Measurement Unit"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    ComboBox { id: unitCombo; width: parent.width; model: ["Units (pcs)", "Kg", "Litres", "Metres"]
                        font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                }
            }

            Row { spacing: 12; width: formCol.width
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Current Stock *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    TextField { id: stockField; width: parent.width; text: "0"; font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                }
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Minimum Stock Level *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    TextField { id: minStockField; width: parent.width; text: "0"; font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
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
            height: 2; color: "#86efac"
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
                background: Rectangle { radius: 8; color: "#22c55e" }
                contentItem: Text { text: "Add Product"; font.pixelSize: 13; font.bold: true; color: "#ffffff"
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                onClicked: dlg.trySubmit()
            }
        }
    }
}
