import QtQuick
import QtQuick.Controls as QQC

import "../helper"
import "../helper/ToastLayout.js" as TL

// Toast layer — renders Toast.show(...) requests as a slide-up pill.
//
// Wrapping (S5e-2, KNOWN-ISSUES 26). The pill used to be one unwrapped line of a fixed 40 dp, so a message of 80 to 134
// characters was cut at both edges. Now `measure` (a hidden, unwrapped copy of the text) gives the one-line width, the
// pill is that wide up to the layer minus 40 dp, the text wraps inside it (at most TL.MAX_LINES, then an ellipsis) and
// the pill grows upward to fit. The sums are in qml/helper/ToastLayout.js (tested headless); this file only binds them.
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
        dismissTimer.interval = TL.dismissMs(msg)
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
        // 0 = parked below the layer, 1 = resting. The two slides animate THIS property (it has no binding, so nothing
        // fights the animation) and y is derived from it, so the pill follows a layer that changes height.
        property real rise: 0
        // The old single-line height; also the floor of the grown pill.
        readonly property real _minHeight: dp(40)
        // Above every popup while in the Overlay; no effect while a child of this host.
        z: 10000
        // Not anchors.horizontalCenter: an anchor to `parent` breaks when the pill changes parent.
        x: parent ? (parent.width - width) / 2 : 0
        y: parent ? TL.pillY(parent.height, rise, height, dp(Constants.tabbarClearance), _minHeight) : 600
        width: TL.pillWidth(measure.implicitWidth, parent ? parent.width - dp(40) : dp(360), dp(32))
        height: TL.pillHeight(pillText.contentHeight, _minHeight, dp(16))
        radius: dp(Constants.radiusPill)
        color: Qt.rgba(0.008, 0.024, 0.090, 0.92)
        opacity: 0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: Constants.durMed } }

        NumberAnimation {
            id: slideUp
            target: pill
            property: "rise"
            to: 1
            duration: Constants.durMed
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            id: slideDown
            target: pill
            property: "rise"
            to: 0
            duration: Constants.durMed
            easing.type: Easing.InCubic
            onFinished: host._release()
        }

        // The message on ONE line, only to learn how wide it wants to be. Hidden and never wrapped, so it cannot depend
        // on the pill (the pill width depends on it: wrapping this one would be a binding loop).
        Text {
            id: measure
            visible: false
            text: pillText.text
            font: pillText.font
        }

        Text {
            id: pillText
            anchors.centerIn: parent
            width: TL.textWidth(pill.width, dp(32))
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: TL.MAX_LINES
            elide: Text.ElideRight
            color: Constants.textOnBrand
            font.pixelSize: sp(Constants.fsBody)
        }
    }
}
