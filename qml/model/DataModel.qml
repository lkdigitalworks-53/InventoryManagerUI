import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// DataModel.qml  –  Orchestrator / single source of truth
//
// Listens to Logic signals and delegates to the appropriate store.
// Moves cross-store orchestration (e.g. order completion with stock checks)
// out of Main.qml and into a dedicated layer.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: dataModel

    // ── Public interface ──────────────────────────────────────────────────────

    property alias dispatcher: _logicBus.target

    // Reactive ordersModel kept in sync for ListModel-based UI binding
    property ListModel ordersModel: ListModel {}

    // Stock error info for UI dialogs
    property string stockErrorMsg: ""

    // ── Public methods for direct page access ──────────────────────────────

    function tryCompleteOrder(orderId) {
        return _tryCompleteOrder(orderId)
    }

    function syncOrdersModel() {
        _syncOrdersModel()
    }

    function updateOrderInModel(orderId) {
        _updateOrderInModel(orderId)
    }

    function _hasAnyRole(roles) {
        if (!AuthStore.role) return false
        for (var i = 0; i < roles.length; ++i)
            if (AuthStore.role === roles[i]) return true
        return false
    }

    // ── Action dispatcher ─────────────────────────────────────────────────────

    Connections {
        id: _logicBus

        // ── App lifecycle ─────────────────────────────────────────────────────
        function onLoadData() {
            _syncOrdersModel()
        }

        function onSyncAllStores() {
            OrdersStore.syncFromFirebase()
            InventoryStore.syncFromFirebase()
            SalesStore.syncFromFirebase()
            StaffStore.syncFromFirebase()
            TransactionStore.syncFromFirebase()
            SupplierStore.syncFromFirebase()
            StockBatchStore.syncFromFirebase()
            _syncOrdersModel()
        }

        // ── Orders ────────────────────────────────────────────────────────────
        function onAddOrder(customer, items, total, status, date, email, phone, products, discountType, discountValue, orderChannel, staffId) {
            OrdersStore.addOrder(customer, items, total, status, date, email, phone, products, discountType, discountValue, orderChannel, staffId)
            _syncOrdersModel()
            var newOrderId = OrdersStore.orders[OrdersStore.orders.length - 1].orderId
            logic.orderAdded(newOrderId)

            if (OrdersStore.autoApproveEnabled) {
                var success = _tryCompleteOrder(newOrderId)
                if (!success)
                    logic.orderCompletionFailed(newOrderId, dataModel.stockErrorMsg)
            }
        }

        function onUpdateOrder(orderId, fields) {
            OrdersStore.updateOrder(orderId, fields)
            _updateOrderInModel(orderId)
            logic.orderUpdated(orderId)
        }

        function onCompleteOrder(orderId) {
            var success = _tryCompleteOrder(orderId)
            if (!success) {
                logic.orderCompletionFailed(orderId, dataModel.stockErrorMsg)
            }
        }

        function onApproveAllPending() {
            OrdersStore.approveAllPending()
            _syncOrdersModel()
        }

        function onDeleteOrder(orderId) {
            if (!_hasAnyRole(["owner", "admin", "manager"])) {
                logic.errorOccurred("auth", "You do not have permission to delete orders")
                return
            }
            OrdersStore.deleteOrder(orderId)
            _syncOrdersModel()
            logic.orderDeleted(orderId)
        }

        // ── Inventory ─────────────────────────────────────────────────────────
        function onAddProduct(name, sku, category, description, price, unit, stock, minStock, sellingPrice, taxable, taxPercent) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can add products")
                return
            }
            InventoryStore.addProduct(name, sku, category, description, price, unit, stock, minStock, sellingPrice, taxable, taxPercent)
            logic.productAdded(InventoryStore.products[InventoryStore.products.length - 1].productId)
        }

        function onUpdateProduct(productId, fields) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can update products")
                return
            }
            InventoryStore.updateProduct(productId, fields)
            logic.productUpdated(productId)
        }

        function onRestockProduct(productId, amount) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can restock products")
                return
            }
            InventoryStore.restock(productId, amount)
            logic.productRestocked(productId)
        }

        function onDeleteProduct(productId) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can delete products")
                return
            }
            // Refuse delete while any open order still references this product;
            // historical (completed/cancelled) orders keep their line-item snapshot.
            var openRefs = OrdersStore.openOrdersForProduct(productId)
            if (openRefs.length > 0) {
                logic.errorOccurred("inventory",
                    "Cannot delete: " + openRefs.length + " open order"
                    + (openRefs.length === 1 ? "" : "s")
                    + " reference this product (" + openRefs.slice(0, 3).join(", ")
                    + (openRefs.length > 3 ? "…" : "")
                    + "). Complete or cancel them first.")
                return
            }
            InventoryStore.deleteProduct(productId)
            logic.productDeleted(productId)
        }

        // ── Sales ─────────────────────────────────────────────────────────────
        function onRecordSale(amount, itemCount) {
            SalesStore.recordSale(amount, itemCount)
        }

        // ── Staff ─────────────────────────────────────────────────────────────
        function onAddStaff(name, email, phone, role, department, joinDate, status, salary) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can add staff")
                return
            }
            StaffStore.addStaff(name, email, phone, role, department, joinDate, status, salary)
            logic.staffAdded(StaffStore.staff[StaffStore.staff.length - 1].staffId)
        }

        function onUpdateStaff(staffId, fields) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can update staff")
                return
            }
            StaffStore.updateStaff(staffId, fields)
            logic.staffUpdated(staffId)
        }

        function onDeleteStaff(staffId) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can delete staff")
                return
            }
            StaffStore.deleteStaff(staffId)
            logic.staffDeleted(staffId)
        }
    }

    // ── OrdersStore revision tracking ─────────────────────────────────────────

    Connections {
        target: OrdersStore
        function onRevisionChanged() { _syncOrdersModel() }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    function _syncOrdersModel() {
        ordersModel.clear()
        for (var i = 0; i < OrdersStore.orders.length; ++i) {
            var o = OrdersStore.orders[i]
            ordersModel.append({
                orderId: o.orderId || "", customer: o.customer || "",
                items: o.items || 0, total: o.total || 0,
                status: o.status || "", date: o.date || ""
            })
        }
    }

    function _updateOrderInModel(orderId) {
        var o = OrdersStore.getById(orderId)
        if (!o) return
        for (var i = 0; i < ordersModel.count; ++i) {
            if (ordersModel.get(i).orderId === orderId) {
                ordersModel.set(i, {
                    orderId: o.orderId || "", customer: o.customer || "",
                    items: o.items || 0, total: o.total || 0,
                    status: o.status || "", date: o.date || ""
                })
                break
            }
        }
    }

    // Resolve an order line item back to an inventory record. Prefer
    // productId (stable) and fall back to name (older orders or external data
    // may not carry an id).
    function _resolveInventory(lineItem) {
        if (lineItem.productId) {
            var byId = InventoryStore.getById(lineItem.productId)
            if (byId) return byId
        }
        if (lineItem.name) {
            var byName = InventoryStore.findByName(lineItem.name)
            if (byName) return byName
        }
        return null
    }

    function _lineQty(lineItem) {
        if (lineItem.quantity !== undefined && lineItem.quantity !== null)
            return lineItem.quantity
        return lineItem.qty || 0
    }

    // Cross-store orchestration: validate stock, deduct via FIFO batch
    // consumption, and persist the sale.
    //
    // Key invariant: `product.stock` is the validation source of truth.
    // If the batch ledger drifts below product.stock (manual edit, import,
    // legacy data), we top up the oldest batch silently so the sale still
    // succeeds — never fail a customer-facing flow on a bookkeeping mismatch.
    function _tryCompleteOrder(orderId) {
        var o = OrdersStore.getById(orderId)
        if (!o) return false
        if (o.status === "completed") return true

        // ── 1. Stock validation (against product.stock) ──────────────────
        var errs = []
        if (o.products && o.products.length > 0) {
            for (var i = 0; i < o.products.length; ++i) {
                var p = o.products[i]
                var qty = _lineQty(p)
                var inv = _resolveInventory(p)
                if (!inv) { errs.push(p.name + ": not found in inventory"); continue }
                if (qty > inv.stock) errs.push(p.name + ": need " + qty + ", only " + inv.stock + " in stock")
            }
        }
        if (errs.length > 0) {
            OrdersStore.updateOrder(orderId, { status: "out of stock" })
            dataModel.stockErrorMsg = errs.join("\n")
            _updateOrderInModel(orderId)
            return false
        }

        // ── 2. FIFO consumption + deduct stock ───────────────────────────
        // Build a parallel `linesWithConsumption` array so the post-deduct
        // updateOrder call can stamp the per-batch lineage onto each line
        // item — that's what lets per-supplier sold/revenue/margin queries
        // work later.
        var linesWithConsumption = []
        if (o.products && o.products.length > 0) {
            for (var j = 0; j < o.products.length; ++j) {
                var pp = o.products[j]
                var qqty = _lineQty(pp)
                var invP = _resolveInventory(pp)
                var consumption = []
                if (invP && qqty > 0) {
                    consumption = StockBatchStore.consumeFifo(invP.productId, qqty)
                    var consumed = _sumConsumed(consumption)
                    // Drift guard: if batches couldn't satisfy the qty even
                    // though product.stock said they should, top up the oldest
                    // batch by the deficit and try again. Logged inside the
                    // store; we only retry once because topUp guarantees enough.
                    if (consumed < qqty) {
                        StockBatchStore.topUpOldest(invP.productId, qqty - consumed)
                        var retry = StockBatchStore.consumeFifo(invP.productId, qqty - consumed)
                        for (var r = 0; r < retry.length; ++r) consumption.push(retry[r])
                    }
                    InventoryStore.deductStock(invP.productId, qqty)
                    console.log("[DataModel] FIFO consumed", qqty, "for", invP.productId,
                                "across", consumption.length, "batch(es)")
                } else if (!invP) {
                    console.warn("[DataModel] Could not resolve line item to inventory:", JSON.stringify(pp))
                }
                // Clone the line and stamp consumption — never mutate the
                // OrdersStore row in place since it's shared state.
                var line = {}
                for (var k in pp) line[k] = pp[k]
                line.consumption = consumption
                linesWithConsumption.push(line)
            }
        }

        // ── 3. Persist the order with consumption + record sale events ────
        OrdersStore.updateOrder(orderId, {
            status: "completed",
            products: linesWithConsumption.length > 0 ? linesWithConsumption : undefined
        })
        SalesStore.recordSale(o.total, o.items)
        // The persisted order now carries `consumption[]` per line — read it
        // back so TransactionStore writes the same lineage to every sale doc.
        TransactionStore.recordSaleFromOrder(OrdersStore.getById(orderId))
        _updateOrderInModel(orderId)
        return true
    }

    // Internal: total qty across an FIFO consumption result.
    function _sumConsumed(consumption) {
        var s = 0
        if (!consumption) return 0
        for (var i = 0; i < consumption.length; ++i) s += (consumption[i].qtyConsumed || 0)
        return s
    }
}
