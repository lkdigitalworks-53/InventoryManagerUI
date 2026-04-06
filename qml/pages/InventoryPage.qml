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
            "in_stock_status": (productData["currentStock"] > productData["minimumStock"] ? 1 : 0),
            "price": "₹" + productData["price"],
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
                        addProductLoader.sourceComponent = addProductComponent
                        addProductLoader.item.open()
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

                Rectangle {
                    id: totalProducts
                    width: middleInfoColumn.width
                    height: dp(100)
                    radius: height/8
                    color: "#A8E4A0"
                    border.color: "#3F704D"
                    border.width: dp(1)
                    Item {
                        width: parent.width/2
                        height: parent.height - dp(40)
                        anchors.left: parent.left
                        anchors.leftMargin: dp(15)
                        anchors.verticalCenter: parent.verticalCenter

                        AppText {
                            id: name
                            text: "Total Products"
                            color: "#3F704D"
                            font.pixelSize: sp(12)
                        }
                        AppText {
                            id: details
                            text: "In inventory"
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
                                source: ""
                                anchors.left: parent.left
                            }
                            AppText {
                                text: dataModel.totalProducts
                                color: "#3F704D"
                                font.pixelSize: sp(10)
                                anchors.left: icon.source === "" ? parent.left : icon.left
                            }
                        }
                    }
                }

                Rectangle {
                    id: lowStocks
                    width: middleInfoColumn.width
                    height: dp(100)
                    radius: height/8
                    color: "#FEE8D6"
                    border.color: "#CC5500"
                    border.width: dp(1)
                    Item {
                        width: parent.width/2
                        height: parent.height - dp(40)
                        anchors.left: parent.left
                        anchors.leftMargin: dp(15)
                        anchors.verticalCenter: parent.verticalCenter

                        AppText {
                            id: name2
                            text: "Low Stock"
                            color: "#CC5500"
                            font.pixelSize: sp(12)
                        }
                        AppText {
                            id: details2
                            text: "Needs reorder"
                            color: theme.darkTextColor
                            font.pixelSize: sp(10)
                            anchors.top: name2.bottom
                            anchors.topMargin: dp(5)
                        }
                        Item {
                            width: dp(10)
                            height: dp(10)
                            anchors.bottom: parent.bottom

                            AppImage {
                                id: icon2
                                fillMode: Image.PreserveAspectFit
                                source: ""
                                anchors.left: parent.left
                            }
                            AppText {
                                text: dataModel.totalItemsInLowStockState
                                color: "#CC5500"
                                font.pixelSize: sp(10)
                                anchors.left: icon2.source === "" ? parent.left : icon2.left
                            }
                        }
                    }
                }

                Rectangle {
                    id: totalItems
                    width: middleInfoColumn.width
                    height: dp(100)
                    radius: height/8
                    color: "#ADDFFF"
                    border.color: "#4169E1"
                    border.width: dp(1)
                    Item {
                        width: parent.width/2
                        height: parent.height - dp(40)
                        anchors.left: parent.left
                        anchors.leftMargin: dp(15)
                        anchors.verticalCenter: parent.verticalCenter

                        AppText {
                            id: name3
                            text: "Total Items"
                            color: "#4169E1"
                            font.pixelSize: sp(12)
                        }
                        AppText {
                            id: details3
                            text: "In stock"
                            color: theme.darkTextColor
                            font.pixelSize: sp(10)
                            anchors.top: name3.bottom
                            anchors.topMargin: dp(5)
                        }
                        Item {
                            width: dp(10)
                            height: dp(10)
                            anchors.bottom: parent.bottom

                            AppImage {
                                id: icon3
                                fillMode: Image.PreserveAspectFit
                                source: ""
                                anchors.left: parent.left
                            }
                            AppText {
                                text: dataModel.totalItems
                                color: "#4169E1"
                                font.pixelSize: sp(10)
                                anchors.left: icon3.source === "" ? parent.left : icon3.left
                            }
                        }
                    }
                }

                Rectangle {
                    id: totalValue
                    width: middleInfoColumn.width
                    height: dp(100)
                    radius: height/8
                    color: "#E0B0FF"
                    border.color: "#8F00FF"
                    border.width: dp(1)
                    Item {
                        width: parent.width/2
                        height: parent.height - dp(40)
                        anchors.left: parent.left
                        anchors.leftMargin: dp(15)
                        anchors.verticalCenter: parent.verticalCenter

                        AppText {
                            id: name4
                            text: "Total Value"
                            color: "#8F00FF"
                            font.pixelSize: sp(12)
                        }
                        AppText {
                            id: details4
                            text: "Inventory worth"
                            color: theme.darkTextColor
                            font.pixelSize: sp(10)
                            anchors.top: name4.bottom
                            anchors.topMargin: dp(5)
                        }
                        Item {
                            width: dp(10)
                            height: dp(10)
                            anchors.bottom: parent.bottom

                            AppImage {
                                id: icon4
                                fillMode: Image.PreserveAspectFit
                                source: ""
                                anchors.left: parent.left
                            }
                            AppText {
                                text: "₹" + dataModel.totalValue
                                color: "#8F00FF"
                                font.pixelSize: sp(10)
                                anchors.left: icon4.source === "" ? parent.left : icon4.left
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



    Loader {
       id: addProductLoader
       width: parent.width
       height: childrenRect.height
    }

    Component {
        id: addProductComponent

        AddProductPage {
            id: addProductPage
            anchors.centerIn: inventoryPage
            pushBackContent: inventoryPage

            onClosed: {
                addProductLoader.sourceComponent = null
            }
        }
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
}

