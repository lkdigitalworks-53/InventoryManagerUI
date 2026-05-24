import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import "../model"

// ─────────────────────────────────────────────────────────────────────────────
// ProfileSettingsDialog.qml
//
// Displays and allows editing of the current user's profile details.
// Calls AuthService.updateUserProfile() on save.
// ─────────────────────────────────────────────────────────────────────────────
QQC.Dialog {
    id: root

    signal profileSaved()

    modal: true
    title: "Profile Settings"
    anchors.centerIn: parent
    width: 500
    standardButtons: QQC.Dialog.Save | QQC.Dialog.Cancel

    property bool busy: false
    property string errorMessage: ""

    // Pre-populate fields every time dialog opens
    onOpened: {
        displayNameField.text = AuthStore.displayName
        emailDisplay.text     = AuthStore.email
        phoneField.text       = AuthStore.phone
        addressField.text     = AuthStore.address
        cityField.text        = AuthStore.city
        countryField.text     = AuthStore.country
        postalField.text      = AuthStore.postalCode
        errorText.text        = ""
    }

    onAccepted: {
        if (!busy) {
            busy = true
            AuthService.updateUserProfile(
                phoneField.text.trim(),
                addressField.text.trim(),
                cityField.text.trim(),
                countryField.text.trim(),
                postalField.text.trim()
            )
        }
    }

    Connections {
        target: AuthService
        function onProfileUpdated() {
            busy = false
            root.profileSaved()
        }
        function onBusyChanged() {
            if (!AuthService.busy) busy = false
        }
    }

    ColumnLayout {
        width: parent.width
        spacing: 12

        // ── Read-only account section ──
        Rectangle {
            Layout.fillWidth: true
            height: accountCol.height + 20
            radius: 10
            color: "#f9fafb"
            border.color: "#e5e7eb"

            Column {
                id: accountCol
                x: 14; y: 10; width: parent.width - 28; spacing: 8

                QQC.Label { text: "Account"; font.bold: true; font.pixelSize: 13; color: "#374151" }

                RowLayout {
                    width: parent.width
                    QQC.Label { text: "Display Name"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 120 }
                    QQC.TextField {
                        id: displayNameField
                        Layout.fillWidth: true
                        placeholderText: "Your name"
                        readOnly: true       // name set at signup; update via separate flow
                        opacity: 0.7
                    }
                }
                RowLayout {
                    width: parent.width
                    QQC.Label { text: "Email"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 120 }
                    QQC.Label { id: emailDisplay; color: "#374151"; font.pixelSize: 12; Layout.fillWidth: true }
                }
                RowLayout {
                    width: parent.width
                    QQC.Label { text: "Role"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 120 }
                    Rectangle {
                        width: roleLabel.implicitWidth + 16; height: 22; radius: 11
                        color: "#dbeafe"; border.color: "#93c5fd"
                        QQC.Label { id: roleLabel; text: AuthStore.role; color: "#1d4ed8"; font.pixelSize: 11; font.bold: true; anchors.centerIn: parent }
                    }
                }
                RowLayout {
                    width: parent.width
                    QQC.Label { text: "Workspace"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 120 }
                    QQC.Label { text: AuthStore.tenantName || "(none)"; color: "#374151"; font.pixelSize: 12; Layout.fillWidth: true }
                }
            }
        }

        // ── Editable contact section ──
        QQC.Label { text: "Contact Details"; font.bold: true; font.pixelSize: 13; color: "#374151" }

        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Phone"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 120 }
            QQC.TextField { id: phoneField; Layout.fillWidth: true; placeholderText: "+1 555 000 0000" }
        }
        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Address"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 120 }
            QQC.TextField { id: addressField; Layout.fillWidth: true; placeholderText: "Street address" }
        }
        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "City"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 120 }
            QQC.TextField { id: cityField; Layout.fillWidth: true; placeholderText: "City" }
        }
        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Country"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 120 }
            QQC.TextField { id: countryField; Layout.fillWidth: true; placeholderText: "Country" }
        }
        RowLayout {
            Layout.fillWidth: true
            QQC.Label { text: "Postal Code"; color: "#6b7280"; font.pixelSize: 12; Layout.preferredWidth: 120 }
            QQC.TextField { id: postalField; Layout.fillWidth: true; placeholderText: "Postal / ZIP" }
        }

        QQC.BusyIndicator { running: busy; visible: busy; Layout.alignment: Qt.AlignHCenter }

        QQC.Label {
            id: errorText
            visible: text.length > 0
            color: "#b91c1c"
            font.pixelSize: 12
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
    }
}
