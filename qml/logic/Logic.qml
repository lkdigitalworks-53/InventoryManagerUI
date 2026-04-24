import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// Logic.qml  –  Signal bus (action dispatcher)
//
// Pages emit signals here; DataModel handles them.
// No business logic lives here – this is a pure signal relay.
// ─────────────────────────────────────────────────────────────────────────────
Item {

    // ── Auth ──────────────────────────────────────────────────────────────────
    signal login(string username, string password)
    signal logout()

    // ── App lifecycle ─────────────────────────────────────────────────────────
    signal clearCache()
    signal loadData()
    signal refreshData()          // force pull from Firebase
    signal syncOfflineQueue()     // retry pending offline writes

    // ── Data-ready events (DataModel → UI) ────────────────────────────────────
    signal dataLoaded(var inventoryDataJson, var ordersDataJson)

    // ── Inventory CRUD ────────────────────────────────────────────────────────
    signal addProduct(var productData)
    signal updateProduct(var productData)   // productData must contain product_id
    signal deleteProduct(var productId)

    // ── Inventory feedback (DataModel → UI) ───────────────────────────────────
    signal productAdded(var productData)
    signal productUpdated(var productData)
    signal productDeleted(var productId)

    // ── Orders CRUD ───────────────────────────────────────────────────────────
    signal addOrder(var orderData)
    signal updateOrder(var orderData)       // orderData must contain order_id
    signal deleteOrder(var orderId)

    // ── Orders feedback (DataModel → UI) ─────────────────────────────────────
    signal orderAdded(var orderData)
    signal orderUpdated(var orderData)
    signal orderDeleted(var orderId)

    // ── Sync feedback (DataModel → UI) ────────────────────────────────────────
    signal syncQueueChanged(int pendingCount)   // UI can show a badge
    signal errorOccurred(string context, string message)
}
