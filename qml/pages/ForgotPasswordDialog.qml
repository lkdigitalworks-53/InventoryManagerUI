import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"

QQC.Dialog {
    id: root
    modal: true
    title: "Reset your password"
    anchors.centerIn: parent
    width: Math.min(parent ? parent.width - 40 : 400, 420)
    padding: 20

    property string prefillEmail: ""
    property bool busy: false
    property string errorMessage: ""

    signal resetRequested(string email)

    onOpened: {
        emailField.text = prefillEmail
        errorMessage = ""
        emailField.errorText = ""
    }

    background: Rectangle {
        radius: 12
        color: "#ffffff"
        border.color: Constants.borderColor
    }

    contentItem: ColumnLayout {
        spacing: 12

        Text {
            Layout.fillWidth: true
            text: "Enter the email address associated with your account and we'll send you a link to reset your password."
            color: "#6b7280"
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        AuthTextField {
            id: emailField
            Layout.fillWidth: true
            label: "Email"
            placeholderText: "you@company.com"
            inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
            onAccepted: root._submit()
            onTextChanged: { errorText = ""; root.errorMessage = "" }
        }

        Text {
            Layout.fillWidth: true
            visible: root.errorMessage.length > 0
            text: root.errorMessage
            color: "#b91c1c"
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 8

            AuthSecondaryButton {
                Layout.fillWidth: true
                text: "Cancel"
                enabled: !root.busy
                onClicked: root.reject()
            }

            AuthPrimaryButton {
                Layout.fillWidth: true
                text: "Send reset link"
                loading: root.busy
                enabled: !root.busy
                onClicked: root._submit()
            }
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
