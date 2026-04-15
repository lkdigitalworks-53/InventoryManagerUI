import Felgo
import QtQuick
import QtQuick.Controls 2.15

AppModal {
    id: addNewOrderPage

    fullscreen: false
    closeOnBackgroundClick: false
    modalHeight: dp(400)

    Component.onCompleted: {
        if (listModel.count > 0) {
            var productInfo = {
                "product_id": listModel.get(0)["product_id"],
                "product_name": listModel.get(0)["name"],
                "sellingPrice": listModel.get(0)["sellingPrice"],
                "items": 1,
            }
            console.log(" ########## adding selected products: ", JSON.stringify(productInfo))
            selectProductModel.append(productInfo)
        }
    }

    AppFlickable {
        id: flickableModal
        anchors.fill: parent

        // set contentHeight of flickable to allow scrolling
        contentHeight: newOrderDetails.height + dp(50)
        boundsBehavior: Flickable.StopAtBounds

        // Validation helpers for Add Product
        function _isNotEmpty(input) {
            return input && input.text !== undefined && input.text.trim() !== "";
        }
        function _isValidPhoneNumber(input) {
            if (!input || input.text === undefined) return false;
            if (input.text.length !== 10) return false
            var v = parseInt(input.text);
            return !isNaN(v) && v >= 0;
        }

        property bool canAddProduct: flickableModal._isNotEmpty(nameInput) &&
                                     flickableModal._isNotEmpty(phoneInput) &&
                                     flickableModal._isValidPhoneNumber(phoneInput)

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
                id: customerNameError
                text: "Required"
                color: 'red'
                font.pixelSize: sp(8)
                visible: !flickableModal._isNotEmpty(nameInput)
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
                id: phoneError
                text: "Required"
                color: 'red'
                font.pixelSize: sp(8)
                visible: !flickableModal._isNotEmpty(phoneInput)
            }

            AppText {
              id: phoneFormatError
              text: "Enter a valid phone number"
              color: 'red'
              font.pixelSize: sp(8)
              visible: flickableModal._isNotEmpty(phoneInput) && !flickableModal._isValidPhoneNumber(phoneInput)
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

            Column {
                id: selectProductRepeater
                spacing: dp(5)
                width: parent.width

                Repeater {
                    id: repeater
                    model: selectProductModel
                    delegate: selectProductComponent
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
                    color: flickableModal.canAddProduct ? (addButtonMA.pressed ? '#AAFF4500' : '#FF4500') : theme.lightTextColor
                    opacity: flickableModal.canAddProduct ? 1.0 : 0.6
                    anchors.verticalCenter: parent.verticalCenter

                    function getTotalItems() {
                        var items = 0
                        for (var i = 0; i < selectProductModel.count; ++i) {
                            items += selectProductModel.get(i)["items"]
                        }
                        return items
                    }
                    function getTotalValue() {
                        var value = 0
                        for (var i = 0; i < selectProductModel.count; ++i) {
                            value += selectProductModel.get(i)["sellingPrice"] * selectProductModel.get(i)["items"]
                        }
                        return value
                    }

                    AppText {
                        text: "Add Order"
                        color: flickableModal.canAddProduct ? 'white' : theme.darkTextColor
                        font.pixelSize: sp(12)
                        font.bold: true
                        anchors.centerIn: parent
                    }

                    MouseArea {
                        id: addButtonMA
                        anchors.fill: parent
                        enabled: flickableModal.canAddProduct
                        onClicked: {
                            console.log("====== ")
                            // Prepare the payload for the Logic layer
                            let order = {
                                "customer": nameInput.text,
                                "selected_products_info": selectProductModel.source,
                                "items": addOrderButton.getTotalItems(),
                                "total_value": addOrderButton.getTotalValue(),
                                "status": "pending",
                                "date": new Date().toLocaleString()
                            };
                            console.log("order: ", JSON.stringify(order))
                            console.log("====== ")

                            // Trigger the logic action
                            logic.addOrder(order);
                            selectProductModel.clear()
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

    Component {
        id: selectProductComponent

        Row {
            id: selectProductFeildRow
            spacing: dp(5)
            height: dp(25)
            width: parent.width
            
            // Capture the repeater index to use in nested delegates
            property int repeaterIndex: index

            Rectangle {
                id: addProductRowButton
                height: parent.height
                width: height
                radius: height/4
                color: addRowButtonMA.pressed ? '#AAFF4500' : '#FF4500'
                anchors.verticalCenter: parent.verticalCenter

                AppText {
                    text: "+"
                    color: 'white'
                    font.pixelSize: sp(12)
                    font.bold: true
                    anchors.centerIn: parent
                }

                MouseArea {
                    id: addRowButtonMA
                    anchors.fill: parent
                    onClicked: {
                        // Add a new empty product entry to the array
                        selectProductModel.append({
                                                      "product_id": "",
                                                      "product_name": "",
                                                      "sellingPrice": 0,
                                                      "items": 1
                                                  })
                    }
                }
            }

            ComboBox {
                id: selectProductMenu
                width: parent.width - addProductRowButton.width - noOfItemsButton.width - selectProductFeildRow.spacing
                height: parent.height
                model: listModel
                displayText: currentIndex === -1 ? "Select Product from the list" : getDisplayText(currentIndex)

                function getDisplayText(index) {
                    return listModel.get(index)["name"] + " - ₹" + listModel.get(index)["sellingPrice"]
                }

                indicator: AppIcon {
                    id: downIcon
                    iconType: IconType.caretdown
                    size: dp(10)
                    color: theme.darkTextColor
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: dp(5)
                }
                background: Rectangle {
                    id: background
                    width: parent.width
                    height: parent.height
                    color: theme.lightTextColor
                    radius: height/8
                }
                delegate: Rectangle {
                    id: delegate
                    width: selectProductMenu.width
                    height: selectProductMenu.height
                    color: 'white'
                    radius: height/8

                    AppText {
                        id: selectProductText
                        width: parent.width - dp(10)
                        height: parent.height
                        anchors.left: parent.left
                        anchors.leftMargin: dp(5)
                        color: 'black'
                        fontSize: sp(8)
                        text: selectProductMenu.getDisplayText(index)
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            selectProductMenu.currentIndex = index
                            var productInfo = {
                                "product_id": listModel.get(index)["product_id"],
                                "product_name": listModel.get(index)["name"],
                                "sellingPrice": listModel.get(index)["sellingPrice"],
                                "items": noOfItemsButton.count,
                            }
                            console.log(" ########## adding selected products: ", JSON.stringify(productInfo))
                            // Update the correct row in the array using repeater index
                            selectProductModel.set(selectProductFeildRow.repeaterIndex, productInfo)
                            selectProductMenu.popup.close()
                        }
                    }
                }
            }

            Rectangle {
                id: noOfItemsButton
                height: parent.height
                width: height * 3
                radius: height/4
                color: (decreaseMA.pressed || increaseMA.pressed) ? theme.lightTextColor : 'white'
                anchors.verticalCenter: parent.verticalCenter
                border.color: theme.lightTextColor
                border.width: dp(1)

                property int count: 1

                AppText {
                    id: decreasebutton
                    text: "-"
                    color: 'black'
                    font.pixelSize: sp(16)
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    width: parent.width / 3
                    horizontalAlignment: Text.AlignHCenter
                    enabled: noOfItemsButton.count > 1

                    MouseArea {
                        id: decreaseMA
                        anchors.fill: parent
                        onClicked: {
                            noOfItemsButton.count--
                            // Update the array with new count
                            if (selectProductModel.get(selectProductFeildRow.repeaterIndex)) {
                                var product = selectProductModel.get(selectProductFeildRow.repeaterIndex)
                                product["items"] = noOfItemsButton.count
                                selectProductModel.set(selectProductFeildRow.repeaterIndex, product)
                            }
                        }
                    }
                }

                AppText {
                    id: noOfItemsText
                    text: noOfItemsButton.count
                    color: 'black'
                    font.pixelSize: sp(12)
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: decreasebutton.right
                    width: parent.width / 3
                    horizontalAlignment: Text.AlignHCenter
                }

                AppText {
                    text: "+"
                    color: 'black'
                    font.pixelSize: sp(16)
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: noOfItemsText.right
                    width: parent.width / 3
                    horizontalAlignment: Text.AlignHCenter

                    MouseArea {
                        id: increaseMA
                        anchors.fill: parent
                        onClicked: {
                            noOfItemsButton.count++
                            // Update the array with new count
                            if (selectProductModel.get(selectProductFeildRow.repeaterIndex)) {
                                var product = selectProductModel.get(selectProductFeildRow.repeaterIndex)
                                product["items"] = noOfItemsButton.count
                                selectProductModel.set(selectProductFeildRow.repeaterIndex, product)
                            }
                        }
                    }
                }
            }
        }
    }

    JsonListModel {
        id: listModel
        // keyField: "product_id"
        source: dataModel.inventoryDataJson
    }
    JsonListModel {
        id: selectProductModel
        // keyField: "product_id"
        source: []
    }
}
