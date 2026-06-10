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
        anchors.rightMargin: dp(6)
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
            background: Item {}
            verticalAlignment: TextInput.AlignVCenter
            onAccepted: root.accepted()
        }

        QQC.AbstractButton {
            visible: input.text.length > 0
            implicitWidth: dp(28)
            implicitHeight: dp(28)
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
