import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"

// Format-picker bottom sheet. Emits formatSelected(format) — caller decides
// which exporter runs. Used by orders / inventory / sales / staff headers.
BottomSheet {
    id: root

    sheetTitle: "Export"
    primaryAction: ""
    secondaryAction: "Close"

    signal formatSelected(string format)

    Repeater {
        model: [
            { fmt: "xlsx", icon: "📊", label: qsTr("Excel (.xlsx)"), sub: qsTr("Spreadsheet, formulas preserved") }
        ]
        delegate: ListCard {
            Layout.fillWidth: true
            title: modelData.label
            subtitle: modelData.sub
            onClicked: { root.formatSelected(modelData.fmt); root.close() }

            leading: Rectangle {
                width: dp(38); height: dp(38); radius: dp(12)
                color: Qt.rgba(0.39, 0.40, 0.95, 0.10)
                Text { anchors.centerIn: parent; text: modelData.icon; font.pixelSize: sp(18) }
            }

            Text {
                text: "›"
                color: Constants.textMuted
                font.pixelSize: sp(16)
                Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
            }
        }
    }
}
