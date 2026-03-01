import QtQuick
import Felgo

Item {
    id: inventoryPage

    Column {
        id: inventoryDetails
        width: parent.width
        height: implicitHeight
        spacing: dp(15)

        Item {
            id: topInfo
            width: parent.width - dp(20)
            height: dp(80)
            anchors.horizontalCenter: parent.horizontalCenter
            AppText {
                id: infoTitle
                text: "Inventory \nManagement"
                color: 'black'
                font.pixelSize: dp(16)
                font.bold: true
                anchors.left: parent.left
            }
            AppText {
                id: infoDetails
                text: "Track and manage product \ninventory"
                color: 'black'
                font.pixelSize: dp(12)
                anchors.left: parent.left
                anchors.top: infoTitle.bottom
            }
            Rectangle {
                id: addProductButton
                height: dp(30)
                width: height * 4
                radius: height/4
                color: 'green'
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter

                AppText {
                    text: "+ Add Product"
                    color: 'white'
                    font.pixelSize: dp(12)
                    font.bold: true
                    anchors.centerIn: parent
                }
            }
        }
        Item {
            id: middleInfo
            width: parent.width - dp(20)
            height: middleInfoColumn.height
            anchors.horizontalCenter: parent.horizontalCenter
            Column {
                id: middleInfoColumn
                width: parent.width
                height: implicitHeight
                spacing: dp(10)
                Repeater {
                    model: middleInfoModel
                    delegate: Rectangle {
                        id: delegateItem
                        width: middleInfoColumn.width
                        height: dp(100)
                        radius: height/8
                        color: model.color
                        border.color: model.borderColor
                        border.width: dp(1)
                        Item {
                            width: parent.width/2
                            height: parent.height - dp(40)
                            anchors.left: parent.left
                            anchors.leftMargin: dp(15)
                            anchors.verticalCenter: parent.verticalCenter

                            AppText {
                                id: name
                                text: model.name
                                color: model.borderColor
                                font.pixelSize: dp(12)
                            }
                            AppText {
                                id: details
                                text: model.details
                                color: theme.darkTextColor
                                font.pixelSize: dp(10)
                                anchors.top: name.bottom
                                anchors.topMargin: dp(5)
                            }
                            Item {
                                width: dp(10)
                                height: dp(10)
                                anchors.bottom: parent.bottom

                                AppImage {
                                    id: icon
                                    fillMode: Image.PreserveAspectFit
                                    source: model.icon
                                    anchors.left: parent.left
                                }
                                AppText {
                                    text: model.count
                                    color: model.borderColor
                                    font.pixelSize: dp(10)
                                    anchors.left: icon.source === "" ? parent.left : icon.left
                                }
                            }
                        }
                    }
                }
            }
        }

        AppPaper {
            id: productInventoryInfo
            width: parent.width - dp(20)
            height: dp(80)
            radius: height/8
            anchors.horizontalCenter: parent.horizontalCenter

        }
    }
    ListModel {
        id: middleInfoModel

        ListElement {
            name: "Total Products"
            details: "In inventory"
            count: 0
            icon: ""
            color: "#A8E4A0"
            borderColor: "#3F704D"
        }
        ListElement {
            name: "Low Stock"
            details: "Needs reorder"
            count: 0
            icon: ""
            color: "#FEE8D6"
            borderColor: "#CC5500"

        }
        ListElement {
            name: "Total Items"
            details: "In stock"
            count: 0
            icon: ""
            color: "#ADDFFF"
            borderColor: "#4169E1"
        }
        ListElement {
            name: "Total Value"
            details: "Inventory worth"
            count: 0
            icon: ""
            color: "#E0B0FF"
            borderColor: "#8F00FF"
        }
    }
}

