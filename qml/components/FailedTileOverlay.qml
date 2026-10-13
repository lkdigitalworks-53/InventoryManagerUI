import QtQuick

import "../helper"
import "../helper/FailedTileGeometry.js" as Geo

// FailedTileOverlay — Retry / Discard controls drawn INSIDE a photo tile whose upload gave up
// (2026-09-29, PR #84 follow-up: the old text buttons below a widened tile made the whole strip
// jump). Fill a tile-sized parent with it; the tile keeps its normal footprint.
// Layout maths, contrast and state rules live in helper/FailedTileGeometry.js (headless-tested,
// tests/tst_FailedTileGeometry.qml); this file only paints and forwards taps.
// Design: docs/superpowers/specs/2026-09-29-photo-gallery-failed-tile-actions-design.md
//
//   FailedTileOverlay { anchors.fill: thumb; onRetryRequested: ...; onDiscardRequested: ... }
Item {
    id: root

    // The scrim is inset so it matches RoundedThumb's rounded photo area; the TARGETS are laid out
    // against the full tile edge (this Item's own width), which is what the geometry was designed for.
    property real scrimInset: dp(2)
    property real cornerRadius: dp(Constants.radius) - dp(2)

    signal retryRequested()
    signal discardRequested()

    readonly property var _g: Geo.layout(root.width, dp(1))

    // Scrim: dims whatever the photo is so white glyphs stay readable (>= 4.5:1, see helper).
    // Translucent fill, not live blur -- blur is a per-tile GPU cost and can't be verified here.
    Rectangle {
        anchors.fill: parent
        anchors.margins: root.scrimInset
        radius: root.cornerRadius
        color: Qt.rgba(Geo.SCRIM_RGB[0] / 255, Geo.SCRIM_RGB[1] / 255, Geo.SCRIM_RGB[2] / 255, Geo.SCRIM_ALPHA)
    }

    // Retry: the one loud element on the tile -- brand gradient circle + refresh glyph.
    Item {
        id: retryBtn
        x: root._g.retry.x
        y: root._g.retry.y
        width: root._g.retry.width
        height: root._g.retry.height
        scale: retryArea.pressed ? 0.92 : 1.0
        Behavior on scale { NumberAnimation { duration: Constants.durFast / 2; easing.type: Easing.OutCubic } }

        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Retry upload")
        Accessible.onPressAction: root.retryRequested()

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.35)
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: Constants.gradPrimary.start }
                GradientStop { position: 1.0; color: Constants.gradPrimary.end }
            }
        }
        Icon { anchors.centerIn: parent; name: "retry"; size: sp(18); color: Constants.textOnBrand }
        MouseArea {
            id: retryArea
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.retryRequested()
        }
    }

    // Discard: small frosted chip, top-right; touch target is the larger square around it.
    Item {
        id: discardBtn
        x: root._g.discardHit.x
        y: root._g.discardHit.y
        width: root._g.discardHit.width
        height: root._g.discardHit.height

        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Discard photo")
        Accessible.onPressAction: root.discardRequested()

        Rectangle {
            anchors.centerIn: parent
            width: root._g.discardChip.width
            height: width
            radius: width / 2
            color: Qt.rgba(1, 1, 1, Geo.CHIP_ALPHA)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.3)
            scale: discardArea.pressed ? 0.9 : 1.0
            Behavior on scale { NumberAnimation { duration: Constants.durFast / 2; easing.type: Easing.OutCubic } }
            Icon { anchors.centerIn: parent; name: "close"; size: sp(11); color: Constants.textOnBrand }
        }
        MouseArea {
            id: discardArea
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.discardRequested()
        }
    }
}
