import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"

// Workspace setup. Mirrors prototype: clean centered card, business name +
// optional industry chip selector, gradient primary CTA.
Item {
    id: root
    clip: true   // keep decorative blobs from painting outside the page

    signal createTenantRequested(string tenantName)
    signal signOutRequested()

    property bool busy: false
    property string errorMessage: ""
    property string userEmail: ""

    function clearFields() {
        if (tenantNameField) tenantNameField.text = ""
        errorMessage = ""
    }

    // Clear fields when page becomes invisible (after successful workspace creation)
    onVisibleChanged: {
        if (!visible) {
            Qt.callLater(clearFields)
        }
    }

    Rectangle { anchors.fill: parent; color: Constants.appBg }

    // Background blobs to keep visual continuity with LoginPage.
    Rectangle { z: -1; width: dp(220); height: dp(220); radius: dp(110); x: -dp(70); y: -dp(70); color: Constants.brand1; opacity: 0.40 }
    Rectangle { z: -1; width: dp(180); height: dp(180); radius: dp(90); x: parent.width - dp(140); y: parent.height - dp(180); color: Constants.brand4; opacity: 0.30 }

    AppScrollView {
        id: tenantScroll
        anchors.fill: parent

        ColumnLayout {
            id: col
            width: tenantScroll.availableWidth
            spacing: dp(Constants.space5)

            Item { Layout.preferredHeight: dp(Constants.space7) + SafeArea.top; Layout.fillWidth: true }

            // Brand mark
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: dp(72); height: dp(72); radius: dp(22)
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0.0; color: Constants.brand1 }
                    GradientStop { position: 0.55; color: Constants.brand2 }
                    GradientStop { position: 1.0; color: Constants.brand3 }
                }
                Icon { anchors.centerIn: parent; name: "workspace"; size: sp(30); color: Constants.textSecondary }
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: "Create your workspace"
                font.pixelSize: sp(28)
                font.bold: true
                font.letterSpacing: -0.5
                color: Constants.textPrimary
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space5)
                Layout.rightMargin: dp(Constants.space5)
                horizontalAlignment: Text.AlignHCenter
                text: userEmail.length > 0
                    ? "Signed in as " + userEmail
                    : "One workspace per business. You can invite teammates later."
                font.pixelSize: sp(Constants.fsBodyLg)
                color: Constants.textSecondary
                wrapMode: Text.Wrap
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space5)
                Layout.rightMargin: dp(Constants.space5)
                spacing: dp(Constants.space3)

                AuthTextField {
                    id: tenantNameField
                    Layout.fillWidth: true
                    label: "Business name"
                    placeholderText: "e.g. Aurora Coffee Co."
                    helperText: "This is the name of your workspace."
                    onTextChanged: { errorText = ""; root.errorMessage = "" }
                    onAccepted: _submit()
                }

                // Industry chip row — picks default theme; informational for now.
                Text {
                    text: "Business type"
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsSmall)
                    font.bold: true
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: dp(Constants.space2)

                    property int selected: 0
                    Repeater {
                        model: ["Retail", "Hospitality", "Services", "Wholesale", "Other"]
                        delegate: Rectangle {
                            id: typeChip
                            readonly property bool isOn: index === parent.selected
                            height: dp(32)
                            width: chipTxt.implicitWidth + dp(24)
                            radius: dp(Constants.radiusPill)
                            color: isOn ? Constants.brand2 : Constants.cardBg
                            border.color: isOn ? "transparent" : Constants.borderColor
                            border.width: 1

                            Rectangle {
                                visible: typeChip.isOn
                                anchors.fill: parent
                                radius: parent.radius
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0.0; color: Constants.brand1 }
                                    GradientStop { position: 1.0; color: Constants.brand2 }
                                }
                            }

                            Text {
                                id: chipTxt
                                z: 1
                                anchors.centerIn: parent
                                text: modelData
                                color: typeChip.isOn ? Constants.textOnBrand : Constants.textSecondary
                                font.pixelSize: sp(Constants.fsSmall)
                                font.bold: true
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: parent.parent.selected = index
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    visible: root.errorMessage.length > 0
                    radius: dp(12)
                    color: Constants.cancelledFill
                    border.color: Qt.rgba(0.93, 0.27, 0.27, 0.25)
                    border.width: 1
                    implicitHeight: errTxt.implicitHeight + dp(16)

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: dp(10)
                        spacing: dp(6)

                        Icon {
                            name: "warn"
                            size: sp(Constants.fsSmall)
                            color: Constants.cancelledText
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Text {
                            id: errTxt
                            Layout.fillWidth: true
                            text: root.errorMessage
                            color: Constants.cancelledText
                            font.pixelSize: sp(Constants.fsSmall)
                            wrapMode: Text.Wrap
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                PrimaryButton {
                    Layout.fillWidth: true
                    Layout.topMargin: dp(Constants.space2)
                    text: root.busy ? "Creating workspace…" : "Continue"
                    loading: root.busy
                    enabled: !root.busy
                    onClicked: _submit()
                }

                GhostButton {
                    Layout.fillWidth: true
                    text: "Sign out"
                    enabled: !root.busy
                    onClicked: signOutRequested()
                }
            }

            Item { Layout.preferredHeight: dp(Constants.space7); Layout.fillWidth: true }
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
