.pragma library
.import "OperationKeys.js" as Keys
.import "StockMovements.js" as SM

// Pure decisions around the restock wiring (atomic-ops R4). Design:
// docs/superpowers/specs/2026-11-02-r4-restock-wire-design.md. InventoryStore.restock stays thin and
// asks this file; every branch here runs in Node (functions/test/restockFlow.test.js) and in
// tests/tst_RestockFlow.qml. Nothing here reads a store, a clock or a random source.

// Review R5a (design 2026-11-10-r5a-restock-dialog-design.md, D-R5-4/5/6). Field limits the dialog enforces while typing
// (maxLength) and this file enforces again at the tap (a pasted value can exceed maxLength on some platforms, a caller
// other than the dialog may not enforce it at all).
//   MAX_REASON         = the server's movement-reason limit (SM.MAX_REASON, pinned equal by a test). The reason is
//                        written to the ledger row, the batch note and the purchase row; StockMovements.make cuts the
//                        ledger copy at this length, so a longer text used to be whole in two docs and cut in the third.
//   MAX_SUPPLIER_NAME  = a name that fits a list row and a report column; no server rule exists, this is the app's own.
//   MAX_UNIT_COST      = a FINITE per-unit cost above this is a typo, not a price (1e9 rupees). Keeps qty * cost (qty <= 9999)
//                        far below the double range, so the plan's overflow refusal stays a backstop.
var MAX_REASON = SM.MAX_REASON
var MAX_SUPPLIER_NAME = 100
var MAX_UNIT_COST = 1000000000

// Review D-2 (PR #183 sweep). The cost field's text -> the `unitCost` to hand to makeInput. The dialog used to
// turn a blank, a typo or a negative into 0 before the plan could see it, so the plan's bad-cost refusal never
// ran and a mistyped cost was booked as a free batch (skews the batch cost and the profit). Now:
//   blank       -> NaN : "not given", makeInput falls back to the product's recorded cost (the field's own default)
//   a number    -> that number, negative included: the plan refuses it as bad-cost
//   anything else (letters, "1,5", "Infinity") -> -1 : the plan refuses it as bad-cost. Never silently 0.
// A typed 0 is still 0 (a free sample is a real case).
// PR #191 sweep: `Number()` also reads "0x10" (16), "0b11" (3), "0o7" (7) and "1e3" (1000), so a mistyped cost was
// booked as a different price with no refusal (desktop keyboards are not limited by ImhFormattedNumbersOnly). Only a
// plain decimal is a cost: optional sign, digits, optional fraction ("5." and ".5" are fine).
var _PLAIN_DECIMAL = /^[+-]?(\d+\.?\d*|\.\d+)$/
function costFromText(text) {
    var t = (typeof text === "string") ? text.trim() : ""
    if (t === "") return NaN
    if (!_PLAIN_DECIMAL.test(t)) return -1
    var n = Number(t)
    return isFinite(n) ? n : -1
}

// PR #191 sweep. The "Use" button of the new-supplier row holds the typed name; text still sitting in that field at
// the Confirm tap was never "Use"d and was silently dropped (the restock booked with no supplier). Confirm refuses
// instead of guessing: auto-using a half-typed name could create a supplier nobody meant.
// -> "" (nothing pending) | the message to show
function unusedPartyText(text) {
    return (typeof text === "string" && text.trim().length > 0)
        ? "You typed a new supplier name. Tap Use to add it, or clear the field" : ""
}

// Review D-C (PR #188 sweep). The Add-quantity field is an editable SpinBox: typed text becomes `value` only on
// Enter or focus loss, and nothing guarantees the Confirm tap moves focus first. Reading `value` then books the
// OLD number (type 25, tap Confirm, +10 is booked): wrong stock and a wrong ledger row, with no undo. So the tap
// reads the typed text itself, with the SpinBox's own parser (`valueFromText`, locale aware), and refuses what
// the field would have to guess about.
//   field = the SpinBox: { value, from, to, locale, valueFromText(text, locale), contentItem: { text } }
//   -> { ok: true, qty }                      a whole number from..to (the committed value when the text cannot be read)
//   -> { ok: false, message }                 empty, not a number, a fraction, or outside from..to: nothing is sent
// Never clamps: 100000 typed is not silently booked as 9999.
function qtyFromField(field) {
    var lo = (field && typeof field.from === "number") ? field.from : 1
    var hi = (field && typeof field.to === "number") ? field.to : 9999
    var bad = { ok: false, message: "Enter a whole quantity from " + lo + " to " + hi }
    if (!field || typeof field !== "object") return bad
    var typed = (field.contentItem && typeof field.contentItem.text === "string") ? field.contentItem.text.trim() : null
    if (typed === null || typeof field.valueFromText !== "function") {
        // The text cannot be read (a style without a TextInput): the committed value is all there is.
        var v = field.value
        return (typeof v === "number" && isFinite(v) && Math.floor(v) === v && v >= lo && v <= hi) ? { ok: true, qty: v } : bad
    }
    var n
    try { n = field.valueFromText(typed, field.locale) } catch (e) { return bad }
    if (typeof n !== "number" || !isFinite(n) || Math.floor(n) !== n || n < lo || n > hi) return bad
    return { ok: true, qty: n }
}

