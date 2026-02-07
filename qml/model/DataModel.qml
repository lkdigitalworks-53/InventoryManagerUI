import QtQuick
import Felgo

Item {

    // property to configure target dispatcher / logic
    property alias dispatcher: logicConnection.target

    // whether api is busy (ongoing network requests)
    readonly property bool isBusy: api.busy

    // whether a user is logged in
    readonly property bool userLoggedIn: _.userLoggedIn

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
}
