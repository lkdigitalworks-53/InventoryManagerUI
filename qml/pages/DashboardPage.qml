import QtQuick
import Felgo

FlickablePage {
    id: dashboard
    title: "Dashboard"
    navigationBarHidden: true
    useSafeArea: true
    height: safeArea.height
    // set contentHeight of flickable to allow scrolling
    flickable.contentHeight: menuTab.height + (menuPage.status === Loader.Ready ? menuPage.item.height : 0) + dp(100)
    flickable.boundsBehavior: Flickable.StopAtBounds

    AppPaper {
        id: menuTab
        width: parent.width - dp(20)
        height: dp(40)
        anchors.top: parent.top
        anchors.topMargin: dp(20)
        radius: height/4
        anchors.horizontalCenter: parent.horizontalCenter

        ListModel {
            id: menuTabModel

            ListElement {
                name: "Orders"
                color: "#FEE8D6"
                borderColor: "#CC5500"
            }
            ListElement {
                name: "Inventory"
                color: "#A8E4A0"
                borderColor: "#3F704D"
            }
            ListElement {
                name: "Sales"
                color: "#ADDFFF"
                borderColor: "#4169E1"
            }
            ListElement {
                name: "Staff"
                color: "#E0B0FF"
                borderColor: "#8F00FF"
            }
        }

        Row {
            id: menuButtons
            width: menuTab.width - dp(5)
            height: menuTab.height - dp(5)
            anchors.centerIn: menuTab
            property int selectedIndex: 0

            Repeater {
                model: menuTabModel
                delegate: Rectangle {
                    id: delegateItem
                    z:1
                    width: (menuButtons.width/4)
                    height: menuButtons.height
                    radius: height/4
                    border.color: (index === menuButtons.selectedIndex) ? model.borderColor : 'white'
                    border.width: dp(1)
                    color: (index === menuButtons.selectedIndex) ? model.color : 'white'

                    Row {
                        width: parent.width/2
                        height: parent.height/2
                        anchors.centerIn: parent
                        spacing: dp(3)
                        AppImage {
                            // source: "" + ".png"
                            fillMode: Image.PreserveAspectFit
                        }
                        AppText {
                            text: name
                            color: (index === menuButtons.selectedIndex) ? model.borderColor : 'black'
                            font.pixelSize: sp(10)
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            menuButtons.selectedIndex = (index === menuButtons.selectedIndex) ? -1 : index
                            switch (menuButtons.selectedIndex) {
                            case 0:
                                menuPage.sourceComponent = ordersPageComponent
                                return
                            case 1:
                                menuPage.sourceComponent = inventoryPageComponent
                                return
                            default:
                                menuPage.sourceComponent = null
                                return
                            }
                        }
                    }
                }
            }
        }
    }
    Loader {
       id: menuPage
       width: parent.width
       height: childrenRect.height//parent.height - menuTab.height - dp(10)
       anchors.top: menuTab.bottom
       anchors.topMargin: dp(15)
       sourceComponent: ordersPageComponent
    }

    Component {
        id: inventoryPageComponent
        InventoryPage {
            id: inventoryPage
        }
    }
    Component {
        id: ordersPageComponent
        OrdersPage {
            id: ordersPage
        }
    }
}
