import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"

// Invite team member by UID — bottom sheet. Public contract preserved:
// signal memberInviteRequested(uid, email, displayName, role),
// property alias errorMessage.
BottomSheet {
    id: root

    sheetTitle: "Invite team member"
    primaryAction: "Send invite"
    secondaryAction: "Cancel"

    signal memberInviteRequested(string uid, string email, string displayName, string role)

    property alias errorMessage: errorText.text

    onPrimaryClicked: {
        memberInviteRequested(uidField.text, emailField.text, nameField.text, roleBox.currentText)
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        Text {
            text: qsTr("Invite someone who already has an account. Ask them to open their Profile and copy their User ID, then paste it below. They'll get workspace access immediately.")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsBody)
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }

        AuthTextField {
            id: uidField
            Layout.fillWidth: true
            label: "User UID"
            placeholderText: "Required"
        }

        AuthTextField {
            id: nameField
            Layout.fillWidth: true
            label: "Display name"
            placeholderText: "Visible to teammates"
        }

        AuthTextField {
            id: emailField
            Layout.fillWidth: true
            label: "Email"
            placeholderText: "person@company.com"
            inputMethodHints: Qt.ImhEmailCharactersOnly
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: dp(4)
            Text {
                text: "Role"
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsSmall)
                font.bold: true
            }
            AppComboBox {
                id: roleBox
                Layout.fillWidth: true
                model: ["staff", "manager", "admin"]
                currentIndex: 0
                font.pixelSize: sp(Constants.fsBody)
            }
        }

        Text {
            id: errorText
            text: ""
            visible: text.length > 0
            color: Constants.danger
            font.pixelSize: sp(Constants.fsSmall)
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
    }
}
