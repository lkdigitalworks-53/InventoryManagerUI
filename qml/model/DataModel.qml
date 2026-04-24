import QtQuick
import Felgo

// ─────────────────────────────────────────────────────────────────────────────
// DataModel.qml  –  Single source of truth
//
// Architecture (offline-first, three-layer cache):
//
//   Layer 1 – In-memory  : reactive QML properties, instant UI binding
//   Layer 2 – Local file : survives app restarts; loaded before Firebase reply
//   Layer 3 – Firebase   : cloud truth; real-time listener keeps layers in sync
//
// Offline write strategy:
//   • Firebase SDK disk-persistence (persistenceEnabled: true) automatically
//     buffers writes and replays them when connectivity returns.
//   • An explicit offline queue (Layer-2 JSON file) acts as a belt-and-
//     suspenders fallback: if the process is killed before the SDK can sync,
//     the queue is replayed on next launch.
//
// Firebase data shape:
//   /inventory/{product_id}  → product object
//   /orders/{order_id}       → order object
//
// IDs are compact Base-36 timestamps + random suffix → collision-safe,
// sortable, and valid Firebase path segments.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: dataModelRoot

    // ── Public interface ──────────────────────────────────────────────────────

    property alias dispatcher: _logicBus.target

    // Network / busy state
    readonly property bool isBusy:       api.busy || _sync.isProcessing
    readonly property bool userLoggedIn: _.userLoggedIn

    // Inventory
    readonly property alias inventoryDataJson:        _inv.records
    readonly property int   totalProducts:            _inv.records.length
    readonly property int   totalItems:               _inv.totalItems
    readonly property int   totalValue:               _inv.totalValue
    readonly property int   totalItemsInLowStockState: _inv.lowStockCount

    // Orders
    readonly property alias ordersDataJson:      _ord.records
    readonly property int   totalOrders:         _ord.records.length
    readonly property int   totalPendingOrders:  _ord.pendingCount
    readonly property int   totalCompletedOrders: _ord.completedCount

    // Offline sync
    readonly property int  pendingSyncCount: _sync.queue.length
    readonly property bool hasPendingSync:   _sync.queue.length > 0

    // ── Action dispatcher ─────────────────────────────────────────────────────

    Connections {
        id: _logicBus

        // ── Auth ──────────────────────────────────────────────────────────────
        function onLogin(username, password) { _.userLoggedIn = true  }
        function onLogout()                  { _.userLoggedIn = false }

        // ── App lifecycle ─────────────────────────────────────────────────────
        function onClearCache() {
            cache.clearAll()
        }

        function onLoadData() {
            if (firebaseDb.isFirebaseReady && app.isOnline) {
                // Start Firebase real-time listeners → updates arrive async.
                //  With persistenceEnabled the SDK also returns cached data first.
                _startFirebaseListeners()
            } else {
                // Load local file cache immediately → UI is populated in < 1 ms
                _localStore.loadAll()
            }
        }

        function onRefreshData() {
            _startFirebaseListeners()
        }

        function onSyncOfflineQueue() {
            _sync.processNext()
        }

        // ── Inventory CRUD ────────────────────────────────────────────────────
        function onAddProduct(productData) {
            var id = _makeId()
            productData.product_id = id
            productData.created_at  = new Date().toISOString()
            productData.updated_at  = new Date().toISOString()

            _inv.upsert(productData)
            _localStore.saveInventory()
            _firebaseWrite("inventory/" + id, productData)

            logic.productAdded(productData)
        }

        function onUpdateProduct(productData) {
            if (!productData || !productData.product_id) {
                console.error("[DataModel] updateProduct: missing product_id")
                return
            }
            productData.updated_at = new Date().toISOString()
            _inv.upsert(productData)
            _localStore.saveInventory()
            _firebaseWrite("inventory/" + productData.product_id, productData)
            logic.productUpdated(productData)
        }

        function onDeleteProduct(productId) {
            _inv.remove("product_id", productId)
            _localStore.saveInventory()
            _firebaseRemove("inventory/" + productId)
            logic.productDeleted(productId)
        }

        // ── Orders CRUD ───────────────────────────────────────────────────────
        function onAddOrder(orderData) {
            var id = _makeId()
            orderData.order_id   = id
            orderData.created_at = new Date().toISOString()
            orderData.updated_at = new Date().toISOString()

            _ord.upsert(orderData)
            _localStore.saveOrders()
            _firebaseWrite("orders/" + id, orderData)

            logic.orderAdded(orderData)
        }

        function onUpdateOrder(orderData) {
            if (!orderData || !orderData.order_id) {
                console.error("[DataModel] updateOrder: missing order_id")
                return
            }
            orderData.updated_at = new Date().toISOString()
            _ord.upsert(orderData)
            _localStore.saveOrders()
            _firebaseWrite("orders/" + orderData.order_id, orderData)
            logic.orderUpdated(orderData)
        }

        function onDeleteOrder(orderId) {
            _ord.remove("order_id", orderId)
            _localStore.saveOrders()
            _firebaseRemove("orders/" + orderId)
            logic.orderDeleted(orderId)
        }
    }

    // ── Firebase Realtime Database ────────────────────────────────────────────
    //
    // • persistenceEnabled: true  – Firebase SDK writes to local SQLite so data
    //   survives process kill and sets issued offline are replayed automatically.
    // • listenForValueChange("inventory") / ("orders")  – the SDK fires
    //   onListenEvent whenever anything under that path changes (including on
    //   first attach with cached data).

    FirebaseDatabase {
        id: firebaseDb
        config: firebaseConfig      // id defined in Main.qml, resolved via QML dynamic scope
        persistenceEnabled: true
        property bool isFirebaseReady: false

        onFirebaseReady: {
            console.log("firbase ready for use")
            isFirebaseReady = true
            if (app.isOnline) {
                _startFirebaseListeners()
            }
        }
        onRealtimeValueChanged: function(success, key, value) {
            console.log("firbase onRealtimeValueChanged success: " + success + " key: " + key + " value: " + value)
        }

        // ── One-shot read (fallback) ─────────────────────────────────────────
        onReadCompleted: function(success, value, key) {
            if (!success) {
                console.warn("[Firebase] readCompleted failed  key:", key)
                logic.errorOccurred("Firebase read", "Read failed for: " + key)
                return
            }
            console.log("[Firebase] readCompleted  key:", key)
            _applyFirebaseData(key, value)
        }

        // ── Write acknowledgement ────────────────────────────────────────────
        onWriteCompleted: function(path) {
            console.log("[Firebase] writeCompleted  path:", path)
            _sync.onWriteAck(path)
        }
    }

    // ── Network watcher ───────────────────────────────────────────────────────
    //
    // When connectivity is restored:
    //   1. Process the manual offline queue (belt-and-suspenders).
    //   2. Re-attach listeners so we receive any changes made while offline.

    Connections {
        target: app     // Felgo App exposes isOnline property

        function onIsOnlineChanged() {
            if (app.isOnline) {
                console.log("[Network] Online – flushing offline queue and refreshing listeners")
                _sync.processNext()
                _startFirebaseListeners()
            } else {
                console.log("[Network] Offline – writes will be queued")
            }
        }
    }

    // ── Offline write queue ───────────────────────────────────────────────────
    //
    // Entries: { op: "set"|"delete", path: string, data: var|null,
    //            retries: int, ts: int }
    //
    // The queue is persisted to a JSON file so it survives process restarts.
    // processNext() is called on startup (after loadData) and whenever
    // connectivity is restored.

    Item {
        id: _sync

        property var   queue:        []
        property bool  isProcessing: false
        readonly property int maxRetries:   5
        readonly property int retryDelayMs: 4000

        readonly property string _filePath:
            FileUtils.storageLocation(FileUtils.AppDataLocation, "sync/offline_queue.json")

        Component.onCompleted: _load()

        // Public: enqueue a pending write/delete
        function enqueue(op, path, data) {
            var entry = { op: op, path: path, data: data, retries: 0, ts: Date.now() }
            queue.push(entry)
            _save()
            logic.syncQueueChanged(queue.length)
            console.log("[SyncQueue] Enqueued", op, path, "| depth:", queue.length)
        }

        // Public: attempt to flush the queue (call when online)
        function processNext() {
            if (isProcessing || queue.length === 0) return
            if (!app.isOnline) return

            isProcessing = true
            var e = queue[0]
            console.log("[SyncQueue] Processing", e.op, e.path,
                        "(attempt " + (e.retries + 1) + "/" + maxRetries + ")")

            if (e.op === "set") {
                firebaseDb.setValue(e.path, e.data)
            } else if (e.op === "delete") {
                firebaseDb.removeValue(e.path)
            } else {
                // Unknown op – discard to avoid blocking the queue
                console.warn("[SyncQueue] Unknown op:", e.op, "– discarding")
                _dequeue()
            }
        }

        // Called by firebaseDb.onWriteCompleted
        function onWriteAck(path) {
            if (!isProcessing || queue.length === 0) return
            if (queue[0].path !== path) return     // ack is for a different write

            console.log("[SyncQueue] Ack OK  path:", path)
            _dequeue()
            if (queue.length > 0) _retryTimer.restart()
        }

        // Called by firebaseDb.onErrorOccurred
        function onWriteError(path) {
            if (!isProcessing || queue.length === 0) return
            if (queue[0].path !== path) return

            var e = queue[0]
            e.retries++
            if (e.retries >= maxRetries) {
                console.error("[SyncQueue] Max retries for", path, "– dropping entry")
                _dequeue()
            } else {
                console.warn("[SyncQueue] Will retry", path, "in", retryDelayMs, "ms")
                isProcessing = false
                _retryTimer.restart()
            }
        }

        // ── Private ───────────────────────────────────────────────────────────
        function _dequeue() {
            queue.shift()
            isProcessing = false
            _save()
            logic.syncQueueChanged(queue.length)
        }

        function _load() {
            var raw = FileUtils.readFile(_filePath)
            if (raw && raw !== "") {
                try {
                    queue = JSON.parse(raw)
                    if (queue.length > 0)
                        console.log("[SyncQueue] Loaded", queue.length, "pending entries")
                } catch (e) {
                    console.warn("[SyncQueue] Could not parse queue file:", e)
                    queue = []
                }
            }
        }

        function _save() {
            FileUtils.writeFile(_filePath, JSON.stringify(queue))
        }

        Timer {
            id: _retryTimer
            interval: _sync.retryDelayMs
            repeat: false
            onTriggered: _sync.processNext()
        }
    }

    // ── Local file store ──────────────────────────────────────────────────────
    //
    // Fast path: data is available instantly on app open (no network round-trip).
    // Firebase listener results overwrite this; every Firebase update is also
    // written back here so the two stay in sync.

    Item {
        id: _localStore

        readonly property string _invPath:
            FileUtils.storageLocation(FileUtils.AppDataLocation, "inventory/inventoryDataJson.json")
        readonly property string _ordPath:
            FileUtils.storageLocation(FileUtils.AppDataLocation, "orders/ordersDataJson.json")

        function loadAll() {
            _inv.records = _read(_invPath, "inventory")
            _ord.records = _read(_ordPath, "orders")
            logic.dataLoaded(_inv.records, _ord.records)
        }

        function saveInventory() {
            var ok = FileUtils.writeFile(_invPath, JSON.stringify(_inv.records))
            if (!ok) console.warn("[LocalStore] Failed to persist inventory")
        }

        function saveOrders() {
            var ok = FileUtils.writeFile(_ordPath, JSON.stringify(_ord.records))
            if (!ok) console.warn("[LocalStore] Failed to persist orders")
        }

        function _read(filePath, label) {
            var raw = FileUtils.readFile(filePath)
            if (!raw || raw === "") return []
            try {
                var parsed = JSON.parse(raw)
                console.log("[LocalStore] Loaded", parsed.length, label, "records")
                return parsed
            } catch (e) {
                console.warn("[LocalStore] Parse error for", label, ":", e)
                return []
            }
        }
    }

    // ── REST API (kept for cloud-function calls) ───────────────────────────────
    RestAPI {
        id: api
        maxRequestTimeout: 5000
    }

    // ── Felgo KV cache ────────────────────────────────────────────────────────
    Storage {
        id: cache
    }

    // ── Private auth state ────────────────────────────────────────────────────
    Item {
        id: _
        property bool userLoggedIn: false
    }

    // ── Inventory in-memory store ─────────────────────────────────────────────

    Item {
        id: _inv

        property var records: []

        // Reactive computed stats (re-evaluate whenever records changes)
        readonly property int totalItems: {
            var s = 0
            for (var i = 0; i < records.length; i++) s += (records[i].currentStock || 0)
            return s
        }
        readonly property int totalValue: {
            var s = 0
            for (var i = 0; i < records.length; i++)
                s += (records[i].currentStock || 0) * (records[i].price || 0)
            return s
        }
        readonly property int lowStockCount: {
            var n = 0
            for (var i = 0; i < records.length; i++) {
                if ((records[i].currentStock || 0) <= (records[i].minimumStock || 0)) n++
            }
            return n
        }

        // Insert or replace by product_id (== intentional: handles int vs string)
        function upsert(record) {
            var arr = records.slice()
            var idx = -1
            for (var i = 0; i < arr.length; i++) {
                if (arr[i].product_id === record.product_id) { idx = i; break }
            }
            if (idx >= 0) arr[idx] = record
            else          arr.push(record)
            records = arr       // assignment triggers QML change notification
        }

        function remove(field, id) {
            // == intentional: handles int vs string IDs
            records = records.filter(function(r) { return r[field] != id })
        }
    }

    // ── Orders in-memory store ────────────────────────────────────────────────

    Item {
        id: _ord

        property var records: []

        readonly property int pendingCount: {
            var n = 0
            for (var i = 0; i < records.length; i++) {
                if (records[i].status === "pending") n++
            }
            return n
        }
        readonly property int completedCount: {
            var n = 0
            for (var i = 0; i < records.length; i++) {
                if (records[i].status === "completed") n++
            }
            return n
        }

        function upsert(record) {
            var arr = records.slice()
            var idx = -1
            for (var i = 0; i < arr.length; i++) {
                if (arr[i].order_id == record.order_id) { idx = i; break }
            }
            if (idx >= 0) arr[idx] = record
            else          arr.push(record)
            records = arr
        }

        function remove(field, id) {
            records = records.filter(function(r) { return r[field] != id })
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    // Convert Firebase object-of-objects → array (Firebase stores children as
    // an object keyed by push-ID or our own ID when using setValue).
    function _toArray(data) {
        if (data === undefined || data === null) return []
        if (Array.isArray(data)) return data
        var keys = Object.keys(data)
        var arr  = []
        for (var i = 0; i < keys.length; i++) {
            var v = data[keys[i]]
            if (v !== null && typeof v === "object") arr.push(v)
        }
        return arr
    }

    // Apply data received from Firebase (onListenEvent or onReadCompleted)
    function _applyFirebaseData(path, value) {
        var arr = _toArray(value)
        if (path === "inventory" || path === "/inventory") {
            _inv.records = arr
            _localStore.saveInventory()
            logic.dataLoaded(_inv.records, _ord.records)
        } else if (path === "orders" || path === "/orders") {
            _ord.records = arr
            _localStore.saveOrders()
            logic.dataLoaded(_inv.records, _ord.records)
        }
    }

    // Start (or re-attach) Firebase real-time listeners.
    // Falls back to one-shot getValue if listenForValueChange is unavailable.
    function _startFirebaseListeners() {
        console.warn("[Firebase] getting values from firebase store")
        firebaseDb.getValue("inventory", "", function(success, key, value) {
            console.log("callback for get value in to firbase")
            if(success) {
                _inv.records = _toArray(value)
                console.log("successfully read objects from DB with size: " + _inv.records.length)
                _localStore.saveInventory()
            } else {
                console.error("DB get error:", message)
            }
        })
        firebaseDb.getValue("orders", "", function(success, key, value) {
            console.log("callback for get value in to firbase")
            if(success) {
                _ord.records = _toArray(value)
                console.log("successfully read object from DB with size: " + _ord.records.length)
                _localStore.saveOrders()
            } else {
                console.error("DB get error:", message)
            }
        })
        logic.dataLoaded(_inv.records, _ord.records)
    }

    // Route a write through Firebase (online) or the offline queue (offline).
    function _firebaseWrite(path, data) {
        console.log("writing")
        if (app.isOnline) {
            console.log("writing in to firebase")
            firebaseDb.setValue(path, data, function(success, message) {
                console.log("callback for writing in to firbase")
                if(success) {
                    console.log("successfully written object to DB")
                } else {
                    console.log("DB write error:", message)
                }
            })
        } else {
            console.log("[DataModel] Offline – queuing write for", path)
            _sync.enqueue("set", path, data)
        }
    }

    // Route a delete through Firebase (online) or the offline queue (offline).
    function _firebaseRemove(path) {
        if (app.isOnline) {
            firebaseDb.removeValue(path)
        } else {
            console.log("[DataModel] Offline – queuing delete for", path)
            _sync.enqueue("delete", path, null)
        }
    }

    // Compact, collision-resistant ID: Base-36 timestamp + 5-char random suffix.
    // Example: "lhj3k2abf7"  – valid Firebase path segment, roughly sortable.
    function _makeId() {
        return Date.now().toString(36) + Math.random().toString(36).substr(2, 5)
    }

    // ── Startup: replay any pending queue entries from last session ────────────
    Component.onCompleted: {
        // Queue is loaded by _sync.Component.onCompleted; give it a tick to
        // populate, then try to flush (will no-op if offline or empty).
        Qt.callLater(function() {
            if (_sync.queue.length > 0) {
                console.log("[DataModel] Replaying", _sync.queue.length, "offline queue entries")
                _sync.processNext()
            }
        })
    }
}
