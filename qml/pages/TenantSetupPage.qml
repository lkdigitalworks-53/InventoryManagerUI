import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"

Item {
    id: root

    signal createTenantRequested(string tenantName)
    signal signOutRequested()

    property bool busy: false
    property string errorMessage: ""
    property string userEmail: ""

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#f0f9ff" }
            GradientStop { position: 1.0; color: "#e0e7ff" }
        }
    }

    Rectangle {
        id: card
        width: Math.min(parent.width - 40, 460)
        height: setupCol.implicitHeight + 40
        radius: 14
        color: "#ffffff"
        border.color: Constants.borderColor
        border.width: 1
        anchors.centerIn: parent

        Rectangle {
            anchors.fill: parent
            anchors.topMargin: 4
            anchors.bottomMargin: -4
            radius: parent.radius
            color: "#10000000"
            z: -1
        }

        ColumnLayout {
            id: setupCol
            anchors.fill: parent
            anchors.margins: 20
            spacing: 14

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4

                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    width: 44; height: 44; radius: 12
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: Constants.primaryBlue }
                        GradientStop { position: 1.0; color: Constants.primaryPurple }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "🏢"
                        font.pixelSize: 22
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    horizontalAlignment: Text.AlignHCenter
                    text: "Set up your workspace"
                    font.pixelSize: 22
                    font.bold: true
                    color: "#111827"
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: userEmail.length > 0 ? ("Signed in as " + userEmail) : "Almost there!"
                    font.pixelSize: 12
                    color: "#6b7280"
                    wrapMode: Text.Wrap
                }
            }

            AuthTextField {
                id: tenantNameField
                Layout.fillWidth: true
                Layout.topMargin: 6
                label: "Business Name"
                placeholderText: "Acme Inc."
                helperText: "This will be the name of your workspace."
                onTextChanged: { errorText = ""; root.errorMessage = "" }
                onAccepted: _submit()
            }

            Rectangle {
                Layout.fillWidth: true
                visible: root.errorMessage.length > 0
                radius: 8
                color: "#fef2f2"
                border.color: "#fecaca"
                border.width: 1
                implicitHeight: errTxt.implicitHeight + 16

                Text {
                    id: errTxt
                    anchors.fill: parent
                    anchors.margins: 8
                    text: "⚠  " + root.errorMessage
                    color: "#b91c1c"
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    verticalAlignment: Text.AlignVCenter
                }
            }

            AuthPrimaryButton {
                Layout.fillWidth: true
                text: root.busy ? "Creating workspace…" : "Create workspace"
                loading: root.busy
                enabled: !root.busy
                onClicked: _submit()
            }

            AuthSecondaryButton {
                Layout.fillWidth: true
                text: "Sign out"
                enabled: !root.busy
                onClicked: signOutRequested()
            }
        }
    }

    function _submit() {
        var err = FormValidator.validateRequired(tenantNameField.text, "Business name", 2)
        if (err.length > 0) {
            tenantNameField.errorText = err
            return
        }
        tenantNameField.errorText = ""
        createTenantRequested(tenantNameField.text.trim())
    }
}
