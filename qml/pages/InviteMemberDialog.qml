import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

QQC.Dialog {
    id: root

    signal memberInviteRequested(string uid, string email, string displayName, string role)

    modal: true
    title: "Invite Team Member"
    anchors.centerIn: parent
    width: 460
    standardButtons: QQC.Dialog.Ok | QQC.Dialog.Cancel

    property alias errorMessage: errorText.text

    onAccepted: {
        memberInviteRequested(uidField.text, emailField.text, nameField.text, roleBox.currentText)
    }

    ColumnLayout {
        width: parent.width
        spacing: 10

        Text {
            text: "Invite an existing authenticated user by UID."
            color: "#4b5563"
            font.pixelSize: 12
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }

        QQC.TextField {
            id: uidField
            placeholderText: "User UID (required)"
            Layout.fillWidth: true
        }

        QQC.TextField {
            id: nameField
            placeholderText: "Display Name"
            Layout.fillWidth: true
        }

        QQC.TextField {
            id: emailField
            placeholderText: "Email"
            Layout.fillWidth: true
        }

        QQC.ComboBox {
            id: roleBox
            Layout.fillWidth: true
            model: ["staff", "manager", "admin"]
            currentIndex: 0
        }

        Text {
            id: errorText
            text: ""
            visible: text.length > 0
            color: "#b91c1c"
            font.pixelSize: 12
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
    }
}
