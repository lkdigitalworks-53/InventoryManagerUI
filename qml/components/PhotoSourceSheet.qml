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
    // Cap the sheet at 80% of viewport height so the content (camera + gallery
    // + URL + remove rows) never spills past the bottom edge on phone-sized
    // screens. ScrollView inside handles overflow when even 80% isn't enough.
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

    contentItem: ColumnLayout {
        id: contentCol
        spacing: 4

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 8
            width: 40; height: 4; radius: 2
            color: "#d1d5db"
        }

        QQC.Label {
            Layout.fillWidth: true
            Layout.topMargin: 8
            Layout.leftMargin: 16
            text: "Set product photo"
            font.pixelSize: 16
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
            implicitHeight: 56

            Row {
                anchors.fill: parent
                anchors.leftMargin: 14; anchors.rightMargin: 14
                spacing: 12
                Icon { name: "camera"; size: 20; anchors.verticalCenter: parent.verticalCenter; color: Constants.textPrimary }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { text: "Take photo"; color: "#111827"; font.pixelSize: 14; font.bold: true }
                    Text { text: "Use the camera"; color: "#6b7280"; font.pixelSize: 11 }
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
            implicitHeight: 56

            Row {
                anchors.fill: parent
                anchors.leftMargin: 14; anchors.rightMargin: 14
                spacing: 12
                Icon { name: "gallery"; size: 20; anchors.verticalCenter: parent.verticalCenter; color: Constants.textPrimary }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { text: "Choose from gallery"; color: "#111827"; font.pixelSize: 14; font.bold: true }
                    Text { text: "Pick an existing image"; color: "#6b7280"; font.pixelSize: 11 }
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
            implicitHeight: 56

            Row {
                anchors.fill: parent
                anchors.leftMargin: 14; anchors.rightMargin: 14
                spacing: 12
                Icon { name: "delete"; size: 20; anchors.verticalCenter: parent.verticalCenter; color: Constants.textPrimary }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { text: "Remove photo"; color: "#b91c1c"; font.pixelSize: 14; font.bold: true }
                    Text { text: "Clear the existing image"; color: "#6b7280"; font.pixelSize: 11 }
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
        if (lower.indexOf("file:") === 0) return s
        if (lower.indexOf("content://") === 0) return s
        var norm = s.replace(/\\/g, "/")
        if (norm.indexOf("/") !== 0) norm = "/" + norm
        return "file://" + norm
    }
}
