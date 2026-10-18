"use strict";

// New in this session — NOT part of the original P0 spec, which only defines
// a single-item recordMutation contract. Needed for bulk operations (import,
// primarily) that would otherwise trade atomicity away for N round trips
// through N individual recordMutation calls. This gives one atomic batch
// write instead — every item lands or none do — which is a stronger
// compliance property than N independent writes, at the cost of a
// batch-size cap.
//
// MAX_BATCH_SIZE=150 keeps the transaction's write count (3 per item at most: one
// working-doc write + one audit_log entry + one stock_movements row for inventory, P1)
// at 450, safely under Firestore's ~500-writes-per-transaction ceiling. A caller needing more than 150 items
// in one shot must split into multiple recordMutations calls; atomicity
// then holds within each chunk, not across chunks - a documented trade-off,
// not a hidden one.
//
// Zero Firebase SDK dependency of its own — same dependency-injection
// pattern as gatewayLogic.js / cutoverLogic.js.

const { ENTITY_COLLECTIONS, ALLOWED_ACTIONS, _deepEqual, isClientRequestId } = require("./gatewayLogic");
const { isCascadeEntityDelete, isReservedAuditId } = require("./photoCleanup");
const MovementLogic = require("./movementLogic");

// Mirrored client-side as Gateway.qml's `maxBatchSize` property (no shared
// build-time constant between this Node runtime and the QML client — see
// that property's comment). If this value ever changes, update both; this
// file's own test below and tests/tst_Gateway.qml both pin the value they
// each hold so a drift fails a test on both sides instead of failing silently
// in production the way the original bug did.
const MAX_BATCH_SIZE = 150;

// Validates + normalizes a recordMutationsBatch request body. Returns
// { ok: true, entity, collection, requestId, items: [...] } or
// { ok: false, status, error }.
function validateBatchMutationRequest(body) {
    const entity = String(body.entity || "");
    const requestId = String(body.requestId || "");
    const items = Array.isArray(body.items) ? body.items : [];

    const collection = ENTITY_COLLECTIONS[entity];
    if (!collection) {
        return { ok: false, status: 400, error: "unsupported-entity" };
    }
    if (!requestId) {
        return { ok: false, status: 400, error: "missing-fields" };
    }
    if (isReservedAuditId(requestId) || !isClientRequestId(requestId)) {
        return { ok: false, status: 400, error: "invalid-request-id" };
    }
    // Whole-record mutations never carry client movements: the server derives the rows (P1 D11).
    if (body.movements !== undefined) {
        return { ok: false, status: 400, error: "movements-not-supported" };
    }
    if (items.length === 0) {
        return { ok: false, status: 400, error: "empty-batch" };
    }
    if (items.length > MAX_BATCH_SIZE) {
        return { ok: false, status: 400, error: "batch-too-large" };
    }

    const normalized = [];
    for (const item of items) {
        const entityId = String((item && item.entityId) || "");
        const action = String((item && item.action) || "");
        if (ALLOWED_ACTIONS.indexOf(action) < 0) {
            return { ok: false, status: 400, error: "unsupported-action" };
        }
        if (!entityId) {
            return { ok: false, status: 400, error: "missing-fields" };
        }
        // The batch audit and ledger ids are `<requestId>:<entityId>[~m0]`: a `/` or `~` in the
        // entityId could forge another endpoint's id (D-2, same overwrite class as the requestId).
        if (!isClientRequestId(entityId)) {
            return { ok: false, status: 400, error: "invalid-entity-id" };
        }
        // PH3 (design Q11): a product delete must leave a pending_cleanup marker, which this batch
        // transaction deliberately does not write (it would break the 2-writes-per-item ceiling
        // arithmetic above). Reject the WHOLE batch, zero writes. Client sends none today (bulk
        // import is create-only); revisit when the delete roadmap builds an atomic product delete.
        if (isCascadeEntityDelete(entity, action)) {
            return { ok: false, status: 400, error: "cascade-delete-not-allowed" };
        }
        normalized.push({
            entityId: entityId,
            action: action,
            before: item.before === undefined ? null : item.before,
            after: item.after === undefined ? null : item.after,
            clientTimestamp: item.clientTimestamp || null
        });
    }

    return { ok: true, entity: entity, collection: collection, requestId: requestId, items: normalized };
}

