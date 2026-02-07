import Felgo
import QtQuick

AppPage {
  id: page
  title: "Add New Product"
  enabled: true

  Column {
    anchors.fill: parent
    anchors.margins: dp(16)
    spacing: dp(10)

    AppTextInput {
      id: nameField
      width: parent.width
      placeholderText: "Product Name"
      //label: "Name"
    }

    AppTextInput {
      id: skuField
      width: parent.width
      placeholderText: "e.g., SW-100"
      //label: "SKU (Unique ID)"
    }

    AppTextInput {
      id: priceField
      width: parent.width
      placeholderText: "0.00"
      inputMethodHints: Qt.ImhFormattedNumbersOnly
      //label: "Price"
    }

    AppTextInput {
      id: stockField
      width: parent.width
      placeholderText: "Initial Quantity"
      inputMethodHints: Qt.ImhDigitsOnly
      //label: "Stock Level"
    }

    AppButton {
      text: "Save Product"
      anchors.horizontalCenter: parent.horizontalCenter
      textColor: 'red'
      onClicked: {
        console.log("====== ")
        // Prepare the payload for the Logic layer
        let product = {
          "name": nameField.text,
          "sku": skuField.text,
          "price": parseFloat(priceField.text),
          "initialStock": parseInt(stockField.text),
          "category": "General" // We can add a selector for this later
        };

        // Trigger the logic action
        logic.addProduct(product);
      }
    }
  }
}
