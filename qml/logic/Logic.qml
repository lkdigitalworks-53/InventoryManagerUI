import QtQuick

Item {

    // actions
    signal login(string username, string password)

    signal logout()

    signal clearCache()

    signal loadData()

    signal dataLoaded(var inventoryDataJson, var ordersDataJson)

    // Inventory Actions
    signal addProduct(var productData)

    signal productAdded(var productData)

    signal addOrder(var orderData)

    signal orderAdded(var orderData)
}
