import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Profile editor — bottom sheet. Read-only Account section + editable Contact
// section. Public contract preserved: signal profileSaved(), property bool busy,
// property string errorMessage.
BottomSheet {
    id: root

    sheetTitle: "Profile settings"
    primaryAction: "Save"
    secondaryAction: "Cancel"
    busy: AuthService.busy

    signal profileSaved()

    property string errorMessage: ""
    property string workspaceOriginalName: ""
    property bool workspaceEditMode: false
    readonly property bool canRenameWorkspace: AuthStore.role === "owner"

    // Pre-populate fields every time sheet opens.
    onOpened: {
        displayNameField.text = AuthStore.displayName
        emailDisplay.text     = AuthStore.email
        phoneField.text       = AuthStore.phone
        addressField.text     = AuthStore.address
        cityField.text        = AuthStore.city
        countryField.text     = AuthStore.country
        postalField.text      = AuthStore.postalCode
        workspaceOriginalName = AuthStore.tenantName
        workspaceName.text    = workspaceOriginalName
        workspaceEditMode     = false
        errorMessage = ""
    }

    onPrimaryClicked: {
        if (!busy) {
            errorMessage = ""
            AuthService.saveProfileSettings(
                phoneField.text.trim(),
                addressField.text.trim(),
                cityField.text.trim(),
                countryField.text.trim(),
                postalField.text.trim(),
                workspaceName.text
            )
        }
    }

    Connections {
        target: AuthService
        function onProfileUpdated() {
            root.profileSaved()
            root.close()
        }
        function onProfileUpdateFailed(reason) {
            root.errorMessage = reason
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        // ── Read-only Account card ──
        Rectangle {
            Layout.fillWidth: true
            radius: dp(Constants.radius)
            color: Constants.subtleBg
            border.color: Constants.borderColor
            border.width: 1
            Layout.preferredHeight: accountCol.implicitHeight + dp(Constants.space4 * 2)

            ColumnLayout {
                id: accountCol
                anchors.fill: parent
                anchors.margins: dp(Constants.space4)
                spacing: dp(Constants.space2)

                Text {
                    text: "Account"
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Name"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); Layout.preferredWidth: dp(96) }
                    Text {
                        id: displayNameField
                        Layout.fillWidth: true
                        text: AuthStore.displayName || "—"
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBody)
                        elide: Text.ElideRight
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Email"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); Layout.preferredWidth: dp(96) }
                    Text {
                        id: emailDisplay
                        Layout.fillWidth: true
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBody)
                        elide: Text.ElideRight
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Role"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); Layout.preferredWidth: dp(96) }
                    StatusPill {
                        Layout.alignment: Qt.AlignVCenter
                        status: "processing"
                        label: AuthStore.role || "—"
                    }
                    Item { Layout.fillWidth: true }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Workspace"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); Layout.preferredWidth: dp(96) }
                    QQC.TextField {
                        id: workspaceName
                        text: AuthStore.tenantName || "(none)"
                        placeholderText: "Workspace name"
                        Layout.fillWidth: true
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBody)
                        enabled: root.canRenameWorkspace && root.workspaceEditMode
                        onTextEdited: root.errorMessage = ""
                        background: Rectangle {
                            Layout.fillWidth: true
                            color: workspaceName.enabled ? Constants.cardBg : Constants.subtleBg
                            border.color: workspaceName.enabled ? Constants.primaryBlue : Constants.borderColor
                            border.width: 1
                            radius: workspaceName.enabled ? dp(Constants.radiusSm) : width / 2
                        }
                    }
                    QQC.AbstractButton {
                        id: editButton
                        Layout.preferredWidth: dp(28)
                        Layout.preferredHeight: dp(28)
                        implicitWidth: dp(28)
                        implicitHeight: dp(28)
                        padding: 0
                        topPadding: 0; bottomPadding: 0; leftPadding: 0; rightPadding: 0
                        visible: root.canRenameWorkspace
                        background: Rectangle {
                            anchors.fill: parent
                            radius: dp(10)
                            color: editButton.pressed ? Constants.borderColor : Constants.subtleBg
                            border.color: Constants.borderColor
                            border.width: 1
                            opacity: editButton.enabled ? 1 : 0.5
                            Behavior on color { ColorAnimation { duration: Constants.durFast } }
                        }
                        contentItem: Icon {
                            name: root.workspaceEditMode ? "close" : "edit"
                            color: Constants.textPrimary
                            size: sp(16)
                        }
                        onClicked: {
                            if (root.workspaceEditMode) {
                                workspaceName.text = root.workspaceOriginalName
                                root.workspaceEditMode = false
                                return
                            }
                            root.workspaceEditMode = true
                            Qt.callLater(function() { workspaceName.forceActiveFocus() })
                        }
                    }
                }
                // Build environment — only shown on non-production builds so a
                // dev/test build is unmistakable (prd hides the whole row).
                RowLayout {
                    Layout.fillWidth: true
                    visible: FirebaseService.environment !== "prd"
                    Text { text: qsTr("Environment"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); Layout.preferredWidth: dp(96) }
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        radius: dp(Constants.radiusPill)
                        color: Constants.warn
                        implicitHeight: dp(22)
                        implicitWidth: envBadgeText.implicitWidth + dp(20)
                        Text {
                            id: envBadgeText
                            anchors.centerIn: parent
                            text: FirebaseService.environment.toUpperCase()   // "DEV" | "TEST"
                            color: Constants.textOnBrand
                            font.pixelSize: sp(Constants.fsCaption)
                            font.bold: true
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
            }
        }

        // ── Editable contact section ──
        Text {
            text: "Contact details"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        AuthTextField {
            id: phoneField
            Layout.fillWidth: true
            label: "Phone"
            placeholderText: "+1 555 000 0000"
        }
        AuthTextField {
            id: addressField
            Layout.fillWidth: true
            label: "Address"
            placeholderText: "Street address"
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            AuthTextField {
                id: cityField
                Layout.fillWidth: true
                label: "City"
                placeholderText: "City"
            }
            AuthTextField {
                id: postalField
                Layout.fillWidth: true
                label: "Postal"
                placeholderText: "ZIP"
            }
        }
        AuthTextField {
            id: countryField
            Layout.fillWidth: true
            label: "Country"
            placeholderText: "Country"
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
}
