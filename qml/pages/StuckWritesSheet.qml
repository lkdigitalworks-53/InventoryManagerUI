import QtQuick
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Lists writes that keep failing server-side (Gateway.stuckRows) and lets the
// user retry one now. Rejected (parked) writes are paused until Retry (S2b). Opened by tapping the GlassHeader caption (app.openStuckWrites).
// No Discard here yet: see docs/superpowers/specs/2026-09-29-gateway-park-retry-discard-plan.md (S3).
BottomSheet {
    id: root

    sheetTitle: qsTr("Changes not syncing")
    primaryAction: ""
    secondaryAction: qsTr("Close")

    // Re-read the rows whenever any of these move. The reads are the point of the
    // bindings, not the values.
    property int _stuckWatcher: Gateway.stuckCount
    property int _outboxWatcher: OutboxStore.revision
    property int _inFlightWatcher: OutboxStore.inFlightCount
    property var _rows: {
        root._stuckWatcher; root._outboxWatcher; root._inFlightWatcher
        return Gateway.stuckRows()
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space2)

        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsCaption)
            text: root._rows.length === 0
                ? qsTr("Nothing is stuck right now.")
                : qsTr("These changes are saved on this device. Rejected ones wait until you tap Retry; the rest keep retrying.")
        }

        Repeater {
            model: root._rows

            delegate: Rectangle {
                id: row
                required property var modelData

                Layout.fillWidth: true
                implicitHeight: rowLayout.implicitHeight + dp(Constants.space3) * 2
                radius: dp(Constants.radiusSm)
                color: Constants.cardBg
                border.color: Constants.borderColor
                border.width: 1

                RowLayout {
                    id: rowLayout
                    anchors.fill: parent
                    anchors.margins: dp(Constants.space3)
                    spacing: dp(Constants.space2)

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: dp(2)

                        Text {
                            Layout.fillWidth: true
                            text: row.modelData.title
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBodyLg)
                            font.bold: true
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: row.modelData.detail.length > 0
                            text: row.modelData.detail
                            color: Constants.textSecondary
                            font.pixelSize: sp(Constants.fsBody)
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: row.modelData.inFlight ? qsTr("Sending…")
                                : row.modelData.rejected ? qsTr("Rejected by the server. Paused until you tap Retry.")
                                : qsTr("Not syncing. Still retrying.")
                            color: row.modelData.inFlight ? Constants.textSecondary : Constants.danger
                            font.pixelSize: sp(Constants.fsCaption)
                            wrapMode: Text.WordWrap
                        }
                    }

                    GhostButton {
                        text: row.modelData.rejected ? qsTr("Retry") : qsTr("Retry now")
                        enabled: !row.modelData.inFlight
                        onClicked: {
                            if (Gateway.retryStuck(row.modelData.requestId))
                                Toast.show(qsTr("Retrying…"))
                        }
                    }
                }
            }
        }
    }
}
