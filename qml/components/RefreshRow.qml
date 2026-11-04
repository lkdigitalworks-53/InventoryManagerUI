import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"
import "../helper/RefreshCaption.js" as RefreshCaption

// "Updated 3 min ago" row with tap-to-refresh (L4b). First child of a page's content column, where a pull
// indicator would sit. Pure props plus one signal: the page wires it to `app` (the GlassHeader precedent):
//
//   RefreshRow {
//       Layout.fillWidth: true
//       lastSyncMs: app.refreshLastSyncMs
//       refreshState: app.refreshState
//       online: app.isOnline
//       onRefreshRequested: app.requestManualRefresh()
//   }
//
// What it says and when it can be tapped is decided by RefreshCaption.js (tested in Node and in Qt); this file
// only draws it. Design: docs/superpowers/specs/2026-11-04-l4b-refresh-row-design.md (B-D1..B-D9).
Item {
    id: root

    property real lastSyncMs: 0                 // DataModel.lastSyncMs
    property bool online: true                  // AuthService.isOnline
    property string refreshState: "idle"        // DataModel.refreshState: "idle" | "waiting" | "running"

    signal refreshRequested()

    // The age text is a function of the clock, so a timer keeps it honest. It runs only while the row is visible.
    property real _now: Date.now()
    readonly property var _view: RefreshCaption.view({
        online: root.online, state: root.refreshState, lastSyncMs: root.lastSyncMs, nowMs: root._now })

    function _tick() { _now = Date.now() }
    onLastSyncMsChanged: _tick()
    onRefreshStateChanged: _tick()
    onVisibleChanged: if (visible) _tick()

    Timer {
        interval: 30000
        repeat: true
        running: root.visible
        onTriggered: root._tick()
    }

    implicitHeight: dp(48)   // the whole row is the tap target (48 dp is the Material minimum)

    Accessible.role: Accessible.Button
    Accessible.name: RefreshCaption.accessibleName(root._view)
    Accessible.onPressAction: if (root._view.enabled) root.refreshRequested()

    RowLayout {
        anchors.centerIn: parent
        spacing: dp(Constants.space2)

        // One fixed slot for the icon or the spinner, so the text does not jump when the state changes.
        Item {
            Layout.preferredWidth: dp(18)
            Layout.preferredHeight: dp(18)
            Layout.alignment: Qt.AlignVCenter

            Icon {
                anchors.centerIn: parent
                visible: !root._view.busy
                name: "retry"
                size: sp(14)
                color: root._view.enabled ? Constants.accentBlue : Constants.textMuted
            }
            QQC.BusyIndicator {
                anchors.fill: parent
                visible: root._view.busy
                running: root._view.busy
            }
        }

        Text {
            text: root._view.text
            font.pixelSize: sp(Constants.fsSmall)
            color: root._view.enabled ? Constants.textSecondary : Constants.textMuted
            elide: Text.ElideRight
            Layout.alignment: Qt.AlignVCenter
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root._view.enabled
        onClicked: root.refreshRequested()
    }
}
