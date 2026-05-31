import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"

// Member management — bottom sheet. Public contract preserved:
//   signals: roleUpdateRequested, statusUpdateRequested,
//            removeMemberRequested, refreshRequested
//   properties: members, busy, errorMessage, searchText, filterRole
BottomSheet {
    id: root

    sheetTitle: "Team members"
    primaryAction: ""
    secondaryAction: "Close"

    signal roleUpdateRequested(string uid, string role)
    signal statusUpdateRequested(string uid, string status)
    signal removeMemberRequested(string uid)
    signal refreshRequested()

    property var members: []
    property bool busy: false
    property string errorMessage: ""
    property string searchText: ""
    property string filterRole: "all"

    property string confirmAction: ""
    property string confirmUid: ""
    property string confirmRole: ""
    property string confirmStatus: ""
    property string confirmMessage: ""

    function _matchesFilter(m) {
        var q = (searchText || "").toLowerCase()
        var text = ((m.displayName || "") + " " + (m.email || "") + " " + (m.uid || "")).toLowerCase()
        var roleOk = filterRole === "all" || (m.role || "staff") === filterRole
        var queryOk = q.length === 0 || text.indexOf(q) >= 0
        return roleOk && queryOk
    }

    function _openConfirm(action, uid, role, status) {
        confirmAction = action
        confirmUid = uid || ""
        confirmRole = role || ""
        confirmStatus = status || ""

        if (action === "remove") {
            // Destructive — use the shared bottom-sheet ConfirmDialog so the
            // user sees the standard delete UX (red CTA, slide-up sheet).
            removeMemberConfirm.ask({
                title: qsTr("Remove member?"),
                message: qsTr("“%1” will lose access to this workspace. This cannot be undone.").arg(confirmUid),
                confirmLabel: qsTr("Remove"),
                onConfirm: function() { root.removeMemberRequested(confirmUid) }
            })
            return
        }

        if (action === "role")
            confirmMessage = "Set role for " + confirmUid + " to '" + confirmRole + "'?"
        else if (action === "status")
            confirmMessage = "Change status for " + confirmUid + " to '" + confirmStatus + "'?"
        confirmDlg.open()
    }

    ConfirmDialog { id: removeMemberConfirm }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        // Search + role filter row
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            SearchField {
                Layout.fillWidth: true
                placeholder: "Search by name, email, or UID"
                onTextChanged: root.searchText = text
            }
            AppComboBox {
                Layout.preferredWidth: dp(120)
                model: ["all", "owner", "admin", "manager", "staff"]
                currentIndex: 0
                font.pixelSize: sp(Constants.fsBody)
                onCurrentTextChanged: root.filterRole = currentText
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            Text {
                text: "Workspace membership and roles"
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsCaption)
                Layout.fillWidth: true
            }
            GhostButton {
                text: root.busy ? "Loading…" : "Refresh"
                implicitHeight: dp(36)
                Layout.preferredWidth: dp(110)
                enabled: !root.busy
                onClicked: root.refreshRequested()
            }
        }

        Text {
            visible: root.errorMessage.length > 0
            text: root.errorMessage
            color: Constants.danger
            font.pixelSize: sp(Constants.fsSmall)
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }

        // Member cards
        ColumnLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            Repeater {
                model: root.members
                delegate: ListCard {
                    Layout.fillWidth: true
                    visible: root._matchesFilter(modelData)
                    title: modelData.displayName || "(No name)"
                    subtitle: (modelData.email || "") + (modelData.uid ? "  ·  UID: " + modelData.uid : "")
                    implicitHeight: dp(96)

                    leading: AvatarBadge {
                        size: "lg"
                        label: ((modelData.displayName || modelData.email || "?").charAt(0) || "?").toUpperCase()
                        palette: index % 4 === 0 ? Constants.grad1
                               : index % 4 === 1 ? Constants.grad2
                               : index % 4 === 2 ? Constants.grad3
                               :                   Constants.grad4
                    }

                    RowLayout {
                        spacing: dp(Constants.space2)
                        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight

                        AppComboBox {
                            id: roleBox
                            Layout.preferredWidth: dp(96)
                            Layout.preferredHeight: dp(32)
                            model: ["owner", "admin", "manager", "staff"]
                            font.pixelSize: sp(Constants.fsCaption)
                            currentIndex: {
                                var r = modelData.role || "staff"
                                if (r === "owner") return 0
                                if (r === "admin") return 1
                                if (r === "manager") return 2
                                return 3
                            }
                            onActivated: root._openConfirm("role", modelData.uid || "", currentText, "")
                        }

                        // Compact icon-only Suspend/Activate (eye toggle) so the
                        // row fits inside a phone-width card without clipping.
                        QQC.AbstractButton {
                            Layout.preferredWidth: dp(32)
                            Layout.preferredHeight: dp(32)
                            enabled: !root.busy
                            background: Rectangle {
                                radius: dp(Constants.radiusPill)
                                color: Constants.subtleBg
                                border.color: Constants.borderColor
                                border.width: 1
                            }
                            contentItem: Item {
                                Text {
                                    anchors.centerIn: parent
                                    text: (modelData.status === "suspended") ? "✓" : "⏸"
                                    color: Constants.textSecondary
                                    font.pixelSize: sp(14)
                                    font.bold: true
                                }
                            }
                            QQC.ToolTip.visible: hovered
                            QQC.ToolTip.text: (modelData.status === "suspended") ? "Activate" : "Suspend"
                            onClicked: root._openConfirm("status", modelData.uid || "", "", modelData.status === "suspended" ? "active" : "suspended")
                        }

                        QQC.AbstractButton {
                            Layout.preferredWidth: dp(32)
                            Layout.preferredHeight: dp(32)
                            enabled: !root.busy
                            background: Rectangle {
                                radius: dp(Constants.radiusPill)
                                color: Qt.rgba(0.93, 0.27, 0.27, 0.10)
                                border.color: Qt.rgba(0.93, 0.27, 0.27, 0.25)
                                border.width: 1
                            }
                            contentItem: Item {
                                Text {
                                    anchors.centerIn: parent
                                    text: "✕"
                                    color: Constants.danger
                                    font.pixelSize: sp(14)
                                    font.bold: true
                                }
                            }
                            QQC.ToolTip.visible: hovered
                            QQC.ToolTip.text: "Remove member"
                            onClicked: root._openConfirm("remove", modelData.uid || "", "", "")
                        }
                    }
                }
            }
        }
    }

    // Inner confirm dialog — kept centred (legacy QQC.Dialog) since it overlays
    // on top of the BottomSheet which is already at the screen edge.
    QQC.Dialog {
        id: confirmDlg
        modal: true
        title: "Confirm action"
        anchors.centerIn: parent
        width: dp(420)
        standardButtons: QQC.Dialog.Yes | QQC.Dialog.No

        background: Rectangle {
            radius: dp(Constants.radius)
            color: Constants.cardBg
            border.color: Constants.borderColor
        }

        onAccepted: {
            if (root.confirmAction === "role")
                root.roleUpdateRequested(root.confirmUid, root.confirmRole)
            else if (root.confirmAction === "status")
                root.statusUpdateRequested(root.confirmUid, root.confirmStatus)
        }

        contentItem: Text {
            text: root.confirmMessage
            wrapMode: Text.Wrap
            color: Constants.textPrimary
            font.pixelSize: sp(Constants.fsBody)
            padding: dp(10)
        }
    }
}
