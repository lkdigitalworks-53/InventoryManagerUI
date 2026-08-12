import QtQuick
import "../helper/StockReconcile.js" as StockReconcile
import "../helper/OrderAdjust.js" as OrderAdjust
import "../helper/OrderMath.js" as OrderMath

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

    function tryCompleteOrder(orderId, callback) {
        _tryCompleteOrder(orderId, callback)
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
        function onAddOrder(customer, items, total, status, date, email, phone, products, orderChannel, staffId) {
            OrdersStore.addOrder(customer, items, total, status, date, email, phone, products, orderChannel, staffId,
                function(ok, newOrderId) {
                    if (!ok) {
                        logic.errorOccurred("network", "Could not add order — try again")
                        return
                    }
                    _syncOrdersModel()
                    logic.orderAdded(newOrderId)

                    if (OrdersStore.autoApproveEnabled) {
                        _tryCompleteOrder(newOrderId, function(success) {
                            if (!success)
                                logic.orderCompletionFailed(newOrderId, dataModel.stockErrorMsg)
                        })
                    }
                })
        }

        function onUpdateOrder(orderId, fields) {
            var cur = OrdersStore.getById(orderId)
            var wasCompleted = cur && cur.status === "completed"
            var toCompleted = fields.status === "completed"

            // If status is changing to "completed", route through the full
            // completion flow (stock validation + FIFO deduction + sales record).
            if (toCompleted) {
                if (cur && !wasCompleted) {
                    // First persist all non-status fields so the order snapshot
                    // is complete when _tryCompleteOrder reads it back.
                    var nonStatusFields = {}
                    for (var k in fields) {
                        if (k !== "status") nonStatusFields[k] = fields[k]
                    }
                    if (Object.keys(nonStatusFields).length > 0)
                        OrdersStore.updateOrder(orderId, nonStatusFields)
                    // Now delegate to the orchestrated completion path.
                    // _tryCompleteOrder already calls _updateOrderInModel
                    // internally on both the success and failure paths — not
                    // repeated here.
                    _tryCompleteOrder(orderId, function(success) {
                        if (!success) {
                            logic.orderCompletionFailed(orderId, dataModel.stockErrorMsg)
                            return
                        }
                        logic.orderUpdated(orderId)
                    })
                    return
                }
            } else if (wasCompleted && fields.status !== undefined) {
                // Reverting a COMPLETED order back to pending/processing (or any
                // non-completed status) reverses booked stock/FIFO/sale events —
                // significant enough to gate the same way onAdjustOrder already
                // does. Safe to add here without touching import: import's own
                // field-update payload (OrdersStore.upsertMany's envelopeFields)
                // never includes `status` at all, so it can never reach this
                // branch regardless of who's running the import.
                if (!_hasAnyRole(["owner", "admin", "manager"])) {
                    logic.errorOccurred("auth", "You do not have permission to reopen a completed order")
                    return
                }
                // The completion deducted stock and booked sale events;
                // reopening MUST reverse both or the inventory and the
                // analysis reports permanently overcount (bug 1). This also
                // makes a later re-completion a clean, fresh deduction instead of
                // a second one stacked on top (bug 2). Reversal reads the order's
                // current consumption[] lineage, so it MUST run before the
                // updateOrder below (which may strip consumption from products).
                _reverseCompletedOrder(cur)
                // Persist the new status with consumption cleared off every line —
                // a reopened order holds no booked lineage until it completes again.
                var revertFields = {}
                for (var rk in fields) revertFields[rk] = fields[rk]
                if (revertFields.products === undefined) {
                    var cleared = []
                    var cp = cur.products || []
                    for (var ci = 0; ci < cp.length; ++ci) {
                        var lc = {}
                        for (var lk in cp[ci]) lc[lk] = cp[ci][lk]
                        lc.consumption = []
                        cleared.push(lc)
                    }
                    revertFields.products = cleared
                }
                OrdersStore.updateOrder(orderId, revertFields)
                _updateOrderInModel(orderId)
                logic.orderUpdated(orderId)
                return
            }
            // Normal update path (status not changing completed↔non-completed).
            OrdersStore.updateOrder(orderId, fields)
            _updateOrderInModel(orderId)
            logic.orderUpdated(orderId)
        }

        function onCompleteOrder(orderId) {
            _tryCompleteOrder(orderId, function(success) {
                if (!success) {
                    logic.orderCompletionFailed(orderId, dataModel.stockErrorMsg)
                }
            })
        }

        function onDeleteOrder(orderId) {
            if (!_hasAnyRole(["owner", "admin", "manager"])) {
                logic.errorOccurred("auth", "You do not have permission to delete orders")
                return
            }
            var order = OrdersStore.getById(orderId)
            if (order && order.status === "completed") {
                // A completed order has booked stock/FIFO/sale events —
                // deleting it outright would orphan all of that with no
                // reversal. Reopening (which already reverses everything,
                // see onUpdateOrder's revert branch) before delete is the
                // safe path; reject rather than silently cascade-reverse as
                // a side effect of what the user asked for as a plain delete.
                logic.errorOccurred("order", "Completed orders can't be deleted directly — reopen it to pending first, then delete")
                return
            }
            OrdersStore.deleteOrder(orderId)
            _syncOrdersModel()
            logic.orderDeleted(orderId)
        }

        function onAdjustOrder(orderId, newLines, reason, condition, note) {
            if (!_hasAnyRole(["owner", "admin", "manager"])) {
                logic.errorOccurred("auth", "You do not have permission to adjust orders")
                return
            }
            _tryAdjustOrder(orderId, newLines, reason, condition, note, function(ok) {
                if (ok) {
                    _updateOrderInModel(orderId)
                    logic.orderUpdated(orderId)
                } else {
                    logic.errorOccurred("order", dataModel.stockErrorMsg || "Could not adjust order")
                }
            })
        }

        // ── Inventory ─────────────────────────────────────────────────────────
        function onAddProduct(name, sku, category, description, price, unit, stock, minStock, sellingPrice, taxable, taxPercent) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can add products")
                return
            }
            InventoryStore.addProduct(name, sku, category, description, price, unit, stock, minStock, sellingPrice, taxable, taxPercent,
                undefined, undefined, undefined, function(ok, productId) {
                    if (!ok) {
                        logic.errorOccurred("network", "Could not add product — try again")
                        return
                    }
                    logic.productAdded(productId)
                })
        }

        function onUpdateProduct(productId, fields, reason) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can update products")
                return
            }
            // Capture the pre-edit stock so we can reconcile the FIFO batch
            // ledger after the product update. A manual stock edit only touches
            // product.stock; without this the batch ledger (which backs the
            // Value / Potential-profit / by-supplier Analysis reports) drifts.
            var before = InventoryStore.getById(productId)
            var oldStock = before ? before.stock : undefined
            InventoryStore.updateProduct(productId, fields, reason)
            _reconcileBatchesForStockEdit(productId, oldStock, fields.stock)
            logic.productUpdated(productId)
        }

        function onRestockProduct(productId, amount) {
            if (!_hasAnyRole(["owner", "admin"])) {
                logic.errorOccurred("auth", "Only owner/admin can restock products")
                return
            }
            InventoryStore.restock(productId, amount, undefined, undefined, undefined, function(ok, supplierFailed) {
                if (!ok) {
                    logic.errorOccurred("network", "Could not restock — try again")
                    return
                }
                logic.productRestocked(productId)
                if (supplierFailed) {
                    logic.errorOccurred("network", "Restocked, but the supplier could not be recorded — edit it manually if needed")
                }
            })
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
            StaffStore.addStaff(name, email, phone, role, department, joinDate, status, salary,
                function(ok, staffId) {
                    if (!ok) {
                        logic.errorOccurred("network", "Could not add staff — try again")
                        return
                    }
                    logic.staffAdded(staffId)
                })
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

    // Resolve an order line item back to an inventory record by productId
    // only. No name-based fallback: product names can legitimately duplicate
    // across distinct products, so matching by name here could silently
    // deduct stock from / attribute a sale to the wrong product. Every
    // current order-creation path (NewOrderDialog, OrderDetailDialog,
    // ImportPreviewDialog) always sets productId on a line item — a line
    // missing it is either truly pre-productId legacy data or a data bug,
    // and either way should surface as "not found" rather than be silently
    // guessed at by name.
    function _resolveInventory(lineItem) {
        if (!lineItem.productId) return null
        return InventoryStore.getById(lineItem.productId)
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
    //
    // ASYNC as of the async-write-sequencing design (round 4): stock
    // deduction now goes through Gateway.recordDelta, which can be
    // genuinely rejected server-side (another device already sold the last
    // units since step 1's local pre-check ran) — so this can no longer
    // return a synchronous true/false the way it used to. `callback(ok)`
    // fires once every line's deduction has actually resolved. On a
    // deduction rejection: the order is set to "out of stock" (same as
    // step 1's synchronous pre-check path) and stockErrorMsg is populated,
    // exactly like the old synchronous-failure path — callers that already
    // handled `if (!success) { ...stockErrorMsg... }` need no changes
    // beyond reading that result from the callback instead of a return
    // value. This is also where the ORIGINAL ask that started this whole
    // design — synchronized calls with a real busy indicator instead of a
    // decorative one — actually gets delivered, for this one flow: the
    // caller now has a genuine "still working" window to show one in.
    function _tryCompleteOrder(orderId, callback) {
        var o = OrdersStore.getById(orderId)
        if (!o) { if (callback) callback(false); return }
        if (o.status === "completed") { if (callback) callback(true); return }

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
            if (callback) callback(false)
            return
        }

        // ── 2. FIFO consumption + deduct stock ───────────────────────────
        // Build a parallel `linesWithConsumption` array so the post-deduct
        // updateOrder call can stamp the per-batch lineage onto each line
        // item — that's what lets per-supplier sold/revenue/margin queries
        // work later. Every line's deductStock is fired up front (they're
        // independent products — no reason to serialize them against each
        // other) and this function waits for ALL of them before proceeding,
        // failing the whole order if ANY of them comes back rejected.
        var lines = o.products || []
        var linesWithConsumption = new Array(lines.length)
        var deltaFailed = false
        var deltaFailMsg = ""
        // New (review round 2, partial-multi-line-completion gap): tracks
        // which lines' deductStock actually succeeded, so a sibling line's
        // failure can credit them back — see _afterAllDeltas below.
        var succeededLines = []

        function _afterAllDeltas() {
            if (deltaFailed) {
                // FIFO consumption for every line already ran (synchronously,
                // up front, before any deductStock callback could resolve —
                // see the loop below) regardless of whether THIS order ends
                // up completing. Undo it here so a rejected order doesn't
                // leave stock_batches permanently decremented for units no
                // sale actually accounts for (review finding C5, 2026-08-06).
                // Uses the same restoreFifo the returns flow already relies
                // on for exactly this purpose (see _tryAdjustOrder's return
                // path above).
                for (var li = 0; li < linesWithConsumption.length; ++li) {
                    var restoreLine = linesWithConsumption[li]
                    if (!restoreLine || !Array.isArray(restoreLine.consumption)) continue
                    for (var ri = 0; ri < restoreLine.consumption.length; ++ri) {
                        var rc = restoreLine.consumption[ri]
                        StockBatchStore.restoreFifo(rc.batchId, restoreLine.productId, rc.qtyConsumed)
                    }
                }
                // C5 above only restores the batch ledger. It doesn't touch
                // product.stock itself for lines whose deductStock already
                // succeeded before a SIBLING line's deductStock failed — that
                // stock stays decremented for an order that never completed.
                // Credit it back with the same primitive the returns flow
                // already uses for exactly this "credit stock, batches already
                // handled separately" shape (creditStockNoBatch, recordDelta-
                // based since C4).
                for (var si = 0; si < succeededLines.length; ++si) {
                    InventoryStore.creditStockNoBatch(succeededLines[si].productId, succeededLines[si].qty)
                }
                OrdersStore.updateOrder(orderId, { status: "out of stock" })
                dataModel.stockErrorMsg = deltaFailMsg
                _updateOrderInModel(orderId)
                if (callback) callback(false)
                return
            }
            // ── 3. Persist the order with consumption + record sale events ──
            OrdersStore.updateOrder(orderId, {
                status: "completed",
                products: linesWithConsumption.length > 0 ? linesWithConsumption : undefined
            })
            SalesStore.recordSale(o.total, o.items)
            // The persisted order now carries `consumption[]` per line — read it
            // back so TransactionStore writes the same lineage to every sale doc.
            TransactionStore.recordSaleFromOrder(OrdersStore.getById(orderId))
            _updateOrderInModel(orderId)
            if (callback) callback(true)
        }

        // Extra "loop not finished yet" token (released after the loop
        // below, not inside it) — without this, a deductStock callback
        // that happens to fire SYNCHRONOUSLY (e.g. InventoryStore's
        // no-such-product guard) for an early line could bring the count to
        // zero and trigger _afterAllDeltas() before later lines in the same
        // loop have even been dispatched.
        var pending = 1
        function _oneResolved() {
            pending--
            if (pending === 0) _afterAllDeltas()
        }

        for (var j = 0; j < lines.length; ++j) {
            (function(j) {
                var pp = lines[j]
                var qqty = _lineQty(pp)
                var invP = _resolveInventory(pp)
                var line = {}
                for (var k in pp) line[k] = pp[k]

                if (invP && qqty > 0) {
                    pending++
                    StockBatchStore.consumeFifo(invP.productId, qqty, function(fifoResult) {
                        var consumption = fifoResult.consumption
                        var shortfall = fifoResult.shortfall

                        function _afterConsumption() {
                            InventoryStore.deductStock(invP.productId, qqty, function(result) {
                                if (!result || !result.ok) {
                                    deltaFailed = true
                                    deltaFailMsg = (deltaFailMsg ? deltaFailMsg + "\n" : "") +
                                        (invP.name + ": " + (result && result.error === "insufficient-quantity"
                                            ? "stock ran out before this order could complete"
                                            : "could not update stock — try again"))
                                } else {
                                    succeededLines.push({ productId: invP.productId, qty: qqty })
                                }
                                line.consumption = consumption
                                linesWithConsumption[j] = line
                                _oneResolved()
                            }, false /* reject, don't clamp — round-4 decision for order completion */)
                            console.log("[DataModel] FIFO consumed", qqty, "for", invP.productId,
                                        "across", consumption.length, "batch(es)")
                        }

                        if (shortfall > 0) {
                            // Drift guard: batches couldn't satisfy the qty
                            // even though product.stock said they should.
                            // Top up the oldest batch by the deficit and try
                            // once more — topUp guarantees enough, so a
                            // single retry suffices.
                            StockBatchStore.topUpOldest(invP.productId, shortfall, function() {
                                StockBatchStore.consumeFifo(invP.productId, shortfall, function(retryResult) {
                                    for (var r = 0; r < retryResult.consumption.length; ++r)
                                        consumption.push(retryResult.consumption[r])
                                    _afterConsumption()
                                })
                            })
                        } else {
                            _afterConsumption()
                        }
                    })
                } else {
                    if (!invP) console.warn("[DataModel] Could not resolve line item to inventory:", JSON.stringify(pp))
                    line.consumption = []
                    linesWithConsumption[j] = line
                }
            })(j)
        }

        _oneResolved() // release the loop-not-finished token
    }

    // Complete an imported order that arrived with status "completed".
    // Mirrors _tryCompleteOrder's FIFO consumption + sale recording, but never
    // FAILS on insufficient stock (owner decision "complete + report shortfall"):
    // it consumes what's available, tops up the deficit so the sale still books
    // with correct lineage, deducts product.stock, and reports the shortfall to
    // the caller. The import flow (ImportPreviewDialog) calls this for each
    // freshly-added order whose status is "completed".
    //   returns { ok: bool, understocked: bool }
    // review round 2: was synchronous (`return {ok, understocked}`) — its
    // ImportPreviewDialog caller looped over every newly-completed imported
    // order and used the return value immediately. consumeFifo's async
    // rewrite forced this to become callback-based too. Mirrors
    // adjustOrderForImport's existing precedent just below (already made
    // async in round 4 of the original async-write-sequencing project) —
    // same shape, not a new pattern for this file.
    function completeImportedOrder(orderId, callback) {
        var o = OrdersStore.getById(orderId)
        if (!o) { if (callback) callback({ ok: false, understocked: false }); return }
        var understocked = false
        var linesWithConsumption = []
        var products = o.products || []

        function _finish() {
            OrdersStore.updateOrder(orderId, {
                products: linesWithConsumption.length > 0 ? linesWithConsumption : undefined
            })
            SalesStore.recordSale(o.total, o.items)
            TransactionStore.recordSaleFromOrder(OrdersStore.getById(orderId))
            _updateOrderInModel(orderId)
            if (callback) callback({ ok: true, understocked: understocked })
        }

        var idx = 0
        function _nextLine() {
            if (idx >= products.length) { _finish(); return }
            var pp = products[idx]
            idx++
            var qqty = _lineQty(pp)
            var invP = _resolveInventory(pp)

            function _pushLine(consumption) {
                var line = {}
                for (var k in pp) line[k] = pp[k]
                line.consumption = consumption
                linesWithConsumption.push(line)
                _nextLine()
            }

            if (invP && qqty > 0) {
                if ((invP.stock || 0) < qqty) understocked = true
                StockBatchStore.consumeFifo(invP.productId, qqty, function(fifoResult) {
                    var consumption = fifoResult.consumption
                    function _afterConsumption() {
                        // Fire-and-forget by design here (unlike
                        // _tryCompleteOrder): this function's contract never
                        // branches on the deduction's outcome —
                        // `understocked` is already decided above from the
                        // pre-check, and clamp mode (not reject) means the
                        // delta is never rejected anyway.
                        InventoryStore.deductStock(invP.productId, qqty, function(result) {
                            if (!result || !result.ok)
                                console.warn("[DataModel] completeImportedOrder: deductStock did not confirm", JSON.stringify(result))
                        }, true /* clamp, don't reject — "complete + report shortfall" business rule */)
                        _pushLine(consumption)
                    }
                    if (fifoResult.shortfall > 0) {
                        StockBatchStore.topUpOldest(invP.productId, fifoResult.shortfall, function() {
                            StockBatchStore.consumeFifo(invP.productId, fifoResult.shortfall, function(retryResult) {
                                for (var r = 0; r < retryResult.consumption.length; ++r)
                                    consumption.push(retryResult.consumption[r])
                                _afterConsumption()
                            })
                        })
                    } else {
                        _afterConsumption()
                    }
                })
            } else {
                if (!invP) console.warn("[DataModel] completeImportedOrder: line not resolved to inventory:", JSON.stringify(pp))
                _pushLine([])
            }
        }
        _nextLine()
    }

    // Import-facing counterpart to onAdjustOrder's signal handler. The
    // signal path (logic.adjustOrder -> onAdjustOrder -> _tryAdjustOrder)
    // is fire-and-forget: a bulk import applying several overwrite rows in
    // a loop would have no way to know which ones failed a stock check, so
    // failures would silently vanish into a single, likely-overwritten
    // global error toast instead of the import's own per-row summary.
    // Mirrors completeImportedOrder's existing precedent of calling
    // straight into DataModel instead of through the signal for exactly
    // this reason -- no RBAC check here either, matching that precedent,
    // since import-level access is gated at the import entry point, not
    // per adjustment operation.
    function adjustOrderForImport(orderId, newLines, reason, condition, note, callback) {
        dataModel.stockErrorMsg = ""
        _tryAdjustOrder(orderId, newLines, reason, condition, note, function(ok) {
            if (callback) callback({ ok: ok, message: ok ? "" : dataModel.stockErrorMsg })
        })
    }

    // Reverse a COMPLETED order back to an un-booked state. Mirrors a full
    // return on every line: restores each line's consumed batches to sellable
    // stock, credits product.stock, and appends a negating ledger event so the
    // sold/revenue/profit reports net the original sale back to zero. Used when
    // a completed order is reopened (status → pending/processing). Idempotent at
    // the call site: onUpdateOrder only invokes this on the completed→non-completed
    // edge, and clears consumption[] afterwards so a re-revert is a no-op.
    function _reverseCompletedOrder(o) {
        if (!o || !o.products) return
        for (var i = 0; i < o.products.length; ++i) {
            var line = o.products[i]
            var qty = _lineQty(line)
            if (qty <= 0) continue
            var consumption = Array.isArray(line.consumption) ? line.consumption : []
            // Reverse-FIFO plan over the WHOLE line (return every unit).
            var plan = OrderAdjust.restorePlan(consumption, qty)
            var reversed = []
            for (var p = 0; p < plan.length; ++p)
                reversed.push({ batchId: plan[p].batchId, supplierId: plan[p].supplierId,
                                qtyConsumed: -plan[p].qty, unitCost: plan[p].unitCost })
            // Restore sellable stock (batch ledger + product.stock).
            if (plan.length > 0) {
                for (var pr = 0; pr < plan.length; ++pr)
                    StockBatchStore.restoreFifo(plan[pr].batchId, line.productId, plan[pr].qty)
            } else if (line.productId) {
                // Pre-FIFO line: no lineage — repair via topUpOldest.
                StockBatchStore.topUpOldest(line.productId, qty)
            }
            if (line.productId)
                InventoryStore.creditStockNoBatch(line.productId, qty)
            // Negating ledger event so realised revenue/sold/profit unwind exactly
            // what completion booked. Reason "reopened" surfaces it in history.
            TransactionStore.recordReturn(o, { productId: line.productId, name: line.name, price: line.price },
                                          qty, reversed, "reopened", "restock",
                                          qsTr("Order reopened — sale reversed"))
        }
    }

    // Reverse/adjust a COMPLETED order's lines. Diffs the edited lines vs the
    // order's current lines and, per changed line: restores returned units to
    // their original batches (Restock) or writes them off (Damaged), deducts any
    // added units via fresh FIFO, writes a negative return ledger event, and
    // reconciles any price change on surviving units. Then updates the order +
    // appends an adjustments[] entry. Mirrors _tryCompleteOrder in reverse.
    // Cross-store orchestration for a completed order's return/exchange/price
    // adjustment. See _tryCompleteOrder for the general shape this follows.
    //
    // ASYNC as of 2026-07-29 (the follow-up flagged when _tryCompleteOrder
    // got the round-4 treatment but this didn't, due to this function's
    // size/complexity — now done). Only the ADDED-units branch (exchange
    // replacement / qty-up) touches the network via deductStock; returns and
    // price/discount changes are pure local-state + ledger writes and stay
    // synchronous exactly as before. callback(ok) fires once every added-
    // unit deduction has actually resolved.
    //
    // Known, deliberately unfixed limitation: if an added-unit deduction is
    // rejected, the RETURN and PRICE-ADJUST side effects that already ran
    // earlier in this same call are NOT rolled back — this function reports
    // the real outcome instead of always claiming success, but doesn't
    // attempt compensating writes for what already landed. Full
    // transactional rollback across a multi-step flow like this was
    // explicitly scoped out of the whole async-write-sequencing design (see
    // design doc §2) as a separate, larger initiative.
    function _tryAdjustOrder(orderId, newLines, reason, condition, note, callback) {
        var o = OrdersStore.getById(orderId)
        if (!o) { if (callback) callback(false); return }
        // Only completed orders carry booked stock + sale events to reverse.
        // A pending/processing order never deducted stock, so reversing would
        // corrupt both ledgers. Guard defensively (the UI only routes completed
        // orders here, but RBAC gates WHO, not the order STATE).
        if (o.status !== "completed") {
            dataModel.stockErrorMsg = "Only completed orders can be adjusted"
            if (callback) callback(false)
            return
        }
        // A completed order's tax/total come from TransactionStore.totalsForOrder
        // (OrdersStore.applyAdjustment) -- summing that ledger while it's still
        // mid-sync (cold app start, paginating in older transactions) silently
        // undercounts, since the very entries a return needs to net against
        // (this order's original sale) may not have loaded yet. Refuse rather
        // than commit a wrong total. See Skill 38 / SKILLS.md and
        // docs/superpowers/specs/2026-08-11-ledger-sync-race-CHECKPOINT.md for
        // why this is scoped to completed-order adjustments specifically, not
        // the whole app -- order completion and every other action here don't
        // read this ledger at all.
        if (TransactionStore.hasMore) {
            dataModel.stockErrorMsg = "Still syncing transaction history from a recent restart — "
                + "please wait a few seconds and try again."
            if (callback) callback(false)
            return
        }

        var deltas = OrderAdjust.diffLines(o.products || [], newLines || [])
        for (var pf = 0; pf < deltas.length; ++pf) {
            var pfd = deltas[pf]
            if (pfd.addedQty > 0) {
                var pfInv = InventoryStore.getById(pfd.productId)
                var pfStock = pfInv ? pfInv.stock : 0
                if (pfStock < pfd.addedQty) {
                    dataModel.stockErrorMsg = (pfd.name || pfd.productId) + ": not enough stock to add "
                        + pfd.addedQty + " more (only " + Math.max(0, pfStock) + " available)"
                    if (callback) callback(false)
                    return
                }
            }
        }

        var alloc = OrderMath.allocate(o)
        var allocByPid = {}
        for (var ai = 0; ai < alloc.perLine.length; ++ai) {
            var pl = alloc.perLine[ai]
            allocByPid[pl.productId] = pl
        }

        var refundAmount = 0
        var restock = (condition !== "damaged")
        // Capture FIFO lineage for any ADDED units (exchange replacement / qty
        // increase), keyed by productId, so we can stamp it onto the adjusted
        // order line below. Without this the replacement's consumption lives
        // only on its sale event, so order-sourced reports (export Totals block,
        // Revenue-by-supplier) miss its COGS and supplier — overstating profit
        // and undercounting the supplier axis on every exchange (bug 14).
        var addedConsByPid = {}

        // Added-unit confirmations are deferred until after the main loop —
        // recordSaleFromOrder/addedConsByPid/refundAmount for THESE units only
        // happen once we know the deduction actually landed, not optimistically
        // during the loop. Each entry: { d, invA, cons, ok }.
        var pendingAdditions = []
        var deltaFailed = false
        var deltaFailMsg = ""

        function _finishAdjustment() {
            if (deltaFailed) {
                // Same gap as _tryCompleteOrder's partial-multi-line-completion
                // fix above, second site: pendingAdditions holds every ADDED-
                // units line whose deductStock already succeeded before a
                // SIBLING addition failed. Their FIFO consumption and
                // product.stock deduction already landed and were never
                // reversed — undo both here, same primitives as the single-
                // line failure path just above (restoreFifo + creditStockNoBatch).
                for (var pf2 = 0; pf2 < pendingAdditions.length; ++pf2) {
                    var failedEntry = pendingAdditions[pf2]
                    for (var fci = 0; fci < failedEntry.cons.length; ++fci) {
                        var fc = failedEntry.cons[fci]
                        StockBatchStore.restoreFifo(fc.batchId, failedEntry.d.productId, fc.qtyConsumed)
                    }
                    InventoryStore.creditStockNoBatch(failedEntry.d.productId, failedEntry.d.addedQty)
                }
                dataModel.stockErrorMsg = deltaFailMsg
                if (callback) callback(false)
                return
            }
            // Now that every added-unit deduction is confirmed, record their
            // sale events and fold their lineage/refund impact in.
            for (var pa = 0; pa < pendingAdditions.length; ++pa) {
                var entry = pendingAdditions[pa]
                var d = entry.d, invA = entry.invA, cons = entry.cons
                // Tax the ADDED units at the product's CURRENT setting (bug 3).
                // The original units' sale event is immutable and keeps the
                // tax booked at completion, so "originals unchanged, added
                // units current tax" holds in the authoritative event ledger
                // even when the product's tax changed after completion.
                TransactionStore.recordSaleFromOrder({
                    orderId: o.orderId, date: o.date, orderChannel: o.orderChannel,
                    staffId: o.staffId,
                    products: [{ productId: d.productId, name: d.name, price: d.newPrice,
                                 quantity: d.addedQty, consumption: cons,
                                 taxable: !!invA.taxable,
                                 taxPercent: invA.taxable ? (invA.taxPercent || 0) : 0 }]
                })
                if (d.productId) addedConsByPid[d.productId] = cons
                refundAmount -= d.addedQty * d.newPrice
            }
            _finishAdjustmentSync()
        }

        // Everything from here to applyAdjustment() is unchanged from before
        // this conversion — pure local computation + ledger writes, no
        // network dependency, so it stays synchronous once _finishAdjustment
        // has folded in the (now-confirmed) added-units impact above.
        function _finishAdjustmentSync() {
            // Re-stamp surviving consumption[] onto the adjusted lines so the
            // order-sourced Revenue-by-supplier breakdown keeps its FIFO lineage
            // (returns reduce a line's consumption; additions don't carry lineage
            // here, which is acceptable — added units' lineage lives in their sale
            // event). Without this, an adjusted line loses consumption and the
            // Revenue supplier axis drops the whole order.
            var enrichedLines = (newLines || []).map(function(nl) {
                var orig = _findLine(o.products, nl.productId)
                var origCons = orig && Array.isArray(orig.consumption) ? orig.consumption : []
                var oldQ = orig ? (orig.quantity || 0) : 0
                var newQ = nl.quantity || 0
                var returnedQ = Math.max(0, oldQ - newQ)
                var survCons = OrderAdjust.survivingConsumption(origCons, returnedQ)
                // Append the FIFO lineage for any ADDED units on this line so the
                // adjusted order carries full consumption (original surviving + new).
                // Fixes exchange/qty-up COGS + supplier attribution in order-sourced
                // reports (bug 14).
                var added = addedConsByPid[nl.productId]
                if (Array.isArray(added) && added.length > 0)
                    survCons = survCons.concat(added)
                var copy = {}
                for (var k in nl) copy[k] = nl[k]
                copy.consumption = survCons
                return copy
            })

            // ── Per-line discount change (revenue adjustment) ─────────────────
            // Discount is per-line now. A discount-only edit doesn't change unit
            // price, so diffLines won't surface it — scan matched lines directly.
            // Isolate the discount-RATE change from any qty change by valuing the
            // discount delta on the SURVIVING units only (returned/added units are
            // already revenue-handled by the blocks above). Emits one price_adjust
            // per changed line (reason "discount") so it nets into ledger Profit
            // and shows in BOTH the order's and the product's history (bug 17).
            function _lineDiscAmt(ln) {
                var gross = (ln.quantity || 0) * (ln.price || 0)
                if (ln.discountType === "percent") {
                    var p = parseFloat(ln.discountValue) || 0
                    if (p < 0) p = 0; if (p > 100) p = 100
                    return gross * (p / 100)
                }
                var d = parseFloat(ln.discountValue) || 0
                if (d < 0) d = 0; if (d > gross) d = gross
                return d
            }
            var newByPid = {}
            for (var nbi = 0; nbi < (newLines || []).length; ++nbi) {
                var nlx = newLines[nbi]
                newByPid[nlx.productId || nlx.name] = nlx
            }
            for (var oli = 0; oli < (o.products || []).length; ++oli) {
                var ol2 = o.products[oli]
                var key3 = ol2.productId || ol2.name
                var nl2 = newByPid[key3]
                if (!nl2) continue   // fully removed lines: revenue handled by return block
                var oldQ2 = ol2.quantity || 0
                var newQ2 = nl2.quantity || 0
                if (oldQ2 <= 0 || newQ2 <= 0) continue
                // Per-unit discount under each setting.
                var oldPerUnitDisc = _lineDiscAmt(ol2) / oldQ2
                var newPerUnitDisc = _lineDiscAmt(nl2) / newQ2
                var survQ = Math.min(oldQ2, newQ2)
                var addedQ2 = Math.max(0, newQ2 - oldQ2)
                // Discount delta has TWO parts:
                //  • surviving units: their per-unit discount changes old→new.
                //  • added units: booked by the added-units sale event at full price
                //    with NO discount, so the scanner must book their new per-unit
                //    discount here too (else addedQ/newQ of the line discount is
                //    silently lost → event-ledger net overshoots vs the live order).
                // Returned units' old discount is already unwound by the return block.
                var discDelta = survQ * (newPerUnitDisc - oldPerUnitDisc)
                              + addedQ2 * newPerUnitDisc
                if (Math.abs(discDelta) < 0.005) continue
                // revenue down when discount up: recordPriceAdjust(qty, perUnitDelta)
                // yields revenueDelta = -(qty*perUnitDelta). Factor as (1, discDelta)
                // so revenueDelta = -discDelta exactly, independent of survQ.
                TransactionStore.recordPriceAdjust(
                    o, { productId: ol2.productId || "", name: ol2.name },
                    1, discDelta, "discount",
                    (note ? note + " · " : "") + "discount "
                        + (Math.round(_lineDiscAmt(ol2) * 100) / 100) + "->"
                        + (Math.round(_lineDiscAmt(nl2) * 100) / 100) + " on " + ol2.name)
                refundAmount += discDelta   // discount up → refund owed to customer
            }

            OrdersStore.applyAdjustment(orderId, enrichedLines, {
                date: new Date().toISOString(),
                reason: reason || "", condition: condition || "",
                lineDeltas: deltas, refundAmount: refundAmount,
                note: note || "", actorUid: AuthStore.uid || ""
            })
            if (callback) callback(true)
        }

        // Extra "loop not finished yet" token — same reason as
        // _tryCompleteOrder: a deductStock callback firing SYNCHRONOUSLY for
        // an early delta (e.g. a not-found guard) must not trigger
        // _finishAdjustment() before later deltas in the same loop have even
        // been dispatched.
        var pending = 1
        function _oneResolved() {
            pending--
            if (pending === 0) _finishAdjustment()
        }

        for (var i = 0; i < deltas.length; ++i) {
            var d = deltas[i]

            // ── Returned / removed units ─────────────────────────────────
            if (d.returnedQty > 0) {
                var line = _findLine(o.products, d.productId)
                var consumption = line && Array.isArray(line.consumption) ? line.consumption : []
                var plan = OrderAdjust.restorePlan(consumption, d.returnedQty)
                var reversed = []
                for (var p = 0; p < plan.length; ++p)
                    reversed.push({ batchId: plan[p].batchId, supplierId: plan[p].supplierId,
                                    qtyConsumed: -plan[p].qty, unitCost: plan[p].unitCost })
                if (restock) {
                    if (plan.length > 0) {
                        for (var pr = 0; pr < plan.length; ++pr)
                            StockBatchStore.restoreFifo(plan[pr].batchId, d.productId, plan[pr].qty)
                    } else if (d.productId) {
                        // Pre-FIFO line: no lineage — repair via topUpOldest.
                        StockBatchStore.topUpOldest(d.productId, d.returnedQty)
                    }
                    InventoryStore.creditStockNoBatch(d.productId, d.returnedQty)
                }
                // Damaged: units are written off — batch ledger NOT credited and
                // product.stock stays reduced (it already reflects the sale).
                TransactionStore.recordReturn(o, { productId: d.productId, name: d.name, price: d.oldPrice },
                                              d.returnedQty, reversed, reason, condition, note)
                // Refund the returned units at the ORIGINAL-sale per-unit rate
                // (net+tax)/qty read from the immutable sale event — NOT the live
                // allocation, which on a 2nd adjustment already reflects
                // adjustment #1's discount edit (SITE 6). Fall back to the live
                // allocation, then the old price, for pre-event legacy orders.
                var saleEv = TransactionStore.firstSaleEvent(o.orderId, d.productId)
                var perUnit = OrderMath.refundPerUnit(saleEv)
                if (perUnit === 0) {
                    var pl2 = allocByPid[d.productId]
                    perUnit = pl2 && pl2.qty > 0 ? (pl2.net + pl2.tax) / pl2.qty : d.oldPrice
                }
                refundAmount += d.returnedQty * perUnit
            }

            // ── Added units (exchange replacement / modify-up) ───────────
            if (d.addedQty > 0) {
                var invA = InventoryStore.getById(d.productId)
                if (invA) {
                    (function(dCaptured, invACaptured) {
                        pending++
                        StockBatchStore.consumeFifo(dCaptured.productId, dCaptured.addedQty, function(fifoResult) {
                            var cons = fifoResult.consumption

                            function _afterConsumption() {
                                InventoryStore.deductStock(dCaptured.productId, dCaptured.addedQty, function(result) {
                                    if (!result || !result.ok) {
                                        deltaFailed = true
                                        deltaFailMsg = (deltaFailMsg ? deltaFailMsg + "\n" : "") +
                                            (dCaptured.name + ": " + (result && result.error === "insufficient-quantity"
                                                ? "stock ran out before this exchange could complete"
                                                : "could not update stock — try again"))
                                        // cons already landed on the server (the
                                        // consumeFifo calls above already resolved,
                                        // before this callback can fire) — undo it,
                                        // same fix and reasoning as _tryCompleteOrder
                                        // above (review finding C5, 2026-08-06). NOT
                                        // pushing to pendingAdditions already
                                        // correctly keeps this line's sale/refund
                                        // impact out of _finishAdjustment; this
                                        // closes the matching gap on the batch ledger.
                                        for (var rci = 0; rci < cons.length; ++rci) {
                                            var rc2 = cons[rci]
                                            StockBatchStore.restoreFifo(rc2.batchId, dCaptured.productId, rc2.qtyConsumed)
                                        }
                                    } else {
                                        pendingAdditions.push({ d: dCaptured, invA: invACaptured, cons: cons })
                                    }
                                    _oneResolved()
                                }, false /* reject, matching this flow's own pre-check intent */)
                            }

                            if (fifoResult.shortfall > 0) {
                                StockBatchStore.topUpOldest(dCaptured.productId, fifoResult.shortfall, function() {
                                    StockBatchStore.consumeFifo(dCaptured.productId, fifoResult.shortfall, function(retryResult) {
                                        for (var rr = 0; rr < retryResult.consumption.length; ++rr)
                                            cons.push(retryResult.consumption[rr])
                                        _afterConsumption()
                                    })
                                })
                            } else {
                                _afterConsumption()
                            }
                        })
                    })(d, invA)
                }
            }

            // ── Price change on surviving units (modify) ─────────────────
            // A pure revenue correction on units that remain — recorded as a
            // dedicated price_adjust event (quantity:0 so Units Sold is NOT
            // affected; total carries the revenue delta; profit nets it since
            // COGS is unchanged).
            if (d.oldPrice !== d.newPrice && d.newQty > 0 && d.oldQty > 0) {
                var survivingQty = Math.min(d.oldQty, d.newQty)
                var perUnitDelta = d.oldPrice - d.newPrice
                if (survivingQty > 0 && perUnitDelta !== 0) {
                    TransactionStore.recordPriceAdjust(
                        o, { productId: d.productId, name: d.name },
                        survivingQty, perUnitDelta, reason,
                        (note ? note + " · " : "") + "price " + d.oldPrice + "->" + d.newPrice)
                    refundAmount += survivingQty * perUnitDelta
                }
            }
        }

        _oneResolved() // release the loop-not-finished token
    }

    // Find an order line by productId. No name fallback — see _resolveInventory
    // above for why matching by name risks hitting a different product entirely.
    function _findLine(lines, productId) {
        if (!lines || !productId) return null
        for (var i = 0; i < lines.length; ++i) {
            if (lines[i].productId === productId) return lines[i]
        }
        return null
    }

    // Reconcile a manual product.stock edit into the FIFO batch ledger so the
    // batch-derived Analysis reports (Value, Potential profit, by-supplier) stay
    // in sync with product.stock. A decrease drains oldest batches first
    // (consumeFifo); an increase tops up the newest batch (topUpOldest). The
    // decision is the pure StockReconcile.delta; the side effects reuse the same
    // primitives the order-completion flow uses. `fieldsStock` is undefined when
    // the edit didn't touch stock — delta() returns "none" in that case.
    function _reconcileBatchesForStockEdit(productId, oldStock, fieldsStock) {
        var d = StockReconcile.delta(oldStock, fieldsStock)
        if (d.action === "consume") {
            // Drain oldest batches. If the ledger had drifted below
            // product.stock and can't fully cover the decrease, that's
            // fine — consumeFifo's per-batch floor rejects rather than
            // partially applies (review round 2 async rewrite), so any
            // shortfall here just means fewer batches got touched; the
            // already-missing units simply aren't there to drain. Result
            // ignored — this is a best-effort ledger reconciliation, not a
            // decision any caller branches on.
            StockBatchStore.consumeFifo(productId, d.qty, function() {})
        } else if (d.action === "topup") {
            StockBatchStore.topUpOldest(productId, d.qty)
        }
    }
}
