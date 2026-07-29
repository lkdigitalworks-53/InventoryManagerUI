import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"
import "../helper/StaffScope.js" as StaffScope

// Profile screen — avatar + stats card, Account & Preferences lists,
// destructive sign-out CTA. Wired to AuthStore + emits navigation signals.
Item {
    id: root

    signal backRequested()
    signal editProfileRequested()
    signal manageMembersRequested()
    signal signOutRequested()
    signal leaveWorkspaceRequested()

    Rectangle { anchors.fill: parent; color: Constants.appBg }

    GlassHeader {
        id: header
        topInset: SafeArea.top
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
                Icon {
                    anchors.centerIn: parent
                    name: "back"
                    color: Constants.textPrimary
                    size: sp(22)
                }
            }
            onClicked: root.backRequested()
        }
    }

    AppScrollView {
        id: profileScroll
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

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
                        imageSource: AuthStore.photoUrl ? AuthStore.photoUrl : ""
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
                        font.pixelSize: sp(Constants.fsBodyLg)
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: uidBtn.height
                    visible: AuthStore.uid.length > 0
                    QQC.AbstractButton {
                        id: uidBtn
                        anchors.horizontalCenter: parent.horizontalCenter
                        padding: dp(6)
                        contentItem: Row {
                            spacing: dp(6)
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("ID: %1").arg(root._shortUid(AuthStore.uid))
                                color: Constants.textMuted
                                font.pixelSize: sp(Constants.fsSmall)
                            }
                            Icon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "clipboard"
                                size: sp(Constants.fsSmall)
                            }
                        }
                        background: Rectangle {
                            radius: dp(Constants.radiusSm)
                            color: uidBtn.pressed ? Constants.subtleBg : "transparent"
                        }
                        onClicked: {
                            Clipboard.copy(AuthStore.uid)
                            Toast.show(qsTr("User ID copied"))
                        }
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
                            // Staff see their OWN order count; everyone else the tenant total.
                            title: AuthStore.canViewFinancials
                                   ? String(SalesStore.totalOrders)
                                   : String(StaffScope.ownOrders(OrdersStore.orders || [], AuthStore.currentStaffId).length)
                            caption: "Orders"
                        }
                        StatTile {
                            // Revenue is financial — hidden from staff. Row skips
                            // invisible children, so the hero reflows to 2 tiles.
                            visible: AuthStore.canViewFinancials
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

                        SettingsRow { iconName: "profile"; label: "Edit profile";       onClicked: root.editProfileRequested() }
                        SettingsRow { iconName: "team"; label: "Team members";  onClicked: root.manageMembersRequested(); visible: AuthStore.canInviteMembers }
                        SettingsRow { iconName: "security"; label: "Security & passkeys" }
                        SettingsRow { iconName: "bell"; label: "Notifications";       last: true }
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

                        SettingsRow { iconName: "appearance"; label: "Appearance";   trailingText: "System" }
                        SettingsRow { iconName: "language"; label: "Language";     trailingText: "English" }
                        SettingsRow { iconName: "currency"; label: "Currency";     trailingText: "INR"; last: true }
                    }
                }
            }

            // Sign out
            DangerButton {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                text: qsTr("Sign out")
                onClicked: root.signOutRequested()
            }

            // Leave workspace — only for non-owners. Owners can't self-leave
            // (would orphan the tenant); the row stays hidden for them.
            DangerButton {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: AuthStore.role !== "owner"
                text: qsTr("Leave workspace")
                onClicked: root.leaveWorkspaceRequested()
            }

            Item { Layout.preferredHeight: dp(Constants.tabbarClearance) + SafeArea.bottom; Layout.fillWidth: true }
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
        id: settingsRowRoot
        property string iconName: ""
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
                Icon {
                    anchors.centerIn: parent
                    name: settingsRowRoot.iconName
                    size: sp(16)
                    color: Constants.textSecondary
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

            Icon {
                name: "chevron"
                color: Constants.textMuted
                size: sp(16)
            }
        }
    }

    function _formatRole(r) {
        if (!r) return ""
        return r.charAt(0).toUpperCase() + r.slice(1)
    }

    // Short, shareable rendering of a UID: first 6 + ellipsis + last 4. Full
    // value is what gets copied; this is display-only.
    function _shortUid(u) {
        if (!u || u.length === 0) return qsTr("—")
        if (u.length <= 12) return u
        return u.substring(0, 6) + "…" + u.substring(u.length - 4)
    }
}
