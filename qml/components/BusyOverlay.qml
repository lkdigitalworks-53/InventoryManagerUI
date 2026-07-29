import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

// BusyOverlay.qml — Karobar — full-sheet "unmistakable busy" indicator.
//
// No Figma source for this one (nothing to extract), so this follows the
// project's own existing token/spacing conventions (Constants.qml,
// dp()/sp()) rather than the Figma-extraction workflow.
//
// Sits above a BottomSheet's own content, blocking taps on it while a
// longer-running operation is in flight. Deliberately more solid and more
// prominent than the small button-level BusyIndicator every BottomSheet
// already gets for free via `loading: root.busy` on its PrimaryButton —
// that one is fine for a sub-second action, not reassuring enough on its
// own for something that takes several seconds.
//
// Usage (from within BottomSheet.qml):
//   BusyOverlay {
//       anchors.fill: parent
//       active: root.busy && root.busyMessage.length > 0
//       message: root.busyMessage
//   }
Item {
    id: root

    property bool active: false
    property string message: ""

    // No explicit z — this is added as the LAST declared sibling in its
    // parent, which alone puts it on top (Qt Quick z-ordering follows
    // declaration order; an explicit z is only needed when declaration
    // order can't express the desired stacking).
    visible: opacity > 0
    // A one-shot, infrequent transition (once when an operation starts,
    // once when it ends) — not a continuously-running or rapidly-toggled
    // animation, so the usual "avoid opacity on a complex subtree" caution
    // doesn't weigh much here; the smoother arrival/departure is worth the
    // one-off compositing cost. Duration comes from the project's own
    // token, not a hardcoded number.
    opacity: active ? 1 : 0
    Behavior on opacity {
        NumberAnimation { duration: Constants.durMed; easing.type: Easing.OutCubic }
    }

    Accessible.role: Accessible.AlertMessage
    Accessible.name: root.message.length > 0 ? root.message : qsTr("Busy, please wait")

    Rectangle {
        anchors.fill: parent
        radius: Constants.radius
        color: Qt.rgba(Constants.cardBg.r, Constants.cardBg.g, Constants.cardBg.b, 0.94)
    }

    // Absorb every tap/click so nothing underneath reacts while this is up.
    MouseArea {
        anchors.fill: parent
        onClicked: {}
        onPressed: {}
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: Constants.space4

        QQC.BusyIndicator {
            Layout.alignment: Qt.AlignHCenter
            running: root.visible
            implicitWidth: dp(40)
            implicitHeight: dp(40)
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: dp(260)
            visible: root.message.length > 0
            text: root.message
            color: Constants.textPrimary
            font.pixelSize: sp(Constants.fsBodyLg)
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: dp(260)
            text: qsTr("Don't close the app or press back")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsBody)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
    }
}
