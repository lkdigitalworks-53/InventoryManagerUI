import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

// PhotoSourceSheet — bottom-anchored popup offering Camera / Gallery / URL /
// Remove. No inline components, no Qt.labs.platform — both have caused
// startup crashes when combined with Felgo's stack.
QQC.Popup {
    id: root
    modal: true
    width: parent ? parent.width : 360
    height: Math.min(parent ? parent.height * 0.55 : 400, 400)
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

        // Camera (mobile only)
        Rectangle {
            visible: typeof NativeUtils !== "undefined"
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
                Text { text: "📷"; font.pixelSize: 20; anchors.verticalCenter: parent.verticalCenter }
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
                Text { text: "🖼️"; font.pixelSize: 20; anchors.verticalCenter: parent.verticalCenter }
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
                    if (typeof NativeUtils !== "undefined" && NativeUtils.displayImagePicker) {
                        NativeUtils.imagePickerFinished.connect(root._onGalleryDone)
                        NativeUtils.displayImagePicker()
                        root.close()
                    } else {
                        urlField.placeholderText = "Paste a file:// path or http URL…"
                        urlField.forceActiveFocus()
                    }
                }
            }
        }

        // Paste URL
        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: 12; Layout.rightMargin: 12
            Layout.topMargin: 4
            radius: 10
            color: "#f9fafb"
            border.color: Constants.borderColor
            implicitHeight: urlCol.implicitHeight + 16

            ColumnLayout {
                id: urlCol
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { text: "🌐"; font.pixelSize: 16 }
                    Text {
                        text: "Use an image URL or path"
                        color: "#111827"
                        font.pixelSize: 13
                        font.bold: true
                        Layout.fillWidth: true
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    QQC.TextField {
                        id: urlField
                        Layout.fillWidth: true
                        placeholderText: "https://… or file:///path/to/image.jpg"
                        font.pixelSize: 12
                    }
                    QQC.Button {
                        text: "Use"
                        enabled: urlField.text.length > 4
                        onClicked: {
                            root.photoSourceSelected(urlField.text.trim())
                            urlField.text = ""
                            root.close()
                        }
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
                Text { text: "🗑️"; font.pixelSize: 20; anchors.verticalCenter: parent.verticalCenter }
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

        Item { Layout.fillHeight: true }
    }

    function _onCameraDone(ok, path) {
        if (typeof NativeUtils !== "undefined")
            NativeUtils.cameraPickerFinished.disconnect(root._onCameraDone)
        if (ok && path && path.length > 0)
            root.photoSourceSelected(path)
    }

    function _onGalleryDone(ok, path) {
        if (typeof NativeUtils !== "undefined")
            NativeUtils.imagePickerFinished.disconnect(root._onGalleryDone)
        if (ok && path && path.length > 0)
            root.photoSourceSelected(path)
    }
}
