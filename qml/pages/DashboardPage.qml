import QtQuick
import Felgo

AppPage {
    id: dashboard
    title: "Inventory Manager"
    // navigationBarHidden: true
    // useSafeArea: true

    Column {
        id: dashboardContent

        anchors.top: parent.top
        anchors.topMargin: dp(20)
        width: parent.width
        height: dp(50)
        spacing: dp(5)

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
                }
                ListElement {
                    name: "Inventory"
                }
                ListElement {
                    name: "Sales"
                }
                ListElement {
                    name: "Staff"
                }
            }

            Row {
                id: menuButtons
                width: menuTab.width - dp(5)
                height: menuTab.height - dp(5)
                anchors.centerIn: menuTab
                property int selectedIndex: -1

                Repeater {
                    model: menuTabModel
                    delegate: Rectangle {
                        id: delegateItem
                        z:1
                        width: (menuButtons.width/4)
                        height: menuButtons.height
                        radius: height/4
                        border.color: (index === menuButtons.selectedIndex) ? '#CC5500' : 'white'
                        border.width: dp(1)
                        color: (index === menuButtons.selectedIndex) ? '#FEE8D6' : 'white'

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
                                color: (index === menuButtons.selectedIndex) ? '#CC5500' : 'black'
                                font.pixelSize: dp(10)
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                menuButtons.selectedIndex = (index === menuButtons.selectedIndex) ? -1 : index
                            }
                        }
                    }
                }
            }
        }
    }
}
