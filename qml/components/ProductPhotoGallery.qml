import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Felgo

import "../helper"
import "../model"

// ProductPhotoGallery — cover photo + thumbnail strip for a product's photos (2026-09-21 photos
// feature). Replaces EditProductDialog's old single-photo Image+Icon+BusyIndicator block.
// Design: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md, "UI"
//
// Shows, left to right: every id in `photoIds` (server-confirmed, first = cover), then every
// PhotoQueue item still pending for this product (not yet confirmed). A photoId can appear in
// EITHER list, never both -- PhotoQueue.discard()/InventoryStore.applyPhotoIds() keep them
// disjoint (queue item removed exactly when its id is confirmed into photoIds).
//
// Each tile's image source, in order: PhotoQueue's persisted local file (if this photoId is still
// queued -- works fully offline, it's this device's own file), else the computed Storage thumbnail
// URL (StorageService.photoDownloadUrl, thumb: true). A still-queued tile shows a spinner overlay
// (enqueued/uploading/retrying) or a Retry/Discard mini-row (failed). A confirmed tile shows a
// small remove (×) button when editable.
Item {
    id: root

    property string productId: ""
    property var photoIds: []          // confirmed, from the product doc -- first is cover
    property bool editable: true
    property int tileSize: 72

    signal addPhotoRequested()
    signal removeFailed(string photoId, string error)

    implicitHeight: strip.implicitHeight

    // Explicit property + revision-driven refresh, NOT a `model: root._queuedForProduct()`
    // function-call binding -- this codebase's own established pattern for "a list-store changed,
    // re-sync a derived view" (DataModel.qml's OrdersStore.revisionChanged -> _syncOrdersModel())
    // uses an explicit revision counter + Connections rather than relying on QML's binding engine
    // to track property reads transitively through a nested function call for a Repeater model.
    // Matching that proven pattern here rather than assuming the alternative works, since this
    // can't be verified without qmltestrunner or a device in this sandbox and a silently-stale
    // gallery would be a real, hard-to-notice UX bug.
    property var _queued: []
    function _refreshQueued() {
        var out = []
        for (var i = 0; i < PhotoQueue.items.length; ++i) {
            if (PhotoQueue.items[i].productId === root.productId) out.push(PhotoQueue.items[i])
        }
        _queued = out
    }
    Component.onCompleted: _refreshQueued()
    onProductIdChanged: _refreshQueued()
    Connections {
        target: PhotoQueue
        function onRevisionChanged() { root._refreshQueued() }
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

    RowLayout {
        id: strip
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: dp(Constants.space2)

        Repeater {
            model: root.photoIds
            delegate: Rectangle {
                required property string modelData
                Layout.preferredWidth: root.tileSize
                Layout.preferredHeight: root.tileSize
                radius: dp(Constants.radius)
                color: Constants.subtleBg
                border.color: Constants.borderColor
                border.width: 1
                clip: true

                Image {
                    anchors.fill: parent
                    anchors.margins: dp(2)
                    source: root._thumbUrl(modelData)
                    sourceSize.width: root.tileSize
                    sourceSize.height: root.tileSize
                    fillMode: Image.PreserveAspectCrop
                    cache: true
                    asynchronous: true
                }

                Rectangle {
                    visible: root.editable
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
                        onClicked: root._removeConfirmed(modelData)
                    }
                }

                Rectangle {
                    visible: index === 0
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: dp(14)
                    color: "#111827"
                    opacity: 0.6
                    Text {
                        anchors.centerIn: parent
                        text: qsTr("Cover")
                        color: "#ffffff"
                        font.pixelSize: sp(8)
                    }
                }
            }
        }

        Repeater {
            model: root._queued
            delegate: Rectangle {
                required property var modelData
                Layout.preferredWidth: root.tileSize
                Layout.preferredHeight: root.tileSize
                radius: dp(Constants.radius)
                color: Constants.subtleBg
                border.color: Constants.borderColor
                border.width: 1
                clip: true

                Image {
                    anchors.fill: parent
                    anchors.margins: dp(2)
                    source: "file://" + modelData.mainFilePath
                    sourceSize.width: root.tileSize
                    sourceSize.height: root.tileSize
                    fillMode: Image.PreserveAspectCrop
                    cache: false
                    asynchronous: true
                }

                QQC.BusyIndicator {
                    anchors.centerIn: parent
                    running: modelData.state !== "failed"
                    visible: modelData.state !== "failed"
                }

                ColumnLayout {
                    visible: modelData.state === "failed"
                    anchors.fill: parent
                    anchors.margins: dp(2)
                    spacing: dp(2)

                    Item { Layout.fillHeight: true }
                    Icon {
                        Layout.alignment: Qt.AlignHCenter
                        name: "warn"
                        size: sp(16)
                        color: "#dc2626"
                    }
                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: dp(4)
                        Text {
                            text: qsTr("Retry")
                            color: "#2563eb"
                            font.pixelSize: sp(9)
                            font.bold: true
                            MouseArea { anchors.fill: parent; onClicked: PhotoQueue.retry(modelData.photoId) }
                        }
                        Text {
                            text: qsTr("Discard")
                            color: "#dc2626"
                            font.pixelSize: sp(9)
                            font.bold: true
                            MouseArea { anchors.fill: parent; onClicked: PhotoQueue.discard(modelData.photoId) }
                        }
                    }
                }
            }
        }

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
