import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

// Rounded search field with a leading magnifier glyph.
Rectangle {
    id: root

    property alias text: input.text
    property alias placeholder: input.placeholderText
    property alias inputItem: input
    signal accepted()
    signal cleared()

    implicitHeight: dp(44)
    radius: dp(14)
    color: Constants.cardBg
    border.color: Constants.borderColor
    border.width: 1

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: dp(12)
        anchors.rightMargin: 0
        spacing: dp(8)

        Icon {
            name: "search"
            size: sp(14)
            color: Constants.textSecondary
        }

        QQC.TextField {
            id: input
            Layout.fillWidth: true
            Layout.fillHeight: true
            placeholderText: "Search…"
            font.pixelSize: sp(Constants.fsBody)
            // S5e-3c: the pill is a fixed light fill, so the typed text and the hint are pinned, not left to the system palette
            color: Constants.textPrimary
            placeholderTextColor: Constants.textSecondary
            background: Item {}
            verticalAlignment: TextInput.AlignVCenter
            Accessible.name: input.placeholderText    // S5e-1: named by what it searches, whatever the page set
            onAccepted: root.accepted()
        }

        // S5e-1 (KNOWN-ISSUES 94): was an unnamed 28 dp button. Now named, and as tall as the field (44 dp; the field
        // height is shared by five pages, so 48 would change them all). The icon is centred in the wider target.
        QQC.AbstractButton {
            visible: input.text.length > 0
            implicitWidth: dp(44)
            implicitHeight: dp(44)
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Clear search")
            contentItem: Icon {
                name: "close"
                anchors.centerIn: parent
                color: Constants.textSecondary
                size: sp(13)
            }
            onClicked: { input.text = ""; root.cleared() }
        }
    }
}
