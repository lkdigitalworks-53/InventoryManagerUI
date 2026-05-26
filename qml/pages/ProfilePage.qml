import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Profile screen — avatar + stats card, Account & Preferences lists,
// destructive sign-out CTA. Wired to AuthStore + emits navigation signals.
Item {
    id: root

    signal backRequested()
    signal editProfileRequested()
    signal manageMembersRequested()
    signal signOutRequested()

    Rectangle { anchors.fill: parent; color: Constants.appBg }

    GlassHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: "Profile"

        leading: QQC.AbstractButton {
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: dp(40)
            implicitHeight: dp(40)
            padding: 0
            background: Rectangle { color: parent.pressed ? Qt.rgba(0,0,0,0.04) : "transparent"; radius: dp(12) }
            contentItem: Item {
                Text {
                    anchors.centerIn: parent
                    text: "←"
                    color: Constants.textPrimary
                    font.pixelSize: sp(22)
                    font.bold: true
                }
            }
            onClicked: root.backRequested()
        }
    }

    QQC.ScrollView {
        id: profileScroll
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

        ColumnLayout {
            id: stack
            // Bind to ScrollView's actual content area, not page width — root
            // may be wider than the ScrollView when scrollbars are present.
            width: profileScroll.availableWidth
            spacing: dp(Constants.space5)

            // Hero avatar + stats — each child wrapped in a full-width Item so
            // its own anchors.horizontalCenter pegs reliably to the page
            // centre, regardless of how Layout.alignment propagates inside a
            // nested ColumnLayout.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: heroAvatar.height
                    AvatarBadge {
                        id: heroAvatar
                        anchors.horizontalCenter: parent.horizontalCenter
                        size: "xl"
                        label: ((AuthStore.displayName || AuthStore.email || "?").charAt(0) || "?").toUpperCase()
                        palette: Constants.grad1
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: heroName.implicitHeight
                    Text {
                        id: heroName
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: AuthStore.displayName || AuthStore.email || "Account"
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsH2)
                        font.bold: true
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: heroSub.implicitHeight
                    Text {
                        id: heroSub
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: (AuthStore.role ? _formatRole(AuthStore.role) + " · " : "")
                              + (AuthStore.tenantName || "Workspace")
                        color: Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: heroStats.height
                    Layout.topMargin: dp(Constants.space2)
                    Row {
                        id: heroStats
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: dp(Constants.space2)

                        StatTile {
                            title: String(SalesStore.totalOrders)
                            caption: "Orders"
                        }
                        StatTile {
                            title: SalesStore.formatCurrency(SalesStore.totalRevenue)
                            caption: "Revenue"
                        }
                        StatTile {
                            title: String(StaffStore.totalStaff())
                            caption: "Team"
                        }
                    }
                }
            }

            // Account
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                Text {
                    text: "Account"
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }

                Rectangle {
                    Layout.fillWidth: true
                    radius: dp(Constants.radius)
                    color: Constants.cardBg
                    border.color: Constants.borderColor
                    border.width: 1
                    Layout.preferredHeight: accountList.implicitHeight + dp(8)

                    ColumnLayout {
                        id: accountList
                        anchors.fill: parent
                        anchors.margins: dp(4)
                        spacing: 0

                        SettingsRow { emoji: "👤"; label: "Edit profile";       onClicked: root.editProfileRequested() }
                        SettingsRow { emoji: "🏢"; label: "Workspace settings"; onClicked: root.editProfileRequested() }
                        SettingsRow { emoji: "🧑‍🤝‍🧑"; label: "Team members";  onClicked: root.manageMembersRequested(); visible: AuthStore.canInviteMembers }
                        SettingsRow { emoji: "🔐"; label: "Security & passkeys" }
                        SettingsRow { emoji: "🔔"; label: "Notifications";       last: true }
                    }
                }
            }

            // Preferences
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                Text {
                    text: "Preferences"
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }

                Rectangle {
                    Layout.fillWidth: true
                    radius: dp(Constants.radius)
                    color: Constants.cardBg
                    border.color: Constants.borderColor
                    border.width: 1
                    Layout.preferredHeight: prefsList.implicitHeight + dp(8)

                    ColumnLayout {
                        id: prefsList
                        anchors.fill: parent
                        anchors.margins: dp(4)
                        spacing: 0

                        SettingsRow { emoji: "🎨"; label: "Appearance";   trailingText: "System" }
                        SettingsRow { emoji: "🌐"; label: "Language";     trailingText: "English" }
                        SettingsRow { emoji: "💱"; label: "Currency";     trailingText: "INR"; last: true }
                    }
                }
            }

            // Sign out
            DangerButton {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                text: "Sign out"
                onClicked: root.signOutRequested()
            }

            Item { Layout.preferredHeight: dp(Constants.tabbarClearance); Layout.fillWidth: true }
        }
    }

    component StatTile: Rectangle {
        property string title: ""
        property string caption: ""
        radius: dp(Constants.radius)
        color: Constants.cardBg
        border.color: Constants.borderColor
        border.width: 1
        implicitWidth: dp(96)
        implicitHeight: dp(60)

        ColumnLayout {
            anchors.centerIn: parent
            spacing: 0
            Text {
                text: title
                color: Constants.textPrimary
                font.pixelSize: sp(Constants.fsTitle)
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                Layout.alignment: Qt.AlignHCenter
            }
            Text {
                text: caption
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsCaption)
                horizontalAlignment: Text.AlignHCenter
                Layout.alignment: Qt.AlignHCenter
            }
        }
    }

    component SettingsRow: QQC.AbstractButton {
        property string emoji: "•"
        property string label: ""
        property string trailingText: ""
        property bool last: false
        Layout.fillWidth: true
        implicitHeight: dp(52)

        background: Rectangle {
            color: parent.pressed ? Constants.subtleBg : "transparent"
            Behavior on color { ColorAnimation { duration: Constants.durFast } }
            Rectangle {
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.leftMargin: dp(14); anchors.rightMargin: dp(14)
                height: 1
                color: Constants.borderColor
                visible: !parent.parent.last
            }
        }

        contentItem: RowLayout {
            spacing: dp(Constants.space3)
            anchors.leftMargin: dp(14)
            anchors.rightMargin: dp(14)

            Rectangle {
                width: dp(32); height: dp(32); radius: dp(10)
                color: Qt.rgba(0.39, 0.40, 0.95, 0.10)
                Text {
                    anchors.centerIn: parent
                    text: parent.parent.parent.emoji
                    font.pixelSize: sp(16)
                }
            }

            Text {
                text: parent.parent.label
                color: Constants.textPrimary
                font.pixelSize: sp(Constants.fsBodyLg)
                Layout.fillWidth: true
            }

            Text {
                visible: parent.parent.trailingText.length > 0
                text: parent.parent.trailingText
                color: Constants.textMuted
                font.pixelSize: sp(Constants.fsSmall)
            }

            Text {
                text: "›"
                color: Constants.textMuted
                font.pixelSize: sp(16)
            }
        }
    }

    function _formatRole(r) {
        if (!r) return ""
        return r.charAt(0).toUpperCase() + r.slice(1)
    }
}
