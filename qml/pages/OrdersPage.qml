import QtQuick
import QtQuick.Controls
import QtQuick.Layouts 1.3
import Qt.labs.qmlmodels
import Felgo

Item {
    id: ordersPage
    width: parent.width
    height: orderDetails.height

    function appendRowToOrderTable(orderData) {
        var row = {
            "order_id": orderData["order_id"],
            "customer": orderData["customer"],
            "items": orderData["items"],
            "total_value": orderData["total_value"],
            "status": orderData["status"],
            "date": orderData["date"],
            "actions": orderData["View"],
        }
        tableModel.appendRow(row)
    }

    Connections {
        target: logic
        function onOrderAdded(orderData) {
            appendRowToOrderTable(orderData)
        }
        function onDataLoaded(inventoryDataJson, ordersDataJson) {
            console.log(" ---------- ordersDataJson:  ", ordersDataJson.length)
            for (var i = 0; i < ordersDataJson.length; ++i) {
                appendRowToOrderTable(ordersDataJson[i])
            }
        }
    }

    Component.onCompleted: {
        if (dataModel.ordersDataJson !== undefined && dataModel.ordersDataJson.length > 0) {
            console.log(" %%%%%%%%%%%%%%%% ordersDataJson size: ", dataModel.ordersDataJson.length)
            for(var i = 0; i < dataModel.ordersDataJson.length; ++i) {
                // console.log("%%%%%%%%%%%%%%%% row: ", JSON.stringify(dataModel.ordersDataJson[i]))
                appendRowToOrderTable(dataModel.ordersDataJson[i])
            }
        }
    }

    Column {
        id: orderDetails
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
                text: "Order Management"
                color: 'black'
                font.pixelSize: sp(16)
                font.bold: true
                anchors.left: parent.left
            }
            AppText {
                id: infoDetails
                text: "Manage and track \ncustomer orders"
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
                color: addProductButtonMA.pressed ? '#AAFF4500' : '#FF4500'
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter

                AppText {
                    text: "+ New Order"
                    color: 'white'
                    font.pixelSize: sp(12)
                    font.bold: true
                    anchors.centerIn: parent
                }

                MouseArea {
                    id: addProductButtonMA
                    anchors.fill: parent
                    onClicked: {
                        addOrderLoader.sourceComponent = addOrderComponent
                        addOrderLoader.item.open()
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
                    id: totalOrders
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
                            id: name
                            text: "Total Orders"
                            color: "#CC5500"
                            font.pixelSize: sp(12)
                        }
                        AppText {
                            id: details
                            text: "All time"
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
                                text: dataModel.totalOrders
                                color: "#CC5500"
                                font.pixelSize: sp(10)
                                anchors.left: icon.source === "" ? parent.left : icon.left
                            }
                        }
                    }
                }

                Rectangle {
                    id: pendingOrders
                    width: middleInfoColumn.width
                    height: dp(100)
                    radius: height/8
                    color: "#FFFD74"
                    border.color: "#D19033"
                    border.width: dp(1)
                    Item {
                        width: parent.width/2
                        height: parent.height - dp(40)
                        anchors.left: parent.left
                        anchors.leftMargin: dp(15)
                        anchors.verticalCenter: parent.verticalCenter

                        AppText {
                            id: name2
                            text: "Pending"
                            color: "#D19033"
                            font.pixelSize: sp(12)
                        }
                        AppText {
                            id: details2
                            text: "Awaiting processing"
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
                                text: dataModel.totalPendingOrders
                                color: "#D19033"
                                font.pixelSize: sp(10)
                                anchors.left: icon2.source === "" ? parent.left : icon2.left
                            }
                        }
                    }
                }

                Rectangle {
                    id: completedOrders
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
                            id: name3
                            text: "Completed"
                            color: "#3F704D"
                            font.pixelSize: sp(12)
                        }
                        AppText {
                            id: details3
                            text: "This month"
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
                                text: dataModel.totalCompletedOrders
                                color: "#3F704D"
                                font.pixelSize: sp(10)
                                anchors.left: icon3.source === "" ? parent.left : icon3.left
                            }
                        }
                    }
                }
            }
        }

        AppPaper {
            id: recentOrderInfo
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
                        id: recentOrdersTitle
                        text: "Recent Orders"
                        color: 'black'
                        font.pixelSize: sp(12)
                    }
                    AppText {
                        id: recentOrdersDetails
                        text: "Latest customer orders"
                        color: theme.darkTextColor
                        font.pixelSize: sp(10)
                        anchors.top: recentOrdersTitle.bottom
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
                        placeholderText: "Search Orders..."
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
                        model: ["Order ID", "Customer", "Items", "Total", "Status", "Date", "Actions"]
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
       id: addOrderLoader
       width: parent.width
       height: childrenRect.height
    }

    Component {
        id: addOrderComponent

        AddNewOrderPage {
            id: addOrderPage
            // anchors.centerIn: ordersPage
            pushBackContent: ordersPage

            onClosed: {
                addOrderLoader.sourceComponent = null
            }
        }
    }


    TableModel {
        id: tableModel
        TableModelColumn { display: "order_id" }
        TableModelColumn { display: "customer" }
        TableModelColumn { display: "items" }
        TableModelColumn { display: "total_value" }
        TableModelColumn { display: "status" }
        TableModelColumn { display: "date" }
        TableModelColumn { display: "actions" }
    }
}

