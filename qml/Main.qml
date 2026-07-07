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
    licenseKey: "7DE3BC3AD3A76DE396F0C706C3CB0BF4683B3E0DFDA541CA89163CB320232DE3F86B5062338D5EC6739022887374C5F67D7D2608B2E60C244858D28D69BB55949A55CE835EEA6F1B9CCA4CFC5030EBA41123AF6A00DB2A89E6F13061B4C31BC756EC3DB9CB23FA3605E16FF8FE4A5814B8FC94195D2F19D84568E267062B7B0E26B6298502A3F2AB250ED082D7228E2C486F1C5B04D9116774011ADE0F175FB5337E55BA899802D721D9B37943F48D1E53CA15FFDA0BB8F3B52AC658860DD9F53ECC1DEAA17E636ECEB4886B002C92BBAD11C9F1AE2E76C545879DA62CA6849A66C8A9B8E179E188D9B46A4C26719827EEB8FD4ED222FDBC81A6F21268A155BB43FF7CE4DEE3A1AB8A408B8AD9A9EA56F523E6287B16B80C17BC0E354FEEA087E09E85A624960560FF4F7221F0203C3FC1C329865ED4D2CDB50BD99C53C1FB4B"

    property bool compact: width < dp(Constants.compactBreakpoint)
    property string authErrorMessage: ""
    property string permissionErrorMessage: ""
    property string memberErrorMessage: ""
    property string successMessage: ""

    // Consume the Android Back event so it does NOT propagate to the OS (which
    // would background/exit the app). "AutoAccept" = mark the event accepted;
    // true keeps the app open and lets our _handleBack router do the navigation
    // (we call Qt.quit() ourselves only on the second tap of double-tap-exit).
    backButtonAutoAcceptGlobally: true

    // Cached payload from SalesPage.exportRequested. The export sheet's
    // format-selected handler reads this when the user picks a format.
    property var _pendingAnalysisExport: null

    // app initialization
    Component.onCompleted: {
        AuthService.isOnline = isOnline
        AuthService.ensureFreshToken()
    }

    onIsOnlineChanged: {
        AuthService.isOnline = isOnline
        successMessage = isOnline ? qsTr("Back online!") : qsTr("Internet is not available. Do not perform any action.")
    }

    // ── Android hardware/keyboard Back router ───────────────────────────────
    // Single source of truth for Back behavior; mirrors the on-screen back
    // button. Closes the top-most transient layer first. If a dialog id is
    // added/renamed, update the `dialogs` list below.
    property bool _exitArmed: false
    Timer {
        id: _exitArmTimer
        interval: 2000
        onTriggered: app._exitArmed = false
    }

    onBackButtonPressedGlobally: app._handleBack()

    // Google OAuth deep-link redirect (Android). Hand the custom-scheme URL to
    // GoogleAuthService, which exchanges the code for an id_token; LoginPage's
    // GoogleAuthService.onIdTokenReady then drives the existing Firebase step.
    onAppLinkUrlReceived: function(appLinkUrl) {
        if (GoogleAuthService.isRedirect(appLinkUrl))
            GoogleAuthService.handleRedirect(appLinkUrl)
    }

    function _handleBack() {
        // 1. Open modal sheet / dialog → close the first open one.
        var dialogs = [photoSourceSheet, addProductDlg, editProductDlg,
                       newOrderDlg, orderDetail, restockDlg, addStaffDlg, inviteMemberDlg,
                       memberMgmtDlg, staffDetailDlg, profileDlg, manageCategoriesDlg,
                       manageChannelsDlg, notificationsSheet, filterSheet, exportSheet,
                       forgotPasswordDlg, confirmDlg, stockErrorDlg, permissionErrorDlg]
        for (var i = 0; i < dialogs.length; ++i) {
            if (dialogs[i] && dialogs[i].opened) { dialogs[i].close(); return }
        }
        // 2. Full-screen overlay visible → close back to Dashboard.
        if (profilePage.visible)         { profilePage.close();         return }
        if (staffPageOverlay.visible)    { staffPageOverlay.close();    return }
        if (activityPageOverlay.visible) { activityPageOverlay.close(); return }
        // 3. Not on Home tab → go to Home.
        if (navigation.visible && navigation.currentIndex !== 0) {
            navigation.currentIndex = 0
            return
        }
        // 4. Home root → double-tap to exit.
        if (_exitArmed) { Qt.quit(); return }
        _exitArmed = true
        Toast.show(qsTr("Press back again to exit"))
        _exitArmTimer.restart()
    }

    // Bind the SafeArea singleton to Felgo's live device insets. The insets live
    // on NativeUtils (NOT on App), so bind there. Updates on rotation / cutout
    // change via safeAreaInsetsChanged. 0 on desktop.
    Binding { target: SafeArea; property: "top";    value: NativeUtils.safeAreaInsets.top }
    Binding { target: SafeArea; property: "bottom"; value: NativeUtils.safeAreaInsets.bottom }
    Binding { target: SafeArea; property: "left";   value: NativeUtils.safeAreaInsets.left }
    Binding { target: SafeArea; property: "right";  value: NativeUtils.safeAreaInsets.right }

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

    // Delays the FIFO migration just enough for OrdersStore /
    // InventoryStore / TransactionStore / PartyStore to finish their
    // initial GETs. The migration itself short-circuits when the
    // `_migrations/fifo_v1` flag is set, so this is safe to fire on
    // every tenantContextReady.
    Timer {
        id: migrationKickoffTimer
        interval: 1500
        running: false
        repeat: false
        onTriggered: MigrationService.runIfNeeded()
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
            stockErrorDlg.show({
                title: qsTr("Insufficient Inventory"),
                message: dataModel.stockErrorMsg || qsTr("Cannot complete order due to insufficient stock."),
                variant: "error"
            })
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
            // TransactionStore powers the Analysis charts and the per-product
            // History — without this re-sync the report cards go blank after
            // a relaunch since the singleton's `Component.onCompleted` ran
            // before the tenant id was known.
            TransactionStore.syncFromFirebase()
            // SupplierStore + StockBatchStore are the FIFO cost ledger that
            // backs every per-supplier analytic. Same reasoning: their initial
            // fetch fired before tenant context, so re-sync now.
            SupplierStore.syncFromFirebase()
            StockBatchStore.syncFromFirebase()
            // ActivityLog is now Firestore-backed (tenant-scoped). Re-sync so the
            // full recent-activity history (product/staff edits, not just orders)
            // survives sign-out/sign-in instead of being wiped to in-memory empty.
            ActivityLog.syncFromFirebase()
            // Channel + category config is now Firestore-backed too, so a new
            // device / reinstall picks up the workspace's channels, categories,
            // and chosen defaults instead of falling back to the seed list.
            OrderChannelStore.syncFromFirebase()
            CategoryStore.syncFromFirebase()
            // Kick the one-shot FIFO backfill once the upstream stores have
            // had a beat to land their data. The check inside is idempotent.
            migrationKickoffTimer.restart()
            // Flush any compliance-gateway writes that were queued offline /
            // before this tenant context was known (no-op in "direct" mode).
            Gateway.drainNow()
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
            TransactionStore.clear()
            SupplierStore.clear()
            StockBatchStore.clear()
            // PartyStore is QSettings-backed (device-local, not tenant-
            // scoped). Without this, the next account inherits the previous
            // user's supplier names.
            PartyStore.clear()
            // Per-process flag must be reset so runIfNeeded() can re-evaluate
            // for the next tenant context.
            MigrationService.reset()
            // Drop any queued gateway writes so a pending tenant's mutations
            // never replay under the next account.
            Gateway.clear()
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

    AlertDialog {
        id: stockErrorDlg
    }

    QQC.Dialog {
        id: permissionErrorDlg
        modal: true
        title: "Permission Denied"
        anchors.centerIn: parent
        width: dp(420)
        standardButtons: QQC.Dialog.Ok
        Column {
            width: parent.width
            spacing: dp(8)
            Text {
                text: permissionErrorMessage
                font.pixelSize: sp(12)
                color: "#b91c1c"
                wrapMode: Text.Wrap
                width: parent.width
            }
        }
    }

    // Toast layer. Use Toast.show("...") from anywhere to drive it.
    ToastHost {
        id: toastHost
        anchors.fill: parent
        z: 999
    }
    // Bridge legacy `successMessage` writes through Toast for one source of truth.
    onSuccessMessageChanged: if (successMessage.length > 0) Toast.show(successMessage)

    // ── Layer 5: Navigation ───────────────────────────────────────────────────
    // Force bottom-tab navigation (no swipe drawer). Per prototype the bottom
    // bar is always visible on every screen size — Felgo's default would swap
    // to a drawer in portrait, which is wrong for our mobile-first design.
    Navigation {
        id: navigation
        visible: AuthStore.isAuthenticated && AuthStore.tenantId.length > 0
        enabled: isOnline

        // No built-in tabs — our FloatingTabbar is the only nav UI. Felgo's
        // TabControl tabs were stacking under the floating pill.
        navigationMode: navigationModeNone

        // Hide Felgo's framework header — pages render their own GlassHeader.
        headerView: Item { width: 1; height: 0 }
        // Hide Felgo's framework footer too (belt-and-suspenders).
        footerView: Item { width: 1; height: 0 }

        // ── Tab: Dashboard ──
        NavigationItem {
            title: qsTr("Home")
            iconType: IconType.home
            visible: AuthStore.isAuthenticated

            NavigationStack {
                initialPage: AppPage {
                    title: qsTr("Home")
                    navigationBarHidden: true

                    DashboardPage {
                        anchors.fill: parent
                        compact: app.compact
                        canViewFinancials: AuthStore.canViewFinancials
                        currentStaffId:    AuthStore.currentStaffId
                        onNewOrderRequested: newOrderDlg.open()
                        onAddProductRequested: addProductDlg.open()
                        onInviteStaffRequested: {
                            if (AuthStore.canInviteMembers) inviteMemberDlg.open()
                            else addStaffDlg.open()
                        }
                        onNavigateToOrders:    navigation.currentIndex = 1
                        onNavigateToInventory: navigation.currentIndex = 2
                        onNavigateToSales:     navigation.currentIndex = 3
                        onNavigateToStaff:     staffPageOverlay.open()
                        onNavigateToProfile:   profilePage.open()
                        onShowNotificationsRequested: notificationsSheet.open()
                        onActivityItemClicked: function(kind, entityId) {
                            app._routeActivity(kind, entityId)
                        }
                        onSeeAllActivityRequested: activityPageOverlay.open()
                    }
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
                        id: ordersPage
                        anchors.fill: parent
                        compact: app.compact
                        canApproveAll: AuthStore.canApproveAll
                        canApprovePending: AuthStore.canApprovePending
                        canDeleteOrders: AuthStore.canDeleteOrders
                        canViewAllSales: AuthStore.canViewAllSales
                        currentStaffId:  AuthStore.currentStaffId
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
                        onExportRequested: { exportSheet.kind = "orders"; exportSheet.open() }
                        onImportRequested: {
                            importDlg.mode = "orders"
                            importDlg.pickAndStart()
                        }
                        onFiltersRequested: {
                            // ordersPage's id is only visible here (page scope);
                            // the root-level filterSheet can't name it, so hand
                            // it the page object to write back through.
                            filterSheet.targetPage = ordersPage
                            filterSheet.range = ordersPage.dateRange
                            filterSheet.customFrom = ordersPage.customFrom
                            filterSheet.customTo = ordersPage.customTo
                            filterSheet.open()
                        }
                    }
                }
            }
        }

        // ── Tab: Inventory ──
        NavigationItem {
            title: qsTr("Stock")
            iconType: IconType.archive
            visible: AuthStore.isAuthenticated

            NavigationStack {
                initialPage: AppPage {
                    title: qsTr("Inventory")
                    navigationBarHidden: true

                    InventoryPage {
                        anchors.fill: parent
                        compact: app.compact
                        canManageInventory: AuthStore.canManageInventory
                        canOpenProductDetail: AuthStore.canOpenProductDetail
                        canViewFinancials: AuthStore.canViewFinancials
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
                        onExportRequested: { exportSheet.kind = "products"; exportSheet.open() }
                        onImportRequested: {
                            importDlg.mode = "products"
                            importDlg.pickAndStart()
                        }
                    }
                }
            }
        }

        // ── Tab: Analysis ──
        NavigationItem {
            title: qsTr("Analysis")
            iconType: IconType.linechart
            visible: AuthStore.isAuthenticated

            NavigationStack {
                initialPage: AppPage {
                    title: qsTr("Analysis")
                    navigationBarHidden: true

                    SalesPage {
                        anchors.fill: parent
                        compact: app.compact
                        canViewFinancials: AuthStore.canViewFinancials
                        canViewSuppliers:  AuthStore.canViewSuppliers
                        canViewAllSales:   AuthStore.canViewAllSales
                        currentStaffId:    AuthStore.currentStaffId
                        currentStaffName:  AuthStore.displayName
                        // SalesPage hands us the active-view payload here so
                        // Main.qml doesn't need a reachable id reference into
                        // the NavigationStack subtree.
                        onExportRequested: function(payload) {
                            app._pendingAnalysisExport = payload
                            exportSheet.kind = "sales"
                            exportSheet.open()
                        }
                    }
                }
            }
        }

        // Staff tab removed — the prototype's bottom bar has 4 slots
        // (Home / Orders / Stock / Sales). Staff lives as a full-screen
        // overlay reached from the Dashboard "Invite staff" tile and the
        // Profile page's "Team members" row.
    }

    // ── Floating glass tabbar ───────────────────────────────────────────────
    // Sits on top of Navigation. Felgo's default tabbar visuals are hidden via
    // footerView; this overlay drives navigation.currentIndex and matches the
    // prototype's `.tabbar` styling exactly.
    FloatingTabbar {
        id: floatingTabbar
        visible: navigation.visible
                 && !profilePage.visible
                 && !staffPageOverlay.visible
                 && !activityPageOverlay.visible
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: dp(12)
        anchors.rightMargin: dp(12)
        anchors.bottomMargin: dp(14) + SafeArea.bottom
        z: 50
        currentIndex: navigation.currentIndex
        tabs: [
            { iconName: "home", label: "Home" },
            { iconName: "orders", label: "Orders" },
            { iconName: "products", label: "Stock" },
            { iconName: "analysis", label: qsTr("Analysis") }
        ]
        onTabChanged: function(idx) {
            if (navigation.currentIndex !== idx)
                navigation.currentIndex = idx
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
                order.status, order.date, order.email, order.phone, order.products,
                order.orderChannel || "", order.staffId || "")
        }
        onManageChannelsRequested: manageChannelsDlg.open()
    }
    OrderDetailDialog {
        id: orderDetail
        onAdjustRequested: function(oid, newLines, originalLines) {
            confirmReturnSheet.openFor(oid, newLines, originalLines)
        }
    }
    ConfirmReturnSheet {
        id: confirmReturnSheet
        onConfirmed: function(oid, newLines, reason, condition, note) {
            logic.adjustOrder(oid, newLines, reason, condition, note)
        }
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
        onPhotoPickRequested: function(hasExisting) { photoSourceSheet.openFor(addProductDlg, hasExisting) }
    }
    ManageCategoriesDialog { id: manageCategoriesDlg }
    ManageOrderChannelsDialog { id: manageChannelsDlg }
    EditProductDialog {
        id: editProductDlg
        onProductUpdateRequested: function(pid, fields) {
            logic.updateProduct(pid, fields)
        }
        onPhotoPickRequested: function(hasExisting) { photoSourceSheet.openFor(editProductDlg, hasExisting) }
    }

    // Shared photo-source sheet, hoisted to the App root so it isn't trapped in
    // a BottomSheet's scrollable body (where it opens off-screen). `openFor`
    // remembers the requesting dialog and routes the result back to it via the
    // dialog's applyPhotoSource()/clearPhotoSource() contract.
    PhotoSourceSheet {
        id: photoSourceSheet
        property var _requester: null
        function openFor(dialog, hasExisting) {
            _requester = dialog
            hasExistingPhoto = hasExisting
            open()
        }
        onPhotoSourceSelected: function(url) {
            if (_requester) _requester.applyPhotoSource(url)
        }
        onRemoveRequested: {
            if (_requester) _requester.clearPhotoSource()
        }
    }
    ImportPreviewDialog {
        id: importDlg
        dataModelRef: dataModel
        onImportCompleted: function(message) {
            successMessage = message
            successToastTimer.restart()
            if (mode === "products") OrdersStore.syncFromFirebase()
        }
        onFilePickRequested: {
            NativeUtils.filePickerFinished.connect(app._onImportFilePicked)
            // Filter format differs by platform: desktop maps to QFileDialog (Qt
            // name-filter like "Name (*.ext)"); mobile uses a MIME type. A bare
            // "*/*" reads as a literal pattern on desktop → no selectable files.
            var isMobile = (Qt.platform.os === "android" || Qt.platform.os === "ios")
            var filter = isMobile
                ? "*/*"
                : "Spreadsheets (*.xlsx *.xls *.csv)"
            NativeUtils.displayFilePicker(qsTr("Choose a spreadsheet"), "", filter)
        }
    }

    // Receives the native file-picker result for import. One-shot: disconnects
    // itself so repeated imports don't stack the connection.
    function _onImportFilePicked(accepted, files) {
        NativeUtils.filePickerFinished.disconnect(app._onImportFilePicked)
        if (!accepted || !files || files.length === 0) return
        var picked = String(files[0])
        // toReadablePath() exists to copy an Android content:// URI into a
        // readable cache file. On desktop the picker returns a real filesystem
        // path / file:// URL that QFile can already open — and routing a bare
        // Windows path ("C:\…") through toReadablePath's QUrl round-trip mangles
        // it (drive letter parsed as a URL scheme) → empty → the misleading
        // "Could not read the selected file" toast. So only use it for
        // content:// (Android); otherwise hand the picked path straight to the
        // dialog, exactly like the (working) desktop photo picker does.
        var needsCopy = picked.toLowerCase().indexOf("content://") === 0
        var local = needsCopy ? NativeFile.toReadablePath(files[0]) : picked
        if (!local || local.length === 0) {
            successMessage = qsTr("Could not read the selected file")
            successToastTimer.restart()
            return
        }
        importDlg.importFromUserPath(local)
    }


    // Routes a click on a recent-activity / notification entry to the right
    // page + detail dialog. `kind` matches ActivityLog kinds plus "order"
    // for the order-row case and "low_stock" for low-stock notifications.
    function _routeActivity(kind, entityId) {
        if (!kind) return
        if (kind === "order") {
            // Staff may only open their own orders (fail-closed); others'
            // order detail stays blocked, mirroring the OrdersPage own-scope.
            if (!AuthStore.canViewAllSales) {
                var o = OrdersStore.getById(entityId)
                if (!o || (o.staffId || "") !== AuthStore.currentStaffId) return
            }
            navigation.currentIndex = 1   // Orders tab
            if (entityId) Qt.callLater(function() { orderDetail.openFor(entityId) })
        } else if (kind === "product_added"
                || kind === "product_updated"
                || kind === "product_restocked"
                || kind === "low_stock") {
            // Staff can't open product detail anywhere — block the route entirely.
            if (!AuthStore.canOpenProductDetail) return
            navigation.currentIndex = 2   // Stock tab
            if (entityId) Qt.callLater(function() { editProductDlg.openFor(entityId, false) })
        } else if (kind === "staff_added" || kind === "staff_updated") {
            staffPageOverlay.open()
            if (entityId) Qt.callLater(function() { staffDetailDlg.openFor(entityId, false) })
        }
    }

    // Deliver a freshly-written export file, platform-aware. Mobile: the share
    // sheet (route to Drive/Mail/Files). Desktop: open the file directly, since
    // NativeUtils.share is mobile-only (a no-op on desktop would leave the file
    // stranded in app-private storage). `label` names the export in the toast.
    function _deliverExport(url, label) {
        if (!url || url.length === 0) {
            successMessage = qsTr("Export failed")
            successToastTimer.restart()
            return
        }
        var os = Qt.platform.os
        var isMobile = (os === "android" || os === "ios")
        if (isMobile && typeof NativeUtils !== "undefined" && NativeUtils.share) {
            successMessage = qsTr("%1 exported — choose where to save.").arg(label)
            NativeUtils.share("", url)
        } else {
            successMessage = qsTr("%1 exported — opening…").arg(label)
            Qt.openUrlExternally(url)
        }
        successToastTimer.restart()
    }

    function _exportProducts() {
        var src = InventoryStore.products || []
        var out = []
        for (var i = 0; i < src.length; ++i) {
            var p = src[i]
            var clone = JSON.parse(JSON.stringify(p))
            // supplierId may live on the product or on its latest batch/txn.
            var sid = p.supplierId || TransactionStore.lastSupplierFor(p.productId)
            clone.supplier = sid ? (SupplierStore.nameOf(sid) || "") : ""
            out.push(clone)
        }
        _deliverExport(XlsxService.writeProducts(out, ""), qsTr("Products"))
    }

    function _exportOrders() {
        var src = OrdersStore.orders || []
        var out = []
        for (var i = 0; i < src.length; ++i) {
            var o = JSON.parse(JSON.stringify(src[i]))
            var st = o.staffId ? StaffStore.getById(o.staffId) : null
            o.staffName = st ? st.name : ""
            var lines = o.products || []
            for (var j = 0; j < lines.length; ++j) {
                var inv = lines[j].productId ? InventoryStore.getById(lines[j].productId) : null
                lines[j].sku = inv && inv.sku ? inv.sku : ""
            }
            out.push(o)
        }
        _deliverExport(XlsxService.writeOrders(out, ""), qsTr("Orders"))
    }

    function _exportStaff() {
        _deliverExport(XlsxService.writeStaff(StaffStore.staff, ""), qsTr("Staff"))
    }

    // Analysis report — emits the same view the user is currently looking
    // at (Revenue / Sold / Purchased / Current). SalesPage hands us the
    // payload via `onExportRequested` because its `id` lives inside a
    // NavigationStack subtree and isn't reachable by name from this scope.
    function _exportSalesReport() {
        var payload = _pendingAnalysisExport
        // New multi-sheet payload: { suggestedName, sheets:[{name,title,sections}] }.
        // One workbook, one sheet per report view (bug 11). Fall back to the
        // legacy single-sheet payload shape for safety.
        if (payload && payload.sheets && payload.sheets.length > 0) {
            var wbUrl = XlsxService.writeAnalysisWorkbook(payload.sheets,
                                                          payload.suggestedName || "")
            _deliverExport(wbUrl, qsTr("Analysis report"))
            _pendingAnalysisExport = null
            return
        }
        if (!payload || !payload.sections || payload.sections.length === 0) {
            successMessage = qsTr("Export failed")
            successToastTimer.restart()
            return
        }
        var url = XlsxService.writeAnalysis(payload.title || qsTr("Analysis"),
                                            payload.sections,
                                            payload.suggestedName || "")
        _deliverExport(url, payload.title || qsTr("Analysis"))
        // Clear once consumed so a stale payload can't leak into a future export.
        _pendingAnalysisExport = null
    }
    AddStaffDialog {
        id: addStaffDlg
        onStaffCreated: function(payload) {
            logic.addStaff(payload.name, payload.email, payload.phone, payload.role,
                           payload.department, payload.joinDate, payload.status, payload.salary)

            if (payload.createLogin) {
                // Provision login against the id StaffStore just generated —
                // robust under reordering / async sync, unlike "last element".
                var staffId = StaffStore.lastAddedId
                AuthService.provisionStaffCredentials(payload.name, payload.email, payload.loginPassword,
                                                      payload.phone, payload.department, payload.appRole,
                                                      staffId)
            }
        }
    }

    // Staff FAB choice sheet (hoisted to App root). Routes to the two existing
    // staff dialogs; both are already hosted here.
    StaffActionSheet {
        id: staffActionSheet
        onAddStaffSelected: addStaffDlg.open()
        onInviteSelected: {
            inviteMemberDlg.errorMessage = ""
            inviteMemberDlg.open()
        }
    }
    RestockDialog { id: restockDlg }

    // ── Profile overlay ─────────────────────────────────────────────────────
    // Slides over the tab content as a full-screen page. Reusable across tabs.
    ProfilePage {
        id: profilePage
        anchors.fill: parent
        z: 200
        visible: false
        function open() { visible = true }
        function close() { visible = false }

        onBackRequested: close()
        // Don't close the profile page first — the dialog is modal and its
        // overlay covers the page. Closing first briefly reveals the dashboard.
        onEditProfileRequested: profileDlg.open()
        onManageMembersRequested: {
            close()
            staffPageOverlay.open()
        }
        onSignOutRequested: {
            // Confirm before signing out — destructive action that drops the
            // workspace context and clears local store caches.
            confirmDlg.ask({
                title: "Sign out?",
                message: "You'll need to sign in again to access this workspace.",
                confirmLabel: "Sign out",
                onConfirm: function() {
                    profilePage.close()
                    logic.signOutRequested()
                }
            })
        }
        onLeaveWorkspaceRequested: {
            // Removes only the tenant membership, then signs out. The user
            // stays registered globally — they may own or belong to other
            // workspaces. Owner self-removal is blocked in AuthService.
            confirmDlg.ask({
                title: qsTr("Leave workspace?"),
                message: qsTr("You'll be removed from this workspace and signed out. Your sign-in still works elsewhere."),
                confirmLabel: qsTr("Leave workspace"),
                onConfirm: function() {
                    profilePage.close()
                    AuthService.leaveCurrentTenant()
                }
            })
        }
    }

    // ── Staff overlay ───────────────────────────────────────────────────────
    // Reached from Dashboard "Invite staff" tile and Profile "Team members"
    // row. Same overlay pattern as profilePage.
    Item {
        id: staffPageOverlay
        anchors.fill: parent
        z: 200
        visible: false
        function open() { visible = true }
        function close() { visible = false }

        StaffPage {
            anchors.fill: parent
            compact: app.compact
            showBackButton: true
            canManageStaff: AuthStore.canManageStaff
            canInviteMembers: AuthStore.canInviteMembers
            onBackRequested: staffPageOverlay.close()
            onAddStaffClicked: addStaffDlg.open()
            onStaffActionsRequested: staffActionSheet.open()
            onExportRequested: { exportSheet.kind = "staff"; exportSheet.open() }
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

        // Tap-outside-to-close — only on the bottommost area covered by tabbar.
        // Easier: a small floating "Done" button anchored top-left through
        // GlassHeader's leading slot. For now keep the close via tab switch
        // (when user taps Home/Orders/Stock/Sales the overlay closes).
        Connections {
            target: navigation
            function onCurrentIndexChanged() { staffPageOverlay.close() }
        }
    }

    // ── Activity overlay (full list reached from Dashboard "See all") ───────
    Item {
        id: activityPageOverlay
        anchors.fill: parent
        z: 200
        visible: false
        function open() { visible = true }
        function close() { visible = false }

        ActivityPage {
            anchors.fill: parent
            canViewFinancials: AuthStore.canViewFinancials
            currentStaffId:    AuthStore.currentStaffId
            onBackRequested: activityPageOverlay.close()
            onActivityItemClicked: function(kind, entityId) {
                activityPageOverlay.close()
                app._routeActivity(kind, entityId)
            }
        }

        Connections {
            target: navigation
            function onCurrentIndexChanged() { activityPageOverlay.close() }
        }
    }

    // ── Utility sheets (notifications / filters / export) ───────────────────
    NotificationsSheet {
        id: notificationsSheet
        onNotificationItemClicked: function(kind, entityId) {
            app._routeActivity(kind, entityId)
        }
    }

    FilterSheet {
        id: filterSheet
        // Drive the orders list directly. The status dimension lives on the
        // page chips; this sheet only carries the date range.
        //
        // This sheet lives at Main's root, but the OrdersPage instance lives
        // inside NavigationStack.initialPage (a Component) — its `ordersPage`
        // id is NOT visible out here, so naming it threw ReferenceError and
        // silently dropped every applied filter. The page-scoped
        // onFiltersRequested hands us the page object via targetPage instead.
        property var targetPage: null
        onFiltersApplied: function(status, range) {
            if (!targetPage) return
            targetPage.dateRange = range
            targetPage.customFrom = filterSheet.customFrom
            targetPage.customTo = filterSheet.customTo
        }
        onResetRequested: {
            if (!targetPage) return
            targetPage.dateRange = "all"
            targetPage.customFrom = ""
            targetPage.customTo = ""
        }
    }

    ExportSheet {
        id: exportSheet
        // `kind` is set by the caller before open(): "orders" | "products" | "sales" | "staff".
        property string kind: "orders"
        onFormatSelected: function(format) {
            switch (kind) {
                case "products": app._exportProducts(); break
                case "orders":   app._exportOrders();   break
                case "sales":    app._exportSalesReport(); break
                case "staff":    app._exportStaff();    break
            }
        }
    }
}