// The key made at the tap. "" only if the nonce is not a plain token (cannot happen with restockNonce).
function newKey(nowMs, random) {
    return Keys.restockKey(Keys.restockNonce(nowMs, random))
}

function _pad(n) { return (n < 10 ? "0" : "") + n }

// "yyyy-MM-dd" in the device's local time, the format the purchase row's `date` always had.
function localDate(d) {
    return d.getFullYear() + "-" + _pad(d.getMonth() + 1) + "-" + _pad(d.getDate())
}

// Same rules as InventoryStore._resolveSupplierId (design R4-D5, review observation O1), now also for a
// STRUCTURED party (R5a, D-R5-2):
//   party = "" / null / undefined      no supplier
//   party = "SUP-..."  (string)        an id, kept as typed (known or not: the batch and the purchase only store it)
//   party = "Acme"     (string)        a name: a known supplier case-insensitively, otherwise a NEW supplier
//   party = { id }                     an id, always (never reinterpreted)
//   party = { newName }                a NAME, always: a known supplier case-insensitively (so a second device or a
//                                      retyped name does not make a duplicate), otherwise a NEW supplier. A name that
//                                      happens to start with "SUP-" is still a name here; the plain string form would
//                                      have read it as an id and stored a supplier id that exists nowhere.
// Names are trimmed first, so " Acme" matches "Acme". Whitespace-only is refused, and so is a name longer than
// MAX_SUPPLIER_NAME (reason "supplier-too-long"). `suppliers` = [{ supplierId, name }].
// -> { ok: true, supplier: null | { id } | { newName } } | { ok: false, reason: "bad-supplier" | "supplier-too-long" }
function _knownByName(lower, list) {
    for (var j = 0; j < list.length; ++j) {
        var s = list[j]
        if (s && typeof s.name === "string" && s.name.trim().toLowerCase() === lower && typeof s.supplierId === "string" && s.supplierId.length > 0)
            return s.supplierId
    }
    return ""
}
function _byName(raw, list) {
    // PR #191 sweep: a name that IS a known supplier is that supplier whatever its length (legacy or imported names
    // can exceed the limit, and refusing them would force a duplicate); the limit only guards a NEW name.
    var known = _knownByName(raw.toLowerCase(), list)
    if (known !== "") return { ok: true, supplier: { id: known } }
    if (raw.length > MAX_SUPPLIER_NAME) return { ok: false, reason: "supplier-too-long" }
    return { ok: true, supplier: { newName: raw } }
}
function supplierFor(party, suppliers) {
    if (party === undefined || party === null || party === "") return { ok: true, supplier: null }
    var list = Array.isArray(suppliers) ? suppliers : []
    if (typeof party === "object") {
        if (typeof party.newName === "string") {
            var nn = party.newName.trim()
            return nn.length === 0 ? { ok: false, reason: "bad-supplier" } : _byName(nn, list)
        }
        if (typeof party.id === "string" && party.id.trim().length > 0) return { ok: true, supplier: { id: party.id.trim() } }
        return { ok: false, reason: "bad-supplier" }
    }
    var raw = String(party).trim()
    if (raw.length === 0) return { ok: false, reason: "bad-supplier" }
    if (raw.indexOf("SUP-") === 0) return { ok: true, supplier: { id: raw } }
    return _byName(raw, list)
}

// What the restock dialog hands to InventoryStore.restock as `party` (R5a, D-R5-2). A typed NEW supplier name wins over
// the picker (the dialog clears it when the person picks a row, so both are never set at once); otherwise the picked
// id, or "" for the placeholder row. `ids` = the picker's id list (index 0 is ""). A bad or out-of-range index is "no supplier"
// (an index with no string behind it, such as 99, -1, 1.5 or NaN, falls through the typeof check).
function partyFor(newName, index, ids) {
    var typed = (typeof newName === "string") ? newName.trim() : ""
    if (typed.length > 0) return { newName: typed }
    var list = Array.isArray(ids) ? ids : []
    return (typeof index === "number" && index > 0 && typeof list[index] === "string") ? list[index] : ""
}

