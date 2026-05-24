import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

QQC.Dialog {
    id: root
    modal: true
    anchors.centerIn: parent
    padding: 20
    width: Math.min(parent ? parent.width - 40 : 420, 420)

    property string message: ""
    property string confirmLabel: "Delete"
    property string cancelLabel: "Cancel"
    property color confirmColor: "#dc2626"
    property var _onConfirm: null

    function ask(opts) {
        title = opts.title || "Are you sure?"
        message = opts.message || ""
        confirmLabel = opts.confirmLabel || "Delete"
        cancelLabel = opts.cancelLabel || "Cancel"
        confirmColor = opts.confirmColor || "#dc2626"
        _onConfirm = (typeof opts.onConfirm === "function") ? opts.onConfirm : null
        open()
    }

    background: Rectangle {
        radius: 12
        color: "#ffffff"
        border.color: Constants.borderColor
    }

    contentItem: ColumnLayout {
        spacing: 14

        QQC.Label {
            Layout.fillWidth: true
            text: root.message
            color: "#374151"
            font.pixelSize: 13
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 8

            QQC.Button {
                Layout.fillWidth: true
                text: root.cancelLabel
                onClicked: root.close()
            }

            QQC.Button {
                Layout.fillWidth: true
                text: root.confirmLabel
                background: Rectangle { radius: 8; color: root.confirmColor }
                contentItem: Text {
                    text: root.confirmLabel
                    color: "#ffffff"
                    font.bold: true
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: {
                    var fn = root._onConfirm
                    root._onConfirm = null
                    root.close()
                    if (fn) fn()
                }
            }
        }
    }
}
