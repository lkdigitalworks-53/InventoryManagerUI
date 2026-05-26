import QtQuick

import "../helper"

// Modern status chip used across order rows, inventory cards, etc.
// Knows: pending | processing | completed | cancelled | low | active | out-of-stock.
Rectangle {
    id: root

    property string status: "pending"
    property string label: ""
    property bool large: false

    readonly property var _palettes: ({
        "pending":      { fill: Constants.pendingFill,    text: Constants.pendingText,    stroke: Constants.pendingStroke },
        "processing":   { fill: Constants.processingFill, text: Constants.processingText, stroke: Constants.processingStroke },
        "completed":    { fill: Constants.completedFill,  text: Constants.completedText,  stroke: Constants.completedStroke },
        "active":       { fill: Constants.completedFill,  text: Constants.completedText,  stroke: Constants.completedStroke },
        "cancelled":    { fill: Constants.cancelledFill,  text: Constants.cancelledText,  stroke: Constants.cancelledStroke },
        "low":          { fill: Constants.lowFill,        text: Constants.lowText,        stroke: Constants.danger },
        "out of stock": { fill: Constants.cancelledFill,  text: Constants.cancelledText,  stroke: Constants.cancelledStroke },
        "on leave":     { fill: Constants.pendingFill,    text: Constants.pendingText,    stroke: Constants.pendingStroke },
        "inactive":     { fill: Constants.subtleBg,       text: Constants.textSecondary,  stroke: Constants.borderColor }
    })
    readonly property var _palette: _palettes[status.toLowerCase()] || _palettes["pending"]

    color: _palette.fill
    border.color: Qt.rgba(_palette.stroke.r, _palette.stroke.g, _palette.stroke.b, 0.2)
    border.width: 1
    radius: dp(Constants.radiusPill)
    implicitHeight: large ? dp(28) : dp(22)
    implicitWidth: txt.implicitWidth + (large ? dp(24) : dp(20))

    Text {
        id: txt
        anchors.centerIn: parent
        text: root.label.length > 0 ? root.label : root.status
        color: root._palette.text
        font.pixelSize: root.large ? sp(Constants.fsSmall) : sp(Constants.fsCaption)
        font.bold: true
    }
}
