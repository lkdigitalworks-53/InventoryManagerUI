import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

// Primary CTA — gradient indigo→violet→pink, white text, soft glow.
QQC.Button {
    id: root

    property bool loading: false
    property var palette: Constants.gradHero
    property string trailingText: ""

    implicitHeight: dp(48)
    padding: dp(8)
    leftPadding: dp(16)
    rightPadding: dp(16)

    contentItem: Item {
        // Anchor-based centering: Text fills the available width and centres
        // its content horizontally — no Layout filler items that can compress
        // the label and trigger ElideRight prematurely. Optional busy spinner
        // and trailing text sit beside the Text via anchors.
        Text {
            id: titleText
            anchors.fill: parent
            text: root.text
            color: Constants.textOnBrand
            font.pixelSize: sp(Constants.fsBodyLg)
            font.bold: true
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }

        QQC.BusyIndicator {
            visible: root.loading
            running: root.loading
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: dp(18)
            implicitHeight: dp(18)
            palette.dark: Constants.textOnBrand
        }

        Text {
            visible: root.trailingText.length > 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.trailingText
            color: Qt.rgba(1, 1, 1, 0.85)
            font.pixelSize: sp(Constants.fsBodyLg)
            font.bold: true
        }
    }

    background: Rectangle {
        radius: dp(14)
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop {
                position: 0.0
                color: root.enabled
                    ? (root.pressed ? Qt.darker(root.palette.start, 1.1)
                        : (root.hovered ? Qt.darker(root.palette.start, 1.05) : root.palette.start))
                    : Qt.lighter(root.palette.start, 1.4)
            }
            GradientStop {
                position: root.palette.mid !== undefined ? 0.55 : 1.0
                color: root.enabled
                    ? (root.pressed ? Qt.darker(root.palette.mid !== undefined ? root.palette.mid : root.palette.end, 1.1)
                        : (root.palette.mid !== undefined ? root.palette.mid : root.palette.end))
                    : Qt.lighter(root.palette.mid !== undefined ? root.palette.mid : root.palette.end, 1.4)
            }
            GradientStop {
                position: 1.0
                color: root.enabled
                    ? (root.pressed ? Qt.darker(root.palette.end, 1.1) : root.palette.end)
                    : Qt.lighter(root.palette.end, 1.4)
            }
        }
        Behavior on opacity { NumberAnimation { duration: Constants.durFast } }
    }
}
