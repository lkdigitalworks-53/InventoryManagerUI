import QtQuick

Item {

    // actions
    signal login(string username, string password)

    signal logout()

    signal clearCache()

    // Inventory Actions
    signal addProduct(var productData)
}
