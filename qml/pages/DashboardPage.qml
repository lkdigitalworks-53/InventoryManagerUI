import QtQuick
import Felgo

FlickablePage {
    id: dashboard
    title: "Dashboard"
    navigationBarHidden: true
    useSafeArea: true
    // set contentHeight of flickable to allow scrolling
    flickable.contentHeight: dashboardContent.height
    flickable.boundsBehavior: Flickable.StopAtBounds

    Column {
        id: dashboardContent

        anchors.top: parent.top
        anchors.topMargin: dp(20)
        width: parent.width
        height: implicitHeight
        spacing: dp(15)

        AppPaper {
            id: menuTab
            width: parent.width - dp(20)
            height: dp(40)
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
                                font.pixelSize: dp(10)
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                menuButtons.selectedIndex = (index === menuButtons.selectedIndex) ? -1 : index
                                if (menuButtons.selectedIndex == 1) {
                                    menuPage.sourceComponent = inventoryPageComponent
                                } else {
                                    menuPage.sourceComponent = null
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
           height: parent.height - menuTab.height - dp(10)
        }
    }

    Component {
        id: inventoryPageComponent
        InventoryPage {
            id: inventoryPage
        }
    }
}
