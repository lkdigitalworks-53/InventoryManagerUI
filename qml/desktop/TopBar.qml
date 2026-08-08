import QtQuick
import "../helper"
import "../components"

Item {
    id: root
    height: dp(46)

    property string workspaceName: ""
    property string userName: ""
    property string userRole: ""

    signal searchRequested(string query)

    Rectangle {
        anchors.fill: parent
        color: Constants.cardBg
        border.color: Constants.borderColor
        border.width: 1
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: dp(14)
        anchors.verticalCenter: parent.verticalCenter
        spacing: dp(14)

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Karobar"
            font.pixelSize: dp(13)
            font.bold: true
            color: Constants.textPrimary
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.workspaceName
            font.pixelSize: dp(12)
            color: Constants.textMuted
        }

        SearchField {
            id: searchField
            objectName: "topBarSearchField"
            anchors.verticalCenter: parent.verticalCenter
            width: dp(260)
            height: dp(32)
            placeholder: qsTr("Search orders, products, staff")
            onAccepted: root.searchRequested(text)
        }
    }

    Row {
        anchors.right: parent.right
        anchors.rightMargin: dp(14)
        anchors.verticalCenter: parent.verticalCenter
        spacing: dp(6)

        Rectangle {
            width: dp(20)
            height: dp(20)
            radius: dp(10)
            color: Qt.rgba(Constants.brand1.r, Constants.brand1.g, Constants.brand1.b, 0.15)

            Text {
                anchors.centerIn: parent
                text: root.userName.length > 0 ? root.userName.charAt(0).toUpperCase() : ""
                font.pixelSize: dp(11)
                color: Constants.brand1
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.userRole.length > 0 ? root.userName + " · " + root.userRole : root.userName
            font.pixelSize: dp(12)
            color: Constants.textPrimary
        }
    }
}