// Applies every item in the batch atomically, in a single transaction. Backstop
// CAS check (review finding I1, added this round): mirrors applyMutation's
// single-item check exactly, extended per-item — a stale/racing batch write
// silently clobbering data was the whole point of this finding, since this is
// the LIVE path for every bulk import (Supplier/Order/StockBatch/Inventory/
// Transaction all route recordMutations through here), directly touching the
// "imports must never silently overwrite data" invariant.
//
// On any single item's before mismatching the record's current server state,
// the WHOLE batch is rejected — nothing written, matching this module's own
// stated all-or-nothing design (see the top-of-file comment) rather than
// silently applying a partial batch. Returns EVERY conflicting item's
// current value (not just the first) so the caller isn't left guessing which
// of potentially many rows actually conflicted.
//
// Per-item idempotency: the audit_log doc id for item N is
// `<batchRequestId>:<entityId>` — a retried batch (or a batch that partly
// overlaps a previous one) skips whatever was already applied and only
// writes what's new. An idempotent-replay item is exempt from the CAS check
// (same reasoning as applyMutation's own idempotent-replay short-circuit) —
// it's not a competing write, it's this same request landing twice.
async function applyMutationsBatch(db, params) {
    const tenantRoot = "tenants/" + params.tenantId;

    return db.runTransaction(async (txn) => {
        const refs = params.items.map((item) => ({
            item: item,
            auditRef: db.doc(tenantRoot + "/audit_log/" + params.requestId + ":" + item.entityId),
            workingRef: db.doc(tenantRoot + "/" + params.collection + "/" + item.entityId)
        }));

        // Firestore transactions require all reads before any writes.
        const existingFlags = await Promise.all(refs.map((r) => txn.get(r.auditRef)));
        const workingSnaps = await Promise.all(refs.map((r) => txn.get(r.workingRef)));

        const conflicts = [];
        refs.forEach((r, i) => {
            if (existingFlags[i].exists) return; // idempotent retry — not a competing write
            const current = workingSnaps[i].exists ? workingSnaps[i].data() : null;
            if (!_deepEqual(current, r.item.before)) {
                conflicts.push({ entityId: r.item.entityId, current: current });
            }
        });

        if (conflicts.length > 0) {
            return { ok: false, status: 409, conflicts: conflicts };
        }

        refs.forEach((r, i) => {
            if (existingFlags[i].exists) return; // idempotent retry — already applied

            if (r.item.action === "delete") {
                txn.delete(r.workingRef);
            } else {
                txn.set(r.workingRef, r.item.after || {}, { merge: false });
            }
            // Inventory stock changes leave a server-derived ledger row (P1 spec D11). The conflict
            // check above proved the stored doc equals item.before, so before/after explain the change.
            if (params.entity === "inventory") {
                const rows = MovementLogic.buildRows(
                    MovementLogic.deriveForMutation(r.item.action, r.item.before, r.item.after), {
                        baseId: params.requestId + ":" + r.item.entityId,
                        productId: r.item.entityId,
                        actorUid: params.actorUid,
                        actorRole: params.actorRole,
                        serverTimestamp: params.serverTimestamp,
                        clientTimestamp: r.item.clientTimestamp,
                        requestId: params.requestId
                    });
                for (const row of rows) txn.set(db.doc(tenantRoot + "/stock_movements/" + row.id), row.data);
            }

            txn.set(r.auditRef, {
                entryId: params.requestId + ":" + r.item.entityId,
                tenantId: params.tenantId,
                actorUid: params.actorUid,
                actorRole: params.actorRole,
                action: r.item.action,
                entity: params.entity,
                entityId: r.item.entityId,
                before: r.item.before,
                after: r.item.after,
                serverTimestamp: params.serverTimestamp,
                clientTimestamp: r.item.clientTimestamp,
                requestId: params.requestId,
                batchEntityId: r.item.entityId
            });
        });

        return { ok: true };
    });
}

module.exports = {
    MAX_BATCH_SIZE,
    validateBatchMutationRequest,
    applyMutationsBatch
};
