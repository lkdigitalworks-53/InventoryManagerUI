import QtQuick
import Felgo

Item {

    // property to configure target dispatcher / logic
    property alias dispatcher: logicConnection.target

    // whether api is busy (ongoing network requests)
    readonly property bool isBusy: api.busy

    // whether a user is logged in
    readonly property bool userLoggedIn: _.userLoggedIn

    readonly property alias inventoryDataJson: _.inventoryDataJson

    // listen to actions from dispatcher
    Connections {
        id: logicConnection

        // action 1 - login
        function onLogin(username, password) {
            _.userLoggedIn = true
        }

        // action 62- logout
        function onLogout() {
            _.userLoggedIn = false
        }

        // action 3 - clearCache
        function onClearCache() {
            cache.clearAll()
        }

        function onLoadData() {
            // Saving all json response in file, which can be added as a resource file.
            var fileName = FileUtils.storageLocation(FileUtils.AppDataLocation, "inventory/inventoryDataJson.json")
            var inventoryDataStr = FileUtils.readFile(fileName)
            _.inventoryDataJson = JSON.parse(inventoryDataStr)
            console.log("============= reading data: ")
            console.log("inventoryDataStr: ", inventoryDataStr)
            console.log("_.inventoryDataJson: ", JSON.stringify(_.inventoryDataJson))
            console.log("============= ")

            logic.dataLoaded(_.inventoryDataJson)
        }

        // action 4 - add product data
        function onAddProduct(productData) {
                          if (_.inventoryDataJson === undefined) {
                              _.inventoryDataJson = []
                          }
                          productData["product_id"] = _.inventoryDataJson.length + 1
                          _.inventoryDataJson.push(productData)

                          console.log("============= writing data: ")
                          console.log("JSON.stringify(_.inventoryDataJson): ", JSON.stringify(_.inventoryDataJson))
                          console.log("_.inventoryDataJson size: ", _.inventoryDataJson.length)

                          // Saving all json response in file, which can be added as a resource file.
                          var fileName = FileUtils.storageLocation(FileUtils.AppDataLocation, "inventory/inventoryDataJson.json")
                          var success = FileUtils.writeFile(fileName, JSON.stringify(_.inventoryDataJson))
                          console.log("============= writing success: ", success)


                          let addProductLocalUrl = "http://127.0.0.1:5001/inventorymanager-48392/us-central1/addProduct";

                          HttpRequest.post(addProductLocalUrl)
                          .set("Content-Type", "application/json")
                          .send({ "data": productData }) // Wrapped in "data" for Firebase onCall protocol
                          .then(function(res) {
                              NativeUtils.displayMessageBox("Success", "Product added successfully", 1);
                          })
                          .catch(function(err) {
                              console.error("API Error:", err.message);
                              NativeUtils.displayMessageBox("Error", "Failed to add product: " + err.message, 1);
                          });

                          logic.productAdded(productData)
                      }
    }

    // you can place getter functions here that do not modify the data
    // pages trigger write operations through logic signals only

    // rest api for data access
    RestAPI {
        id: api
        maxRequestTimeout: 3000 // use max request timeout of 3 sec
    }

    // storage for caching
    Storage {
        id: cache
    }

    // private
    Item {
        id: _

        // auth
        property bool userLoggedIn: false
        property var inventoryDataJson: undefined

    }
}
