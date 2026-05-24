import Felgo
import QtQuick
import QtQuick.Controls
import QtQuick.Controls as QQC
import QtQuick.Layouts
import QtQuick.Window

import "model"
import "logic"
import "pages"
import "helper"
import "components"

App {
    id: app

    // You get free licenseKeys from https://felgo.com/licenseKey
    licenseKey: ""

    property bool compact: width < 520
    property string authErrorMessage: ""
    property string permissionErrorMessage: ""
    property string memberErrorMessage: ""
    property string successMessage: ""

    // app initialization
    Component.onCompleted: {
        AuthService.ensureFreshToken()
    }

    // Bring the app window to the foreground when Google sign-in completes.
    // Without this, the OS browser keeps focus and the user sees no change.
    Connections {
        target: OAuthServer
        function onTokenReceived(idToken) {
            var win = oauthWindowProbe.Window.window
            if (win) {
                win.raise()
                win.requestActivate()
            }
        }
    }

    // Helper item used solely to read the attached Window.window property at runtime.
    Item { id: oauthWindowProbe; visible: false; width: 0; height: 0 }

    Timer {
        interval: 120000
        running: true
        repeat: true
        onTriggered: AuthService.ensureFreshToken()
    }

    Timer {
        id: successToastTimer
        interval: 2200
        running: false
        repeat: false
        onTriggered: successMessage = ""
    }

    // ── Layer 1: Theme ────────────────────────────────────────────────────────
    CustomeTheme {
        id: theme
    }

    // ── Layer 2: Signal Bus ───────────────────────────────────────────────────
    Logic {
        id: logic
    }

    // ── Layer 3: Centralized State ────────────────────────────────────────────
    DataModel {
        id: dataModel
        dispatcher: logic
    }

    // ── Layer 4: View Helpers ─────────────────────────────────────────────────
    ViewHelper {
        id: viewHelper
    }

    // ── Stock error popup ─────────────────────────────────────────────────────
    Connections {
        target: logic
        function onOrderCompletionFailed(orderId, errorMessage) {
            stockErrorDlg.open()
        }

        function onErrorOccurred(context, message) {
            // Reuse the permissionErrorDlg as a generic action-blocked popup —
            // matches the "you can't do that right now" semantics across contexts.
            permissionErrorMessage = message ||
                (context === "auth" ? "You do not have permission for this action"
                                    : "Action not allowed")
            permissionErrorDlg.title = context === "auth" ? "Permission Denied" : "Action Blocked"
            permissionErrorDlg.open()
        }

        function onSignInWithEmail(email, password) {
            AuthService.signInWithEmail(email, password)
        }

        function onSignUpWithEmail(email, password, displayName) {
            AuthService.signUpWithEmail(email, password, displayName)
        }

        function onSignOutRequested() {
            AuthService.signOut()
        }

        function onSignInWithGoogleToken(idToken) {
            AuthService.signInWithGoogleIdToken(idToken)
        }

        function onSendPasswordResetEmail(email) {
            AuthService.sendPasswordResetEmail(email)
        }

        function onRefreshAuthToken() {
            AuthService.refreshIdToken()
        }

        function onSetTenantContext(tenantId, tenantName, role) {
            AuthService.setTenantContext(tenantId, tenantName, role)
        }

        function onInviteMember(uid, email, displayName, role) {
            AuthService.inviteMemberToCurrentTenant(uid, email, displayName, role)
        }
    }

    Connections {
        target: AuthService
        function onLoginSucceeded() {
            authErrorMessage = ""
            logic.authLoginSucceeded()
        }

        function onSignupSucceeded() {
            authErrorMessage = ""
            logic.authSignupSucceeded()
        }

        function onOnboardingRequired() {
            authErrorMessage = ""
        }

        function onTenantContextReady(tenantId, role) {
            authErrorMessage = ""
            // Re-sync every store from Firestore so a re-login (after switching
            // accounts) doesn't display the previous user's cached collections.
            OrdersStore.syncFromFirebase()
            InventoryStore.syncFromFirebase()
            SalesStore.syncFromFirebase()
            StaffStore.syncFromFirebase()
            logic.loadData()
            inviteMemberDlg.errorMessage = ""
            memberErrorMessage = ""
            AuthService.loadTenantMembers()
        }

        function onSignedOut() {
            // Wipe in-memory store state so User B never briefly sees User A's
            // orders / inventory / sales / staff while the next sync runs.
            OrdersStore.clear()
            InventoryStore.clear()
            SalesStore.clear()
            StaffStore.clear()
            dataModel.ordersModel.clear()
            logic.authSignedOut()
        }

        function onTokenRefreshed() {
            logic.authTokenRefreshed()
        }

        function onPasswordResetSent(email) {
            forgotPasswordDlg.busy = false
            forgotPasswordDlg.close()
            successMessage = "Password reset link sent to " + email
            successToastTimer.restart()
        }

        function onAuthFailed(reason) {
            authErrorMessage = reason || "Authentication failed"
            logic.authFailed(reason)
            if (inviteMemberDlg.visible)
                inviteMemberDlg.errorMessage = authErrorMessage
            if (forgotPasswordDlg.visible) {
                forgotPasswordDlg.busy = false
                forgotPasswordDlg.errorMessage = authErrorMessage
            }
        }

        function onTenantMembersLoaded() {
            memberErrorMessage = ""
        }

        function onMemberOperationSucceeded(message) {
            memberErrorMessage = ""
            inviteMemberDlg.errorMessage = ""
            successMessage = message || "Operation completed"
            successToastTimer.restart()
        }

        function onMemberOperationFailed(reason) {
            memberErrorMessage = reason || "Operation failed"
            if (inviteMemberDlg.visible)
                inviteMemberDlg.errorMessage = reason || "Operation failed"
        }
    }

    QQC.Dialog {
        id: stockErrorDlg; modal: true; title: "Insufficient Inventory"
        anchors.centerIn: parent; width: 420; height: stockErrCol.height + 120
        standardButtons: QQC.Dialog.Ok
        Column {
            id: stockErrCol; width: parent.width; spacing: 8
            Text { text: "Cannot complete order — insufficient stock:"; font.pixelSize: 13; font.bold: true; color: "#991b1b"; wrapMode: Text.Wrap; width: parent.width }
            Text { text: dataModel.stockErrorMsg; font.pixelSize: 12; color: "#ef4444"; wrapMode: Text.Wrap; width: parent.width }
        }
    }

    QQC.Dialog {
        id: permissionErrorDlg
        modal: true
        title: "Permission Denied"
        anchors.centerIn: parent
        width: 420
        standardButtons: QQC.Dialog.Ok
        Column {
            width: parent.width
            spacing: 8
            Text {
                text: permissionErrorMessage
                font.pixelSize: 12
                color: "#b91c1c"
                wrapMode: Text.Wrap
                width: parent.width
            }
        }
    }

    Rectangle {
        visible: successMessage.length > 0
        z: 999
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 20
        radius: 8
        color: "#16a34a"
        border.color: "#14532d"
        width: Math.min(520, successText.implicitWidth + 28)
        height: 42
        Text {
            id: successText
            anchors.centerIn: parent
            color: "#ffffff"
            font.pixelSize: 12
            text: successMessage
        }
    }

    // ── Layer 5: Navigation ───────────────────────────────────────────────────
    Navigation {
        id: navigation
        visible: AuthStore.isAuthenticated && AuthStore.tenantId.length > 0

        // ── Header (overlaid above navigation content) ──
        headerView: Rectangle {
            id: header
            width: parent.width
            height: 80
            gradient: Gradient {
                GradientStop { position: 0.0; color: theme.headerGradientStart }
                GradientStop { position: 1.0; color: theme.headerGradientEnd }
            }
            Column {
                anchors.centerIn: parent; spacing: 4
                Text {
                    text: {
                        if (AuthStore.tenantName && AuthStore.tenantName.length > 0)
                            return "🏢  " + AuthStore.tenantName
                        if (AuthStore.isAuthenticated)
                            return "Workspace loading…"
                        return "Business Management"
                    }
                    color: "#ffffff"; font.bold: true; font.pixelSize: 18
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Text {
                    text: AuthStore.tenantName && AuthStore.tenantName.length > 0
                        ? "Business Management · Manage your operations"
                        : "Manage your business operations efficiently"
                    color: "#dbeafe"; font.pixelSize: 12
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
            Row {
                anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                spacing: 8
                Rectangle {
                    radius: 10
                    height: 22
                    width: Math.min(250, authTxt.width + 14)
                    color: AuthStore.isAuthenticated ? "#dcfce7" : "#fee2e2"
                    border.color: AuthStore.isAuthenticated ? "#16a34a" : "#ef4444"
                    Text {
                        id: authTxt
                        anchors.centerIn: parent
                        text: {
                            if (!AuthStore.isAuthenticated) return "Guest"
                            var who = AuthStore.email || "Signed In"
                            return AuthStore.role
                                ? who + " · " + AuthStore.role
                                : who
                        }
                        color: AuthStore.isAuthenticated ? "#14532d" : "#7f1d1d"
                        font.pixelSize: 10
                        elide: Text.ElideRight
                        width: Math.min(220, implicitWidth)
                    }
                }
                Rectangle {
                    width: 36; height: 36; radius: 18; color: "transparent"
                    Text {
                        text: FirebaseService.syncing ? "⏳" : "🔄"; font.pixelSize: 16
                        anchors.centerIn: parent
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: logic.syncAllStores()
                    }
                }
                Rectangle {
                    width: 36; height: 36; radius: 18; color: "transparent"
                    Text {
                        text: "⎋"; font.pixelSize: 16
                        anchors.centerIn: parent
                        color: "#ffffff"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: logic.signOutRequested()
                    }
                }
                Rectangle {
                    width: 36; height: 36; radius: 18; color: "transparent"
                    visible: AuthStore.canInviteMembers
                    Text {
                        text: "👥"; font.pixelSize: 16
                        anchors.centerIn: parent
                        color: "#ffffff"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            AuthService.loadTenantMembers()
                            memberMgmtDlg.open()
                        }
                    }
                }
                Rectangle {
                    width: 36; height: 36; radius: 18; color: "transparent"
                    Text {
                        text: "👤"; font.pixelSize: 16
                        anchors.centerIn: parent
                        color: "#ffffff"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: profileDlg.open()
                    }
                    ToolTip.visible: profileHover.containsMouse
                    ToolTip.text: "Profile Settings"
                    HoverHandler { id: profileHover }
                }
            }
        }

        // ── Tab: Orders ──
        NavigationItem {
            title: qsTr("Orders")
            iconType: IconType.shoppingcart
            visible: AuthStore.isAuthenticated

            NavigationStack {
                initialPage: AppPage {
                    title: qsTr("Orders")
                    navigationBarHidden: true

                    OrdersPage {
                        anchors.fill: parent
                        anchors.margins: 16
                        compact: app.compact
                        canApproveAll: AuthStore.canApproveAll
                        canDeleteOrders: AuthStore.canDeleteOrders
                        onAddOrderClicked: newOrderDlg.open()
                        onOrderDetailsClicked: function(orderId) { orderDetail.openFor(orderId) }
                        onDeleteOrderClicked: function(orderId) {
                            confirmDlg.ask({
                                title: "Delete order?",
                                message: "Order " + orderId + " will be permanently removed. This cannot be undone.",
                                confirmLabel: "Delete order",
                                onConfirm: function() { logic.deleteOrder(orderId) }
                            })
                        }
                        onExportRequested: app._exportOrders()
                        onImportRequested: {
                            importDlg.mode = "orders"
                            importDlg.pickAndStart()
                        }
                    }
                }
            }
        }

        // ── Tab: Inventory ──
        NavigationItem {
            title: qsTr("Inventory")
            iconType: IconType.archive
            visible: AuthStore.isAuthenticated

            NavigationStack {
                initialPage: AppPage {
                    title: qsTr("Inventory")
                    navigationBarHidden: true

                    InventoryPage {
                        anchors.fill: parent
                        anchors.margins: 16
                        compact: app.compact
                        canManageInventory: AuthStore.canManageInventory
                        onAddProductClicked: addProductDlg.open()
                        onRestockClicked: function(pid) { restockDlg.openFor(pid) }
                        onViewProductClicked: function(pid) { editProductDlg.openFor(pid, false) }
                        onEditProductClicked: function(pid) { editProductDlg.openFor(pid, true) }
                        onDeleteProductClicked: function(pid) {
                            var p = InventoryStore.getById(pid)
                            var nm = p ? p.name : pid
                            confirmDlg.ask({
                                title: "Delete product?",
                                message: "“" + nm + "” will be removed from inventory. This cannot be undone.",
                                confirmLabel: "Delete product",
                                onConfirm: function() { logic.deleteProduct(pid) }
                            })
                        }
                        onExportRequested: app._exportProducts()
                        onImportRequested: {
                            importDlg.mode = "products"
                            importDlg.pickAndStart()
                        }
                    }
                }
            }
        }

        // ── Tab: Sales ──
        NavigationItem {
            title: qsTr("Sales")
            iconType: IconType.linechart
            visible: AuthStore.canViewSales

            NavigationStack {
                initialPage: AppPage {
                    title: qsTr("Sales")
                    navigationBarHidden: true

                    SalesPage {
                        anchors.fill: parent
                        anchors.margins: 16
                        compact: app.compact
                        onExportRequested: app._exportSalesReport()
                    }
                }
            }
        }

        // ── Tab: Staff ──
        NavigationItem {
            title: qsTr("Staff")
            iconType: IconType.users
            visible: AuthStore.canViewStaff

            NavigationStack {
                initialPage: AppPage {
                    title: qsTr("Staff")
                    navigationBarHidden: true

                    StaffPage {
                        anchors.fill: parent
                        anchors.margins: 16
                        compact: app.compact
                        canManageStaff: AuthStore.canManageStaff
                        canInviteMembers: AuthStore.canInviteMembers
                        onAddStaffClicked: addStaffDlg.open()
                        onExportRequested: app._exportStaff()
                        onViewStaffClicked: function(sid) { staffDetailDlg.openFor(sid, false) }
                        onEditStaffClicked: function(sid) { staffDetailDlg.openFor(sid, true) }
                        onDeleteStaffClicked: function(sid) {
                            var s = StaffStore.getById(sid)
                            var nm = s ? s.name : sid
                            confirmDlg.ask({
                                title: "Delete staff member?",
                                message: "“" + nm + "” will be removed. If they had login credentials, their workspace access is also revoked.",
                                confirmLabel: "Delete staff",
                                onConfirm: function() { logic.deleteStaff(sid) }
                            })
                        }
                        onInviteMemberClicked: {
                            inviteMemberDlg.errorMessage = ""
                            inviteMemberDlg.open()
                        }
                        onManageMembersClicked: {
                            memberErrorMessage = ""
                            AuthService.loadTenantMembers()
                            memberMgmtDlg.open()
                        }
                    }
                }
            }
        }
    }

    LoginPage {
        id: loginPage
        anchors.fill: parent
        visible: !AuthStore.isAuthenticated || (AuthStore.isAuthenticated && !AuthService.profileResolved)
        z: 100
        busy: AuthService.busy
        errorMessage: authErrorMessage
        onSignInRequested: function(email, password) {
            authErrorMessage = ""
            logic.signInWithEmail(email, password)
        }
        onSignUpRequested: function(name, email, password) {
            authErrorMessage = ""
            logic.signUpWithEmail(email, password, name)
        }
        onGoogleSignInRequested: function(googleIdToken) {
            authErrorMessage = ""
            logic.signInWithGoogleToken(googleIdToken)
        }
        onForgotPasswordRequested: function(email) {
            authErrorMessage = ""
            forgotPasswordDlg.prefillEmail = email || ""
            forgotPasswordDlg.errorMessage = ""
            forgotPasswordDlg.busy = false
            forgotPasswordDlg.open()
        }
    }

    ForgotPasswordDialog {
        id: forgotPasswordDlg
        onResetRequested: function(email) {
            forgotPasswordDlg.busy = true
            forgotPasswordDlg.errorMessage = ""
            logic.sendPasswordResetEmail(email)
        }
    }

    TenantSetupPage {
        id: tenantSetupPage
        anchors.fill: parent
        visible: AuthStore.isAuthenticated && AuthService.profileResolved && AuthService.onboardingNeeded
        z: 101
        busy: AuthService.busy
        errorMessage: authErrorMessage
        userEmail: AuthStore.email
        onCreateTenantRequested: function(tenantName) {
            authErrorMessage = ""
            AuthService.createTenantForCurrentUser(tenantName)
        }
        onSignOutRequested: logic.signOutRequested()
    }

    InviteMemberDialog {
        id: inviteMemberDlg
        onMemberInviteRequested: function(uid, email, displayName, role) {
            logic.inviteMember(uid, email, displayName, role)
        }
    }

    MemberManagementDialog {
        id: memberMgmtDlg
        members: AuthService.tenantMembers
        busy: AuthService.membersBusy
        errorMessage: memberErrorMessage
        onRefreshRequested: AuthService.loadTenantMembers()
        onRoleUpdateRequested: function(uid, role) {
            AuthService.updateMemberRole(uid, role)
        }
        onStatusUpdateRequested: function(uid, status) {
            AuthService.setMemberStatus(uid, status)
        }
        onRemoveMemberRequested: function(uid) {
            confirmDlg.ask({
                title: "Remove workspace member?",
                message: "This member will lose access to the workspace immediately.",
                confirmLabel: "Remove member",
                onConfirm: function() { AuthService.removeMember(uid) }
            })
        }
    }

    // ── Dialogs ───────────────────────────────────────────────────────────────
    ProfileSettingsDialog {
        id: profileDlg
        onProfileSaved: {
            successMessage = "Profile updated successfully"
            successToastTimer.restart()
        }
    }

    NewOrderDialog {
        id: newOrderDlg
        onOrderCreated: function(order) {
            logic.addOrder(order.customer, order.items, order.total,
                order.status, order.date, order.email, order.phone, order.products)
        }
    }
    OrderDetailDialog {
        id: orderDetail
        onOrderUpdated: function(oid) { logic.updateOrder(oid, {}) }
    }
    ConfirmDialog {
        id: confirmDlg
    }

    StaffDetailDialog {
        id: staffDetailDlg
        onStaffUpdateRequested: function(sid, fields) {
            logic.updateStaff(sid, fields)
        }
    }

    AddProductDialog {
        id: addProductDlg
        onManageCategoriesRequested: manageCategoriesDlg.open()
    }
    ManageCategoriesDialog { id: manageCategoriesDlg }
    EditProductDialog {
        id: editProductDlg
        onProductUpdateRequested: function(pid, fields) {
            logic.updateProduct(pid, fields)
        }
    }
    ImportPreviewDialog {
        id: importDlg
        onImportCompleted: function(message) {
            successMessage = message
            successToastTimer.restart()
            if (mode === "products") OrdersStore.syncFromFirebase()
        }
        onPathPromptRequested: importPathPrompt.open()
    }

    // Path-prompt is hoisted out of ImportPreviewDialog because a QQC.Dialog
    // nested inside another Dialog won't render until the outer one is open.
    QQC.Dialog {
        id: importPathPrompt
        modal: true
        anchors.centerIn: parent
        title: importDlg.mode === "products" ? "Open products .xlsx" : "Open orders .xlsx"
        width: Math.min(parent ? parent.width - 40 : 480, 480)
        standardButtons: QQC.Dialog.Ok | QQC.Dialog.Cancel

        contentItem: ColumnLayout {
            spacing: 8
            QQC.Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "Paste the full path of the .xlsx file (or a https URL). On mobile, share the sheet into this app from Files / Drive / Sheets."
                color: "#6b7280"
                font.pixelSize: 12
            }
            QQC.TextField {
                id: importPathField
                Layout.fillWidth: true
                placeholderText: "/sdcard/Download/products.xlsx  or  C:/Users/me/Downloads/products.xlsx"
            }
        }

        onAccepted: {
            if (importPathField.text.length > 0) {
                importDlg.importFromUserPath(importPathField.text.trim())
                importPathField.text = ""
            }
        }
        onRejected: importPathField.text = ""
    }

    function _exportProducts() {
        var url = XlsxService.writeProducts(InventoryStore.products, "")
        if (!url || url.length === 0) {
            successMessage = "Export failed"
        } else {
            successMessage = "✓ Products exported. Saved to Downloads."
            // On mobile, hand off via the share sheet so the user can route to Drive/Mail/etc.
            if (typeof NativeUtils !== "undefined" && NativeUtils.share)
                NativeUtils.share("", url)
        }
        successToastTimer.restart()
    }

    function _exportOrders() {
        var url = XlsxService.writeOrders(OrdersStore.orders, "")
        if (!url || url.length === 0) {
            successMessage = "Export failed"
        } else {
            successMessage = "✓ Orders exported. Saved to Downloads."
            if (typeof NativeUtils !== "undefined" && NativeUtils.share)
                NativeUtils.share("", url)
        }
        successToastTimer.restart()
    }

    function _exportStaff() {
        var url = XlsxService.writeStaff(StaffStore.staff, "")
        if (!url || url.length === 0) {
            successMessage = "Export failed"
        } else {
            successMessage = "✓ Staff exported. Saved to Downloads."
            if (typeof NativeUtils !== "undefined" && NativeUtils.share)
                NativeUtils.share("", url)
        }
        successToastTimer.restart()
    }

    // Sales "report" — for now we export the underlying orders, which carry
    // all the data driving the Sales page KPIs. A dedicated formatted report
    // is a future iteration.
    function _exportSalesReport() {
        var url = XlsxService.writeOrders(OrdersStore.orders, "sales_report_" + Qt.formatDateTime(new Date(), "yyyyMMdd") + ".xlsx")
        if (!url || url.length === 0) {
            successMessage = "Export failed"
        } else {
            successMessage = "✓ Sales report exported. Saved to Downloads."
            if (typeof NativeUtils !== "undefined" && NativeUtils.share)
                NativeUtils.share("", url)
        }
        successToastTimer.restart()
    }
    AddStaffDialog {
        id: addStaffDlg
        onStaffCreated: function(payload) {
            logic.addStaff(payload.name, payload.email, payload.phone, payload.role,
                           payload.department, payload.joinDate, payload.status, payload.salary)

            if (payload.createLogin) {
                // The staff record was just appended; grab its id so we can
                // stamp the auth uid back onto it for cascade-aware deletes.
                var staffArr = StaffStore.staff
                var staffId = staffArr.length > 0 ? staffArr[staffArr.length - 1].staffId : ""
                AuthService.provisionStaffCredentials(payload.name, payload.email, payload.loginPassword,
                                                      payload.phone, payload.department, payload.appRole,
                                                      staffId)
            }
        }
    }
    RestockDialog { id: restockDlg }
}
