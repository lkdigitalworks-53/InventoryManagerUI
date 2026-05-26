import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

// Mobile confirm dialog — bottom sheet style with destructive primary action
// rendered as a danger button. Public contract preserved: ask({...}).
QQC.Dialog {
    id: root
    modal: true
    parent: QQC.Overlay.overlay
    width: Math.min(parent ? parent.width : dp(480), dp(480))
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? parent.height - height : 0
    padding: 0
    topPadding: 0
    bottomPadding: 0

    property string sheetTitle: "Are you sure?"
    property string message: ""
    property string confirmLabel: "Delete"
    property string cancelLabel: "Cancel"
    property color confirmColor: Constants.danger
    property var _onConfirm: null

    function ask(opts) {
        sheetTitle = opts.title || "Are you sure?"
        message = opts.message || ""
        confirmLabel = opts.confirmLabel || "Delete"
        cancelLabel = opts.cancelLabel || "Cancel"
        confirmColor = opts.confirmColor || Constants.danger
        _onConfirm = (typeof opts.onConfirm === "function") ? opts.onConfirm : null
        open()
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: Constants.durMed }
            NumberAnimation { property: "y"; from: parent ? parent.height : 600;
                              to: parent ? parent.height - root.height : 0;
                              duration: Constants.durSlow; easing.type: Easing.OutCubic }
        }
    }
    exit: Transition {
        ParallelAnimation {
            NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: Constants.durMed }
            NumberAnimation { property: "y"; from: parent ? parent.height - root.height : 0;
                              to: parent ? parent.height : 600;
                              duration: Constants.durMed; easing.type: Easing.InCubic }
        }
    }

    QQC.Overlay.modal: Rectangle { color: Constants.overlay }

    background: Rectangle {
        radius: dp(Constants.radiusXl)
        color: Constants.cardBg
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            height: parent.radius
            color: parent.color
        }
    }

    contentItem: ColumnLayout {
        spacing: dp(Constants.space3)

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: dp(8)
            width: dp(44); height: dp(5); radius: 999
            color: Constants.borderColor
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: dp(Constants.space5)
            Layout.rightMargin: dp(Constants.space5)
            Layout.topMargin: dp(Constants.space2)
            spacing: dp(Constants.space2)

            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: dp(56); height: dp(56); radius: dp(18)
                color: Qt.rgba(0.93, 0.27, 0.27, 0.10)
                Text {
                    anchors.centerIn: parent
                    text: "⚠"
                    color: Constants.danger
                    font.pixelSize: sp(26)
                }
            }

            Text {
                text: root.sheetTitle
                color: Constants.textPrimary
                font.pixelSize: sp(Constants.fsH3)
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
                wrapMode: Text.Wrap
            }

            Text {
                text: root.message
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsBody)
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
                wrapMode: Text.Wrap
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: dp(Constants.space5)
            Layout.rightMargin: dp(Constants.space5)
            Layout.topMargin: dp(Constants.space3)
            Layout.bottomMargin: dp(Constants.space6)
            spacing: dp(Constants.space2)

            GhostButton {
                Layout.fillWidth: true
                text: root.cancelLabel
                onClicked: root.close()
            }

            DangerButton {
                Layout.fillWidth: true
                text: root.confirmLabel
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
