import QtQuick
import QtQuick.Controls
import QtQuick.Layouts 1.3
import Qt.labs.qmlmodels
import Felgo

Item {
    id: inventoryPage
    width: parent.width
    height: inventoryDetails.height

    function appendRowToInventoryTable(productData) {
        var row = {
            "product_id": productData["product_id"],
            "name": productData["name"],
            "sku": productData["sku"],
            "category": productData["category"],
            "stock": productData["currentStock"],
            "in_stock_status": productData["currentStock"] > (productData["minimumStock"] ? 1 : 0),
            "price": productData["price"],
            "actions": "Restock",
        }
        tableModel.appendRow(row)
    }

    Connections {
        target: logic

        function onProductAdded(productData) {
            appendRowToInventoryTable(productData)
        }
    }

    Component.onCompleted: {
        if (dataModel.inventoryDataJson !== undefined && dataModel.inventoryDataJson.length > 0) {
            console.log(" %%%%%%%%%%%%%%%% inventoryDataJson size: ", dataModel.inventoryDataJson.length)
            for(var i = 0; i < dataModel.inventoryDataJson.length; ++i) {
                // console.log("%%%%%%%%%%%%%%%% row: ", JSON.stringify(dataModel.inventoryDataJson[i]))
                appendRowToInventoryTable(dataModel.inventoryDataJson[i])
            }
        }
    }

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
                font.pixelSize: sp(16)
                font.bold: true
                anchors.left: parent.left
            }
            AppText {
                id: infoDetails
                text: "Track and manage product \ninventory"
                color: 'black'
                font.pixelSize: sp(12)
                anchors.left: parent.left
                anchors.top: infoTitle.bottom
            }
            Rectangle {
                id: addProductButton
                height: dp(30)
                width: height * 4
                radius: height/4
                color: addProductButtonMA.pressed ? 'lightGreen' : 'green'
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter

                AppText {
                    text: "+ Add Product"
                    color: 'white'
                    font.pixelSize: sp(12)
                    font.bold: true
                    anchors.centerIn: parent
                }

                MouseArea {
                    id: addProductButtonMA
                    anchors.fill: parent
                    onClicked: {
                        addProductPage.open()
                    }
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
                                font.pixelSize: sp(12)
                            }
                            AppText {
                                id: details
                                text: model.details
                                color: theme.darkTextColor
                                font.pixelSize: sp(10)
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
                                    font.pixelSize: sp(10)
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
            height: infoContent.height + dp(20)
            radius: height/32
            anchors.horizontalCenter: parent.horizontalCenter

            ColumnLayout {
                id: infoContent
                width: parent.width - dp(20)
                anchors.top: parent.top
                anchors.topMargin: dp(10)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: dp(10)

                Item {
                    id: infoDetailsHeader
                    width: parent.width
                    height: childrenRect.height

                    AppText {
                        id: productInfoTitle
                        text: "Product Inventory"
                        color: 'black'
                        font.pixelSize: sp(12)
                    }
                    AppText {
                        id: productInfoDetails
                        text: "All products and stock levels"
                        color: theme.darkTextColor
                        font.pixelSize: sp(10)
                        anchors.top: productInfoTitle.bottom
                        anchors.topMargin: dp(3)
                    }
                }

                Rectangle {
                    id: searchBar
                    width: parent.width
                    height: dp(25)
                    color: theme.lightTextColor
                    radius: height/4
                    AppIcon {
                        id: searchIcon
                        iconType: IconType.search
                        size: dp(10)
                        color: theme.darkTextColor
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: dp(5)
                        visible: searchInput.text === "" || searchInput.text === undefined
                    }

                    AppTextInput {
                        id: searchInput
                        width: parent.width - dp(10)
                        anchors.left: searchInput.text === "" || searchInput.text === undefined ? searchIcon.right : parent.left
                        anchors.leftMargin: dp(5)
                        height: parent.height
                        placeholderText: "Search Products..."
                        placeholderColor: theme.darkTextColor
                        fontSize: sp(7)
                    }
                }

                Item {
                    id: tableScroll
                    width: parent.width
                    height: dp(300)
                    clip:true

                    HorizontalHeaderView {
                        id: header
                        syncView: infoTable
                        model: ["Product ID", "Name", "SKU", "Category", "Stock", "Status", "Price", "Actions"]
                        clip:true
                        movableColumns: false

                        delegate: Rectangle {
                            implicitWidth: dp(100)
                            implicitHeight: dp(30)

                            Text {
                                text: modelData
                                anchors.centerIn: parent
                                font.bold: true
                            }
                            Rectangle {
                                width: parent.width
                                height: dp(1)
                                color: theme.lightTextColor
                                anchors.bottom: parent.bottom
                            }
                        }
                    }

                    TableView {
                        id: infoTable
                        width: tableScroll.width
                        height: tableScroll.height - header.height
                        anchors.top: header.bottom
                        clip: true
                        model: tableModel
                        // columnSpacing: dp(5)
                        contentWidth: dp(100)
                        contentHeight: infoTable.height / 8
                        resizableColumns: false
                        resizableRows: false
                        syncDirection: Qt.Horizontal

                        delegate: Rectangle {
                            implicitWidth: dp(100)
                            implicitHeight: dp(30)

                            Text {
                                text: display
                                anchors.centerIn: parent
                                elide: Text.ElideRight
                            }
                            Rectangle {
                                width: parent.width
                                height: 1
                                color: theme.lightTextColor
                                anchors.bottom: parent.bottom
                            }
                        }
                    }
                }
            }
        }
    }

    AddProductPage {
        id: addProductPage
        anchors.centerIn: inventoryPage
        pushBackContent: inventoryPage
    }

    TableModel {
        id: tableModel
        TableModelColumn { display: "product_id" }
        TableModelColumn { display: "name" }
        TableModelColumn { display: "sku" }
        TableModelColumn { display: "category" }
        TableModelColumn { display: "stock" }
        TableModelColumn { display: "in_stock_status" }
        TableModelColumn { display: "price" }
        TableModelColumn { display: "actions" }
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

