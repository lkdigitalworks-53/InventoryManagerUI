import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"

// Staff FAB choice sheet — owner/admin pick between creating a new teammate
// (with login credentials) and inviting someone who already has an account.
// Thin router: emits a signal per choice; Main.qml opens the matching dialog.
BottomSheet {
    id: root

    sheetTitle: qsTr("Add to team")
    primaryAction: ""
    secondaryAction: qsTr("Cancel")

    signal addStaffSelected()
    signal inviteSelected()

    ListCard {
        Layout.fillWidth: true
        title: qsTr("Add staff member")
        subtitle: qsTr("Create a login for a new teammate")
        onClicked: { root.addStaffSelected(); root.close() }

        leading: Rectangle {
            width: dp(38); height: dp(38); radius: dp(12)
            color: Qt.rgba(0.39, 0.40, 0.95, 0.10)
            Icon { anchors.centerIn: parent; name: "staff"; size: sp(18); color: Constants.textPrimary }
        }

        Icon {
            name: "chevron"
            color: Constants.textMuted
            size: sp(16)
            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
        }
    }

    ListCard {
        Layout.fillWidth: true
        title: qsTr("Invite existing user")
        subtitle: qsTr("Add someone who already has an account")
        onClicked: { root.inviteSelected(); root.close() }

        leading: Rectangle {
            width: dp(38); height: dp(38); radius: dp(12)
            color: Qt.rgba(0.39, 0.40, 0.95, 0.10)
            Icon { anchors.centerIn: parent; name: "add"; size: sp(18); color: Constants.textPrimary }
        }

        Icon {
            name: "chevron"
            color: Constants.textMuted
            size: sp(16)
            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
        }
    }
}
