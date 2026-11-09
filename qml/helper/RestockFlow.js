.pragma library
.import "OperationKeys.js" as Keys

// Pure decisions around the restock wiring (atomic-ops R4). Design:
// docs/superpowers/specs/2026-11-02-r4-restock-wire-design.md. InventoryStore.restock stays thin and
// asks this file; every branch here runs in Node (functions/test/restockFlow.test.js) and in
// tests/tst_RestockFlow.qml. Nothing here reads a store, a clock or a random source.

// Review D-2 (PR #183 sweep). The cost field's text -> the `unitCost` to hand to makeInput. The dialog used to
// turn a blank, a typo or a negative into 0 before the plan could see it, so the plan's bad-cost refusal never
// ran and a mistyped cost was booked as a free batch (skews the batch cost and the profit). Now:
//   blank       -> NaN : "not given", makeInput falls back to the product's recorded cost (the field's own default)
//   a number    -> that number, negative included: the plan refuses it as bad-cost
//   anything else (letters, "1,5", "Infinity") -> -1 : the plan refuses it as bad-cost. Never silently 0.
// A typed 0 is still 0 (a free sample is a real case).
function costFromText(text) {
    var t = (typeof text === "string") ? text.trim() : ""
    if (t === "") return NaN
    var n = Number(t)
    return (isNaN(n) || !isFinite(n)) ? -1 : n
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

// Same rules as InventoryStore._resolveSupplierId (design R4-D5, review observation O1):
// empty -> no supplier; a "SUP-" prefix is an id (kept as typed, known or not: the server's batch and
// purchase only store it); otherwise a name that
// matches a known supplier case-insensitively is that supplier; anything else is a NEW supplier.
// `suppliers` = [{ supplierId, name }]. Names are trimmed first, so " Acme" matches "Acme" (the old
// path compared untrimmed text and would have made a duplicate). Whitespace-only text is refused.
// -> { ok: true, supplier: null | { id } | { newName } } | { ok: false, reason: "bad-supplier" }
function supplierFor(party, suppliers) {
    if (party === undefined || party === null || party === "") return { ok: true, supplier: null }
    var raw = String(party).trim()
    if (raw.length === 0) return { ok: false, reason: "bad-supplier" }
    var list = Array.isArray(suppliers) ? suppliers : []
    if (raw.indexOf("SUP-") === 0) return { ok: true, supplier: { id: raw } }
    var lower = raw.toLowerCase()
    for (var j = 0; j < list.length; ++j) {
        var s = list[j]
        if (s && typeof s.name === "string" && s.name.trim().toLowerCase() === lower && typeof s.supplierId === "string" && s.supplierId.length > 0)
            return { ok: true, supplier: { id: s.supplierId } }
    }
    return { ok: true, supplier: { newName: raw } }
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
// from here so the two cannot drift. The rest are app-side problems or free-text limits (R5 may refine).
function refusalText(reason) {
    switch (reason) {
    case "bad-quantity": return "Quantity must be greater than zero"
    case "bad-cost": return "Unit cost is not a valid amount"
    case "bad-supplier": return "Supplier name is not valid"
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
