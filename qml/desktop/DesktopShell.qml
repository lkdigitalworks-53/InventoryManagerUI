import QtQuick
import "../helper"
import "DesktopNav.js" as DesktopNav

Item {
    id: root

    readonly property alias sidebarWidth: sidebar.width
    readonly property alias topBarHeight: topBar.height

    property var navigationTarget
    property var staffOverlay
    property var activityOverlay
    property var profileOverlay
    property string workspaceName: ""
    property string userName: ""
    property string userRole: ""
    property string currentSection: "dashboard"

    TopBar {
        id: topBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        workspaceName: root.workspaceName
        userName: root.userName
        userRole: root.userRole
    }

    Sidebar {
        id: sidebar
        width: dp(180)
        anchors.top: topBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        currentSection: root.currentSection
        onSectionSelected: function(section) { root._goTo(section) }
    }

    function _goTo(section) {
        currentSection = section
        var stackIndex = DesktopNav.navigationIndexForSection(section)
        if (stackIndex >= 0) {
            if (navigationTarget)
                navigationTarget.currentIndex = stackIndex
            return
        }
        var overlayId = DesktopNav.overlayIdForSection(section)
        if (overlayId === "staffPageOverlay" && staffOverlay) staffOverlay.open()
        else if (overlayId === "activityPageOverlay" && activityOverlay) activityOverlay.open()
        else if (overlayId === "profilePage" && profileOverlay) profileOverlay.open()
    }
}
