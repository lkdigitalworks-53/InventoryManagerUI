import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Staff detail / edit — bottom sheet. Public contract preserved:
//   signal staffUpdateRequested(staffId, fields)
//   function openFor(id, startInEdit)
//   property string staffId
//   property bool editMode
BottomSheet {
    id: root

    sheetTitle: editMode ? "Edit staff member" : "Staff profile"
    primaryAction: editMode ? "Save changes" : (AuthStore.canManageStaff ? "Edit" : "")
    secondaryAction: editMode ? "Cancel" : "Close"
    primaryPalette: editMode ? Constants.gradHero : ({ start: Constants.brand1, end: Constants.brand2 })

    signal staffUpdateRequested(string staffId, var fields)

    property string staffId: ""
    property bool editMode: false
    property bool _populating: false

    // Component 2 (async-write-sequencing design §4/§7.1). Same shape as
    // EditProductDialog — acquired entering edit mode, released leaving it.
    // "error" (added 2026-07-29, real bug report) distinguishes "couldn't
    // get a real answer" from "denied" — a genuine other holder.
    property string _lockState: "pending" // "pending" | "granted" | "denied" | "error"
    property var _lockHolder: null

    function _enterEditMode() {
        editMode = true
        _lockState = "pending"
        _lockHolder = null
        var lockedStaffId = staffId
        LockManager.acquire("staff", staffId, function(result) {
            if (root.staffId !== lockedStaffId) return
            _lockState = result.granted ? "granted" : result.reason
            _lockHolder = result.holder
            if (!result.granted) {
                errorText.text = result.reason === "denied"
                    ? (result.holder && result.holder.name
                        ? qsTr("%1 is currently editing this profile — try again shortly").arg(result.holder.name)
                        : qsTr("This profile is currently being edited elsewhere — try again shortly"))
                    : qsTr("Couldn't confirm this profile is free to edit (connection issue) — try again")
            }
        })
    }

    function openFor(id, startInEdit) {
        if (editMode) LockManager.release("staff", staffId)
        staffId = id
        editMode = false
        _lockState = "pending"
        _lockHolder = null
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
        if (startInEdit) _enterEditMode()
        open()
    }

    onPrimaryClicked: {
        if (!editMode) { _enterEditMode() }
        else _submit()
    }
    onSecondaryClicked: {
        if (editMode) {
            // Discard edits — repopulate from store and switch out of edit mode.
            openFor(staffId, false)
        }
    }
    onClosed: {
        if (editMode) LockManager.release("staff", staffId)
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        // Header card with avatar + name + role
        Rectangle {
            Layout.fillWidth: true
            radius: dp(Constants.radius)
            color: Qt.rgba(0.39, 0.40, 0.95, 0.06)
            border.color: Constants.borderColor
            border.width: 1
            Layout.preferredHeight: hdr.implicitHeight + dp(Constants.space4 * 2)

            RowLayout {
                id: hdr
                anchors.fill: parent
                anchors.margins: dp(Constants.space3)
                spacing: dp(Constants.space3)

                AvatarBadge {
                    size: "lg"
                    label: StaffStore.initials(nameField.text)
                    palette: Constants.grad2
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: dp(2)
                    Text {
                        text: nameField.text || "(unnamed)"
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBodyLg)
                        font.bold: true
                    }
                    Text {
                        text: (roleField.text || "—") + " · " + (deptField.text || "—")
                        color: Constants.textSecondary
                        font.pixelSize: sp(Constants.fsCaption)
                    }
                    Text {
                        text: "ID: " + root.staffId
                        color: Constants.textMuted
                        font.pixelSize: sp(Constants.fsCaption)
                    }
                }
            }
        }

        // Personal
        Text {
            text: "Personal"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        AuthTextField {
            id: nameField
            Layout.fillWidth: true
            label: "Full name"
            readOnly: !root.editMode
        }
        AuthTextField {
            id: emailField
            Layout.fillWidth: true
            label: "Email"
            readOnly: !root.editMode
            inputMethodHints: Qt.ImhEmailCharactersOnly
        }
        AuthTextField {
            id: phoneField
            Layout.fillWidth: true
            label: "Phone"
            readOnly: !root.editMode
        }

        // Job
        Text {
            text: "Job"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AuthTextField {
                id: roleField
                Layout.fillWidth: true
                label: "Role"
                readOnly: !root.editMode
            }
            AuthTextField {
                id: deptField
                Layout.fillWidth: true
                label: "Department"
                readOnly: !root.editMode
            }
        }

        AuthTextField {
            id: joinField
            Layout.fillWidth: true
            label: "Joined"
            readOnly: true
            placeholderText: "yyyy-MM-dd"
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AuthTextField {
                id: salaryField
                Layout.fillWidth: true
                label: "Salary (₹)"
                readOnly: !root.editMode
                inputMethodHints: Qt.ImhDigitsOnly
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
                    model: ["Active", "On Leave", "Suspended"]
                    enabled: root.editMode
                    font.pixelSize: sp(Constants.fsBody)
                }
            }
        }

        Text {
            id: errorText
            Layout.fillWidth: true
            visible: text.length > 0
            color: Constants.danger
            font.pixelSize: sp(Constants.fsSmall)
            wrapMode: Text.Wrap
        }
    }

    function _submit() {
        if (_lockState !== "granted") {
            if (_lockState === "denied") {
                errorText.text = _lockHolder && _lockHolder.name
                    ? qsTr("%1 is currently editing this profile — try again shortly").arg(_lockHolder.name)
                    : qsTr("This profile is currently being edited elsewhere — try again shortly")
            } else if (_lockState === "error") {
                errorText.text = qsTr("Couldn't confirm this profile is free to edit (connection issue) — try again")
            } else {
                errorText.text = qsTr("Still confirming this profile is free to edit — try again in a moment")
            }
            return
        }
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
        LockManager.release("staff", staffId)
        editMode = false
        close()
    }
}
