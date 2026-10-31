import QtQuick
import QtQuick.Layouts

import "../components"
import "../helper"
import "../helper/AccessState.js" as AccessState

// Full-screen replacement for the app when the signed-in user's own member doc says they may not use
// this shop (removed, suspended, invalid role) or it could not be read. Main.qml shows it while
// AuthService.accessBlock is non-empty. The wording lives in helper/AccessState.js (tested there).
// Design: docs/superpowers/specs/2026-10-28-s2f3-access-wording-design.md
Item {
    id: root

    // "removed" | "suspended" | "role" | "unverified"
    property string reason: ""
    property string tenantName: ""
    property string userEmail: ""
    // True while "Try again" is asking the server: spinner on the button, no second tap.
    property bool checking: false

    signal retryRequested()
    signal signOutRequested()

    readonly property var _copy: AccessState.copy(reason, tenantName)

    // Opaque, and swallows touches: the app underneath is still loaded from the saved session.
    Rectangle { anchors.fill: parent; color: Constants.appBg }
    MouseArea { anchors.fill: parent }

    AppScrollView {
        id: scroll
        anchors.fill: parent

        ColumnLayout {
            width: scroll.availableWidth
            spacing: dp(Constants.space5)

            Item { Layout.preferredHeight: dp(Constants.space7) + SafeArea.top; Layout.fillWidth: true }

            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: dp(72)
                Layout.preferredHeight: dp(72)
                radius: dp(22)
                Accessible.ignored: true
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0.0; color: Constants.brand1 }
                    GradientStop { position: 0.55; color: Constants.brand2 }
                    GradientStop { position: 1.0; color: Constants.brand3 }
                }
                Icon { anchors.centerIn: parent; name: "secure"; size: sp(30) }
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space5)
                Layout.rightMargin: dp(Constants.space5)
                horizontalAlignment: Text.AlignHCenter
                text: root._copy.title
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                font.pixelSize: sp(Constants.fsH1)
                font.bold: true
                color: Constants.textPrimary
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space5)
                Layout.rightMargin: dp(Constants.space5)
                horizontalAlignment: Text.AlignHCenter
                text: root._copy.body
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                font.pixelSize: sp(Constants.fsBodyLg)
                color: Constants.textSecondary
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space5)
                Layout.rightMargin: dp(Constants.space5)
                visible: root.userEmail.length > 0
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("Signed in as %1").arg(root.userEmail)
                textFormat: Text.PlainText
                wrapMode: Text.WrapAnywhere
                font.pixelSize: sp(Constants.fsSmall)
                color: Constants.textMuted
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space5)
                Layout.rightMargin: dp(Constants.space5)
                spacing: dp(Constants.space3)

                PrimaryButton {
                    Layout.fillWidth: true
                    text: qsTr("Try again")
                    loading: root.checking
                    enabled: !root.checking
                    onClicked: root.retryRequested()
                }

                GhostButton {
                    Layout.fillWidth: true
                    text: qsTr("Sign out")
                    onClicked: root.signOutRequested()
                }
            }

            Item { Layout.preferredHeight: dp(Constants.space7) + SafeArea.bottom; Layout.fillWidth: true }
        }
    }
}
