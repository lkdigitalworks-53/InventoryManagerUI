import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// Logic.qml  –  Signal bus (action dispatcher)
//
// Pages emit signals here; DataModel handles them.
// No business logic lives here – this is a pure signal relay.
// ─────────────────────────────────────────────────────────────────────────────
Item {

    // ── App lifecycle ─────────────────────────────────────────────────────────
    signal loadData()
    signal refreshData()
    signal syncAllStores()

    // ── Authentication ────────────────────────────────────────────────────────
    signal signInWithEmail(string email, string password)
    signal signUpWithEmail(string email, string password, string displayName)
    signal signInWithGoogleToken(string idToken)
    signal sendPasswordResetEmail(string email)
    signal signOutRequested()
    signal refreshAuthToken()
    signal setTenantContext(string tenantId, string tenantName, string role)
    signal inviteMember(string uid, string email, string displayName, string role)

    // ── Authentication feedback ───────────────────────────────────────────────
    signal authLoginSucceeded()
    signal authSignupSucceeded()
    signal authSignedOut()
    signal authTokenRefreshed()
    signal authFailed(string reason)
    signal authPasswordResetSent(string email)
    signal memberInvited(string uid)
    signal memberInviteFailed(string reason)

    // ── Orders ────────────────────────────────────────────────────────────────
    signal addOrder(var customer, int items, var total, string status, var date,
                    string email, string phone, var products,
                    string orderChannel, string staffId)
    signal updateOrder(string orderId, var fields)
    signal adjustOrder(string orderId, var newLines, string reason, string condition, string note)
    signal completeOrder(string orderId)
    signal approveAllPending()
    signal deleteOrder(string orderId)

    // ── Orders feedback (DataModel → UI) ─────────────────────────────────────
    signal orderAdded(string orderId)
    signal orderUpdated(string orderId)
    signal orderDeleted(string orderId)
    signal orderCompletionFailed(string orderId, string errorMessage)

    // ── Inventory ─────────────────────────────────────────────────────────────
    signal addProduct(string name, string sku, string category, string description,
                      var price, string unit, int stock, int minStock, var sellingPrice,
                      bool taxable, var taxPercent)
    signal updateProduct(string productId, var fields, string reason)
    signal restockProduct(string productId, int amount)
    signal deleteProduct(string productId)

    // ── Inventory feedback ────────────────────────────────────────────────────
    signal productAdded(string productId)
    signal productUpdated(string productId)
    signal productRestocked(string productId)
    signal productDeleted(string productId)

    // ── Sales ─────────────────────────────────────────────────────────────────
    signal recordSale(var amount, int itemCount)

    // ── Staff ─────────────────────────────────────────────────────────────────
    signal addStaff(string name, string email, string phone, string role,
                    string department, var joinDate, string status, var salary)
    signal updateStaff(string staffId, var fields)
    signal deleteStaff(string staffId)

    // ── Staff feedback ────────────────────────────────────────────────────────
    signal staffAdded(string staffId)
    signal staffUpdated(string staffId)
    signal staffDeleted(string staffId)

    // ── Error feedback ────────────────────────────────────────────────────────
    signal errorOccurred(string context, string message)
}
