import QtQuick
import QtQuick.Controls as QQC

import "../helper"
import "../helper/RefreshCaption.js" as RefreshCaption

// Small refresh button for a page's GlassHeader `actions` (L4b, reshaped after the PR #186 device test: the
// always-visible "Updated N min ago" row was too loud). A tap refreshes. A short caption ("Refreshing…", then
// "Updated just now") floats under the button and fades a few seconds after the refresh settles. Nothing else is
// ever on screen: an automatic refresh (resume, reconnect) never shows a caption, only a tap on THIS button does.
// Pure props plus one signal; the page wires it to `app` (the GlassHeader precedent):
//
//   RefreshAction {
//       lastSyncMs: app.refreshLastSyncMs
//       refreshState: app.refreshState
//       online: app.isOnline
//       onRefreshRequested: app.requestManualRefresh()
//   }
//
// What the caption says is decided by RefreshCaption.js (tested in Node and in Qt); this file only draws it.
// A tap is never swallowed: offline, too soon or busy are answered by the toast that app.requestManualRefresh()
// already shows, and the caption says "Offline · Updated 5 min ago" / "Waiting to refresh…".
Item {
    id: root

    property real lastSyncMs: 0                 // DataModel.lastSyncMs
    property bool online: true                  // AuthService.isOnline
    property string refreshState: "idle"        // DataModel.refreshState: "idle" | "waiting" | "running"

    signal refreshRequested()

    // The age text is a function of the clock; the caption lives for seconds, so the time is read at the tap and
    // again whenever the sync time or the state changes. No timer ticks while nothing is shown.
    property real _now: Date.now()
    // True from a tap on this button until the caption has been idle for a while.
    property bool _armed: false
    readonly property var _view: RefreshCaption.view({
        online: root.online, state: root.refreshState, lastSyncMs: root.lastSyncMs, nowMs: root._now })

    function _tick() { _now = Date.now() }
    onLastSyncMsChanged: _tick()
    onRefreshStateChanged: _tick()
    onVisibleChanged: if (visible) _tick()

    function _tap() {
        _tick()
        _armed = true
        root.refreshRequested()
    }

    on_ArmedChanged: if (_armed) pill.open(); else pill.close()

    // The caption stays while a refresh is under way (busy) and for 3.5 s after it settles. `running` restarts the
    // countdown every time the refresh goes busy -> idle.
    Timer {
        interval: 3500
        running: root._armed && !root._view.busy
        onTriggered: root._armed = false
    }

    implicitWidth: dp(38)
    implicitHeight: dp(38)

    Accessible.role: Accessible.Button
    Accessible.name: RefreshCaption.accessibleName(root._view)
    Accessible.onPressAction: if (!root._view.busy) root._tap()

    IconActionButton {
        id: button
        anchors.fill: parent
        variant: "ghost"
        iconName: root._view.busy ? "" : "retry"
        enabled: !root._view.busy
        opacity: 0.7
        Accessible.ignored: true   // the wrapper above is the one accessible element
        onClicked: root._tap()
    }

    QQC.BusyIndicator {
        anchors.centerIn: parent
        width: dp(20)
        height: dp(20)
        running: root._view.busy
        visible: root._view.busy
    }

    // A Popup draws in the window Overlay, above the page, and is anchored to the button. Not modal, takes no
    // focus, and never closes itself on an outside press: only the countdown above closes it.
    QQC.Popup {
        id: pill
        parent: button
        x: button.width - width
        y: button.height + dp(6)
        padding: dp(Constants.space2)
        modal: false
        focus: false
        closePolicy: QQC.Popup.NoAutoClose

        enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Constants.durFast } }
        exit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: Constants.durFast } }

        background: Rectangle {
            radius: dp(Constants.radiusSm)
            color: Constants.elevatedBg
            border.color: Constants.borderColor
        }
        contentItem: Text {
            text: root._view.text
            font.pixelSize: sp(Constants.fsSmall)
            color: Constants.textSecondary
        }
    }
}
