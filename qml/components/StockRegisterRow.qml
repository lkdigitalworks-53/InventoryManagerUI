import QtQuick
import QtQuick.Layouts

import "../helper"
import "../helper/StockRegisterPage.js" as Glue

// One product row of the stock register page (P1 S4b-2). Painting only: every word comes from
// qml/helper/StockRegisterPage.js (tested headless); this file cannot be loaded by qmltestrunner (Felgo), so its
// wiring is pinned by .github/scripts/__tests__/stockRegisterPageWiring.test.js and checked on a device.
Rectangle {
    id: row

    // Roles of the page's regModel = Glue.ROW_KEYS, in the same order (Skill 161 rule 2; a wiring test pins it).
    required property string productId
    required property string title
    required property string note
    required property bool reconciles
    required property string openingText
    required property string inText
    required property string outText
    required property string closingText
    required property string rowName

    // Set by the page: is this the open row, and its per-kind lines (Glue.detailRows).
    property bool open: false
    property var detail: []
    signal toggled(string productId)

    radius: dp(Constants.radius)
    color: Constants.cardBg
    border.color: row.reconciles ? Constants.borderColor : Constants.warn
    border.width: 1
    implicitHeight: rowColumn.implicitHeight + dp(Constants.space3) * 2

    Accessible.role: Accessible.Button
    Accessible.name: row.rowName
    Accessible.onPressAction: row.toggled(row.productId)

    ColumnLayout {
        id: rowColumn
        anchors.fill: parent
        anchors.margins: dp(Constants.space3)
        spacing: dp(Constants.space2)

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            Text {
                Layout.fillWidth: true
                text: row.title
                color: Constants.textPrimary
                font.pixelSize: sp(Constants.fsBodyLg)
                font.bold: true
                elide: Text.ElideRight
            }
            Icon {
                name: "chevron"
                rotation: row.open ? 90 : 0
                color: Constants.textMuted
                size: sp(14)
            }
        }

        Text {
            Layout.fillWidth: true
            visible: row.note.length > 0
            text: row.note
            color: row.reconciles ? Constants.textMuted : Constants.warn
            font.pixelSize: sp(Constants.fsSmall)
            wrapMode: Text.WordWrap
        }

        // Four columns with their names, so the numbers are never bare.
        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)

            Repeater {
                model: [
                    { name: qsTr("Opening"), value: row.openingText },
                    { name: qsTr("In"), value: row.inText },
                    { name: qsTr("Out"), value: row.outText },
                    { name: qsTr("Closing"), value: row.closingText }
                ]
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    spacing: dp(2)
                    Text {
                        text: modelData.name
                        color: Constants.textMuted
                        font.pixelSize: sp(Constants.fsCaption)
                    }
                    Text {
                        Layout.fillWidth: true
                        text: modelData.value
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBody)
                        font.bold: true
                        elide: Text.ElideRight
                    }
                }
            }
        }

        // Per-kind lines of the open row.
        ColumnLayout {
            Layout.fillWidth: true
            visible: row.open
            spacing: dp(Constants.space1)

            Rectangle { Layout.fillWidth: true; height: 1; color: Constants.borderColor }

            Text {
                Layout.fillWidth: true
                visible: row.detail.length === 0
                text: Glue.DETAIL_EMPTY
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsSmall)
                wrapMode: Text.WordWrap
            }
            Repeater {
                model: row.detail
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: dp(Constants.space2)
                    Text {
                        Layout.fillWidth: true
                        text: modelData.label
                        color: Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
                    }
                    Text {
                        text: qsTr("In %1").arg(modelData.inText)
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsSmall)
                    }
                    Text {
                        text: qsTr("Out %1").arg(modelData.outText)
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsSmall)
                    }
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: row.toggled(row.productId)
    }

}
