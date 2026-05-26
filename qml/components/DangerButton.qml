import QtQuick
import QtQuick.Controls as QQC

import "../helper"

// Soft danger button — translucent red surface with red text.
QQC.Button {
    id: root

    implicitHeight: dp(48)
    padding: dp(8)
    leftPadding: dp(16)
    rightPadding: dp(16)
    flat: true

    contentItem: Text {
        text: root.text
        color: root.enabled ? Constants.danger : Constants.textMuted
        font.pixelSize: sp(Constants.fsBodyLg)
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    background: Rectangle {
        radius: dp(14)
        color: root.pressed ? Qt.rgba(0.93, 0.27, 0.27, 0.18) : Qt.rgba(0.93, 0.27, 0.27, 0.10)
        border.color: Qt.rgba(0.93, 0.27, 0.27, 0.25)
        border.width: 1
        Behavior on color { ColorAnimation { duration: Constants.durFast } }
    }
}
