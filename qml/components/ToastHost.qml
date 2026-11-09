import QtQuick
import QtQuick.Controls as QQC

import "../helper"

// Toast layer — renders Toast.show(...) requests as a slide-up pill.
//
// Layering. Every dialog and bottom sheet is a Popup, and Qt draws all popups in the window's Overlay, which sits
// above the whole item tree of the window (QQuickOverlay z = 1000001). A pill that stays a child of this host is
// ordered only against its siblings, so it was always drawn UNDER an open dialog, whatever z it had. While a toast
// shows, the pill therefore lives in the Overlay with a z above every popup (popups keep z 0); once it has slid
// away it returns here. Out of the Overlay while idle on purpose: an Overlay that has children is visible and sees
// every press first (it ignores the ones no popup claims), and the idle app should not be on that path.
Item {
    id: host
    z: 9999

    // The window's popup layer; null until the window exists. The pill then stays here (shown, but under dialogs).
    readonly property Item _layer: QQC.Overlay.overlay

    Connections {
        target: Toast
        function onShowRequested(msg) { host._showInternal(msg) }
    }

    function show(msg) { _showInternal(msg) }

    function _showInternal(msg) {
        if (!msg || msg.length === 0) return
        // A toast that arrives while the last one is leaving must not be hidden by that one finishing.
        slideDown.stop()
        pill.parent = host._layer ? host._layer : host
        pillText.text = msg
        pill.opacity = 1
        slideUp.restart()
        dismissTimer.restart()
    }

    // The toast has slid away: hide the pill and take it back out of the Overlay.
    function _release() {
        pill.opacity = 0
        pill.parent = host
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
        // Above every popup while in the Overlay; no effect while a child of this host.
        z: 10000
        // Not anchors.horizontalCenter: an anchor to `parent` breaks when the pill changes parent.
        x: parent ? (parent.width - width) / 2 : 0
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
            onFinished: host._release()
        }

        Text {
            id: pillText
            anchors.centerIn: parent
            color: Constants.textOnBrand
            font.pixelSize: sp(Constants.fsBody)
        }
    }
}
