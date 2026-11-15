"use strict";

// P1 (CGST Rule 56(2)) stock-movement ledger rows. Rows are built HERE, on the
// server, inside the same transaction as the stock change. The client may say
// WHAT happened (kind, signed qty, reason, valueAtCost); when it says nothing,
// the server derives a default row, so no stock change can leave the ledger.
// Row id, productId, actor, role and times are always stamped by the server, so
// the ledger cannot be forged by a client. Pure module: no Firebase dependency.

// Direction of the stock change each kind may carry: +1 increases stock,
// -1 decreases it, 0 either way. `sales_return` is the one kind beyond the
// spec's nine (see specs/2026-09-24-p1-server-side-stock-movements-design.md).
const KIND_DIRECTION = {
    receipt: 1,
    sales_return: 1,
    sale: -1,
    loss: -1,
    theft: -1,
    destroyed: -1,
    write_off: -1,
    free_sample: -1,
    gift: -1,
    adjustment: 0
};
const MOVEMENT_KINDS = Object.keys(KIND_DIRECTION);

// P1 S2e-1 reason policy (design docs/superpowers/specs/2026-11-13-p1-s2e1-reason-policy-and-cost-design.md).
// A kind in REASON_REQUIRED cannot be recorded without a reason of at least MIN_REASON_LENGTH characters
// (after trim): these are the events an auditor, an insurer or a tax officer asks "what happened" about, and
// all of them are ITC-blocked under CGST 17(5)(h). free_sample is optional on purpose (high volume, and the ITC
// block on it is under review), adjustment and the supply kinds are optional. Mirrored client side in
// qml/helper/StockMovements.js; functions/test/stockMovementsParity.test.js fails when they drift.
const REASON_REQUIRED = ["loss", "theft", "destroyed", "write_off", "gift"];
const MIN_REASON_LENGTH = 3;

// Kinds whose cost value the SERVER stamps (the six non-supply outward events of CGST 56(2)): qty x the
// product's cost (`price`, as stored when the row is written), never a client-sent number.
const VALUE_KINDS = ["loss", "theft", "destroyed", "write_off", "free_sample", "gift"];

// Default kind for a stock change the client did not describe, by operation.
// Anything else defaults to "adjustment".
const DEFAULT_KIND_BY_OPTYPE = { completeOrder: "sale" };

// Explicit movements per recordDelta request.
const MAX_MOVEMENTS = 50;
// Firestore's per-transaction write ceiling. Every write path must keep
// (working docs + audit entries + movement rows [+ marker]) under it.
const MAX_TXN_WRITES = 500;
const MAX_REASON = 500;
// Quantities may be fractional; tolerate float noise, nothing more.
const EPSILON = 1e-9;

function _fail(error) {
    return { ok: false, status: 400, error: error };
}

// raw: undefined/null (no movements) or a non-empty array of
// { kind, qty, reason?, valueAtCost? }. Returns
// { ok: true, movements: [normalized...] } or { ok: false, status, error }.
function validateMovements(raw) {
    if (raw === undefined || raw === null) return { ok: true, movements: [] };
    if (!Array.isArray(raw) || raw.length === 0) return _fail("invalid-movements");
    if (raw.length > MAX_MOVEMENTS) return _fail("too-many-movements");

    const movements = [];
    for (const m of raw) {
        if (!m || typeof m !== "object") return _fail("invalid-movements");
        if (MOVEMENT_KINDS.indexOf(m.kind) < 0) return _fail("invalid-movement-kind");

        if (typeof m.qty !== "number" || !isFinite(m.qty) || m.qty === 0) return _fail("invalid-movement-qty");
        const direction = KIND_DIRECTION[m.kind];
        if (direction !== 0 && Math.sign(m.qty) !== direction) return _fail("invalid-movement-qty");

        const value = m.valueAtCost === undefined ? 0 : m.valueAtCost;
        if (typeof value !== "number" || !isFinite(value) || value < 0) return _fail("invalid-movement-value");

        const reason = (m.reason === undefined || m.reason === null) ? "" : m.reason;
        if (typeof reason !== "string" || reason.length > MAX_REASON) return _fail("invalid-movement-reason");

        const trimmed = reason.trim();
        if (REASON_REQUIRED.indexOf(m.kind) >= 0 && trimmed.length < MIN_REASON_LENGTH) return _fail("movement-reason-required");

        movements.push({ kind: m.kind, qty: m.qty, reason: trimmed, valueAtCost: value, derived: false });
    }
    return { ok: true, movements: movements };
}

// The ledger must agree with the stock change it explains: the movements'
// signed quantities sum to exactly the delta the server APPLIED (after floors
// and clamps), never the delta the client asked for.
function totalsMatch(movements, appliedDelta) {
    let sum = 0;
    for (const m of movements) sum += m.qty;
    return Math.abs(sum - appliedDelta) <= EPSILON;
}

// Server-derived row for a stock change the client did not describe. Zero
// change derives nothing. If defaultKind contradicts the direction of the
// change (e.g. "sale" on an increase) the row falls back to "adjustment".
function deriveMovement(appliedDelta, defaultKind) {
    if (!isFinite(appliedDelta) || Math.abs(appliedDelta) <= EPSILON) return [];
    const direction = KIND_DIRECTION[defaultKind];
    const kind = (direction === undefined || (direction !== 0 && Math.sign(appliedDelta) !== direction))
        ? "adjustment" : defaultKind;
    return [{ kind: kind, qty: appliedDelta, reason: "", valueAtCost: 0, derived: true }];
}

