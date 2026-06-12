import QtQuick
import QtQuick.Layouts

import "../helper"

// Sticky page header with glassmorphism. Hosts a title (left) and an arbitrary
// action row (right). Drop into the top of any page above a Flickable.
Rectangle {
    id: root

    property string title: ""
    property string subtitle: ""
    property string greeting: ""              // optional small line above title
    property alias actions: actionRow.data    // append IconActionButton instances
    property alias leading: leadingHolder.data
    property bool elevated: true

    // Top safe-area inset (status bar / cutout). The glass background still
    // paints up under the status bar, but the tappable title/action row drops
    // below it by this amount. 0 on desktop. Callers pass SafeArea.top.
    property real topInset: 0

    height: dp(64) + topInset
    color: Constants.glassBg
    border.color: Constants.borderColor
    border.width: 0
    z: 5

    // Bottom hairline — provides visual seam between header and scroll content.
    Rectangle {
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: 1; color: Constants.borderColor; opacity: 0.6
    }

    RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.top: parent.top
        anchors.topMargin: root.topInset
        anchors.leftMargin: dp(Constants.space4)
        anchors.rightMargin: dp(Constants.space4)
        spacing: dp(Constants.space2)

        // Optional leading slot (e.g. back button). Fills the row height so
        // any single child can use anchors.verticalCenter to sit centered
        // with the title text on the right.
        Item {
            id: leadingHolder
            Layout.preferredWidth: childrenRect.width
            Layout.fillHeight: true
            Layout.alignment: Qt.AlignVCenter
            visible: children.length > 0
        }

        ColumnLayout {
            spacing: dp(2)
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter

            Text {
                visible: root.greeting.length > 0
                text: root.greeting
                font.pixelSize: sp(Constants.fsSmall)
                color: Constants.textSecondary
            }

            Text {
                text: root.title
                font.pixelSize: root.greeting.length > 0 ? sp(Constants.fsH2) : sp(Constants.fsH3)
                font.bold: true
                color: Constants.textPrimary
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Text {
                visible: root.subtitle.length > 0 && root.greeting.length === 0
                text: root.subtitle
                font.pixelSize: sp(Constants.fsCaption)
                color: Constants.textSecondary
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        RowLayout {
            id: actionRow
            spacing: dp(Constants.space2)
            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
        }
    }
}
