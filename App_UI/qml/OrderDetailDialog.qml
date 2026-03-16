
import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

Dialog {
    id: dlg
    title: "Order Details"
    modal: true
    width: Math.min(420, parent ? parent.width - 24 : 420)
    height: Math.min(parent ? parent.height - 24 : 640, contentItem.implicitHeight)
    standardButtons: Dialog.Ok | Dialog.Cancel

    property string orderId: ""
    property int index: -1

    function openFor(id) {
        orderId = id; index = OrdersStore.findIndexById(id)
        if (index >= 0) {
            var o = OrdersStore.get(index)
            customerField.text = o.customer
            itemsField.text    = String(o.items)
            totalField.text    = String(OrdersStore.formatCurrency(o.total))
            statusCombo.currentIndex = ["pending","processing","completed"].indexOf(String(o.status))
            dateField.text     = String(o.date)
            notesField.text    = o.notes || ""
        }
        dlg.open()
    }

    contentItem: ScrollView {
        clip: true
        ScrollBar.vertical: ScrollBar {}
        ColumnLayout { spacing: 10; padding: 0; anchors.margins: 16; width: parent.availableWidth
            Label { text: orderId; font.bold: true; font.pixelSize: 14 }
            TextField { id: customerField; Layout.fillWidth: true; readOnly: true; placeholderText: "Customer" }
            TextField { id: itemsField;    Layout.fillWidth: true; readOnly: true; placeholderText: "Items" }
            TextField { id: totalField;    Layout.fillWidth: true; readOnly: true; placeholderText: "Total" }
            ComboBox  { id: statusCombo;   Layout.fillWidth: true; model: ["pending","processing","completed"] }
            TextField { id: dateField;     Layout.fillWidth: true; readOnly: true; placeholderText: "Date" }
            TextArea  { id: notesField;    Layout.fillWidth: true; Layout.preferredHeight: 100; placeholderText: "Notes" }
        }
    }
}
