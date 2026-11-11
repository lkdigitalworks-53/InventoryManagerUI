.pragma library
.import "ProductSearch.js" as Search
.import "ProductPickability.js" as Pick
.import "PickerDraft.js" as Draft

// Pure view-model of the order picker sheet (design 2026-11-03, slice S2). ProductPickerSheet.qml holds the
// state (query, category, in-stock toggle, draft) and calls build() whenever any input changes, including when
// a store revision ticks; everything the sheet decides (what rows show, in what order, which are hidden, what the
// draft is worth, whether it may be committed, what to say when the list is empty) is decided HERE, in one tested
// place (Skill 83), on top of the three S1 helpers. Tests: functions/test/pickerSheetModel.test.js.
//
// Every row of the view is FLAT (strings, numbers, booleans only, every key always present) so the sheet can keep
// it in a ListModel and update it in place: replacing a JS-array model on every stepper tap would reset the list
// to the top (Skill 83, the gallery model).
//
// Hooks (plain closures supplied by the dialog, see ProductPickability.js for the contract):
//   hasPendingMint(id), hasQueuedRestock(id) [optional], unsyncedState(id), isDeleting(id) [optional],
//   inOrderQty(id) [optional], availableFor(product).
// A missing required hook makes every row disabled "unavailable" (fail closed), never addable.
// Optional hook (slice S3): commitCheck(plan) -> { ok, text }, the dialog's dry run of the order's completion (does
// the order still fit in one atomic operation?). Absent: no check. Present but throwing, not a function, or not saying
// ok: the draft cannot be committed (fail closed), with the hook's text when it gave one. It runs only when the cheap
// gate (PickerDraft.canCommit) already passed, so an empty or over-full draft costs nothing.

var REASON_TEXT = {
    "out-of-stock": "Out of stock",
    "order-full": "Order is full",
    "unavailable": "Not available right now"
}
var MAX_QUERY_SHOWN = 40
var CHECK_FAILED_TEXT = "Could not check this order. Try again"

function _isProduct(p) { return !!p && typeof p === "object" && typeof p.productId === "string" && p.productId.length > 0 }
function _num(n) { return (typeof n === "number" && isFinite(n)) ? n : 0 }
function _str(s) { return (typeof s === "string") ? s : ((s === undefined || s === null) ? "" : String(s)) }
function _has(o, k) { return !!o && typeof o === "object" && Object.prototype.hasOwnProperty.call(o, k) }

// Words for a disabled row. A reason this file does not know yet still gets words, never a silent dead row.
function reasonTextFor(reason) {
    return _has(REASON_TEXT, reason) ? REASON_TEXT[reason] : REASON_TEXT.unavailable
}

function priceOf(product) {
    if (!product || typeof product !== "object") return 0
    var p = (product.sellingPrice !== undefined) ? product.sellingPrice : product.price
    return (typeof p === "number" && isFinite(p) && p > 0) ? p : 0
}

// ["All", ...] the category chips: every distinct non-blank category of the catalog, case-insensitive,
// first spelling kept, sorted by name. Built from the whole catalog (not the visible rows), so a chip does not
// vanish while a product of that category is syncing.
function categories(products) {
    var seen = {}
    var list = []
    if (Array.isArray(products))
        for (var i = 0; i < products.length; ++i) {
            var p = products[i]
            if (!_isProduct(p)) continue
            var c = _str(p.category).trim()
            var key = c.toLowerCase()
            if (c === "" || _has(seen, key)) continue
            seen[key] = true
            list.push(c)
        }
    list.sort(function(a, b) {
        var x = a.toLowerCase(), y = b.toLowerCase()
        return x < y ? -1 : (x > y ? 1 : (a < b ? -1 : (a > b ? 1 : 0)))
    })
    return ["All"].concat(list)
}

function hiddenNote(count) {
    var n = _num(count)
    if (n <= 0) return ""
    return n === 1 ? "1 product hidden while it syncs" : n + " products hidden while they sync"
}

