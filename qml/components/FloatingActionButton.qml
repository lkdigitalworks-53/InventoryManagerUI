import QtQuick
import QtQuick.Controls as QQC

import "../helper"

// Single-action FAB anchored bottom-right of a page (above the tabbar).
// Icon glyph is centered using an explicit Item content + Text overlay so
// AbstractButton's default padding can't offset the visual.
QQC.AbstractButton {
    id: root

    property string emoji: "＋"
    property var palette: ({ start: Constants.brand1, end: Constants.brand3 })

    implicitWidth: dp(56)
    implicitHeight: dp(56)
    padding: 0
    topPadding: 0
    bottomPadding: 0
    leftPadding: 0
    rightPadding: 0

    background: Rectangle {
        radius: dp(Constants.radiusLg)
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: root.palette.start }
            GradientStop { position: 1.0; color: root.palette.end }
        }
        scale: root.pressed ? 0.96 : 1.0
        Behavior on scale { NumberAnimation { duration: Constants.durFast } }
    }

    contentItem: Item {
        Text {
            anchors.centerIn: parent
            // Apply small visual offset compensation: the glyph's optical
            // baseline sits below the geometric centre, so nudge up by 1dp.
            anchors.verticalCenterOffset: -dp(1)
            text: root.emoji
            color: Constants.textOnBrand
            font.pixelSize: sp(28)
            font.bold: true
        }
    }
}
