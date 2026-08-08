import QtQuick
import "../helper"

Item {
    id: root

    property string currentSection: "dashboard"

    readonly property var items: [
        { key: "dashboard", label: qsTr("Dashboard") },
        { key: "orders",    label: qsTr("Orders") },
        { key: "inventory", label: qsTr("Inventory") },
        { key: "analysis",  label: qsTr("Analysis") },
        { key: "staff",     label: qsTr("Staff") },
        { key: "activity",  label: qsTr("Activity") },
        { key: "settings",  label: qsTr("Settings") }
    ]

    signal sectionSelected(string section)

    function selectSection(key) {
        if (currentSection === key)
            return
        currentSection = key
        sectionSelected(key)
    }

    Rectangle {
        anchors.fill: parent
        color: Constants.cardBg
        border.color: Constants.borderColor
        border.width: 1
    }

    Column {
        id: list
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: dp(8)
        spacing: dp(2)

        Repeater {
            model: root.items

            delegate: Rectangle {
                id: delegate
                required property var modelData
                objectName: "sidebarItem_" + modelData.key
                width: list.width
                height: dp(36)
                radius: Constants.radiusSm
                color: modelData.key === root.currentSection
                       ? Qt.rgba(Constants.brand1.r, Constants.brand1.g, Constants.brand1.b, 0.12)
                       : "transparent"

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: dp(10)
                    anchors.verticalCenter: parent.verticalCenter
                    text: delegate.modelData.label
                    font.pixelSize: dp(13)
                    color: delegate.modelData.key === root.currentSection
                           ? Constants.brand1
                           : Constants.textSecondary
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.selectSection(delegate.modelData.key)
                }
            }
        }
    }
}
