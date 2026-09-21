"use strict";

// One atomic, idempotent multi-write operation. Design:
// docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
//
// A "compound" business operation (order completion today) touches several
// working-tier docs at once. Sent as N separate recordDelta/recordMutation
// calls it is neither atomic nor replay-safe as a unit. This module applies the
// whole list in ONE Firestore transaction: every op lands or none does, and a
// retry of the same requestId is a no-op that returns the first result.
//
// Zero Firebase SDK dependency - same dependency-injection pattern as
// gatewayLogic.js / batchMutationLogic.js.

const {
    validateMutationRequest,
    validateDeltaRequest,
    _deepEqual
} = require("./gatewayLogic");

// 200 ops = up to 200 working-doc writes + 200 per-op audit entries + 1 marker
// = 401 writes, under Firestore's ~500-writes-per-transaction ceiling. Mirrored
// client-side as Gateway.qml's `maxOperationOps` (no shared build-time constant
// between this Node runtime and the QML client); both sides pin the value in a
// test so drift fails a test instead of failing in production.
const MAX_OPS = 200;

// Allowlist so the audit trail never carries a free-form client string.
// Adding an operation type is a server deploy on purpose.
const OP_TYPES = ["completeOrder"];

// Every id below becomes a Firestore document id, and requestId is chosen by the
// client. A "/" turns the id into a nested path (a request that can never
// succeed but is retried forever: a 500 instead of a clean 400), and an id
// that could collide with another entry in audit_log would make a retry
// "replay" a write that never happened. So ids are validated here:
//   - no "/", not "." or "..", at most MAX_ID_LENGTH characters (all ids)
//   - requestId must start with "{opType}:" (a namespace no other endpoint uses:
//     recordMutation/recordDelta ids are "req-...") and must not contain "~",
//     the separator of the per-op audit ids "{requestId}~{index}", so a marker
//     id can never equal a per-op id.
const MAX_ID_LENGTH = 200;

function isSafeDocId(id) {
    return id.length > 0 && id.length <= MAX_ID_LENGTH
        && id.indexOf("/") < 0 && id !== "." && id !== "..";
}

// Validates + normalizes a recordOperation request body. Reuses the single-item
// validators per op (with a derived per-op request id) so entity/action/delta
// rules stay defined in exactly one place. Returns
// { ok: true, requestId, opType, ops, clientTimestamp } or
// { ok: false, status, error, opIndex? }.
function validateOperationRequest(body) {
    const requestId = String((body && body.requestId) || "");
    const opType = String((body && body.opType) || "");
    const rawOps = (body && Array.isArray(body.ops)) ? body.ops : [];

    if (!requestId || !opType) return { ok: false, status: 400, error: "missing-fields" };
    if (OP_TYPES.indexOf(opType) < 0) return { ok: false, status: 400, error: "unsupported-op-type" };
    if (!isSafeDocId(requestId) || requestId.indexOf("~") >= 0 || requestId.indexOf(opType + ":") !== 0)
        return { ok: false, status: 400, error: "invalid-request-id" };
    if (rawOps.length === 0) return { ok: false, status: 400, error: "empty-operation" };
    if (rawOps.length > MAX_OPS) return { ok: false, status: 400, error: "operation-too-large" };

    const ops = [];
    for (let i = 0; i < rawOps.length; i++) {
        const raw = rawOps[i] || {};
        const perOp = Object.assign({}, raw, { requestId: opAuditId(requestId, i) });
        let v;
        if (raw.kind === "delta") v = validateDeltaRequest(perOp);
        else if (raw.kind === "mutation") v = validateMutationRequest(perOp);
        else return { ok: false, status: 400, error: "unsupported-kind", opIndex: i };
        if (!v.ok) return Object.assign({}, v, { opIndex: i });
        if (!isSafeDocId(v.entityId)) return { ok: false, status: 400, error: "invalid-entity-id", opIndex: i };
        ops.push(Object.assign({ kind: raw.kind }, v));
    }
    return { ok: true, requestId: requestId, opType: opType, ops: ops,
             clientTimestamp: (body && body.clientTimestamp) || null };
}

function opAuditId(requestId, index) { return requestId + "~" + index; }

