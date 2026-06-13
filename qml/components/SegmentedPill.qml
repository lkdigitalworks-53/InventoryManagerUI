import QtQuick
import QtQuick.Layouts

import "../helper"

// Pill-shaped segmented control (e.g. Day / Week / Month / Year).
// Single-select; emits `segmentSelected(index, label)`.
Rectangle {
    id: root

    property var model: ["Day","Week","Month","Year"]
    property int selected: 0
    signal segmentSelected(int index, string label)

    implicitHeight: dp(40)
    radius: dp(Constants.radiusPill)
    color: Constants.cardBg
    border.color: Constants.borderColor
    border.width: 1

    RowLayout {
        anchors.fill: parent
        anchors.margins: dp(4)
        spacing: dp(4)

        Repeater {
            model: root.model
            delegate: Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                readonly property bool isOn: index === root.selected

                Rectangle {
                    anchors.fill: parent
                    radius: dp(Constants.radiusPill)
                    visible: parent.isOn
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: Constants.brand1 }
                        GradientStop { position: 1.0; color: Constants.brand2 }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: dp(4)
                    anchors.rightMargin: dp(4)
                    text: modelData
                    color: parent.isOn ? Constants.textOnBrand : Constants.textSecondary
                    font.pixelSize: sp(Constants.fsBody)
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.selected = index
                        root.segmentSelected(index, modelData)
                    }
                }
            }
        }
    }
}
