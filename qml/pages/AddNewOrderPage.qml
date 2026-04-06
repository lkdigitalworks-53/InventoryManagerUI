import Felgo
import QtQuick

AppModal {
    id: addNewOrderPage

    fullscreen: false
    closeOnBackgroundClick: false
    modalHeight: dp(400)

    AppFlickable {
        id: flickableModal
        anchors.fill: parent

        // set contentHeight of flickable to allow scrolling
        contentHeight: newOrderDetails.height + dp(50)
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: newOrderDetails
            width: parent.width - dp(20)
            anchors.topMargin: dp(20)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: dp(10)

            Item {
                width: parent.width
                height: dp(5)
            }

            Item {
                id: infoDetailsHeader
                width: newOrderDetails.width - dp(10)
                height: childrenRect.height + dp(10)

                AppText {
                    id: orderInfoTitle
                    width: parent.width
                    text: "Create New Order"
                    color: 'black'
                    font.pixelSize: sp(12)
                    font.bold: true
                    anchors.top: infoDetailsHeader.top
                    horizontalAlignment: Text.AlignHCenter
                }

                AppIcon {
                    id: crossIcon
                    iconType: IconType.close
                    size: dp(12)
                    color: theme.darkTextColor
                    anchors.right: parent.right
                    anchors.verticalCenter: orderInfoTitle.verticalCenter
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            addNewOrderPage.close()
                        }
                    }
                }
                AppText {
                    id: orderInfoDetails
                    width: parent.width
                    text: "Add customer details and select products to create a new order"
                    color: theme.darkTextColor
                    font.pixelSize: sp(10)
                    anchors.top: orderInfoTitle.bottom
                    anchors.topMargin: dp(3)
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            AppText {
                id: orderInfoHeader
                text: "Customer Information"
                color: theme.darkTextColor
                font.pixelSize: sp(12)
                font.bold: true
            }

            Rectangle {
                width: parent.width
                height: dp(1)
                color: theme.darkTextColor
                opacity: 0.6
            }

            AppText {
                id: customerNameFeildHeader
                text: "Customer Name *"
                color: 'black'
                font.pixelSize: sp(12)
            }

            Rectangle {
                id: nameFeild
                width: parent.width
                height: dp(25)
                color: theme.lightTextColor
                radius: height/4

                AppTextInput {
                    id: nameInput
                    width: parent.width - dp(10)
                    height: parent.height
                    anchors.left: parent.left
                    anchors.leftMargin: dp(5)
                    placeholderText: "Enter customer name"
                    placeholderColor: theme.darkTextColor
                    fontSize: sp(8)
                }
            }

            AppText {
                id: emailFeildHeader
                text: "Email"
                color: 'black'
                font.pixelSize: sp(12)
            }

            Rectangle {
                id: emailFeild
                width: parent.width
                height: dp(25)
                color: theme.lightTextColor
                radius: height/4

                AppTextInput {
                    id: skuInput
                    width: parent.width - dp(10)
                    height: parent.height
                    anchors.left: parent.left
                    anchors.leftMargin: dp(5)
                    placeholderText: "customer@example.com"
                    placeholderColor: theme.darkTextColor
                    fontSize: sp(8)
                }
            }

            AppText {
                id: phoneFeildHeader
                text: "Phone Number *"
                color: 'black'
                font.pixelSize: sp(12)
            }

            Rectangle {
                id: phoneFeild
                width: parent.width
                height: dp(25)
                color: theme.lightTextColor
                radius: height/4

                AppTextInput {
                    id: phoneInput
                    width: parent.width - dp(10)
                    height: parent.height
                    anchors.left: parent.left
                    anchors.leftMargin: dp(5)
                    placeholderText: "+91 - XXXXX XXXXX"
                    placeholderColor: theme.darkTextColor
                    fontSize: sp(8)
                }
            }

            Item {
                width: parent.width
                height: dp(5)
            }

            AppText {
                id: productInfoHeader
                text: "Add Products"
                color: theme.darkTextColor
                font.pixelSize: sp(12)
                font.bold: true
            }

            Rectangle {
                width: parent.width
                height: dp(1)
                color: theme.darkTextColor
                opacity: 0.6
            }

            AppText {
                id: selectProductHeader
                text: "Select Product *"
                color: 'black'
                font.pixelSize: sp(12)
            }

            Rectangle {
                id: selectProductFeild
                width: parent.width
                height: dp(25)
                color: theme.lightTextColor
                radius: height/8

                AppTextInput {
                    id: selectProductInput
                    width: parent.width - dp(10)
                    height: parent.height
                    anchors.left: parent.left
                    anchors.leftMargin: dp(5)
                    placeholderText: "Select Product from the list"
                    placeholderColor: theme.darkTextColor
                    fontSize: sp(8)
                }
            }

            Row {
                id: actionButtonFeildRow
                spacing: dp(5)
                height: dp(30)
                width: parent.width
                layoutDirection: Qt.RightToLeft

                Rectangle {
                    id: addOrderButton
                    height: dp(30)
                    width: height * 4
                    radius: height/4
                    color: addButtonMA.pressed ? '#AAFF4500' : '#FF4500'
                    anchors.verticalCenter: parent.verticalCenter

                    AppText {
                        text: "Add Order"
                        color: 'white'
                        font.pixelSize: sp(12)
                        font.bold: true
                        anchors.centerIn: parent
                    }

                    MouseArea {
                        id: addButtonMA
                        anchors.fill: parent
                        onClicked: {
                            console.log("====== ")
                            // Prepare the payload for the Logic layer
                            let order = {

                            };
                            console.log("order: ", JSON.stringify(order))
                            console.log("====== ")

                            // Trigger the logic action
                            logic.addOrder(order);
                            addNewOrderPage.close()
                        }
                    }
                }

                Rectangle {
                    id: cancelButton
                    height: dp(30)
                    width: height * 3
                    radius: height/4
                    color: cancelButtonMA.pressed ? theme.lightTextColor : 'white'
                    anchors.verticalCenter: parent.verticalCenter
                    border.color: theme.lightTextColor
                    border.width: dp(1)

                    AppText {
                        text: "Cancel"
                        color: 'black'
                        font.pixelSize: sp(12)
                        font.bold: true
                        anchors.centerIn: parent
                    }

                    MouseArea {
                        id: cancelButtonMA
                        anchors.fill: parent
                        onClicked: {
                            addNewOrderPage.close()
                        }
                    }
                }
            }
        }
    }
}