// Applies every op in one transaction. Reads first (Firestore requires all
// reads before any write), computes the whole result in memory, and only if
// every op is acceptable writes anything. A rejection therefore leaves NO trace
// (no working-doc write, no audit entry, no marker), so the same requestId can
// safely be retried later with a re-planned payload.
//
// Returns { ok: true, results, idempotentReplay? } or
// { ok: false, status, error, opIndex, field?, current?, conflict? }.
async function applyOperation(db, params) {
    const tenantRoot = "tenants/" + params.tenantId;
    const markerRef = db.doc(tenantRoot + "/audit_log/" + params.requestId);

    return db.runTransaction(async (txn) => {
        const existing = await txn.get(markerRef);
        if (existing.exists) {
            // Only an operation marker carries `results`. Anything else at this id is
            // not a replay of this operation: never report success for it.
            const stored = existing.data().results;
            if (!Array.isArray(stored)) return { ok: false, status: 409, error: "request-id-in-use" };
            return { ok: true, idempotentReplay: true, results: stored };
        }

        // One read per distinct working doc; later ops see earlier ops' effects.
        const state = {};   // path -> { ref, existed, exists, data }
        for (const op of params.ops) {
            const path = tenantRoot + "/" + op.collection + "/" + op.entityId;
            if (state[path]) continue;
            const ref = db.doc(path);
            const snap = await txn.get(ref);
            state[path] = { ref: ref, existed: snap.exists, exists: snap.exists,
                            data: snap.exists ? snap.data() : null };
        }

        const audits = [];
        const results = [];
        for (let i = 0; i < params.ops.length; i++) {
            const op = params.ops[i];
            const entry = state[tenantRoot + "/" + op.collection + "/" + op.entityId];

            if (op.kind === "delta") {
                if (!entry.exists) return { ok: false, status: 404, error: "not-found", opIndex: i };
                const before = {};
                const after = {};
                for (const field in op.deltas) {
                    const curVal = entry.data[field] || 0;
                    let nextVal = curVal + op.deltas[field];
                    if (Object.prototype.hasOwnProperty.call(op.floors, field) && nextVal < op.floors[field]) {
                        return { ok: false, status: 409, error: "insufficient-quantity",
                                 opIndex: i, field: field, current: curVal };
                    }
                    if (Object.prototype.hasOwnProperty.call(op.clamps, field) && nextVal < op.clamps[field]) {
                        nextVal = op.clamps[field];
                    }
                    before[field] = curVal;
                    after[field] = nextVal;
                }
                entry.data = Object.assign({}, entry.data, after);
                audits.push({ i: i, op: op, action: "delta", before: before, after: after });
                results.push({ entity: op.entity, entityId: op.entityId, kind: "delta", after: after });
            } else {
                if (!_deepEqual(entry.data, op.before)) {
                    return { ok: false, status: 409, error: "conflict", conflict: true,
                             opIndex: i, current: entry.data };
                }
                if (op.action === "delete") {
                    entry.exists = false;
                    entry.data = null;
                } else {
                    entry.exists = true;
                    entry.data = op.after || {};
                }
                audits.push({ i: i, op: op, action: op.action, before: op.before, after: op.after });
                results.push({ entity: op.entity, entityId: op.entityId, kind: "mutation",
                               after: op.action === "delete" ? null : (op.after || {}) });
            }
        }

        // Every op accepted: now (and only now) write.
        for (const path in state) {
            const entry = state[path];
            if (entry.exists) txn.set(entry.ref, entry.data, { merge: false });
            else if (entry.existed) txn.delete(entry.ref);
        }
        for (const a of audits) {
            txn.set(db.doc(tenantRoot + "/audit_log/" + opAuditId(params.requestId, a.i)), {
                entryId: opAuditId(params.requestId, a.i),
                tenantId: params.tenantId,
                actorUid: params.actorUid,
                actorRole: params.actorRole,
                action: a.action,
                entity: a.op.entity,
                entityId: a.op.entityId,
                before: a.before,
                after: a.after,
                serverTimestamp: params.serverTimestamp,
                clientTimestamp: params.clientTimestamp,
                requestId: opAuditId(params.requestId, a.i),
                operationId: params.requestId,
                opType: params.opType,
                opIndex: a.i
            });
        }
        // The marker is what makes a retry a no-op. Its id IS the requestId,
        // like every other audit_log entry.
        txn.set(markerRef, {
            entryId: params.requestId,
            tenantId: params.tenantId,
            actorUid: params.actorUid,
            actorRole: params.actorRole,
            action: "operation",
            opType: params.opType,
            opCount: params.ops.length,
            results: results,
            serverTimestamp: params.serverTimestamp,
            clientTimestamp: params.clientTimestamp,
            requestId: params.requestId
        });
        return { ok: true, results: results };
    });
}

module.exports = { MAX_OPS, OP_TYPES, validateOperationRequest, applyOperation, opAuditId };
