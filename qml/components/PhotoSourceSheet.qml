import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Felgo

import "../helper"

// PhotoSourceSheet — bottom-anchored popup offering Camera / Gallery /
// Remove. No inline components, no Qt.labs.platform — both have caused
// startup crashes when combined with Felgo's stack.
QQC.Popup {
    id: root
    modal: true
    // Declare this at the App root (see Main.qml), NOT inside a BottomSheet. The
    // sheet's default `body` alias routes children into its tall, scrollable
    // content column, so a parent-relative `y` would open this popup off-screen
    // (the EditProductDialog bug). At App root, `parent` is the window, so the
    // bottom-anchored positioning below is window-relative and correct.
    width: parent ? parent.width : 360
    // Cap the sheet at 80% of viewport height so it never spills past the bottom
    // edge on phone-sized screens. The Flickable in contentItem scrolls the rows
    // when even 80% isn't enough.
    height: Math.min(contentCol.implicitHeight + dp(24),
                     parent ? parent.height * 0.8 : 480)
    x: 0
    y: parent ? parent.height - height : 0
    padding: 0
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside

    property bool hasExistingPhoto: false

    signal photoSourceSelected(string url)
    signal removeRequested()

    background: Rectangle {
        color: "#ffffff"
        radius: 16
        border.color: Constants.borderColor
    }

    // A Flickable, not a ScrollView: BottomSheet.qml explains why a sheet must not size itself from a ScrollView (its deferred layout
    // pass reports height 0 on first open). The Popup height below still reads contentCol.implicitHeight directly; the Flickable only
    // makes the rows reachable when that height is more than the 80% cap (a big system font, or the phone turned sideways).
    contentItem: Flickable {
        clip: true
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: contentCol.implicitHeight

        ColumnLayout {
            id: contentCol
            width: root.availableWidth
            spacing: 4

            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 8
                Layout.preferredWidth: 40; Layout.preferredHeight: 4; radius: 2
                color: "#d1d5db"
            }

            QQC.Label {
                Layout.fillWidth: true
                Layout.topMargin: 8
                Layout.leftMargin: 16
                text: "Set product photo"
                font.pixelSize: sp(Constants.fsTitle)
                font.bold: true
                color: "#111827"
            }

            // Camera (mobile only — no camera picker on desktop)
            Rectangle {
                visible: Qt.platform.os === "android" || Qt.platform.os === "ios"
                Layout.fillWidth: true
                Layout.leftMargin: 12; Layout.rightMargin: 12
                Layout.topMargin: 4
                radius: 10
                color: cameraTap.pressed ? "#f3f4f6" : "#ffffff"
                border.color: Constants.borderColor
                implicitHeight: Math.max(56, camLabels.implicitHeight + 20)

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 14
                    spacing: 12
                    Icon { id: camIcon; name: "camera"; size: 20; anchors.verticalCenter: parent.verticalCenter; color: Constants.textPrimary }
                    Column {
                        id: camLabels
                        width: Math.max(0, parent.width - camIcon.width - parent.spacing)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text { width: parent.width; wrapMode: Text.WordWrap; text: "Take photo"; color: "#111827"; font.pixelSize: sp(Constants.fsBodyLg); font.bold: true }
                        Text { width: parent.width; wrapMode: Text.WordWrap; text: "Use the camera"; color: "#6b7280"; font.pixelSize: sp(Constants.fsCaption) }
                    }
                }
                MouseArea {
                    id: cameraTap
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (typeof NativeUtils !== "undefined") {
                            NativeUtils.cameraPickerFinished.connect(root._onCameraDone)
                            NativeUtils.displayCameraPicker()
                            root.close()
                        }
                    }
                }
            }

            // Gallery / Files
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 12; Layout.rightMargin: 12
                Layout.topMargin: 2
                radius: 10
                color: galleryTap.pressed ? "#f3f4f6" : "#ffffff"
                border.color: Constants.borderColor
                implicitHeight: Math.max(56, galLabels.implicitHeight + 20)

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 14
                    spacing: 12
                    Icon { id: galIcon; name: "gallery"; size: 20; anchors.verticalCenter: parent.verticalCenter; color: Constants.textPrimary }
                    Column {
                        id: galLabels
                        width: Math.max(0, parent.width - galIcon.width - parent.spacing)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text { width: parent.width; wrapMode: Text.WordWrap; text: "Choose from gallery"; color: "#111827"; font.pixelSize: sp(Constants.fsBodyLg); font.bold: true }
                        Text { width: parent.width; wrapMode: Text.WordWrap; text: "Pick an existing image"; color: "#6b7280"; font.pixelSize: sp(Constants.fsCaption) }
                    }
                }
                MouseArea {
                    id: galleryTap
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        var isMobile = (Qt.platform.os === "android" || Qt.platform.os === "ios")
                        // Close this modal sheet BEFORE launching a picker. On desktop,
                        // opening the native file dialog while the modal is still tearing
                        // down suppresses the dialog — so defer it to the next tick.
                        root.close()
                        if (isMobile && NativeUtils.displayImagePicker) {
                            // Mobile: the OS photo picker.
                            NativeUtils.imagePickerFinished.connect(root._onGalleryDone)
                            NativeUtils.displayImagePicker(qsTr("Choose a photo"))
                        } else {
                            // Desktop: no native photo picker — use the system file
                            // dialog with a Qt name-filter (NOT a MIME wildcard).
                            NativeUtils.filePickerFinished.connect(root._onPhotoFilePicked)
                            Qt.callLater(function() {
                                NativeUtils.displayFilePicker(qsTr("Choose a photo"), "",
                                    "Image files (*.png *.jpg *.jpeg *.gif *.bmp *.webp)")
                            })
                        }
                    }
                }
            }

            // Remove (only when there's an existing photo)
            Rectangle {
                visible: root.hasExistingPhoto
                Layout.fillWidth: true
                Layout.leftMargin: 12; Layout.rightMargin: 12
                Layout.topMargin: 2
                radius: 10
                color: removeTap.pressed ? "#fef2f2" : "#ffffff"
                border.color: Constants.borderColor
                implicitHeight: Math.max(56, remLabels.implicitHeight + 20)

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 14
                    spacing: 12
                    Icon { id: remIcon; name: "delete"; size: 20; anchors.verticalCenter: parent.verticalCenter; color: Constants.textPrimary }
                    Column {
                        id: remLabels
                        width: Math.max(0, parent.width - remIcon.width - parent.spacing)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text { width: parent.width; wrapMode: Text.WordWrap; text: "Remove photo"; color: "#b91c1c"; font.pixelSize: sp(Constants.fsBodyLg); font.bold: true }
                        Text { width: parent.width; wrapMode: Text.WordWrap; text: "Clear the existing image"; color: "#6b7280"; font.pixelSize: sp(Constants.fsCaption) }
                    }
                }
                MouseArea {
                    id: removeTap
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.removeRequested()
                        root.close()
                    }
                }
            }

            Item { Layout.preferredHeight: dp(8); Layout.fillWidth: true }
        }
    }

    function _onCameraDone(ok, path) {
        if (typeof NativeUtils !== "undefined")
            NativeUtils.cameraPickerFinished.disconnect(root._onCameraDone)
        if (ok && path && path.length > 0)
            root.photoSourceSelected(_toFileUrl(path))
    }

    function _onGalleryDone(ok, path) {
        if (typeof NativeUtils !== "undefined")
            NativeUtils.imagePickerFinished.disconnect(root._onGalleryDone)
        if (ok && path && path.length > 0)
            root.photoSourceSelected(_toFileUrl(path))
    }

    // Desktop gallery path: the system file dialog returns via filePickerFinished
    // (a list of files), unlike the mobile image picker's single-path signal.
    function _onPhotoFilePicked(ok, files) {
        if (typeof NativeUtils !== "undefined")
            NativeUtils.filePickerFinished.disconnect(root._onPhotoFilePicked)
        if (ok && files && files.length > 0)
            root.photoSourceSelected(_toFileUrl(files[0]))
    }

    // Normalize a picker result to a valid URL. A raw Windows path like
    // "C:/dir/x.png" assigned to a url property mis-parses ("file://c/…" — the
    // drive letter becomes the host); prepend a slash so it becomes a correct
    // "file:///C:/dir/x.png". Already-schemed sources pass through unchanged.
    function _toFileUrl(raw) {
        var s = String(raw).trim()
        var lower = s.toLowerCase()
        if (lower.indexOf("http://") === 0 || lower.indexOf("https://") === 0) return s
        if (lower.indexOf("content://") === 0) return s
        // The desktop picker returns a malformed 2-slash "file://C:/…", where
        // "C:" parses as the URL HOST so the path collapses to "//c/…" and both
        // Image.source and QFile fail. Strip "file:" + leading slashes, then
        // re-apply the drive-letter rule below so "file://C:/…", "file:///C:/…",
        // and a raw "C:\…" all converge to a valid "file:///C:/…". (Mirrors
        // ImportPreviewDialog._toFileUrl, the verified-working desktop path.)
        if (lower.indexOf("file:") === 0)
            s = s.substring(5).replace(/^\/+/, "")
        var norm = s.replace(/\\/g, "/")
        if (norm.indexOf("/") !== 0) norm = "/" + norm
        return "file://" + norm
    }
}
