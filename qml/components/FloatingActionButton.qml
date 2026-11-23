import QtQuick
import QtQuick.Controls as QQC

import "../helper"

// Single-action FAB anchored bottom-right of a page (above the tabbar).
// Icon glyph is centered using an explicit Item content + Text overlay so
// AbstractButton's default padding can't offset the visual.
QQC.AbstractButton {
    id: root

    property string iconName: "add"
    // Spoken name (TalkBack). Every instance passes one: the icon alone would be read as "add".
    property string label: ""
    property var palette: ({ start: Constants.brand1, end: Constants.brand3 })

    implicitWidth: dp(56)
    implicitHeight: dp(56)
    padding: 0
    topPadding: 0
    bottomPadding: 0
    leftPadding: 0
    rightPadding: 0

    Accessible.role: Accessible.Button
    Accessible.name: root.label

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
        Icon {
            anchors.centerIn: parent
            name: root.iconName
            color: Constants.textOnBrand
            size: sp(28)
        }
    }
}
