import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../model"
import "../helper"

QQC.Dialog {
    id: root

    signal staffUpdateRequested(string staffId, var fields)

    modal: true
    title: editMode ? "Edit Staff Member" : "Staff Profile"
    anchors.centerIn: parent
    width: Math.min(parent ? parent.width - 40 : 540, 540)
    padding: 20

    property string staffId: ""
    property bool editMode: false
    property bool _populating: false

    function openFor(id, startInEdit) {
        staffId = id
        editMode = !!startInEdit
        var s = StaffStore.getById(id)
        _populating = true
        if (s) {
            nameField.text       = s.name || ""
            emailField.text      = s.email || ""
            phoneField.text      = s.phone || ""
            roleField.text       = s.role || ""
            deptField.text       = s.department || ""
            joinField.text       = s.joinDate || ""
            salaryField.text     = (s.salary !== undefined && s.salary !== null) ? String(s.salary) : ""
            statusCombo.currentIndex = s.status === "on_leave" ? 1 : (s.status === "suspended" ? 2 : 0)
        }
        errorText.text = ""
        _populating = false
        open()
    }

    background: Rectangle {
        radius: 12
        color: "#ffffff"
        border.color: Constants.borderColor
    }

    contentItem: ColumnLayout {
        spacing: 12

        // Header strip with avatar + name
        Rectangle {
            Layout.fillWidth: true
            radius: 10
            color: "#f9fafb"
            border.color: "#e5e7eb"
            implicitHeight: hdr.implicitHeight + 20

            RowLayout {
                id: hdr
                anchors.fill: parent
                anchors.margins: 10
                spacing: 12

                Rectangle {
                    width: 48; height: 48; radius: 24
                    color: "#ede9fe"
                    QQC.Label {
                        anchors.centerIn: parent
                        text: StaffStore.initials(nameField.text)
                        color: "#7c3aed"
                        font.pixelSize: 16
                        font.bold: true
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    QQC.Label {
                        text: nameField.text || "(unnamed)"
                        font.bold: true
                        font.pixelSize: 14
                        color: "#111827"
                    }
                    QQC.Label {
                        text: (roleField.text || "—") + " • " + (deptField.text || "—")
                        font.pixelSize: 11
                        color: "#6b7280"
                    }
                    QQC.Label {
                        text: "ID: " + root.staffId
                        font.pixelSize: 10
                        color: "#9ca3af"
                    }
                }
            }
        }

        // Personal
        QQC.Label { text: "Personal Information"; font.bold: true; font.pixelSize: 13; color: "#374151"; Layout.topMargin: 4 }

        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Full Name"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
            QQC.TextField { id: nameField; Layout.fillWidth: true; readOnly: !root.editMode }
        }
        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Email"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
            QQC.TextField { id: emailField; Layout.fillWidth: true; readOnly: !root.editMode }
        }
        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Phone"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
            QQC.TextField { id: phoneField; Layout.fillWidth: true; readOnly: !root.editMode }
        }

        // Job
        QQC.Label { text: "Job Information"; font.bold: true; font.pixelSize: 13; color: "#374151"; Layout.topMargin: 8 }

        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Role"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
            QQC.TextField { id: roleField; Layout.fillWidth: true; readOnly: !root.editMode }
        }
        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Department"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
            QQC.TextField { id: deptField; Layout.fillWidth: true; readOnly: !root.editMode }
        }
        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Join Date"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
            QQC.TextField { id: joinField; Layout.fillWidth: true; readOnly: true; opacity: 0.7; placeholderText: "yyyy-MM-dd" }
        }
        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Salary (₹)"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
            QQC.TextField { id: salaryField; Layout.fillWidth: true; readOnly: !root.editMode; inputMethodHints: Qt.ImhDigitsOnly }
        }
        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Status"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 110 }
            QQC.ComboBox {
                id: statusCombo
                Layout.fillWidth: true
                model: ["Active", "On Leave", "Suspended"]
                enabled: root.editMode
            }
        }

        QQC.Label {
            id: errorText
            Layout.fillWidth: true
            visible: text.length > 0
            color: "#b91c1c"
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 8

            QQC.Button {
                text: "Close"
                visible: !root.editMode
                Layout.fillWidth: true
                onClicked: root.close()
            }

            QQC.Button {
                text: "Edit"
                visible: !root.editMode && AuthStore.canManageStaff
                Layout.fillWidth: true
                background: Rectangle { radius: 8; color: Constants.primaryBlue }
                contentItem: Text {
                    text: "Edit"
                    color: "#ffffff"
                    font.bold: true
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: root.editMode = true
            }

            QQC.Button {
                text: "Cancel"
                visible: root.editMode
                Layout.fillWidth: true
                onClicked: {
                    // Re-pull values from store (discard edits)
                    root.openFor(root.staffId, false)
                    root.editMode = false
                }
            }

            QQC.Button {
                text: "Save"
                visible: root.editMode
                Layout.fillWidth: true
                background: Rectangle { radius: 8; color: Constants.primaryBlue }
                contentItem: Text {
                    text: "Save"
                    color: "#ffffff"
                    font.bold: true
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: root._submit()
            }
        }
    }

    function _submit() {
        var errs = []
        if (!nameField.text || nameField.text.trim().length < 2) errs.push("Enter a valid name")
        if (!emailField.text || emailField.text.indexOf("@") < 0) errs.push("Enter a valid email")
        if (!roleField.text || roleField.text.trim().length === 0) errs.push("Enter a role")
        if (!deptField.text || deptField.text.trim().length === 0) errs.push("Enter a department")
        if (errs.length > 0) {
            errorText.text = errs.join(" · ")
            return
        }
        var sal = parseInt(salaryField.text)
        if (isNaN(sal)) sal = 0

        var statusVal = "active"
        if (statusCombo.currentIndex === 1) statusVal = "on_leave"
        else if (statusCombo.currentIndex === 2) statusVal = "suspended"

        staffUpdateRequested(root.staffId, {
            name: nameField.text.trim(),
            email: emailField.text.trim(),
            phone: phoneField.text.trim(),
            role: roleField.text.trim(),
            department: deptField.text.trim(),
            salary: sal,
            status: statusVal
        })
        errorText.text = ""
        root.editMode = false
        root.close()
    }
}