// The dialog's "Use" button for the typed new-supplier name (R5a, D-R5-1). Nothing is created here: the supplier is
// created INSIDE the restock operation, so a restock that fails leaves no orphan supplier and burns no number.
//   -> { kind: "none" }                          empty text: nothing to do
//   -> { kind: "invalid", message }              over-long text
//   -> { kind: "existing", id, name }            matches a known supplier (case-insensitive): pick that row, make nothing
//   -> { kind: "new", name }                     a new supplier, created with the restock
function newPartyChoice(text, suppliers) {
    var raw = (typeof text === "string") ? text.trim() : ""
    if (raw.length === 0) return { kind: "none" }
    var r = supplierFor({ newName: raw }, suppliers)
    if (!r.ok) return { kind: "invalid", message: refusalText(r.reason) }
    if (r.supplier.id !== undefined) {
        var list = Array.isArray(suppliers) ? suppliers : []
        var name = raw
        for (var i = 0; i < list.length; ++i) if (list[i] && list[i].supplierId === r.supplier.id) name = String(list[i].name)
        return { kind: "existing", id: r.supplier.id, name: name }
    }
    return { kind: "new", name: r.supplier.newName }
}

// Builds RestockPlan.build's input from what the tap knows. `now` is ONE Date: the ISO timestamp and
// the local date both come from it (O4), so a tap at 23:59:59.9 cannot get two different days.
// a = { key, product, qty, unitCost, reason, party, suppliers, now }
// `unitCost` that is not a number falls back to the product's cost, then 0 (the old default).
// -> { ok: true, input } | { ok: false, reason }
function makeInput(a) {
    var p = (a && a.product && typeof a.product === "object") ? a.product : null
    if (p === null) return { ok: false, reason: "bad-product" }
    if (Object.prototype.toString.call(a.now) !== "[object Date]" || isNaN(a.now.getTime())) return { ok: false, reason: "bad-time" }
    var sup = supplierFor(a.party, a.suppliers)
    if (!sup.ok) return sup
    // R5a: limits. The text is measured trimmed (the planner trims it too); a non-string reason is the planner's to ignore.
    if (typeof a.reason === "string" && a.reason.trim().length > MAX_REASON) return { ok: false, reason: "reason-too-long" }
    if (typeof a.unitCost === "number" && isFinite(a.unitCost) && a.unitCost > MAX_UNIT_COST) return { ok: false, reason: "cost-too-large" }
    var cost = (typeof a.unitCost === "number" && !isNaN(a.unitCost)) ? a.unitCost : (typeof p.price === "number" ? p.price : 0)
    return { ok: true, input: {
        key: a.key, productId: p.productId, productName: p.name, category: p.category,
        qty: a.qty, unitCost: cost, reason: a.reason,
        now: a.now.toISOString(), date: localDate(a.now), supplier: sup.supplier
    } }
}

// How a Gateway.recordOperation callback result must be treated.
//   "applied"  the server answered in time ({ ok: true, results })
//   "queued"   not answered (offline, not awaiting, or the await window ran out: { ok: false, pending })
//   "rejected" everything else (a server refusal, a discard, bad-request, anything unreadable)
function classify(res) {
    if (!res || typeof res !== "object") return "rejected"
    if (res.ok === true) return res.queued === true ? "queued" : "applied"
    return res.pending === true ? "queued" : "rejected"
}

// Person-facing text for a refusal made BEFORE anything is queued (RestockPlan.build's reasons).
// bad-quantity is the one text the dialogs already showed; InventoryStore.restockQtyRefusal reads it
// from here so the two cannot drift. The rest are app-side problems or field limits (R5a added the three limit texts).
function refusalText(reason) {
    switch (reason) {
    case "bad-quantity": return "Quantity must be greater than zero"
    case "bad-cost": return "Unit cost is not a valid amount"
    case "cost-too-large": return "Unit cost is too large. Enter the price of ONE unit, up to " + MAX_UNIT_COST
    case "bad-supplier": return "Supplier name is not valid"
    case "supplier-too-long": return "Supplier name is too long. Use at most " + MAX_SUPPLIER_NAME + " characters"
    case "reason-too-long": return "The reason is too long. Use at most " + MAX_REASON + " characters"
    case "too-large": return "The note is too long to save. Shorten it and try again"
    case "reserved-text": return "Remove any {{ or }} from the text and try again"
    }
    return "Could not restock (" + String(reason) + "). Please report this"
}

// The Activity entry of a settled restock, from RestockPlan.reflect's outcome alone (the plan is gone
// after a relaunch). Same wording the old restock wrote. `supplierName` may be "".
// -> { title, subtitle }
function activityText(out, supplierName) {
    var reason = (out.batch && typeof out.batch.note === "string") ? out.batch.note : ""
    var qty = out.batch ? out.batch.qtyReceived : 0
    return {
        title: "Restocked: " + (out.purchase ? out.purchase.productName : ""),
        subtitle: "+" + qty + " · now " + out.stock + " in stock"
                  + (supplierName ? " · from " + supplierName : "")
                  + (reason ? " · " + reason : "")
    }
}
