import QtQuick
import QtQuick.Controls as QQC

import "../helper"

// Square 38×38 icon button used across glass headers and floating bars.
// Variants: "default" (white bg + border), "ghost" (transparent), "glass" (elevated bg).
QQC.Button {
    id: root

    property string variant: "default"  // "default" | "ghost" | "glass"
    property string iconName: ""
    property string badgeText: ""

    implicitWidth: dp(38)
    implicitHeight: dp(38)
    flat: true
    padding: 0

    background: Rectangle {
        radius: dp(Constants.radiusSm + 2)
        color: root.variant === "ghost"
                ? "transparent"
                : (root.variant === "glass"
                    ? Constants.elevatedBg
                    : Constants.cardBg)
        border.color: root.variant === "ghost" ? "transparent" : Constants.borderColor
        border.width: root.variant === "ghost" ? 0 : 1
        opacity: root.pressed ? 0.85 : 1.0
        Behavior on opacity { NumberAnimation { duration: Constants.durFast } }
    }

    contentItem: Item {
        Text {
            anchors.centerIn: parent
            text: root.text
            font.pixelSize: sp(18)
            color: Constants.textPrimary
            visible: root.iconName.length === 0
        }
        Icon {
            anchors.centerIn: parent
            name: root.iconName
            size: sp(18)
            color: Constants.textPrimary
            visible: root.iconName.length > 0
        }
        // Tiny notification badge (e.g. on the bell icon)
        Rectangle {
            visible: root.badgeText.length > 0
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: dp(-2)
            anchors.topMargin: dp(-2)
            width: Math.max(dp(16), badgeLbl.implicitWidth + dp(6))
            height: dp(16)
            radius: dp(8)
            color: Constants.brand3
            Text {
                id: badgeLbl
                anchors.centerIn: parent
                text: root.badgeText
                color: Constants.textOnBrand
                font.pixelSize: sp(10)
                font.bold: true
            }
        }
    }
}
