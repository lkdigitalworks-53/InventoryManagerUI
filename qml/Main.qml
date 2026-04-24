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
    id: app
    // You get free licenseKeys from https://felgo.com/licenseKey
    // With a licenseKey you can:
    //  * Publish your games & apps for the app stores
    //  * Remove the Felgo Splash Screen or set a custom one (available with the Pro Licenses)
    //  * Add plugins to monetize, analyze & improve your apps (available with the Pro Licenses)
    licenseKey: "3F3506BFF764D512407759CE7C931A6C77E48DA3278D3AF6B2DB7D966F71336AC3B65A1A2071AD04DBDDEADE75498FA8DAB000F286994F014C551A8DCD0A73F94A393BBAF93E96885BD905C1672DE5A3433F21555EF65B2D71C7AD5EB3D61D215C7EFA75FB1F88CCA38B49B429DA14BEFF579766A21876288320A2035BAFE8C7183916C77118B8B6F88591F14D1490B29D274678CD96A687681A2D0FF1C35C0918C5C0D8BC5BD7DBE1E7A64371F1D17E9AEF7715D77BB0A859F515C0DE9A085092043CEE4028E2B9E387B913296F5F53468FA473D5A4E31BFA890038B73E37CD673D0AB5F96DD360724E07ED359F03FC526DDFA79BD1E13FEAA0C753632875C110263AA58AC49AD42E9E70D5048797EBCB08F42AB4F165D70E0C2D52F255BA55E4F55CC7DE591730E18694CAEC0D8E8FD7C5CA2EF07A14023AACAACC004F0A3E"

    // app initialization
    Component.onCompleted: {
        // if device has network connection, clear cache at startup
        // you'll probably implement a more intelligent cache cleanup for your app
        // e.g. to only clear the items that aren't required regularly
        if(isOnline) {
            logic.clearCache()
            console.log("======== logging in")
            firebaseAuth.loginUserAnonymously()
        }

        logic.loadData()
    }
    // theming
    CustomeTheme {
        id: theme
    }

    FirebaseConfig {
        id: firebaseConfig
        projectId: "inventorymanager-48392"
        // Get these values from your Firebase Console (Project Settings > General > Web App)
        apiKey: "AIzaSyAeA5Mb6ZmtKLOb3Oxw_n-dh62_qY0r4mA"
        applicationId: "1:219471233608:android:9691b11222183348e24e7d"
        databaseUrl: "https://inventorymanager-48392-default-rtdb.asia-southeast1.firebasedatabase.app"
    }

    // Use the FirebaseAuth Item to register and log in/log out users
    FirebaseAuth {
        id: firebaseAuth
        config: firebaseConfig
        onFirebaseReady: console.log("firbase auth is ready")
        onLoggedIn: console.log("firbase logged in")
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
        // enabled: dataModel.userLoggedIn

        // first tab
        NavigationItem {
            title: qsTr("Dashboard")

            NavigationStack {
                // splitView: tablet // use side-by-side view on tablets
                initialPage: DashboardPage { }
            }
        }

        // second tab
        NavigationItem {
            title: qsTr("Profile") // use qsTr for strings you want to translate
            // iconType: IconType.circle

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
}
