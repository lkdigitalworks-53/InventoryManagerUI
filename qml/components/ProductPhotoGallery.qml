import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Felgo

import "../helper"
import "../helper/PhotoUrl.js" as PhotoUrl
import "../helper/FailedTileGeometry.js" as FTG
import "../model"

// ProductPhotoGallery — horizontal photo filmstrip for a product's photos (2026-09-21 photos
// feature; rearranged 2026-09-29 from a wrapping Flow grid to this filmstrip after PR #84
// device-test feedback: "arrangement" felt boxy, and square image corners visibly overran the
// rounded tile frame at all four corners — clip:true clips to the bounding box, not the radius;
// see RoundedThumb.qml).
// Design: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md, "UI"
//
// Failed uploads (2026-09-29): Retry/Discard now live INSIDE the tile as FailedTileOverlay, so a failed
// tile keeps the normal footprint -- no widening, no strip-height jump (the old text-button row below
// the tile did both). See docs/superpowers/specs/2026-09-29-photo-gallery-failed-tile-actions-design.md.
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
    property int tileSize: dp(72)

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

    implicitHeight: filmRow.implicitHeight

    RowLayout {
        id: filmRow
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: dp(Constants.space2)

        ListView {
            id: filmList
            Layout.fillWidth: true
            Layout.preferredHeight: root.tileSize
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
                readonly property string overlayMode: FTG.overlayMode(modelData.kind, isQueued ? modelData.item.state : "")
                readonly property bool isFailed: overlayMode === "failed"
                width: root.tileSize
                height: root.tileSize

                Rectangle {
                    id: frame
                    width: root.tileSize
                    height: root.tileSize
                    radius: dp(Constants.radius)
                    color: Constants.subtleBg
                    border.color: tile.isFailed ? Constants.danger : Constants.borderColor
                    border.width: tile.isFailed ? 2 : 1

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
                        visible: tile.overlayMode === "busy"
                        running: visible
                    }
                    // Failed upload: Retry/Discard inside the tile (Loader owns create/destroy -- the
                    // overlay only exists while the tile is failed).
                    Loader {
                        anchors.fill: parent   // full tile edge: the overlay's geometry is designed for it
                        active: tile.isFailed
                        sourceComponent: FailedTileOverlay {
                            cornerRadius: dp(Constants.radius) - dp(2)
                            onRetryRequested: PhotoQueue.retry(tile.modelData.item.photoId)
                            onDiscardRequested: PhotoQueue.discard(tile.modelData.item.photoId)
                        }
                    }

                    // Cover badge -- small corner pill instead of the old full-width bottom
                    // banner text: reads as "this one is special" without visually dominating a
                    // 72px tile (part of the 2026-09-29 arrangement rework).
                    Rectangle {
                        visible: !tile.isQueued && tile.modelData.isCover
                        width: dp(15); height: dp(15)
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
