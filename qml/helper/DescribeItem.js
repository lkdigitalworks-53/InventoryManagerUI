.pragma library

// Plain-language label for one outbox item, for the stuck-writes dialog.
// Design: docs/superpowers/specs/2026-09-29-stuck-writes-dialog-retry-now-design.md
//
// Pure: no QML, no stores. It only sees the item, so a stock delta can show the
// record id but not the product name (the item carries no name). Never throws.

var NOUN = {
    inventory: "product",
    stock_batch: "stock batch",
    order: "order",
    staff: "team member",
    removed_staff: "team member record",
    supplier: "supplier",
    transaction: "transaction"
}

var NOUN_PLURAL = {
    inventory: "products",
    stock_batch: "stock batches",
    order: "orders",
    staff: "team members",
    removed_staff: "team member records",
    supplier: "suppliers",
    transaction: "transactions"
}

var VERB = { create: "Added", update: "Edited", "delete": "Deleted" }

// Operation types (Gateway.recordOperation). Unknown ones fall back below.
var OPERATION = { completeOrder: "Order completion", restock: "Restock" }

function _has(map, key) {
    return typeof key === "string" && Object.prototype.hasOwnProperty.call(map, key)
}

function _text(v) {
    return (typeof v === "string" || typeof v === "number") ? String(v).trim() : ""
}

// Best human name on a document: name (product, staff, supplier), productName
// (transaction), customer (order). "" when none.
function _nameOf(doc) {
    if (!doc || typeof doc !== "object") return ""
    return _text(doc.name) || _text(doc.productName) || _text(doc.customer)
}

function _noun(entity) { return _has(NOUN, entity) ? NOUN[entity] : "record" }
function _nouns(entity) { return _has(NOUN_PLURAL, entity) ? NOUN_PLURAL[entity] : "records" }

// The label for an operation item: the ORDER op's customer name, else the order id,
// else the first op's id (the old behaviour). A completion's first op is a stock batch,
// whose id means nothing to the person, so the order op wins (Q-EC, 2026-10-13).
function _opDetail(ops) {
    for (var i = 0; i < ops.length; ++i) {
        var op = ops[i]
        if (!op || typeof op !== "object" || op.entity !== "order") continue
        return _text(op.after && op.after.customer) || _text(op.entityId)
    }
    var first = ops.length > 0 && ops[0] ? ops[0] : {}
    return _text(first.entityId)
}

// A restock's label: "3 \u00d7 Tomato" (quantity and product name from the purchase record), else the
// product id, else "". Its first ops are server-side mints, which carry nothing a person could read.
function _restockDetail(ops) {
    var qty = 0
    var id = ""
    var name = ""
    for (var i = 0; i < ops.length; ++i) {
        var op = ops[i]
        if (!op || typeof op !== "object") continue
        if (op.entity === "inventory" && op.deltas && typeof op.deltas === "object") {
            id = _text(op.entityId)
            if (typeof op.deltas.stock === "number") qty = op.deltas.stock
        } else if (op.entity === "transaction" && op.after && typeof op.after === "object") {
            name = _text(op.after.productName)
        }
    }
    var who = name || id
    if (!who) return ""
    return qty > 0 ? qty + " \u00d7 " + who : who
}

// -> { title, detail }. `detail` is the record's name, else its id, else "".
function describe(item) {
    if (!item || typeof item !== "object") return { title: "Pending change", detail: "" }

    if (Array.isArray(item.ops)) {
        return {
            title: _has(OPERATION, item.opType) ? OPERATION[item.opType] : "Multi-step change",
            detail: item.opType === "restock" ? _restockDetail(item.ops) : _opDetail(item.ops)
        }
    }

    if (Array.isArray(item.items)) {
        var n = item.items.length
        return {
            title: n === 1 ? "1 " + _noun(item.entity) + " change"
                           : n + " " + _nouns(item.entity) + " changed",
            detail: ""
        }
    }

    if (item.deltas && typeof item.deltas === "object")
        return { title: "Stock change", detail: _text(item.entityId) }

    var verb = _has(VERB, item.action) ? VERB[item.action] : "Changed"
    // A delete has no `after`; the name lives on `before`.
    var name = _nameOf(item.after) || _nameOf(item.before)
    return {
        title: verb + " " + _noun(item.entity),
        detail: name || _text(item.entityId)
    }
}
