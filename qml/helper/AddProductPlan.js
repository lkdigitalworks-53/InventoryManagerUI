.pragma library
.import "OperationKeys.js" as Keys
.import "DocLimits.js" as DocLimits

// Pure planner for the atomic add-product operation (atomic-ops AP2). Designs:
// docs/superpowers/specs/2026-11-13-add-product-atomic-operation-design.md (sections 2, 8, 9) and
// docs/superpowers/specs/2026-11-15-ap2-add-product-client-plan-design.md (this slice).
//
// build() turns "add this product with this opening stock" into the ordered op list the server applies in ONE
// transaction (functions/lib/operationLogic.js, opType addProduct): the server mints the product id, the batch id
// (only when stock > 0) and the supplier id (only for a new supplier name) inside the transaction, so a refused or
// repeated add burns nothing and duplicates nothing. The server derives the ledger row of the opening stock itself
// (a `receipt`, design D-AP-4), so the plan sends no movements. reflect() reads the server's results back.
//
// Nothing here reads a store or sends anything. Dormant until AP3 wires InventoryStore.addProduct to it.

var PRD = "prd"
var SUP = "sup"
var BAT = "batch"
var TOK_PRD = "{{prd}}"
var TOK_SUP = "{{sup}}"
var TOK_BAT = "{{batch}}"

var _DATE = /^\d{4}-\d{2}-\d{2}$/
// What Date.toISOString() gives. Stricter than the restock planner's "non-empty": `now` is stored in four docs, so a
// string that is not a timestamp (or holds `{{`) must never get that far.
var _ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/
var _PREFIX = "addProduct:"

// The regexes above prove a SHAPE only: 2026-13-45T25:61:61Z has it and no Date can read it (PR #201 sweep F1). A real
// instant parses AND comes back unchanged to the second, which also refuses 31 February (it rolls into March) and 24:00.
// The round trip, not Date.parse alone, so the answer does not depend on how lenient the engine's parser is.
function _realTime(s) {
    var t = Date.parse(s)
    return isFinite(t) && new Date(t).toISOString().substring(0, 19) === s.substring(0, 19)
}

// The two time checks of every planner (OrderPlan.js uses them too): an ISO instant as Date.toISOString() writes it, and a
// local date "yyyy-MM-dd", both REAL (see _realTime).
function isIsoInstant(s) { return typeof s === "string" && _ISO.test(s) && _realTime(s) }
function isIsoDate(s) { return typeof s === "string" && _DATE.test(s) && _realTime(s + "T00:00:00Z") }

function _refuse(reason) { return { ok: false, reason: reason } }
function _isNum(n) { return typeof n === "number" && isFinite(n) }
function _text(v) { return typeof v === "string" ? v : "" }
// Money to 2 places, like the order totals; a huge value is kept as it is (x * 100 can overflow to Infinity).
function _money(x) { var r = Math.round(x * 100) / 100; return isFinite(r) ? r : x }
// Cosmetic text is cut, never refused. Never splits a surrogate pair.
function _clip(s, n) {
    if (s.length <= n) return s
    var cut = s.substring(0, n)
    var last = cut.charCodeAt(n - 1)
    return (last >= 0xD800 && last <= 0xDBFF) ? cut.substring(0, n - 1) : cut
}

// D-AP-12: the server replaces `{{name}}` in every string of an op, so typed text holding `{{` or `}}` would be stored
// as an id (`{{prd}}`) or make the whole add a 400 (`{{$stock}}`). One space goes between every touching pair, so no
// `{{` or `}}` is left: `{{` -> `{ {`, `{{{` -> `{ { {`. A single brace and all other text are byte-identical.
function neutralisePlaceholders(s) {
    return _text(s).replace(/\{(?=\{)/g, "{ ").replace(/\}(?=\})/g, "} ")
}
// Typed text as it is stored: trimmed, then neutralised.
function _typed(s) { return neutralisePlaceholders(_text(s).trim()) }

function _create(entity, entityId, after) {
    return { kind: "mutation", entity: entity, entityId: entityId, action: "create", before: null, after: after }
}

function _nonceOf(key) { return key.substring(_PREFIX.length) }

