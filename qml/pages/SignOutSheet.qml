import QtQuick
import QtQuick.Layouts

import "../components"
import "../helper"
import "../helper/SignOutGuard.js" as SignOutGuard
import "../model"

// Shown instead of the plain "Sign out?" / "Leave workspace?" confirm when queued
// writes or photo uploads would be discarded. Lists them, says what is lost, and
// makes staying the easy choice: Stay is the primary button, Back / tap outside / X all
// mean Stay, and the destructive button is secondary and red. Live: if the queue
// drains while the sheet is open it says so and the button turns into the plain action.
// All wording and row logic is SignOutGuard.js (tested headlessly); this file is the view.
// Opened by Main.qml askLeave(). Design: docs/superpowers/specs/2026-10-26-signout-guard-design.md
BottomSheet {
    id: root

    // true = leave-workspace wording; false = sign-out wording. Set by ask().
    property bool leaving: false
    property var _proceed: null

    // Re-read the summary whenever any of these move. The reads are the point of the
    // bindings, not the values.
    property int _outboxWatcher: OutboxStore.revision
    property int _inFlightWatcher: OutboxStore.inFlightCount
    property int _photoWatcher: PhotoQueue.revision
    property var _guard: {
        root._outboxWatcher; root._inFlightWatcher; root._photoWatcher
        return root._summarize()
    }

    sheetTitle: root.leaving ? qsTr("Leave with unsynced work?") : qsTr("Sign out with unsynced work?")
    primaryAction: root.leaving ? qsTr("Stay in workspace") : qsTr("Stay signed in")
    secondaryAction: root._guard.count > 0
        ? (root.leaving ? qsTr("Leave and discard") : qsTr("Sign out and discard"))
        : (root.leaving ? qsTr("Leave workspace") : qsTr("Sign out"))
    secondaryColor: Constants.danger

    function _summarize() {
        return SignOutGuard.build(OutboxStore.items, PhotoQueue.items, {
            leaving: root.leaving,
            inFlight: function(requestId) { return OutboxStore.isInFlight(requestId) },
            productName: function(productId) {
                var p = InventoryStore.getById(productId)
                return p ? p.name : ""
            }
        })
    }

    // How many queued items signing out would discard right now.
    function pendingCount() { return SignOutGuard.build(OutboxStore.items, PhotoQueue.items).count }

    // opts = { leaving: bool, proceed: function }. `proceed` runs only when the person
    // taps the secondary button.
    function ask(opts) {
        root.leaving = opts.leaving === true
        root._proceed = (typeof opts.proceed === "function") ? opts.proceed : null
        open()
    }

    onPrimaryClicked: close()
    onSecondaryClicked: {
        var go = root._proceed
        root._proceed = null
        if (go) go()
    }
    onClosed: root._proceed = null

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space2)

        Text {
            Layout.fillWidth: true
            text: root._guard.summary
            color: Constants.textPrimary
            font.pixelSize: sp(Constants.fsBodyLg)
            font.bold: true
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: root._guard.rows

            delegate: Rectangle {
                id: row
                required property var modelData

                Layout.fillWidth: true
                implicitHeight: rowLayout.implicitHeight + dp(Constants.space3) * 2
                radius: dp(Constants.radiusSm)
                color: Constants.cardBg
                border.color: Constants.borderColor
                border.width: 1

                Accessible.role: Accessible.ListItem
                Accessible.name: row.modelData.title + " " + row.modelData.detail + " " + row.modelData.stateLabel

                ColumnLayout {
                    id: rowLayout
                    anchors.fill: parent
                    anchors.margins: dp(Constants.space3)
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
                    // Words, not only colour: the tag is readable without seeing red.
                    Text {
                        Layout.fillWidth: true
                        text: row.modelData.stateLabel
                        color: row.modelData.state === "attention" ? Constants.danger : Constants.textSecondary
                        font.pixelSize: sp(Constants.fsCaption)
                        font.bold: row.modelData.state === "attention"
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root._guard.more > 0
            text: qsTr("+ %1 more").arg(root._guard.more)
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsBody)
        }

        Repeater {
            model: root._guard.consequences

            delegate: Text {
                required property string modelData

                Layout.fillWidth: true
                Layout.topMargin: dp(Constants.space1)
                text: modelData
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsBody)
                wrapMode: Text.WordWrap
            }
        }
    }
}
