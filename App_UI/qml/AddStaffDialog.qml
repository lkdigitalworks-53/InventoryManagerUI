import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

Dialog {
    id: dlg
    title: "Add New Staff Member"
    modal: true
    width: Math.min(520, parent ? parent.width - 24 : 520)
    height: Math.min(600, parent ? parent.height - 40 : 600)
    anchors.centerIn: parent
    padding: 0
    standardButtons: Dialog.NoButton

    signal staffCreated()

    function trySubmit() {
        var errs = [];
        if (!nameField.text || nameField.text.length < 2) errs.push("Enter a valid name");
        if (!emailField.text || emailField.text.indexOf("@") < 0) errs.push("Enter a valid email");
        if (!phoneField.text) errs.push("Enter a phone number");
        if (!roleField.text) errs.push("Enter a job role");
        if (deptCombo.currentIndex < 0) errs.push("Select a department");
        if (errs.length > 0) { errorLabel.text = errs.join(" · "); errorLabel.visible = true; return; }
        errorLabel.visible = false;

        var sal = parseInt(salaryField.text);
        if (isNaN(sal)) sal = 0;

        StaffStore.addStaff(nameField.text, emailField.text, phoneField.text,
            roleField.text, deptCombo.currentText, joinPicker.date, statusCombo.currentText.toLowerCase().replace(" ", "_"), sal);

        nameField.text = ""; emailField.text = ""; phoneField.text = "";
        roleField.text = ""; salaryField.text = "50000";
        deptCombo.currentIndex = 0; statusCombo.currentIndex = 0;
        joinPicker.date = new Date();
        staffCreated();
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

            Label { text: "Add New Staff Member"; font.pixelSize: 18; font.bold: true; color: "#111827" }
            Label { text: "Add a new team member to your organization"; font.pixelSize: 12; color: "#6b7280" }
            Item { width: 1; height: 8 }

            // Section: Personal Information
            Label { text: "Personal Information"; font.pixelSize: 14; font.bold: true; color: "#7c3aed" }
            Rectangle { width: formCol.width; height: 2; color: "#c4b5fd" }
            Item { width: 1; height: 4 }

            Label { text: "Full Name *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
            TextField { id: nameField; width: formCol.width; placeholderText: "Enter full name"; font.pixelSize: 13
                background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }

            Row { spacing: 12; width: formCol.width
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Email Address *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    TextField { id: emailField; width: parent.width; placeholderText: "employee@company.com"; font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                }
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Phone Number *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    TextField { id: phoneField; width: parent.width; placeholderText: "+91 98765 43210"; font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                }
            }

            Item { width: 1; height: 8 }

            // Section: Job Information
            Label { text: "Job Information"; font.pixelSize: 14; font.bold: true; color: "#7c3aed" }
            Rectangle { width: formCol.width; height: 2; color: "#c4b5fd" }
            Item { width: 1; height: 4 }

            Row { spacing: 12; width: formCol.width
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Job Role *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    TextField { id: roleField; width: parent.width; placeholderText: "e.g., Sales Manager"; font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                }
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Department *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    ComboBox { id: deptCombo; width: parent.width; model: ["Operations", "Sales", "Warehouse", "Support", "Finance", "Marketing"]
                        font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                }
            }

            Row { spacing: 12; width: formCol.width
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Join Date *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    Row { spacing: 6; width: parent.width
                        TextField { id: joinDateField; width: parent.width - 46; readOnly: true; font.pixelSize: 13
                            text: Qt.formatDate(joinPicker.date, "dd/MM/yyyy")
                            background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                        Button { text: "📅"; width: 40; height: 36; onClicked: joinPicker.open()
                            background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                        InlineDatePicker { id: joinPicker; onAccepted: function(d) { joinDateField.text = Qt.formatDate(d, "dd/MM/yyyy"); } }
                    }
                }
                Column { width: (formCol.width - 12) / 2; spacing: 4
                    Label { text: "Employment Status *"; font.pixelSize: 12; font.bold: true; color: "#374151" }
                    ComboBox { id: statusCombo; width: parent.width; model: ["Active", "On Leave"]
                        font.pixelSize: 13
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }
                }
            }

            Label { text: "Salary (₹)"; font.pixelSize: 12; font.bold: true; color: "#374151" }
            TextField { id: salaryField; width: formCol.width; text: "50000"; font.pixelSize: 13
                background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#d1d5db" } }

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
            height: 2; color: "#c4b5fd"
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
                background: Rectangle { radius: 8; color: "#8b5cf6" }
                contentItem: Text { text: "Add Staff Member"; font.pixelSize: 13; font.bold: true; color: "#ffffff"
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                onClicked: dlg.trySubmit()
            }
        }
    }
}