// input = {
//   key            from Keys.addProductKey(...), made at the tap
//   name           non-empty after trimming
//   sku, category, unit, size, description   free text (may be "")
//   price          finite number >= 0;  sellingPrice finite >= 0 (the caller resolves the default = price first)
//   taxable        boolean;             taxPercent finite number in 0..100
//   stock          finite number >= 0 (the opening stock; 0 = no batch);  minStock finite >= 0
//   unitCost       finite number >= 0 (cost of the opening batch; the caller resolves the default first)
//   supplier       null (none) | { id } (a known supplier) | { newName } (create one inside the operation)
//   now            ISO timestamp (Date.toISOString()), date "yyyy-MM-dd" (the caller formats the local date)
// }
// Returns { ok: true, key, opType: "addProduct", ops, at }  (`at` = index of each op, -1 when absent)
//      or { ok: false, reason } with reason one of: bad-key, bad-name, bad-price, bad-tax, bad-stock, bad-cost,
//         bad-supplier, bad-time, too-large. Nothing is built for a refused input.
function build(input) {
    var inp = (input && typeof input === "object") ? input : {}
    if (!Keys.isAddProductKey(inp.key)) return _refuse("bad-key")
    var name = _typed(inp.name)
    if (name.length === 0) return _refuse("bad-name")
    if (!_isNum(inp.price) || inp.price < 0 || !_isNum(inp.sellingPrice) || inp.sellingPrice < 0) return _refuse("bad-price")
    if (typeof inp.taxable !== "boolean" || !_isNum(inp.taxPercent) || inp.taxPercent < 0 || inp.taxPercent > 100) return _refuse("bad-tax")
    if (!_isNum(inp.stock) || inp.stock < 0 || !_isNum(inp.minStock) || inp.minStock < 0) return _refuse("bad-stock")
    // Each factor is finite but the product can overflow (1e308 * 5): JSON turns Infinity into null and the stored
    // `total` would break every sum over the history. Whichever factor is the huge one, it is a cost problem.
    if (!_isNum(inp.unitCost) || inp.unitCost < 0 || !_isNum(inp.stock * inp.unitCost)) return _refuse("bad-cost")
    if (!isIsoInstant(inp.now) || !isIsoDate(inp.date)) return _refuse("bad-time")

    var sup = inp.supplier
    var supplierId = ""          // what the product, the batch and the history carry
    var newName = ""
    if (sup !== null && sup !== undefined) {
        if (typeof sup !== "object") return _refuse("bad-supplier")
        if (typeof sup.newName === "string") {
            newName = _typed(sup.newName)
            if (newName.length === 0) return _refuse("bad-supplier")
            supplierId = TOK_SUP
        } else if (typeof sup.id === "string" && sup.id.length > 0 && sup.id.indexOf("{{") < 0 && sup.id.indexOf("}}") < 0) {
            // A known id comes from the supplier store; one holding a brace pair is no id (the server would rewrite it).
            supplierId = sup.id
        } else {
            return _refuse("bad-supplier")
        }
    }

    var nonce = _nonceOf(inp.key)
    var sku = _typed(inp.sku)
    var category = _typed(inp.category)
    var unit = _typed(inp.unit)
    var size = _typed(inp.size)
    var description = _typed(inp.description)
    var stock = inp.stock
    var hasBatch = stock > 0
    var createdId = Keys.createdTxId(TOK_PRD, nonce)
    var actId = Keys.productAddedActId(TOK_PRD, nonce)

    var ops = []
    var at = { productMint: -1, supplierMint: -1, batchMint: -1, supplierCreate: -1, productCreate: -1,
               batchCreate: -1, created: -1, activity: -1 }

    at.productMint = ops.length; ops.push({ kind: "mint", counter: "product", bind: PRD })
    if (newName.length > 0) { at.supplierMint = ops.length; ops.push({ kind: "mint", counter: "supplier", bind: SUP }) }
    if (hasBatch) { at.batchMint = ops.length; ops.push({ kind: "mint", counter: "stock_batch", bind: BAT }) }

    if (newName.length > 0) {
        at.supplierCreate = ops.length
        ops.push(_create("supplier", TOK_SUP, {
            supplierId: TOK_SUP, name: newName, contact: "", leadTimeDays: 0,
            terms: "", notes: "", createdAt: inp.now, updatedAt: inp.now
        }))
    }

    // The shape InventoryStore._newProductDoc has always sent (a drift test pins the key list).
    at.productCreate = ops.length
    ops.push(_create("inventory", TOK_PRD, {
        productId: TOK_PRD, name: name, sku: sku, category: category, stock: stock, minStock: inp.minStock,
        price: inp.price, sellingPrice: inp.sellingPrice, taxable: inp.taxable, taxPercent: inp.taxPercent,
        size: size, unit: unit, description: description, photoIds: [], supplierId: supplierId
    }))

    if (hasBatch) {
        at.batchCreate = ops.length
        ops.push(_create("stock_batch", TOK_BAT, {
            batchId: TOK_BAT, productId: TOK_PRD, supplierId: supplierId,
            qtyReceived: stock, qtyRemaining: stock, unitCost: inp.unitCost,
            receivedDate: inp.now, poId: "", note: "Initial stock", createdAt: inp.now, updatedAt: inp.now
        }))
    }

    // The "created" history row exists even for stock 0, so the product's history opens with a true creation row.
    var snapshot = { sku: sku, category: category, unit: unit, sellingPrice: inp.sellingPrice, taxable: inp.taxable,
                     taxPercent: inp.taxPercent, size: size, minStock: inp.minStock, description: description,
                     supplierId: supplierId }
    if (supplierId !== "") snapshot.party = supplierId
    at.created = ops.length
    ops.push(_create("transaction", createdId, {
        txId: createdId, kind: "created", timestamp: inp.now, date: inp.date,
        productId: TOK_PRD, productName: name, category: category, party: supplierId,
        quantity: stock, unitCost: inp.unitCost, unitPrice: 0, total: _money(stock * inp.unitCost),
        orderId: "", snapshot: snapshot
    }))

    // The feed row is inside the operation (the server adds actorUid and the timestamp). Same wording the client
    // row always had. No stock token: the client knows the opening stock (server rule D-AP-5).
    at.activity = ops.length
    ops.push(_create("activity", actId, {
        id: actId, kind: "product_added", title: "Product added: " + _clip(name, 150),
        subtitle: (sku ? _clip(sku, 100) + " \u00b7 " : "") + "stock " + stock,
        entityId: TOK_PRD, read: false, dismissed: false
    }))

    // Firestore refuses a doc over 1 MiB; a rejected operation queued in the outbox would retry or park for nothing.
    // The description is the real risk. Refuse before anything is queued; the server stays the authority.
    for (var d = 0; d < ops.length; ++d)
        if (ops[d].kind === "mutation" && DocLimits.exceedsDoc(ops[d].after)) return _refuse("too-large")

    return { ok: true, key: inp.key, opType: "addProduct", ops: ops, at: at }
}

