import Felgo
import QtQuick
import "model"
import "logic"
import "pages"

import "helper"

/*/////////////////////////////////////
  NOTE:
  Additional integration steps are needed to use Felgo Plugins, for example to add and link required libraries for Android and iOS.
  Please follow the integration steps described in the plugin documentation of your chosen plugins:
  - Firebase: https://felgo.com/doc/plugin-firebase/

  To open the documentation of a plugin item in Qt Creator, place your cursor on the item in your QML code and press F1.
  This allows to view the properties, methods and signals of Felgo Plugins directly in Qt Creator.

/////////////////////////////////////*/

App {
    // You get free licenseKeys from https://felgo.com/licenseKey
    // With a licenseKey you can:
    //  * Publish your games & apps for the app stores
    //  * Remove the Felgo Splash Screen or set a custom one (available with the Pro Licenses)
    //  * Add plugins to monetize, analyze & improve your apps (available with the Pro Licenses)
    //licenseKey: "<generate one from https://felgo.com/licenseKey>"

    // app initialization
    Component.onCompleted: {
        // if device has network connection, clear cache at startup
        // you'll probably implement a more intelligent cache cleanup for your app
        // e.g. to only clear the items that aren't required regularly
        if(isOnline) {
            logic.clearCache()
        }
    }

    FirebaseConfig {
        id: firebaseConfig
        projectId: "inventorymanager-48392"
        // Get these values from your Firebase Console (Project Settings > General > Web App)
        apiKey: "AIzaSyDvVhwCOsmAegpM_SyaEx91PadJOsEVRNI"
        applicationId: "1:219471233608:web:d7452b8037080ba4e24e7d"
    }

    // Use the FirebaseAuth Item to register and log in/log out users
    FirebaseAuth {
        id: firebaseAuth

        config: firebaseConfig
    }

    // business logic
    Logic {
        id: logic
    }

    // model
    DataModel {
        id: dataModel
        dispatcher: logic // data model handles actions sent by logic

        // global error handling

    }

    // helper functions for view
    ViewHelper {
        id: viewHelper
    }

    // view
    Navigation {
        id: navigation

        // only enable if user is logged in
        // login page below overlays navigation then
        enabled: dataModel.userLoggedIn

        // first tab
        NavigationItem {
            title: qsTr("Dashboard")

            NavigationStack {
                splitView: tablet // use side-by-side view on tablets
                // initialPage: DashboardPage { }
            }
        }

        // second tab
        NavigationItem {
            title: qsTr("Profile") // use qsTr for strings you want to translate
            iconType: IconType.circle

            NavigationStack {
                initialPage: ProfilePage {
                    // handle logout
                    onLogoutClicked: {
                        logic.logout()

                        // jump to main page after logout
                        navigation.currentIndex = 0
                        navigation.currentNavigationItem.navigationStack.popAllExceptFirst()
                    }
                }
            }
        }
    }

    // login page lies on top of previous items and overlays if user is not logged in
    LoginPage {
        visible: opacity > 0
        enabled: visible
        opacity: 0//dataModel.userLoggedIn ? 0 : 1 // hide if user is logged in

        Behavior on opacity { NumberAnimation { duration: 250 } } // page fade in/out
    }


    // This item contains example code for the chosen Felgo Plugins
    // It is hidden by default and will overlay the QML items above if shown
    PluginMainItem {
        id: pluginMainItem
        visible: false // set this to true to show the plugin example
        property alias firebasePage: firebasePage

        FirebasePage {
            id: firebasePage
            visible: false
            onPopped:  { firebasePage.parent = pluginMainItem; visible = false }
        }
    }
}
