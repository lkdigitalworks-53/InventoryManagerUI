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

        movements.push({ kind: m.kind, qty: m.qty, reason: reason.trim(), valueAtCost: value, derived: false });
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

// One { id, data } per movement. ctx: { baseId, productId, actorUid, actorRole,
// serverTimestamp, clientTimestamp, requestId, operationId?, opType?, opIndex? }.
// `baseId` is the audit_log id of the write that carries the movements, so a
// retried request (which replays from that audit entry) never writes a row twice.
function buildRows(movements, ctx) {
    return movements.map(function (m, j) {
        const id = ctx.baseId + "~m" + j;
        const data = {
            id: id,
            productId: ctx.productId,
            kind: m.kind,
            qty: m.qty,
            reason: m.reason,
            valueAtCost: m.valueAtCost,
            derived: m.derived === true,
            actorUid: ctx.actorUid,
            actorRole: ctx.actorRole,
            serverTimestamp: ctx.serverTimestamp,
            clientTimestamp: ctx.clientTimestamp,
            requestId: ctx.requestId
        };
        if (ctx.operationId !== undefined) {
            data.operationId = ctx.operationId;
            data.opType = ctx.opType;
            data.opIndex = ctx.opIndex;
        }
        return { id: id, data: data };
    });
}

module.exports = {
    KIND_DIRECTION, MOVEMENT_KINDS, DEFAULT_KIND_BY_OPTYPE, MAX_MOVEMENTS, MAX_REASON, MAX_TXN_WRITES,
    validateMovements, totalsMatch, deriveMovement, stockOf, deriveForMutation, buildRows
};