// Reads the server's results for an add (a live answer or a stored replay) into plain docs. It uses only what the
// results themselves say, never the plan, so it works after a relaunch when the plan is gone. Anything that is not
// exactly one add answer is refused (a half-understood result must never be applied to the local stores).
// -> { ok: true, productId, stock, product, batchId ("" when stock 0), batch (doc or null), supplierId, supplier (doc or
//      null), created, activity }
//  | { ok: false, reason: "malformed-results", detail }
function reflect(results) {
    function bad(detail) { return { ok: false, reason: "malformed-results", detail: detail } }
    if (!Array.isArray(results)) return bad("not-a-list")

    var ids = { prd: "", sup: "", batch: "" }
    var docs = { inventory: null, stock_batch: null, supplier: null, transaction: null, activity: null }
    var count = { inventory: 0, stock_batch: 0, supplier: 0, transaction: 0, activity: 0 }
    var mints = 0

    for (var i = 0; i < results.length; ++i) {
        var r = results[i]
        if (!r || typeof r !== "object") return bad("entry-" + i)
        if (r.kind === "mint") {
            if (typeof r.id !== "string" || r.id.length === 0 || !Object.prototype.hasOwnProperty.call(ids, r.bind)) return bad("mint-id")
            if (ids[r.bind] !== "") return bad("mint-twice")
            ids[r.bind] = r.id
            mints++
        } else if (r.kind === "mutation") {
            if (!r.after || typeof r.after !== "object" || !Object.prototype.hasOwnProperty.call(count, r.entity)) return bad("mutation")
            count[r.entity]++
            docs[r.entity] = r.after
        } else {
            return bad("kind-" + i)
        }
    }

    if (ids.prd === "") return bad("no-product-mint")
    if (count.inventory !== 1 || count.transaction !== 1 || count.activity !== 1 || count.stock_batch > 1 || count.supplier > 1) return bad("shape")
    var product = docs.inventory
    var stock = product.stock
    if (product.productId !== ids.prd || !_isNum(stock) || stock < 0) return bad("product-doc")

    // A batch exists exactly when stock > 0, and its mint with it.
    if (stock > 0) {
        if (ids.batch === "" || count.stock_batch !== 1) return bad("batch-missing")
        var batch = docs.stock_batch
        if (batch.batchId !== ids.batch || batch.productId !== ids.prd || batch.qtyReceived !== stock || batch.qtyRemaining !== stock) return bad("batch-doc")
    } else if (ids.batch !== "" || count.stock_batch !== 0) {
        return bad("batch-without-stock")
    }

    // A supplier doc exists exactly when its id was minted, and the product and batch carry it.
    if (ids.sup !== "") {
        if (count.supplier !== 1 || docs.supplier.supplierId !== ids.sup || product.supplierId !== ids.sup
            || (stock > 0 && docs.stock_batch.supplierId !== ids.sup)) return bad("supplier-doc")
    } else if (count.supplier !== 0) {
        return bad("supplier-without-mint")
    }

    // The two history rows carry the same operation nonce (D-AP-11), taken from the ids themselves.
    var txPrefix = "tx-c-" + ids.prd + "-"
    var actPrefix = "act-" + ids.prd + "-"
    var created = docs.transaction
    var activity = docs.activity
    if (typeof created.txId !== "string" || created.txId.indexOf(txPrefix) !== 0 || created.kind !== "created" || created.productId !== ids.prd)
        return bad("created-doc")
    if (typeof activity.id !== "string" || activity.id.indexOf(actPrefix) !== 0 || activity.kind !== "product_added"
        || activity.entityId !== ids.prd || typeof activity.timestamp !== "string"
        || activity.id.substring(actPrefix.length) !== created.txId.substring(txPrefix.length))
        return bad("activity-doc")

    return { ok: true, productId: ids.prd, stock: stock, product: product,
             batchId: ids.batch, batch: stock > 0 ? docs.stock_batch : null,
             supplierId: ids.sup !== "" ? ids.sup : _text(product.supplierId), supplier: docs.supplier,
             created: created, activity: activity }
}
