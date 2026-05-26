import QtQuick
import QtQuick.Layouts

import "../components"
import "../helper"

// Forgot password — converted to bottom sheet. Public contract:
//   property string prefillEmail
//   signal resetRequested(email)
BottomSheet {
    id: root

    sheetTitle: "Reset password"
    primaryAction: "Send reset link"
    secondaryAction: "Cancel"

    property string prefillEmail: ""
    property string errorMessage: ""

    signal resetRequested(string email)

    onOpened: {
        emailField.text = prefillEmail
        errorMessage = ""
        emailField.errorText = ""
    }

    onPrimaryClicked: _submit()

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        Text {
            text: "Enter the email associated with your account and we'll send a secure reset link."
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsBody)
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }

        AuthTextField {
            id: emailField
            Layout.fillWidth: true
            label: "Email"
            placeholderText: "you@company.com"
            inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
            onTextChanged: { errorText = ""; root.errorMessage = "" }
            onAccepted: root._submit()
        }

        Text {
            visible: root.errorMessage.length > 0
            text: root.errorMessage
            color: Constants.danger
            font.pixelSize: sp(Constants.fsSmall)
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
    }

    function _submit() {
        var err = FormValidator.validateEmail(emailField.text)
        if (err.length > 0) {
            emailField.errorText = err
            return
        }
        emailField.errorText = ""
        errorMessage = ""
        resetRequested(emailField.text.trim())
    }
}
