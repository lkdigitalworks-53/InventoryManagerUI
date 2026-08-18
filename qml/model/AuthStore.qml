pragma Singleton
import QtQuick
import QtCore

import "../helper/SettingsPath.js" as SettingsPath

QtObject {
    id: root

    property bool isAuthenticated: false
    property bool isInitialized: false

    property string uid: ""
    property string email: ""
    property string displayName: ""
    property string photoUrl: ""

    property string idToken: ""
    property string refreshToken: ""
    property int expiresAtEpochSec: 0

    property string tenantId: ""
    property string tenantName: ""
    property string role: ""

    // Owner profile details
    property string phone: ""
    property string address: ""
    property string city: ""
    property string country: ""
    property string postalCode: ""

    readonly property bool canManageInventory: role === "owner" || role === "admin"
    readonly property bool canManageStaff: role === "owner" || role === "admin"
    readonly property bool canDeleteOrders: role === "owner" || role === "admin" || role === "manager"
    readonly property bool canApproveAll: role === "owner" || role === "admin" || role === "manager"
    // Approving PENDING orders. Includes staff so they can clear their own
    // backlog when auto-approve is off — but the Orders page scopes the action
    // to each role's visible order set, so staff only ever approve their own.
    readonly property bool canApprovePending: role === "owner" || role === "admin" || role === "manager" || role === "staff"
    readonly property bool canViewSales: role === "owner" || role === "admin" || role === "manager"
    readonly property bool canViewStaff: role === "owner" || role === "admin" || role === "manager"
    readonly property bool canInviteMembers: role === "owner" || role === "admin"

    // ── Staff-role restriction flags ─────────────────────────────────────
    // Every flag is permissive (true) for non-staff, so owner/admin/manager
    // behavior is unchanged. Client-side UI gating only (server enforcement is
    // the separately-planned P0 gateway).
    readonly property bool isStaffRole:          role === "staff"
    readonly property bool canViewFinancials:    role !== "staff"  // Value/Purchased/Revenue/Profit, cost, revenue
    readonly property bool canViewSuppliers:     role !== "staff"  // supplier names anywhere
    readonly property bool canViewAllSales:      role !== "staff"  // others' sales; staff see only their own
    readonly property bool canOpenProductDetail: role !== "staff"  // the product detail/edit dialog

    // The logged-in user's own staffId, resolved from the staff roster by
    // appUid. "" for non-staff / unlinked users. Referencing StaffStore.staff
    // directly makes this re-resolve when the roster array is reassigned
    // (StaffStore has no `revision` property).
    readonly property string currentStaffId: {
        var _s = StaffStore.staff   // reactivity tie — re-resolve on roster change
        return StaffStore.findByAppUid(uid)
    }

    property Settings _settings: Settings {
        category: "AuthStore"
        // See qml/helper/SettingsPath.js -- "" under a real app build
        // (Application.organization is set, defers to normal QSettings
        // resolution, untouched); an explicit temp-file path only when it
        // isn't (qmltestrunner), so session persistence is actually
        // exercised by the test suite instead of silently no-op-ing.
        location: SettingsPath.settingsLocationOverride(
                      Application.organization,
                      StandardPaths.writableLocation(StandardPaths.TempLocation))
        property string sessionJson: ""
    }

    function clear() {
        isAuthenticated = false
        uid = ""
        email = ""
        displayName = ""
        photoUrl = ""
        idToken = ""
        refreshToken = ""
        expiresAtEpochSec = 0
        tenantId = ""
        tenantName = ""
        role = ""
        phone = ""
        address = ""
        city = ""
        country = ""
        postalCode = ""
    }

    function loadSession() {
        clear()
        if (_settings.sessionJson && _settings.sessionJson.length > 2) {
            try {
                var s = JSON.parse(_settings.sessionJson)
                uid = s.uid || ""
                email = s.email || ""
                displayName = s.displayName || ""
                photoUrl = s.photoUrl || ""
                idToken = s.idToken || ""
                refreshToken = s.refreshToken || ""
                expiresAtEpochSec = s.expiresAtEpochSec || 0
                tenantId = s.tenantId || ""
                tenantName = s.tenantName || ""
                role = s.role || ""
                phone = s.phone || ""
                address = s.address || ""
                city = s.city || ""
                country = s.country || ""
                postalCode = s.postalCode || ""
                isAuthenticated = !!idToken
            } catch (e) {
                clear()
            }
        }
        isInitialized = true
    }

    function saveSession() {
        _settings.sessionJson = JSON.stringify({
            uid: uid,
            email: email,
            displayName: displayName,
            refreshToken: refreshToken,
            expiresAtEpochSec: expiresAtEpochSec,
            tenantId: tenantId,
            tenantName: tenantName,
            role: role,
            phone: phone,
            address: address,
            city: city,
            country: country,
            postalCode: postalCode,
            photoUrl: photoUrl,
            idToken: idToken
        })
    }

    function applyAuth(auth) {
        uid = auth.uid || uid
        email = auth.email || email
        displayName = auth.displayName || displayName
        photoUrl = auth.photoUrl || photoUrl
        idToken = auth.idToken || idToken
        refreshToken = auth.refreshToken || refreshToken
        expiresAtEpochSec = auth.expiresAtEpochSec || expiresAtEpochSec
        isAuthenticated = !!idToken
        saveSession()
    }

    function applyTenantContext(context) {
        tenantId = context.tenantId || ""
        tenantName = context.tenantName || ""
        role = context.role || ""
        saveSession()
    }

    function updateProfile(profileData) {
        if (profileData.phone !== undefined) phone = profileData.phone
        if (profileData.address !== undefined) address = profileData.address
        if (profileData.city !== undefined) city = profileData.city
        if (profileData.country !== undefined) country = profileData.country
        if (profileData.postalCode !== undefined) postalCode = profileData.postalCode
        if (profileData.tenantName !== undefined) tenantName = profileData.tenantName
        saveSession()
    }
}
