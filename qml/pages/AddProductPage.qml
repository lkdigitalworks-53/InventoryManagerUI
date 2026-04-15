import Felgo
import QtQuick

AppModal {
  id: addNewProductPage

  fullscreen: false
  closeOnBackgroundClick: false
  modalHeight: dp(800)

  AppFlickable {
    id: flickableModal
    anchors.fill: parent

    // set contentHeight of flickable to allow scrolling
    contentHeight: newProductDetails.height + dp(50)
    boundsBehavior: Flickable.StopAtBounds

    // Validation helpers for Add Product
    function _isNotEmpty(input) {
      return input && input.text !== undefined && input.text.trim() !== "";
    }

    function _isValidPrice(input) {
      if (!input || input.text === undefined) return false;
      var v = parseFloat(input.text);
      return !isNaN(v) && v >= 0;
    }

    function _isValidStock(input) {
      if (!input || input.text === undefined) return false;
      var v = parseFloat(input.text);
      return !isNaN(v) && v >= 0 && Math.floor(v) === v;
    }

    property bool canAddProduct: flickableModal._isNotEmpty(nameInput) &&
                                flickableModal._isNotEmpty(skuInput) &&
                                flickableModal._isNotEmpty(categoryInput) &&
                                flickableModal._isNotEmpty(priceInput) &&
                                flickableModal._isNotEmpty(sellingPriceInput) &&
                                flickableModal._isNotEmpty(currentStockInput) &&
                                flickableModal._isValidPrice(priceInput) &&
                                flickableModal._isValidPrice(sellingPriceInput) &&
                                flickableModal._isValidStock(currentStockInput)

    Column {
      id: newProductDetails
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
        width: newProductDetails.width - dp(10)
        height: childrenRect.height + dp(10)

        AppText {
          id: productInfoTitle
          width: parent.width
          text: "Add New Product"
          color: 'black'
          font.pixelSize: sp(22)
          font.bold: true
          anchors.top: infoDetailsHeader.top
          horizontalAlignment: Text.AlignHCenter
        }

        AppIcon {
            id: crossIcon
            iconType: IconType.close
            size: dp(20)
            color: theme.darkTextColor
            anchors.right: parent.right
            anchors.verticalCenter: productInfoTitle.verticalCenter
            MouseArea {
              anchors.fill: parent
              onClicked: {
                addNewProductPage.close()
              }
            }
        }
        AppText {
          id: productInfoDetails
          width: parent.width
          text: "Add a new product to your inventory with details and stock information"
          color: theme.darkTextColor
          font.pixelSize: sp(18)
          anchors.top: productInfoTitle.bottom
          anchors.topMargin: dp(3)
          horizontalAlignment: Text.AlignHCenter
        }
      }

      AppText {
        id: productInfoHeader
        text: "Product Information"
        color: theme.darkTextColor
        font.pixelSize: sp(20)
        font.bold: true
      }

      Rectangle {
        width: parent.width
        height: dp(2)
        color: theme.darkTextColor
        opacity: 0.6
      }

      Item {
          width: parent.width
          height: dp(5)
      }

      AppText {
        id: nameError
        text: "Required"
        color: 'red'
        font.pixelSize: sp(18)
        visible: !flickableModal._isNotEmpty(nameInput)
      }

      AppText {
        id: productNameFeildHeader
        text: "Product Name *"
        color: 'black'
        font.pixelSize: sp(18)
      }


      Rectangle {
        id: nameFeild
        width: parent.width
        height: dp(40)
        color: theme.lightTextColor
        radius: height/4

        AppTextInput {
          id: nameInput
          width: parent.width - dp(10)
          height: parent.height
          anchors.left: parent.left
          anchors.leftMargin: dp(5)
          placeholderText: "Enter product name"
          placeholderColor: theme.darkTextColor
          fontSize: sp(18)
        }
      }

      AppText {
        id: skuError
        text: "Required"
        color: 'red'
        font.pixelSize: sp(18)
        visible: !flickableModal._isNotEmpty(skuInput)
      }

      AppText {
        id: skuFeildHeader
        text: "SKU *"
        color: 'black'
        font.pixelSize: sp(18)
      }

      Row {
        id: skuFeildRow
        spacing: dp(5)
        height: dp(40)
        width: parent.width

        Rectangle {
          id: skuFeild
          width: parent.width - generateSKUButton.width
          height: dp(40)
          color: theme.lightTextColor
          anchors.verticalCenter: parent.verticalCenter
          radius: height/4

          AppTextInput {
            id: skuInput
            width: parent.width - dp(10)
            height: parent.height
            anchors.left: parent.left
            anchors.leftMargin: dp(5)
            placeholderText: "Product SKU"
            placeholderColor: theme.darkTextColor
            fontSize: sp(18)
          }
        }

        Rectangle {
          id: generateSKUButton
          height: dp(40)
          width: height * 3
          radius: height/4
          color: 'white'
          anchors.verticalCenter: parent.verticalCenter
          border.color: theme.lightTextColor
          border.width: dp(1)

          AppText {
            text: "Generate"
            color: 'black'
            font.pixelSize: sp(18)
            font.bold: true
            anchors.centerIn: parent
          }

          MouseArea {
            anchors.fill: parent
            onClicked: {
              //Generate SKU
            }
          }
        }
      }
      AppText {
        id: categoryError
        text: "Required"
        color: 'red'
        font.pixelSize: sp(18)
        visible: !flickableModal._isNotEmpty(categoryInput)
      }

      AppText {
        id: categoryFeildHeader
        text: "Category *"
        color: 'black'
        font.pixelSize: sp(18)
      }

      Rectangle {
        id: categoryFeild
        width: parent.width
        height: dp(40)
        color: theme.lightTextColor
        radius: height/4

        AppTextInput {
          id: categoryInput
          width: parent.width - dp(10)
          height: parent.height
          anchors.left: parent.left
          anchors.leftMargin: dp(5)
          placeholderText: "Select category"
          placeholderColor: theme.darkTextColor
          fontSize: sp(18)
        }
      }

      AppText {
        id: descriptionFeildHeader
        text: "Description"
        color: 'black'
        font.pixelSize: sp(18)
      }

      Rectangle {
        id: descriptionFeild
        width: parent.width
        height: dp(100)
        color: theme.lightTextColor
        radius: height/8

        AppTextInput {
          id: descriptionInput
          width: parent.width - dp(10)
          height: parent.height
          anchors.left: parent.left
          anchors.leftMargin: dp(5)
          placeholderText: "Enter product description"
          placeholderColor: theme.darkTextColor
          fontSize: sp(18)
        }
      }

      Item {
        width: parent.width
        height: dp(20)
      }

      AppText {
        id: stockInfoHeader
        text: "Product Information"
        color: theme.darkTextColor
        font.pixelSize: sp(18)
        font.bold: true
      }

      Rectangle {
        width: parent.width
        height: dp(2)
        color: theme.darkTextColor
        opacity: 0.6
      }

      Item {
          width: parent.width
          height: dp(5)
      }

      AppText {
        id: priceError
        text: "Required"
        color: 'red'
        font.pixelSize: sp(18)
        visible: !flickableModal._isNotEmpty(priceInput)
      }

      AppText {
        id: priceFormatError
        text: "Enter a valid non-negative number"
        color: 'red'
        font.pixelSize: sp(18)
        visible: flickableModal._isNotEmpty(priceInput) && !flickableModal._isValidPrice(priceInput)
      }

      AppText {
        id: priceFeildHeader
        text: "Price (₹) *"
        color: 'black'
        font.pixelSize: sp(18)
      }

      Rectangle {
        id: priceFeild
        width: parent.width
        height: dp(40)
        color: theme.lightTextColor
        radius: height/8

        AppTextInput {
          id: priceInput
          width: parent.width - dp(10)
          height: parent.height
          anchors.left: parent.left
          anchors.leftMargin: dp(5)
          placeholderText: "0.00"
          placeholderColor: theme.darkTextColor
          fontSize: sp(18)
        }
      }

      AppText {
        id: sellingPriceError
        text: "Required"
        color: 'red'
        font.pixelSize: sp(18)
        visible: !flickableModal._isNotEmpty(sellingPriceInput)
      }

      AppText {
        id: sellingPriceFormatError
        text: "Enter a valid non-negative number"
        color: 'red'
        font.pixelSize: sp(18)
        visible: flickableModal._isNotEmpty(sellingPriceInput) && !flickableModal._isValidPrice(sellingPriceInput)
      }

      AppText {
        id: sellingPriceFeildHeader
        text: "Selling Price (₹) *"
        color: 'black'
        font.pixelSize: sp(18)
      }

      Rectangle {
        id: sellingPriceFeild
        width: parent.width
        height: dp(40)
        color: theme.lightTextColor
        radius: height/8

        AppTextInput {
          id: sellingPriceInput
          width: parent.width - dp(10)
          height: parent.height
          anchors.left: parent.left
          anchors.leftMargin: dp(5)
          placeholderText: "0.00"
          placeholderColor: theme.darkTextColor
          fontSize: sp(18)
        }
      }

      AppText {
        id: measurementFeildHeader
        text: "Measurement Unit"
        color: 'black'
        font.pixelSize: sp(18)
      }

      Rectangle {
        id: measurementFeild
        width: parent.width
        height: dp(40)
        color: theme.lightTextColor
        radius: height/8

        AppTextInput {
          id: measurementInput
          width: parent.width - dp(10)
          height: parent.height
          anchors.left: parent.left
          anchors.leftMargin: dp(5)
          placeholderText: "Units (pcs)"
          placeholderColor: theme.darkTextColor
          fontSize: sp(18)
        }
      }

      AppText {
        id: currentStockError
        text: "Required"
        color: 'red'
        font.pixelSize: sp(18)
        visible: !flickableModal._isNotEmpty(currentStockInput)
      }

      AppText {
        id: currentStockFormatError
        text: "Enter a non-negative integer"
        color: 'red'
        font.pixelSize: sp(18)
        visible: flickableModal._isNotEmpty(currentStockInput) && !flickableModal._isValidStock(currentStockInput)
      }

      AppText {
        id: currentStockFeildHeader
        text: "Current Stock *"
        color: 'black'
        font.pixelSize: sp(18)
      }

      Rectangle {
        id: currentStockFeild
        width: parent.width
        height: dp(40)
        color: theme.lightTextColor
        radius: height/8

        AppTextInput {
          id: currentStockInput
          width: parent.width - dp(10)
          height: parent.height
          anchors.left: parent.left
          anchors.leftMargin: dp(5)
          placeholderText: "0"
          placeholderColor: theme.darkTextColor
          fontSize: sp(18)
        }
      }

      AppText {
        id: minStockError
        text: "Required"
        color: 'red'
        font.pixelSize: sp(18)
        visible: !flickableModal._isNotEmpty(minimumStockInput)
      }

      AppText {
        id: minimumStockFeildHeader
        text: "Minimum Stock Level *"
        color: 'black'
        font.pixelSize: sp(18)
      }

      Rectangle {
        id: minimumStockFeild
        width: parent.width
        height: dp(40)
        color: theme.lightTextColor
        radius: height/8

        AppTextInput {
          id: minimumStockInput
          width: parent.width - dp(10)
          height: parent.height
          anchors.left: parent.left
          anchors.leftMargin: dp(5)
          placeholderText: "1"
          placeholderColor: theme.darkTextColor
          fontSize: sp(18)
          text: "1"
        }
      }

      Row {
        id: actionButtonFeildRow
        spacing: dp(5)
        height: dp(50)
        width: parent.width
        layoutDirection: Qt.RightToLeft

        Rectangle {
          id: addProductButton
          height: dp(50)
          width: height * 4
          radius: height/4
          color: flickableModal.canAddProduct ? (addButtonMA.pressed ? 'lightGreen' : 'green') : theme.lightTextColor
          opacity: flickableModal.canAddProduct ? 1.0 : 0.6
          anchors.verticalCenter: parent.verticalCenter

          AppText {
            text: "Add Product"
            color: flickableModal.canAddProduct ? 'white' : theme.darkTextColor
            font.pixelSize: sp(20)
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
              let product = {
                "name": nameInput.text,
                "sku": skuInput.text,
                "category": categoryInput.text,
                "description": descriptionInput.text,
                "price": (priceInput.text !== "" ? parseFloat(priceInput.text) : 0),
                "sellingPrice": (sellingPriceInput.text !== "" ? parseFloat(sellingPriceInput.text) : 0),
                "measurementUnit": measurementInput.text,
                "currentStock": (currentStockInput.text !== "" ? parseInt(currentStockInput.text) : 0),
                "minimumStock": (minimumStockInput.text !== "" ? parseInt(minimumStockInput.text) : 0)
              };
              console.log("product: ", JSON.stringify(product))
              console.log("====== ")

              // Trigger the logic action
              logic.addProduct(product);
              addNewProductPage.close()
            }
          }
        }

        Rectangle {
          id: cancelButton
          height: dp(50)
          width: height * 3
          radius: height/4
          color: cancelButtonMA.pressed ? theme.lightTextColor : 'white'
          anchors.verticalCenter: parent.verticalCenter
          border.color: theme.lightTextColor
          border.width: dp(1)

          AppText {
            text: "Cancel"
            color: 'black'
            font.pixelSize: sp(20)
            font.bold: true
            anchors.centerIn: parent
          }

          MouseArea {
            id: cancelButtonMA
            anchors.fill: parent
            onClicked: {
              addNewProductPage.close()
            }
          }
        }
      }
    }
  }
}
