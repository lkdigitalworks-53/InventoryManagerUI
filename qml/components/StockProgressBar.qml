import QtQuick

import "../helper"

// Thin horizontal progress bar. `value` 0..1. Tints red at low stock.
Item {
    id: root

    property real value: 0.5
    property bool low: false
    property int barWidth: dp(64)

    implicitWidth: barWidth
    implicitHeight: dp(6)

    Rectangle {
        anchors.fill: parent
        radius: dp(Constants.radiusPill)
        color: Qt.rgba(0.058, 0.090, 0.165, 0.08)
        clip: true

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * Math.max(0.04, Math.min(1, root.value))
            radius: dp(Constants.radiusPill)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop {
                    position: 0.0
                    color: root.low ? "#f59e0b" : Constants.brand2
                }
                GradientStop {
                    position: 1.0
                    color: root.low ? "#ef4444" : Constants.brand3
                }
            }
            Behavior on width { NumberAnimation { duration: Constants.durMed } }
        }
    }
}