// The stock a working doc carries; anything absent or non-numeric counts as 0.
function stockOf(doc) {
    return (doc && typeof doc.stock === "number" && isFinite(doc.stock)) ? doc.stock : 0;
}

// Server-derived row for a whole-record inventory mutation, from the stock before
// and after: create => receipt, update / delete / anything else => adjustment.
// Delete counts as the stock going to 0 (whatever `after` carries). P1 spec D11.
function deriveForMutation(action, before, after) {
    const delta = (action === "delete" ? 0 : stockOf(after)) - stockOf(before);
    return deriveMovement(delta, action === "create" ? "receipt" : "adjustment");
}

// The product name a ledger row carries, so a deleted product stays readable in the stock register
// (the inventory doc is gone, the row is not). Only a non-empty string survives: trimmed and capped at
// MAX_PRODUCT_NAME. Anything else is `undefined`, and buildRows then omits the field (Firestore rejects
// an `undefined` value, and a blank name would hide a real one that came earlier).
const MAX_PRODUCT_NAME = 200;
function cleanProductName(v) {
    if (typeof v !== "string") return undefined;
    const t = v.trim();
    if (t === "") return undefined;
    let cut = t.slice(0, MAX_PRODUCT_NAME);
    // A cap that lands between the two halves of a surrogate pair (an emoji) would leave a lone half,
    // which the wire turns into U+FFFD. Drop the orphan half instead (PR #195 review).
    const last = cut.charCodeAt(cut.length - 1);
    if (cut.length < t.length && last >= 0xD800 && last <= 0xDBFF) cut = cut.slice(0, -1);
    return cut.trim();
}

// ONE place that picks the name for a write: the document AFTER the change, else the one before it
// (a delete has no after). Either may be null or lack a name.
function nameFor(before, after) {
    const fromAfter = after && typeof after === "object" ? cleanProductName(after.name) : undefined;
    if (fromAfter !== undefined) return fromAfter;
    return before && typeof before === "object" ? cleanProductName(before.name) : undefined;
}

// One { id, data } per movement. ctx: { baseId, productId, actorUid, actorRole,
// serverTimestamp, clientTimestamp, requestId, productName?, operationId?, opType?, opIndex? }.
// `baseId` is the audit_log id of the write that carries the movements, so a
// retried request (which replays from that audit entry) never writes a row twice.
// The product's cost per unit as stored (`price` is COST in this app, `sellingPrice` is what customers pay).
// 0 when the product has no usable cost: a loss must still be recorded, so a missing cost is never an error.
function unitCostOf(doc) {
    const c = doc && typeof doc === "object" ? doc.price : undefined;
    return (typeof c === "number" && isFinite(c) && c > 0) ? c : 0;
}

// valueAtCost of one movement: stamped for VALUE_KINDS (client value ignored), untouched otherwise.
// Rounded to paise. `unitCost` undefined means the caller has no product doc: leave the value as it is.
function valueFor(m, unitCost) {
    if (unitCost === undefined || VALUE_KINDS.indexOf(m.kind) < 0) return m.valueAtCost;
    // Round half-up to paise. The absolute 1e-6 paise nudge undoes binary float error at exact halves
    // (2.5 x 19.99 is 49.974999999999994 in floats, but 49.975 on paper = 49.98). It is ABSOLUTE, not relative:
    // a relative nudge would move a big honest value (1e13 paise) by whole paise.
    const v = Math.round(Math.abs(m.qty) * unitCost * 100 + 1e-6) / 100;
    return isFinite(v) ? v : 0;
}

function buildRows(movements, ctx) {
    return movements.map(function (m, j) {
        const id = ctx.baseId + "~m" + j;
        const data = {
            id: id,
            productId: ctx.productId,
            kind: m.kind,
            qty: m.qty,
            reason: m.reason,
            valueAtCost: valueFor(m, ctx.unitCost),
            derived: m.derived === true,
            actorUid: ctx.actorUid,
            actorRole: ctx.actorRole,
            serverTimestamp: ctx.serverTimestamp,
            clientTimestamp: ctx.clientTimestamp,
            requestId: ctx.requestId
        };
        const productName = cleanProductName(ctx.productName);
        if (productName !== undefined) data.productName = productName;
        if (ctx.operationId !== undefined) {
            data.operationId = ctx.operationId;
            data.opType = ctx.opType;
            data.opIndex = ctx.opIndex;
        }
        return { id: id, data: data };
    });
}

module.exports = {
    KIND_DIRECTION, MOVEMENT_KINDS, REASON_REQUIRED, MIN_REASON_LENGTH, VALUE_KINDS, unitCostOf, valueFor, DEFAULT_KIND_BY_OPTYPE, MAX_MOVEMENTS, MAX_REASON, MAX_TXN_WRITES, MAX_PRODUCT_NAME,
    cleanProductName, nameFor, validateMovements, totalsMatch, deriveMovement, stockOf, deriveForMutation, buildRows
};
