import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

// Alert dialog — bottom sheet style for info/error messages with OK action.
// Usage: alertDlg.show({ title: "Error", message: "...", variant: "error" })
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

    property string alertTitle: "Alert"
    property string message: ""
    property string okLabel: "OK"
    property string variant: "info"  // "info", "error", "success", "warning"
    property var _onOk: null

    function show(opts) {
        alertTitle = opts.title || "Alert"
        message = opts.message || ""
        okLabel = opts.okLabel || "OK"
        variant = opts.variant || "info"
        _onOk = (typeof opts.onOk === "function") ? opts.onOk : null
        open()
    }

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
                color: {
                    switch (root.variant) {
                        case "error": return Qt.rgba(0.93, 0.27, 0.27, 0.10)
                        case "warning": return Qt.rgba(0.98, 0.71, 0.16, 0.10)
                        case "success": return Qt.rgba(0.13, 0.77, 0.34, 0.10)
                        default: return Qt.rgba(0.24, 0.51, 0.98, 0.10)
                    }
                }
                Icon {
                    anchors.centerIn: parent
                    name: {
                        switch (root.variant) {
                            case "error": return "warn"
                            case "warning": return "warn"
                            case "success": return "check"
                            default: return "info"
                        }
                    }
                    color: {
                        switch (root.variant) {
                            case "error": return Constants.danger
                            case "warning": return "#f59e0b"
                            case "success": return "#22c55e"
                            default: return Constants.brand2
                        }
                    }
                    size: sp(26)
                }
            }

            Text {
                text: root.alertTitle
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
                Layout.preferredWidth: parent.width
            }
        }

        PrimaryButton {
            Layout.fillWidth: true
            Layout.leftMargin: dp(Constants.space5)
            Layout.rightMargin: dp(Constants.space5)
            Layout.topMargin: dp(Constants.space3)
            Layout.bottomMargin: dp(Constants.space6) + SafeArea.bottom
            text: root.okLabel
            palette: root.variant === "error" ? Constants.gradDanger : Constants.gradHero
            onClicked: {
                var fn = root._onOk
                root._onOk = null
                root.close()
                if (fn) fn()
            }
        }
    }
}
