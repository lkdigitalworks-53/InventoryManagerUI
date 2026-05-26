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
    property var primaryPalette: Constants.gradHero
    default property alias body: bodyHolder.data

    signal primaryClicked()
    signal secondaryClicked()

    modal: true
    parent: QQC.Overlay.overlay

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

    contentItem: ColumnLayout {
        id: contentLayout
        spacing: 0
        transform: Translate { y: root._slideOffset }

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
                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        color: Constants.textSecondary
                        font.pixelSize: sp(16)
                    }
                }
                background: Rectangle { color: "transparent" }
                onClicked: root.close()
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
                onClicked: { root.secondaryClicked(); root.close() }
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
}