function _ctx(hooks, orderLines, draft) {
    var h = (hooks && typeof hooks === "object") ? hooks : {}
    return {
        hasPendingMint: h.hasPendingMint,
        hasQueuedRestock: h.hasQueuedRestock,
        unsyncedState: h.unsyncedState,
        isDeleting: h.isDeleting,
        inOrderQty: h.inOrderQty,
        availableFor: h.availableFor,
        inDraft: function(id) { return _has(draft, id) ? draft[id] : 0 },
        lineLimitReached: Draft.lineLimitReached(orderLines, draft)
    }
}

// The unit a row is counted in. The store defaults a blank unit to "pcs" (InventoryStore), so does the picker: a row
// never shows a bare number.
function _unitOf(p) {
    var u = typeof p.unit === "string" ? p.unit.trim() : ""    // only text is a unit: a number or an object is junk
    return u.length > 0 ? u : "pcs"
}

function _pill(row, p, unit) {
    if (row.visibility !== "enabled") {
        if (row.reason === Pick.REASON.outOfStock) return { status: "out of stock", label: "Out of stock" }
        if (row.reason === Pick.REASON.orderFull) return { status: "pending", label: "Order full" }
        return { status: "inactive", label: "Unavailable" }
    }
    var low = typeof p.minStock === "number" && isFinite(p.minStock) && row.available <= p.minStock
    return { status: low ? "low" : "active", label: row.available + " " + unit + " left" }
}

function _viewRow(row) {
    var p = row.product
    var unit = _unitOf(p)
    var pill = _pill(row, p, unit)
    var photo = (Array.isArray(p.photoIds) && typeof p.photoIds[0] === "string") ? p.photoIds[0] : ""
    var enabled = row.visibility === "enabled"
    return {
        productId: p.productId,
        name: _str(p.name).length > 0 ? _str(p.name) : p.productId,
        sku: _str(p.sku),
        category: _str(p.category),
        unit: unit,
        photoId: photo,
        price: priceOf(p),
        maxQty: _num(row.maxQty),
        qty: _num(row.inDraft),
        canAdd: enabled,
        reasonText: enabled ? "" : reasonTextFor(row.reason),
        pillStatus: pill.status,
        pillLabel: pill.label,
        inOrderLabel: row.inOrder > 0 ? "In this order: " + row.inOrder + " " + unit : "",
        atMax: enabled && row.inDraft >= row.maxQty    // enabled means maxQty >= 1, so this implies a quantity
    }
}

// True when the new rows are the same products in the same order as `prevIds`, so the sheet may update the
// list rows in place instead of resetting the list.
function sameOrder(prevIds, rows) {
    if (!Array.isArray(prevIds) || !Array.isArray(rows) || prevIds.length !== rows.length) return false
    for (var i = 0; i < rows.length; ++i)
        if (!rows[i] || prevIds[i] !== rows[i].productId) return false
    return true
}

// Two flat objects (a draft, a view row) hold the same keys with the same values. Values are strings, numbers or
// booleans, never undefined, so === is enough.
function _sameFlat(a, b) {
    if (!a || !b || typeof a !== "object" || typeof b !== "object") return false
    var ka = Object.keys(a), kb = Object.keys(b)
    if (ka.length !== kb.length) return false
    for (var i = 0; i < ka.length; ++i)
        if (!_has(b, ka[i]) || a[ka[i]] !== b[ka[i]]) return false
    return true
}

// True when two lists of strings are equal item by item. The sheet keeps the array it already gave the chips when
// this is true: a new array, even an equal one, makes the chip Repeater rebuild every chip (a flicker and a reset
// of the chip scroll position on every stepper tap and every key typed).
function sameList(a, b) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false
    for (var i = 0; i < a.length; ++i)
        if (a[i] !== b[i]) return false
    return true
}

// Indexes of the rows that differ from the rows the list shows now (`prev`), so the sheet calls ListModel.set for
// those only: a stepper tap changes one row, and setting every row of a catalog of thousands on each tap is the
// slow path. When `prev` is not the same length, or a row is junk, every index is returned (never a stale row).
function changedRows(prev, rows) {
    var out = []
    if (!Array.isArray(rows)) return out
    var same = Array.isArray(prev) && prev.length === rows.length
    for (var i = 0; i < rows.length; ++i)
        if (!same || !_sameFlat(prev[i], rows[i])) out.push(i)
    return out
}

