pragma Singleton
import QtQuick

// P1 — Stock-movement taxonomy (CGST Rule 56(2)). Every stock-relevant event
// (receipt/sale/loss/theft/destroyed/write_off/free_sample/gift/adjustment/
// sales_return) gets one immutable stock_movements row via the gateway.
//
// `sales_return` is a documented deviation from the spec's literal 8-value
// enum — see docs/superpowers/plans/2026-07-11-p1-stock-movement-taxonomy.md
// for the reasoning (CGST Rule 56(2) has no "return" column at all; a sales
// return is GST-mechanically a reduction to "supply", not an independent
// event — a distinct kind keeps the ledger self-documenting instead of a
// sign-flipped, easily-misread "sale").
//
// Write-only this session: no local synced list, no read-back. The
// opening/closing-balance register report that will eventually READ these
// back is a separate, future piece of work.
QtObject {
    id: stockMovementStore

    // The 7 kinds a person can pick for a manual stock-decrease adjustment.
    // receipt/sale/sales_return are never user-picked — they're stamped by
    // their own dedicated flows (restock / order completion / returns).
    readonly property var manualAdjustmentKinds: [
        "loss", "theft", "destroyed", "write_off", "free_sample", "gift", "adjustment"
    ]

    readonly property var _allKinds: [
        "receipt", "sale", "loss", "theft", "destroyed", "write_off",
        "free_sample", "gift", "adjustment", "sales_return"
    ]

    function _nextMovementId() {
        // Mirrors Gateway._nextRequestId()'s pattern — this store keeps no
        // local list to scan for a monotonic counter (see file header), so
        // timestamp+random is the id strategy here, not BAT-yyyy-NNN style.
        return "MOV-" + Date.now() + "-" + Math.floor(Math.random() * 1000000)
    }

    // kind: one of _allKinds. qty: signed (negative for stock decreasing).
    // valueAtCost: the movement's cost-basis value (e.g. unitCost * qty for
    // a sale/return; batchCost for a receipt). batchRef: the stock_batches
    // id this movement is tied to, when known — null when not applicable
    // (e.g. a generic manual adjustment with no specific batch lineage).
    // Returns the written doc, or null if `kind`/`productId` is invalid.
    function recordMovement(kind, productId, qty, reason, valueAtCost, batchRef) {
        if (_allKinds.indexOf(kind) < 0) {
            console.warn("[StockMovementStore] recordMovement: unknown kind", kind)
            return null
        }
        if (!productId) {
            console.warn("[StockMovementStore] recordMovement: missing productId")
            return null
        }

        var doc = {
            id: _nextMovementId(),
            productId: productId,
            kind: kind,
            qty: qty || 0,
            reason: reason || "",
            valueAtCost: typeof valueAtCost === "number" ? valueAtCost : (parseFloat(valueAtCost) || 0),
            batchRef: batchRef || null,
            actorUid: AuthStore.uid,
            clientTimestamp: new Date().toISOString()
        }

        Gateway.recordMutation("stock_movement", doc.id, "create", null, doc)
        return doc
    }
}
