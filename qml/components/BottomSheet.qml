import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

// Modal bottom sheet matching the prototype.
//
// Sizing
//   • Width matches the overlay's width.
//   • Height is a FIXED 92% of the overlay — we deliberately don't compute
//     from contentLayout.implicitHeight. That math races with the body
//     ScrollView's deferred layout pass; on the first .open() the implicit
//     height is zero and the dialog appears squished. With a fixed cap, the
//     ScrollView absorbs short content (rendered top-aligned with empty space
//     below) and clips long content (scrollable). This is standard mobile
//     bottom-sheet behaviour and renders correctly on the first show.
QQC.Dialog {
    id: root

    property string sheetTitle: ""
    property string primaryAction: ""
    property string secondaryAction: "Cancel"
    property bool primaryEnabled: true
    property bool busy: false
    // Non-empty turns on the full-sheet BusyOverlay (see contentItem below)
    // instead of just the small button-level spinner PrimaryButton already
    // gets from `loading: root.busy` — opt-in, since a sub-second action
    // doesn't need it, only a genuinely longer-running one.
    property string busyMessage: ""
    property var primaryPalette: Constants.gradHero
    default property alias body: bodyHolder.data

    signal primaryClicked()
    signal secondaryClicked()

    modal: true
    parent: QQC.Overlay.overlay
    // Explicit about matching Popup's own default (CloseOnEscape |
    // CloseOnPressOutside) for the non-busy case, so this is a no-op when
    // not busy — only blocks tap-outside/escape while an operation is
    // actually in flight.
    closePolicy: busy ? QQC.Popup.NoAutoClose
                       : (QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside)

    width: parent ? parent.width : dp(540)
    height: parent ? parent.height * 0.92 : dp(640)
    x: 0
    y: parent ? parent.height - height : 0
    padding: 0
    topPadding: 0
    bottomPadding: 0

    // Slide-up animation: contentItem + background carry a y-offset driven
    // by a Behavior. Animating `y` directly would break the y binding and
    // leave the sheet off-screen on reopen (Qt 6 binding-stomping issue).
    property real _slideOffset: 0
    Behavior on _slideOffset {
        NumberAnimation { duration: Constants.durSlow; easing.type: Easing.OutCubic }
    }

    onAboutToShow: {
        // Re-establish the y-binding (defends against binding loss after a
        // prior animation), then snap offset below screen and let the
        // Behavior animate it up.
        y = Qt.binding(function() { return parent ? parent.height - height : 0 })
        _slideOffset = height
        Qt.callLater(function() { _slideOffset = 0 })
    }
    onAboutToHide: _slideOffset = height

    enter: Transition {
        NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: Constants.durMed }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: Constants.durMed }
    }

    QQC.Overlay.modal: Rectangle { color: Constants.overlay }

    background: Rectangle {
        radius: dp(Constants.radiusXl)
        color: Constants.cardBg
        // Slide offset — both background and contentItem ride together.
        transform: Translate { y: root._slideOffset }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            height: parent.radius
            color: parent.color
        }
    }

    contentItem: Item {
        id: contentRoot
        // Moved here from contentLayout below — both the ColumnLayout and
        // BusyOverlay need to ride the same slide-up offset as one unit,
        // not just the ColumnLayout on its own.
        transform: Translate { y: root._slideOffset }

        ColumnLayout {
            id: contentLayout
            anchors.fill: parent
            spacing: 0

            // Drag handle
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: dp(8)
                width: dp(44); height: dp(5); radius: 999
                color: Constants.borderColor
            }

            // Title row
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space5)
                Layout.rightMargin: dp(Constants.space3)
                Layout.topMargin: dp(Constants.space2)
                spacing: dp(Constants.space2)
                visible: root.sheetTitle.length > 0

                Text {
                    text: root.sheetTitle
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsH3)
                    font.bold: true
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                QQC.AbstractButton {
                    implicitWidth: dp(36); implicitHeight: dp(36)
                    contentItem: Item {
                        Icon {
                            anchors.centerIn: parent
                            name: "close"
                            color: Constants.textSecondary
                            size: sp(16)
                        }
                    }
                    background: Rectangle { color: "transparent" }
                    // Guarded — this bypassed busy entirely before, one of
                    // four separate dismissal paths (back button,
                    // tap-outside, this X, and Cancel below) that all
                    // needed the same guard, not just the obvious ones.
                    onClicked: { if (!root.busy) root.close() }
                }
            }

            // Body — fills remaining vertical space; ScrollView absorbs overflow.
            QQC.ScrollView {
                id: scroller
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: dp(Constants.space5)
                Layout.rightMargin: dp(Constants.space5)
                Layout.topMargin: dp(Constants.space2)
                clip: true
                QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

                // Pin the auto-created internal Flickable to StopAtBounds so the
                // sheet body can't be free-dragged / rubber-banded on touch when
                // its content already fits (Android-only free-drag, see AppScrollView).
                function _pinBounds() {
                    if (contentItem && contentItem.boundsBehavior !== undefined)
                        contentItem.boundsBehavior = Flickable.StopAtBounds
                }
                onContentItemChanged: _pinBounds()
                Component.onCompleted: _pinBounds()

                ColumnLayout {
                    id: bodyHolder
                    width: scroller.availableWidth
                    spacing: dp(Constants.space3)
                }
            }

            // Footer — primary/secondary actions, always visible at bottom.
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space5)
                Layout.rightMargin: dp(Constants.space5)
                Layout.topMargin: dp(Constants.space3)
                Layout.bottomMargin: dp(Constants.space6)
                spacing: dp(Constants.space2)
                visible: root.primaryAction.length > 0 || root.secondaryAction.length > 0

                GhostButton {
                    Layout.fillWidth: true
                    visible: root.secondaryAction.length > 0
                    text: root.secondaryAction
                    onClicked: { if (!root.busy) { root.secondaryClicked(); root.close() } }
                }

                PrimaryButton {
                    Layout.fillWidth: true
                    visible: root.primaryAction.length > 0
                    text: root.primaryAction
                    loading: root.busy
                    enabled: root.primaryEnabled && !root.busy
                    palette: root.primaryPalette
                    onClicked: root.primaryClicked()
                }
            }
        }

        // Declared last among contentRoot's children — on top purely by
        // declaration order, no explicit z needed.
        BusyOverlay {
            anchors.fill: parent
            active: root.busy && root.busyMessage.length > 0
            message: root.busyMessage
        }
    }
}
