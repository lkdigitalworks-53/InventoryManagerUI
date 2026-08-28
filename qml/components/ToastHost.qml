import QtQuick

import "../helper"

// Toast layer — renders Toast.show(...) requests as a slide-up pill.
Item {
    id: host
    z: 9999

    Connections {
        target: Toast
        function onShowRequested(msg) { host._showInternal(msg) }
    }

    function show(msg) { _showInternal(msg) }

    function _showInternal(msg) {
        if (!msg || msg.length === 0) return
        pillText.text = msg
        pill.opacity = 1
        slideUp.restart()
        dismissTimer.restart()
    }

    Timer {
        id: dismissTimer
        interval: 5000
        repeat: false
        running: false
        onTriggered: slideDown.restart()
    }

    Rectangle {
        id: pill
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent ? parent.height : 600
        width: Math.min(parent ? parent.width - dp(40) : dp(360), pillText.implicitWidth + dp(32))
        height: dp(40)
        radius: dp(Constants.radiusPill)
        color: Qt.rgba(0.008, 0.024, 0.090, 0.92)
        opacity: 0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: Constants.durMed } }

        NumberAnimation {
            id: slideUp
            target: pill
            property: "y"
            to: pill.parent ? pill.parent.height - dp(Constants.tabbarClearance) : 490
            duration: Constants.durMed
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            id: slideDown
            target: pill
            property: "y"
            to: pill.parent ? pill.parent.height : 600
            duration: Constants.durMed
            easing.type: Easing.InCubic
            onFinished: pill.opacity = 0
        }

        Text {
            id: pillText
            anchors.centerIn: parent
            color: Constants.textOnBrand
            font.pixelSize: sp(Constants.fsBody)
        }
    }
}
