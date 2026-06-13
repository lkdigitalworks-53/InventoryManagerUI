import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Mobile staff directory — glass header, search, staff cards with avatar +
// name + role/dept + status pill, FAB for add/invite.
Item {
    id: root

    property bool compact: false
    property bool canManageStaff: true
    property bool canInviteMembers: false

    signal addStaffClicked()
    signal inviteMemberClicked()
    signal manageMembersClicked()
    signal staffActionsRequested()
    signal viewStaffClicked(string staffId)
    signal editStaffClicked(string staffId)
    signal deleteStaffClicked(string staffId)
    signal exportRequested()
    signal backRequested()

    property bool showBackButton: false
    property string _searchText: ""

    Rectangle { anchors.fill: parent; color: Constants.appBg }

    GlassHeader {
        id: header
        topInset: SafeArea.top
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: "Staff"
        subtitle: "Manage team & access"

        leading: QQC.AbstractButton {
            visible: root.showBackButton
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

        actions: [
            IconActionButton {
                visible: root.canInviteMembers
                variant: "glass"
                iconName: "staff"
                onClicked: root.manageMembersClicked()
            },
            IconActionButton {
                variant: "glass"
                iconName: "export"
                onClicked: root.exportRequested()
            }
        ]
    }

    QQC.ScrollView {
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

        ColumnLayout {
            id: stack
            width: root.width
            spacing: dp(Constants.space3)

            // Quick KPI strip
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                Layout.topMargin: dp(Constants.space3)
                spacing: dp(Constants.space2)

                GradientKpiCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(110)
                    label: "Total"
                    value: String(StaffStore.totalStaff())
                    trend: StaffStore.departmentCount() + " depts"
                    palette: Constants.grad1
                }
                GradientKpiCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(110)
                    label: "Active"
                    value: String(StaffStore.activeCount())
                    trend: "on shift"
                    palette: Constants.grad4
                }
                GradientKpiCard {
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(110)
                    label: "On leave"
                    value: String(StaffStore.onLeaveCount())
                    trend: "temporarily away"
                    trendVariant: "muted"
                    palette: Constants.grad3
                }
            }

            SearchField {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                placeholder: "Search team…"
                onTextChanged: root._searchText = text
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                Repeater {
                    model: _filteredStaff()
                    delegate: ListCard {
                        Layout.fillWidth: true
                        title: modelData.name + (modelData.role ? "  ·  " + modelData.role : "")
                        subtitle: modelData.department + (modelData.email ? "  ·  " + modelData.email : "")
                        onClicked: root.viewStaffClicked(modelData.staffId)

                        leading: AvatarBadge {
                            label: StaffStore.initials(modelData.name)
                            palette: index % 4 === 0 ? Constants.grad1
                                   : index % 4 === 1 ? Constants.grad2
                                   : index % 4 === 2 ? Constants.grad3
                                   :                   Constants.grad4
                        }

                        StatusPill {
                            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                            status: modelData.status === "active" ? "active"
                                  : modelData.status === "on leave" ? "on leave"
                                  : "inactive"
                            label: modelData.status === "active" ? "On shift"
                                 : modelData.status === "on leave" ? "On leave"
                                 : "Inactive"
                        }
                    }
                }
            }

            // Empty / no-match state
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: _filteredStaff().length === 0
                radius: dp(Constants.radius)
                color: Constants.cardBg
                border.color: Constants.borderColor
                border.width: 1
                Layout.preferredHeight: dp(140)

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: dp(6)
                    Icon { name: "staff"; size: sp(32); color: Constants.textMuted; Layout.alignment: Qt.AlignHCenter }
                    Text {
                        text: root._searchText.length > 0 ? "No matches" : "No team members yet"
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBodyLg)
                        font.bold: true
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Text {
                        text: root._searchText.length > 0
                            ? "Try a different search."
                            : "Tap + to add or invite a teammate."
                        color: Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
            }

            Item { Layout.preferredHeight: dp(Constants.tabbarClearance) + SafeArea.bottom; Layout.fillWidth: true }
        }
    }

    FloatingActionButton {
        visible: root.canManageStaff || root.canInviteMembers
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: dp(Constants.space5)
        anchors.bottomMargin: dp(96)
        onClicked: {
            // Owner/admin can both create staff and invite existing users →
            // offer the choice sheet. Others can only add staff → go direct.
            if (root.canInviteMembers)
                root.staffActionsRequested()
            else
                root.addStaffClicked()
        }
    }

    function _filteredStaff() {
        var arr = (StaffStore.staff || []).slice()
        var q = (root._searchText || "").toLowerCase().trim()
        if (q.length === 0) return arr
        return arr.filter(function(s) {
            var hay = (s.name + " " + (s.role || "") + " " + (s.department || "") + " " + (s.email || "")).toLowerCase()
            return hay.indexOf(q) >= 0
        })
    }
}
