import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Felgo

import "../helper"
import "../helper/PhotoUrl.js" as PhotoUrl
import "../model"

// ProductPhotoGallery — horizontal photo filmstrip for a product's photos (2026-09-21 photos
// feature; rearranged 2026-09-29 from a wrapping Flow grid to this filmstrip after PR #84
// device-test feedback: "arrangement" felt boxy, and square image corners visibly overran the
// rounded tile frame at all four corners — clip:true clips to the bounding box, not the radius;
// see RoundedThumb.qml).
// Design: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md, "UI"
//
// Layout: [ horizontally scrolling ListView of tiles ][ fixed + tile ]. The + tile sits OUTSIDE
// the scrollable ListView, at a fixed position, on purpose — the 2026-09-28 test plan rejected a
// horizontal Flickable specifically because it would hide the + tile until scrolled. Pinning it
// outside the scroll region keeps that guarantee (always reachable, no scroll needed) while still
// fixing the overflow/wrap complaint: only the photo tiles scroll, and a Flickable can never
// overflow its own bounds the way a wrapping Flow's uneven last row could look.
//
// Model: every id in `photoIds` (server-confirmed, first = cover), then every PhotoQueue item
// still pending for this product (not yet confirmed) — built once into `_combined` rather than
// left as two separate Repeaters, so a tile's cover flag is a precomputed field (`isCover`) and
// not something the delegate has to infer from its own `index` (that inference is what caused the
// original "Cover on every tile" bug: a delegate with a `required property` on it stops Qt from
// injecting an un-declared `index`).
Item {
    id: root

    property string productId: ""
    property var photoIds: []          // confirmed, from the product doc -- first is cover
    property bool editable: true
    property int tileSize: 72

    signal addPhotoRequested()
    signal removeFailed(string photoId, string error)

    property var _queued: []
    property var _combined: []

    function _refreshAll() {
        var q = []
        for (var i = 0; i < PhotoQueue.items.length; ++i) {
            if (PhotoQueue.items[i].productId === root.productId) q.push(PhotoQueue.items[i])
        }
        root._queued = q

        var out = []
        for (var c = 0; c < root.photoIds.length; ++c)
            out.push({ kind: "confirmed", photoId: root.photoIds[c], isCover: c === 0 })
        for (var j = 0; j < q.length; ++j)
            out.push({ kind: "queued", item: q[j] })
        root._combined = out
    }
    Component.onCompleted: _refreshAll()
    onProductIdChanged: _refreshAll()
    onPhotoIdsChanged: _refreshAll()
    Connections {
        target: PhotoQueue
        function onRevisionChanged() { root._refreshAll() }
    }

    function _thumbUrl(photoId) {
        return StorageService.photoDownloadUrl(root.productId, photoId, true)
    }

    function _removeConfirmed(photoId) {
        StorageService.removeProductPhoto(root.productId, photoId, function(ok, err) {
            if (ok) {
                var remaining = []
                for (var i = 0; i < root.photoIds.length; ++i)
                    if (root.photoIds[i] !== photoId) remaining.push(root.photoIds[i])
                InventoryStore.applyPhotoIds(root.productId, remaining, photoId, "remove")
            } else {
                root.removeFailed(photoId, err)
            }
        })
    }

    readonly property bool _hasFailedQueued: {
        for (var i = 0; i < root._queued.length; ++i)
            if (root._queued[i].state === "failed") return true
        return false
    }
    // A failed tile grows a Retry/Discard row below its image (real touch targets, not 9px text
    // crammed inside a 72px square) -- the row's extra height, added to every delegate's box via
    // the shared ListView height so a failed tile is never clipped.
    readonly property int _failedExtra: dp(Constants.space2) + dp(40)
    readonly property int _rowHeight: root.tileSize + (root._hasFailedQueued ? root._failedExtra : 0)

    implicitHeight: filmRow.implicitHeight

    RowLayout {
        id: filmRow
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: dp(Constants.space2)

        ListView {
            id: filmList
            Layout.fillWidth: true
            Layout.preferredHeight: root._rowHeight
            orientation: ListView.Horizontal
            clip: true
            spacing: dp(Constants.space2)
            model: root._combined

            add: Transition {
                NumberAnimation { properties: "opacity,scale"; from: 0; to: 1; duration: Constants.durMed; easing.type: Easing.OutCubic }
            }
            remove: Transition {
                NumberAnimation { properties: "opacity,scale"; from: 1; to: 0; duration: Constants.durFast; easing.type: Easing.InCubic }
            }
            displaced: Transition {
                NumberAnimation { properties: "x"; duration: Constants.durMed; easing.type: Easing.OutCubic }
            }

            delegate: Item {
                id: tile
                required property var modelData
                readonly property bool isQueued: modelData.kind === "queued"
                readonly property bool isFailed: isQueued && modelData.item.state === "failed"
                width: isFailed ? Math.max(root.tileSize, dp(160)) : root.tileSize
                height: filmList.height

                Rectangle {
                    id: frame
                    width: root.tileSize
                    height: root.tileSize
                    radius: dp(Constants.radius)
                    color: Constants.subtleBg
                    border.color: tile.isFailed ? Constants.danger : Constants.borderColor
                    border.width: 1

                    RoundedThumb {
                        id: thumb
                        anchors.fill: parent
                        anchors.margins: dp(2)
                        radius: dp(Constants.radius) - dp(2)
                        cache: !tile.isQueued
                        // Queued: this device's own local file (works fully offline). Confirmed:
                        // the computed Storage thumbnail URL.
                        source: tile.isQueued
                            ? PhotoUrl.toFileUrl(tile.modelData.item.mainFilePath)
                            : root._thumbUrl(tile.modelData.photoId)
                        onStatusChanged: if (!tile.isQueued && status === Image.Error)
                            console.warn("[ProductPhotoGallery] thumb failed to load:", source)
                    }

                    QQC.BusyIndicator {
                        anchors.centerIn: parent
                        visible: tile.isQueued && !tile.isFailed
                        running: visible
                    }
                    Icon {
                        visible: tile.isFailed
                        anchors.centerIn: parent
                        name: "warn"
                        size: sp(22)
                        color: Constants.danger
                    }

                    // Cover badge -- small corner pill instead of the old full-width bottom
                    // banner text: reads as "this one is special" without visually dominating a
                    // 72px tile (part of the 2026-09-29 arrangement rework).
                    Rectangle {
                        visible: !tile.isQueued && tile.modelData.isCover
                        width: dp(20); height: dp(20)
                        radius: dp(10)
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: dp(2)
                        color: "#111827"
                        opacity: 0.85
                        Icon { anchors.centerIn: parent; name: "star"; size: sp(11); color: "#ffffff" }
                    }

                    Rectangle {
                        visible: !tile.isQueued && root.editable
                        width: dp(20); height: dp(20)
                        radius: dp(10)
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: dp(2)
                        color: "#111827"
                        opacity: 0.85
                        Icon { anchors.centerIn: parent; name: "close"; size: sp(11); color: "#ffffff" }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._removeConfirmed(tile.modelData.photoId)
                        }
                    }
                }

                RowLayout {
                    visible: tile.isFailed
                    anchors.top: frame.bottom
                    anchors.topMargin: dp(Constants.space2)
                    width: tile.width
                    spacing: dp(Constants.space2)

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: dp(40)
                        radius: dp(Constants.radius)
                        color: Constants.subtleBg
                        border.color: Constants.accentBlue
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: qsTr("Retry")
                            color: Constants.accentBlue
                            font.pixelSize: sp(Constants.fsSmall)
                            font.bold: true
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: PhotoQueue.retry(tile.modelData.item.photoId)
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: dp(40)
                        radius: dp(Constants.radius)
                        color: Constants.subtleBg
                        border.color: Constants.danger
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: qsTr("Discard")
                            color: Constants.danger
                            font.pixelSize: sp(Constants.fsSmall)
                            font.bold: true
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: PhotoQueue.discard(tile.modelData.item.photoId)
                        }
                    }
                }
            }
        }

        // Fixed, outside the scrollable ListView -- see file header. Same 10-photo ceiling as
        // before.
        Rectangle {
            visible: root.editable && (root.photoIds.length + root._queued.length) < 10
            Layout.preferredWidth: root.tileSize
            Layout.preferredHeight: root.tileSize
            radius: dp(Constants.radius)
            color: Constants.subtleBg
            border.color: Constants.borderColor
            border.width: 1

            Icon { anchors.centerIn: parent; name: "add"; size: sp(20); color: Constants.textSecondary }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.addPhotoRequested()
            }
        }
    }
}
