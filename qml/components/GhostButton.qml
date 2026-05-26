import QtQuick
import QtQuick.Controls as QQC

import "../helper"

// Outlined ghost button — secondary actions in sheets and forms.
QQC.Button {
    id: root

    property color textColor: Constants.textPrimary

    implicitHeight: dp(48)
    padding: dp(8)
    leftPadding: dp(16)
    rightPadding: dp(16)
    flat: true

    contentItem: Text {
        text: root.text
        color: root.enabled ? root.textColor : Constants.textMuted
        font.pixelSize: sp(Constants.fsBodyLg)
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    background: Rectangle {
        radius: dp(14)
        color: root.pressed ? Qt.rgba(0,0,0,0.04) : "transparent"
        border.color: Constants.borderColor
        border.width: 1
        Behavior on color { ColorAnimation { duration: Constants.durFast } }
    }
}
