import QtQuick
import Felgo

Item {

    // property to configure target dispatcher / logic
    property alias dispatcher: logicConnection.target

    // whether api is busy (ongoing network requests)
    readonly property bool isBusy: api.busy

    // whether a user is logged in
    readonly property bool userLoggedIn: _.userLoggedIn

    // Inventory related data
    readonly property alias inventoryDataJson: _inventory.inventoryDataJson
    property int totalProducts: _inventory.inventoryDataJson !== undefined ? _inventory.inventoryDataJson.length : 0
    property int totalItems: _inventory.inventoryDataJson !== undefined ? _inventory.getTotalItems() : 0
    property int totalValue: _inventory.inventoryDataJson !== undefined ? _inventory.getTotalValue() : 0
    property int totalItemsInLowStockState: _inventory.inventoryDataJson !== undefined ? _inventory.getTotalItemsInLowStockState() : 0

    // Orders related data
    readonly property alias ordersDataJson: _orders.ordersDataJson


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
            // readin inventory data.
            var fileName = FileUtils.storageLocation(FileUtils.AppDataLocation, "inventory/inventoryDataJson.json")
            var inventoryDataStr = FileUtils.readFile(fileName)
            if (inventoryDataStr !== "") {
                _inventory.inventoryDataJson = JSON.parse(inventoryDataStr)
                console.log("============= reading data: ")
                console.log("inventoryDataStr: ", inventoryDataStr)
                console.log("_inventory.inventoryDataJson: ", JSON.stringify(_inventory.inventoryDataJson))
                console.log("============= ")
            }

            // readin orders data.
            fileName = FileUtils.storageLocation(FileUtils.AppDataLocation, "orders/ordersDataJson.json")
            var ordersDataStr = FileUtils.readFile(fileName)
            if (ordersDataStr !== "") {
                _orders.ordersDataJson = JSON.parse(ordersDataStr)
                console.log("============= reading orders data: ")
                console.log("ordersDataStr: ", ordersDataStr)
                console.log("_inventory.inventoryDataJson: ", JSON.stringify(_orders.ordersDataJson))
                console.log("============= ")
            }

            logic.dataLoaded(_inventory.inventoryDataJson, _orders.ordersDataJson)
        }

        // action 4 - add product data
        function onAddProduct(productData) {
            if (_inventory.inventoryDataJson === undefined) {
                _inventory.inventoryDataJson = []
            }
            productData["product_id"] = _inventory.inventoryDataJson.length + 1
            _inventory.inventoryDataJson.push(productData)

            totalProducts = _inventory.inventoryDataJson !== undefined ? _inventory.inventoryDataJson.length : 0
            totalItems = _inventory.inventoryDataJson !== undefined ? _inventory.getTotalItems() : 0
            totalValue = _inventory.inventoryDataJson !== undefined ? _inventory.getTotalValue() : 0
            totalItemsInLowStockState = _inventory.inventoryDataJson !== undefined ? _inventory.getTotalItemsInLowStockState() : 0

            console.log("============= writing inventory data: ")
            console.log("JSON.stringify(_inventory.inventoryDataJson): ", JSON.stringify(_inventory.inventoryDataJson))
            console.log("_inventory.inventoryDataJson size: ", _inventory.inventoryDataJson.length)

            // Saving all json response in file, which can be added as a resource file.
            var fileName = FileUtils.storageLocation(FileUtils.AppDataLocation, "inventory/inventoryDataJson.json")
            var success = FileUtils.writeFile(fileName, JSON.stringify(_inventory.inventoryDataJson))
            console.log("============= writing inventory success: ", success)


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

        function onAddOrder(orderData) {
            if (_orders.ordersDataJson === undefined) {
                _orders.ordersDataJson = []
            }
            orderData["order_id"] = _orders.ordersDataJson.length + 1
            _orders.ordersDataJson.push(orderData)

            console.log("============= writing orders data: ")
            console.log("JSON.stringify(_orders.ordersDataJson): ", JSON.stringify(_orders.ordersDataJson))
            console.log("_orders.ordersDataJson size: ", _orders.ordersDataJson.length)

            // Saving all json response in file, which can be added as a resource file.
            var fileName = FileUtils.storageLocation(FileUtils.AppDataLocation, "orders/ordersDataJson.json")
            var success = FileUtils.writeFile(fileName, JSON.stringify(_orders.ordersDataJson))
            console.log("============= writing orders success: ", success)
            logic.orderAdded(orderData)

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
    }

    Item {
        id: _inventory

        property var inventoryDataJson: undefined

        function getTotalItems() {
            var totalItems = 0
            for(var i = 0; i < inventoryDataJson.length; ++i) {
                totalItems += inventoryDataJson[i]["currentStock"]
            }
            return totalItems
        }

        function getTotalValue() {
            var totalValue = 0
            for(var i = 0; i < inventoryDataJson.length; ++i) {
                totalValue += inventoryDataJson[i]["currentStock"] * inventoryDataJson[i]["price"]
            }
            return totalValue
        }

        function getTotalItemsInLowStockState() {
            var totalItemsInLowStock = 0
            for(var i = 0; i < inventoryDataJson.length; ++i) {
                totalItemsInLowStock += inventoryDataJson[i]["currentStock"] <= inventoryDataJson[i]["minimumStock"]
            }
            return totalItemsInLowStock
        }
    }

    Item {
        id: _orders

        property var ordersDataJson: undefined
    }
}