function _emptyState(products, matched, rows, hiddenCount, query, inStockOnly) {
    if (rows.length > 0) return { kind: "", text: "" }
    var catalog = false
    if (Array.isArray(products))
        for (var i = 0; i < products.length && !catalog; ++i) catalog = _isProduct(products[i])
    if (!catalog) return { kind: "no-products", text: "There are no products to add yet." }
    if (hiddenCount > 0) return { kind: "all-hidden", text: "Everything that matches is still syncing." }
    if (inStockOnly && matched > 0) return { kind: "none-in-stock", text: "No in-stock product matches." }
    var q = _str(query).trim()
    if (q.length > MAX_QUERY_SHOWN) q = q.substring(0, MAX_QUERY_SHOWN) + "..."
    return { kind: "no-match", text: q.length > 0 ? "No products match \"" + q + "\"." : "No products in this category." }
}

// -> { ok, text }. See the commitCheck hook above.
function _check(hooks, draft, orderLines) {
    var h = (hooks && typeof hooks === "object") ? hooks : {}
    if (h.commitCheck === undefined || h.commitCheck === null) return { ok: true, text: "" }
    try {
        var r = h.commitCheck(Draft.commitPlan(draft, orderLines))
        if (r && r.ok === true) return { ok: true, text: "" }
        return { ok: false, text: (r && typeof r.text === "string" && r.text.length > 0) ? r.text : CHECK_FAILED_TEXT }
    } catch (e) {
        return { ok: false, text: CHECK_FAILED_TEXT }
    }
}

// input: { products, hooks, orderLines, draft, query, category, inStockOnly }
// -> { draft, draftChanged, rows, hiddenCount, hiddenNote, empty: {kind, text}, totals: {items, lines, amount},
//      canCommit: {ok, reason}, commitNote }   reason: "" | "empty" | "too-many-lines" | "check-failed"
// `draft` is the draft AFTER reconcile: a quantity above what the product can give now is clamped, one whose product
// became unavailable or left the catalog is dropped. The sheet writes it back when draftChanged. Never throws on junk.
function build(input) {
    var inp = input || {}
    var products = Array.isArray(inp.products) ? inp.products : []
    var orderLines = Array.isArray(inp.orderLines) ? inp.orderLines : []
    var draft0 = (inp.draft && typeof inp.draft === "object") ? inp.draft : {}

    var byId = {}
    for (var i = 0; i < products.length; ++i)
        if (_isProduct(products[i])) byId["k:" + products[i].productId] = products[i]

    // Reconcile over the WHOLE catalog, not just the visible rows: a draft survives filtering (rule 4).
    var ctx0 = _ctx(inp.hooks, orderLines, draft0)
    var draft = Draft.reconcile(draft0, function(id) {
        return Pick.classify(byId["k:" + id], ctx0).maxQty    // an id that left the catalog classifies as 0
    })

    var ctx = _ctx(inp.hooks, orderLines, draft)
    var matched = Search.filter(products, inp.query, { category: inp.category })
    var sum = Pick.summarize(matched, ctx, { inStockOnly: !!inp.inStockOnly })

    var rows = []
    for (var r = 0; r < sum.rows.length; ++r) rows.push(_viewRow(sum.rows[r]))

    var gate = Draft.canCommit(orderLines, draft)
    var note = gate.reason === "too-many-lines" ? "An order holds at most " + Draft.MAX_LINES + " lines." : ""
    if (gate.ok) {
        var chk = _check(inp.hooks, draft, orderLines)
        if (!chk.ok) { gate = { ok: false, reason: "check-failed" }; note = chk.text }
    }
    return {
        draft: draft,
        draftChanged: !_sameFlat(draft, draft0),
        rows: rows,
        hiddenCount: sum.hiddenCount,
        hiddenNote: hiddenNote(sum.hiddenCount),
        empty: _emptyState(products, matched.length, rows, sum.hiddenCount, inp.query, !!inp.inStockOnly),
        totals: Draft.totals(draft, function(id) { return _has(byId, "k:" + id) ? priceOf(byId["k:" + id]) : 0 }),
        canCommit: gate,
        commitNote: note
    }
}
