
import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

Dialog {
    id: dlg
    title: "New Order"
    modal: true
    width: Math.min(420, parent ? parent.width - 24 : 420)
    height: Math.min(parent ? parent.height - 24 : 640, contentItem.implicitHeight)
    standardButtons: Dialog.Ok | Dialog.Cancel

    property alias customer: customerField.text
    property int items: itemsField.value
    property alias total: totalField.text
    property string status: statusCombo.currentText
    property date date: picker.date

    signal orderCreated(var order)

    function isFuture(d) {
        var today = new Date(); today.setHours(0,0,0,0);
        var dd = new Date(d); dd.setHours(0,0,0,0);
        return dd.getTime() > today.getTime();
    }

    contentItem: ScrollView {
        clip: true
        ScrollBar.vertical: ScrollBar {}
        ColumnLayout {
            id: form
            width: parent.availableWidth
            spacing: 10; padding: 0
            anchors.margins: 16

            TextField { id: customerField; Layout.fillWidth: true; placeholderText: "Customer name" }
            SpinBox   { id: itemsField;    Layout.fillWidth: true; from: 1; to: 1000; value: 1 }
            TextField { id: totalField;    Layout.fillWidth: true; placeholderText: "Total (amount)" }
            ComboBox  { id: statusCombo;   Layout.fillWidth: true; model: ["pending", "processing", "completed"] }
            RowLayout {
                Layout.fillWidth: true; spacing: 6
                TextField { id: dateFieldInput; Layout.fillWidth: true; readOnly: true; placeholderText: "Date"; text: Qt.formatDate(picker.date, "yyyy-MM-dd") }
                Button { text: "Pick"; onClicked: picker.open() }
                InlineDatePicker { id: picker; onAccepted: function(d){ dateFieldInput.text = Qt.formatDate(d, "yyyy-MM-dd"); } }
            }
            Label { id: errorLabel; visible: false; color: "#ef4444"; text: "" }
        }
    }

    onAccepted: {
        var errs = []
        if (!customerField.text || customerField.text.length < 2) errs.push("Enter a valid customer name")
        if (itemsField.value < 1) errs.push("Items must be ≥ 1")
        var amount = OrdersStore.parseCurrency(totalField.text)
        if (amount <= 0) errs.push("Enter a valid total amount")
        if (isFuture(picker.date)) errs.push("Date cannot be in the future")
        if (errs.length > 0) { errorLabel.text = errs.join(" · "); errorLabel.visible = true; return }
        errorLabel.visible = false
        orderCreated({ customer: customerField.text, items: itemsField.value, total: amount, status: statusCombo.currentText, date: picker.date })
        customerField.text = ""; itemsField.value = 1; totalField.text = ""; statusCombo.currentIndex = 0; picker.date = new Date();
    }
}
