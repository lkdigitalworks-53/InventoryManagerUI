import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Add Staff bottom sheet — preserves Job Information, Join Date, optional
// app-login provisioning. Public contract: signal staffCreated(payload).
BottomSheet {
    id: dlg

    sheetTitle: "Add staff member"
    primaryAction: "Save"
    secondaryAction: "Cancel"
    primaryPalette: ({ start: Constants.brand2, end: Constants.brand3 })

    signal staffCreated(var payload)

    // True while an async login-credential provision is in flight. While set,
    // the dialog stays open + busy and listens for the AuthService result so a
    // failure (weak password, email exists, write denied) is shown instead of
    // silently closing.
    property bool _provisioning: false

    onOpened: {
        nameField.text = ""; emailField.text = ""; phoneField.text = ""
        roleField.text = ""; salaryField.text = ""
        loginPasswordField.text = ""
        appRoleCombo.currentIndex = 0; deptCombo.currentIndex = 0; statusCombo.currentIndex = 0
        joinPicker.date = new Date()
        errorLabel.text = ""
        _provisioning = false
        busy = false
    }

    onPrimaryClicked: { if (!busy) trySubmit() }

    // Result of the async staff-credential provision (only while _provisioning).
    Connections {
        target: AuthService
        enabled: dlg._provisioning
        function onMemberOperationSucceeded(message) {
            dlg._provisioning = false
            dlg.busy = false
            Toast.show("Staff added")
            dlg.close()
        }
        function onAuthFailed(reason) {
            dlg._provisioning = false
            dlg.busy = false
            errorLabel.text = reason || "Could not create staff login"
        }
    }

    // addStaff's id-minting step is a real network round-trip now (an atomic
    // Firestore counter, not a local computation) — it can fail (offline,
    // etc.) before AuthService.provisionStaffCredentials is ever reached, in
    // which case the AuthService Connections above never fires. Without this,
    // the sheet would stay stuck open + busy on that failure with no way for
    // the user to dismiss it or retry.
    Connections {
        target: logic
        enabled: dlg._provisioning
        function onErrorOccurred(context, message) {
            dlg._provisioning = false
            dlg.busy = false
            errorLabel.text = message || "Could not add staff"
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        AuthTextField {
            id: nameField
            Layout.fillWidth: true
            label: "Full name"
            placeholderText: "Alex Chen"
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AuthTextField {
                id: emailField
                Layout.fillWidth: true
                label: "Email"
                placeholderText: "person@company.com"
                inputMethodHints: Qt.ImhEmailCharactersOnly
            }
            AuthTextField {
                id: phoneField
                Layout.fillWidth: true
                label: "Phone"
                placeholderText: "+91 98765 43210"
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            ColumnLayout {
                Layout.fillWidth: true
                spacing: dp(4)
                Text { text: "Role"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
                AuthTextField {
                    id: roleField
                    Layout.fillWidth: true
                    placeholderText: "e.g. Sales Manager"
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: dp(4)
                Text { text: "Department"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
                AppComboBox {
                    id: deptCombo
                    Layout.fillWidth: true
                    model: ["Operations", "Sales", "Warehouse", "Support", "Finance", "Marketing"]
                    font.pixelSize: sp(Constants.fsBody)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            ColumnLayout {
                Layout.fillWidth: true
                spacing: dp(4)
                Text { text: "Joined"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
                RowLayout {
                    Layout.fillWidth: true
                    AuthTextField {
                        id: joinDateField
                        Layout.fillWidth: true
                        readOnly: true
                        text: Qt.formatDate(joinPicker.date, "dd/MM/yyyy")
                    }
                    IconActionButton {
                        iconName: "calendar"
                        onClicked: joinPicker.open()
                    }
                    InlineDatePicker { id: joinPicker; onAccepted: function(d) { joinDateField.text = Qt.formatDate(d, "dd/MM/yyyy") } }
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: dp(4)
                Text { text: "Status"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
                AppComboBox {
                    id: statusCombo
                    Layout.fillWidth: true
                    model: ["Active", "On Leave"]
                    font.pixelSize: sp(Constants.fsBody)
                }
            }
        }

        AuthTextField {
            id: salaryField
            Layout.fillWidth: true
            label: "Salary (₹)"
            placeholderText: "50000"
            text: ""
            inputMethodHints: Qt.ImhFormattedNumbersOnly
        }

        // Login provisioning toggle + role selector
        Rectangle {
            Layout.fillWidth: true
            radius: dp(Constants.radius)
            color: Constants.subtleBg
            border.color: Constants.borderColor
            border.width: 1
            Layout.preferredHeight: loginCol.implicitHeight + dp(24)
            clip: true

            ColumnLayout {
                id: loginCol
                anchors.fill: parent
                anchors.margins: dp(Constants.space3)
                spacing: dp(Constants.space2)

                Text {
                    text: qsTr("App login")
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBody)
                    font.bold: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: dp(Constants.space2)
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: dp(4)
                        Text { text: qsTr("App role"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
                        AppComboBox {
                            id: appRoleCombo
                            Layout.fillWidth: true
                            model: ["Staff", "Manager", "Admin"]
                            font.pixelSize: sp(Constants.fsBody)
                        }
                    }
                }

                AuthPasswordField {
                    id: loginPasswordField
                    Layout.fillWidth: true
                    label: qsTr("Temporary password")
                    placeholderText: qsTr("min 6 characters")
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

    function trySubmit() {
        var errs = []
        if (!nameField.text || nameField.text.length < 2) errs.push("Enter a valid name")
        if (!emailField.text || emailField.text.indexOf("@") < 0) errs.push("Enter a valid email")
        if (!phoneField.text) errs.push("Enter a phone number")
        if (!roleField.text) errs.push("Enter a role")
        if (deptCombo.currentIndex < 0) errs.push("Select a department")
        // App login is mandatory — password always required.
        if (!loginPasswordField.text || loginPasswordField.text.length < 6)
            errs.push("Login password ≥ 6 chars")
        if (errs.length > 0) { errorLabel.text = errs.join(" · "); return }
        errorLabel.text = ""

        var sal = parseInt(salaryField.text)
        if (isNaN(sal)) sal = 0

        var payload = {
            name: nameField.text,
            email: emailField.text,
            phone: phoneField.text,
            role: roleField.text,
            department: deptCombo.currentText,
            joinDate: joinPicker.date,
            status: statusCombo.currentText.toLowerCase().replace(" ", "_"),
            salary: sal,
            createLogin: true,
            loginPassword: loginPasswordField.text,
            appRole: appRoleCombo.currentText.toLowerCase()
        }

        // Login is mandatory. Arm the result listener BEFORE emitting
        // staffCreated. The provision can resolve SYNCHRONOUSLY — in the current
        // pre-Blaze build Gateway.provisioningAvailable is false, so
        // provisionMember invokes its callback inline and AuthService emits
        // memberOperationSucceeded/authFailed DURING the staffCreated() call
        // below. The Connections block is gated on `_provisioning`; setting it
        // after the emit would let the synchronous signal arrive while the
        // listener was still disabled, leaving the sheet stuck open + busy.
        _provisioning = true
        busy = true
        staffCreated(payload)
        // The Connections block closes the sheet on success or shows the error
        // on failure — whether that result arrived synchronously during the emit
        // above or arrives later for a real network call.
        return
    }
}
