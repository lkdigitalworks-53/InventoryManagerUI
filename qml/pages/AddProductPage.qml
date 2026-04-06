import Felgo
import QtQuick

AppModal {
  id: addNewProductPage

  fullscreen: false
  closeOnBackgroundClick: false
  modalHeight: dp(400)

  AppFlickable {
    id: flickableModal
    anchors.fill: parent

    // set contentHeight of flickable to allow scrolling
    contentHeight: newProductDetails.height + dp(50)
    boundsBehavior: Flickable.StopAtBounds

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
          font.pixelSize: sp(10)
          anchors.top: productInfoTitle.bottom
          anchors.topMargin: dp(3)
          horizontalAlignment: Text.AlignHCenter
        }
      }

      AppText {
        id: productInfoHeader
        text: "Product Information"
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
        id: productNameFeildHeader
        text: "Product Name *"
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
          placeholderText: "Enter product name"
          placeholderColor: theme.darkTextColor
          fontSize: sp(8)
        }
      }

      AppText {
        id: skuFeildHeader
        text: "SKU *"
        color: 'black'
        font.pixelSize: sp(12)
      }

      Row {
        id: skuFeildRow
        spacing: dp(5)
        height: dp(25)
        width: parent.width

        Rectangle {
          id: skuFeild
          width: parent.width - generateSKUButton.width
          height: dp(25)
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
            fontSize: sp(8)
          }
        }

        Rectangle {
          id: generateSKUButton
          height: dp(25)
          width: height * 3
          radius: height/4
          color: 'white'
          anchors.verticalCenter: parent.verticalCenter
          border.color: theme.lightTextColor
          border.width: dp(1)

          AppText {
            text: "Generate"
            color: 'black'
            font.pixelSize: sp(10)
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
        id: categoryFeildHeader
        text: "Category *"
        color: 'black'
        font.pixelSize: sp(12)
      }

      Rectangle {
        id: categoryFeild
        width: parent.width
        height: dp(25)
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
          fontSize: sp(8)
        }
      }

      AppText {
        id: descriptionFeildHeader
        text: "Description"
        color: 'black'
        font.pixelSize: sp(12)
      }

      Rectangle {
        id: descriptionFeild
        width: parent.width
        height: dp(75)
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
          fontSize: sp(8)
        }
      }

      Item {
        width: parent.width
        height: dp(5)
      }

      AppText {
        id: stockInfoHeader
        text: "Product Information"
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
        id: priceFeildHeader
        text: "Price *"
        color: 'black'
        font.pixelSize: sp(12)
      }

      Rectangle {
        id: priceFeild
        width: parent.width
        height: dp(25)
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
          fontSize: sp(8)
        }
      }

      AppText {
        id: measurementFeildHeader
        text: "Measurement Unit"
        color: 'black'
        font.pixelSize: sp(12)
      }

      Rectangle {
        id: measurementFeild
        width: parent.width
        height: dp(25)
        color: theme.lightTextColor
        radius: height/8

        AppTextInput {
          id: measurementInput
          width: parent.width - dp(10)
          height: parent.height
          anchors.left: parent.left
          anchors.leftMargin: dp(5)
          placeholderText: "Units pcs"
          placeholderColor: theme.darkTextColor
          fontSize: sp(8)
        }
      }

      AppText {
        id: currentStockFeildHeader
        text: "Current Stock *"
        color: 'black'
        font.pixelSize: sp(12)
      }

      Rectangle {
        id: currentStockFeild
        width: parent.width
        height: dp(25)
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
          fontSize: sp(8)
        }
      }

      AppText {
        id: minimumStockFeildHeader
        text: "Minimum Stock Level *"
        color: 'black'
        font.pixelSize: sp(12)
      }

      Rectangle {
        id: minimumStockFeild
        width: parent.width
        height: dp(25)
        color: theme.lightTextColor
        radius: height/8

        AppTextInput {
          id: minimumStockInput
          width: parent.width - dp(10)
          height: parent.height
          anchors.left: parent.left
          anchors.leftMargin: dp(5)
          placeholderText: "0"
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
          id: addProductButton
          height: dp(30)
          width: height * 4
          radius: height/4
          color: addButtonMA.pressed? 'lightGreen' : 'green'
          anchors.verticalCenter: parent.verticalCenter

          AppText {
            text: "Add Product"
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
              let product = {
                "name": nameInput.text,
                "sku": skuInput.text,
                "category": categoryInput.text,
                "description": descriptionInput.text,
                "price": parseFloat(priceInput.text),
                "measurementUnit": measurementInput.text,
                "currentStock": parseInt(currentStockInput.text),
                "minimumStock": parseInt(minimumStockInput.text)
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
              addNewProductPage.close()
            }
          }
        }
      }
    }
  }
}
