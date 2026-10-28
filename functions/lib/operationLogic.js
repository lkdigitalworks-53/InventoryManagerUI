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
const { isCascadeEntityDelete } = require("./photoCleanup");
const MovementLogic = require("./movementLogic");
const CounterRegistry = require("./counterRegistry");

// 200 ops = up to 200 working-doc writes + 200 per-op audit entries + 1 marker
// = 401 writes, against a Firestore per-transaction ceiling the repo assumes is ~500. That ceiling,
// and whether serverTimestamp() counts as an extra write per doc (which would make it 601), are both
// UNVERIFIED (BC1 design review R3): treat MAX_OPS as a latent question, not a proven bound. Doc check
// 2026-10-18: the public Firestore quotas page lists no per-commit write COUNT (only 10 MiB request size, 270 s
// transaction time, 500 field transforms per document), so 500 is kept as a conservative budget, not a known
// limit; the real answer still comes from the dev deploy check (P1 test plan, D-1). Mirrored
// client-side as Gateway.qml's `maxOperationOps` (no shared build-time constant
// between this Node runtime and the QML client); both sides pin the value in a
// test so drift fails a test instead of failing in production.
const MAX_OPS = 200;

// Allowlist so the audit trail never carries a free-form client string.
// Adding an operation type is a server deploy on purpose.
// "restock" (R2, design M9) is accepted here so the server is deployed before the client that sends it.
// Like completeOrder it carries no per-opType shape check (D5); a restock stock delta must name its
// `receipt` movement explicitly, otherwise the server derives `adjustment`.
const OP_TYPES = ["completeOrder", "restock"];

// `mint` op (design 2026-10-28-r2-mint-engine-design.md): the server hands out counter ids INSIDE the
// operation transaction, so a rejected operation burns no number. Later ops name the id as {{bind}}.
const MAX_MINT_OPS = 5;
const MAX_MINT_SKIPS = 20;          // M5: occupied ids skipped before giving up (409 mint-exhausted)
const BIND_NAME = /^[a-z][A-Za-z0-9]{0,15}$/;
const PLACEHOLDER = /\{\{([^{}]*)\}\}/g;
const MAX_SUBST_DEPTH = 16;         // how deep into `after` strings are scanned / replaced

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


// ---- placeholders -------------------------------------------------------------------------------
// {{name}} tokens in an op's entityId and in the string values of its `after` are replaced by the id
// a `mint` op bound to `name`. Never in keys, `before` or `deltas`. See design section 2 and M6.

// Calls fn(value) for every string value in `node` (objects and arrays, depth-capped, never keys).
function eachString(node, fn, depth) {
    if (typeof node === "string") { fn(node); return; }
    if (depth >= MAX_SUBST_DEPTH || node === null || typeof node !== "object") return;
    if (Array.isArray(node)) { for (const v of node) eachString(v, fn, depth + 1); return; }
    if (Object.prototype.toString.call(node) !== "[object Object]") return;
    for (const k of Object.keys(node)) eachString(node[k], fn, depth + 1);
}

// Copy of `node` with every bound {{name}} inside a string value replaced; names not in `bound`
// stay as typed (M6: free text is never rejected). Non-plain objects are returned as they are.
function substituteDeep(node, bound, depth) {
    if (typeof node === "string") return replaceBound(node, bound);
    if (depth >= MAX_SUBST_DEPTH || node === null || typeof node !== "object") return node;
    if (Array.isArray(node)) return node.map((v) => substituteDeep(v, bound, depth + 1));
    if (Object.prototype.toString.call(node) !== "[object Object]") return node;
    const out = {};
    for (const k of Object.keys(node)) out[k] = substituteDeep(node[k], bound, depth + 1);
    return out;
}

function replaceBound(str, bound) {
    return str.replace(PLACEHOLDER, function (whole, name) {
        return Object.prototype.hasOwnProperty.call(bound, name) ? bound[name] : whole;
    });
}

// Names referenced by {{...}} tokens in `str`.
function placeholderNames(str) {
    const names = [];
    str.replace(PLACEHOLDER, function (whole, name) { names.push(name); return whole; });
    return names;
}

// True when `str` still holds brace pairs after bound names were replaced: not a legal doc id.
function hasBraces(str) { return str.indexOf("{{") >= 0 || str.indexOf("}}") >= 0; }

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

    // `mint` ops first: they decide which {{names}} exist and where they are declared.
    const declaredAt = {};
    let mintCount = 0;
    for (let i = 0; i < rawOps.length; i++) {
        const raw = rawOps[i] || {};
        if (raw.kind !== "mint") continue;
        mintCount++;
        if (mintCount > MAX_MINT_OPS) return { ok: false, status: 400, error: "too-many-mints", opIndex: i };
        if (!CounterRegistry.isKnownCounter(raw.counter)) return { ok: false, status: 400, error: "unknown-counter", opIndex: i };
        if (typeof raw.bind !== "string" || !BIND_NAME.test(raw.bind)) return { ok: false, status: 400, error: "invalid-bind-name", opIndex: i };
        if (Object.prototype.hasOwnProperty.call(declaredAt, raw.bind)) return { ok: false, status: 400, error: "duplicate-bind-name", opIndex: i };
        declaredAt[raw.bind] = i;
    }

    const ops = [];
    for (let i = 0; i < rawOps.length; i++) {
        const raw = rawOps[i] || {};
        if (raw.kind === "mint") {
            const reg = CounterRegistry.describe(raw.counter, "0000");
            ops.push({ kind: "mint", counter: raw.counter, bind: raw.bind, entity: reg.entity, collection: reg.collection });
            continue;
        }
        const perOp = Object.assign({}, raw, { requestId: opAuditId(requestId, i) });
        let v;
        if (raw.kind === "delta") v = validateDeltaRequest(perOp);
        else if (raw.kind === "mutation") v = validateMutationRequest(perOp);
        else return { ok: false, status: 400, error: "unsupported-kind", opIndex: i };
        if (!v.ok) return Object.assign({}, v, { opIndex: i });
        if (!isSafeDocId(v.entityId)) return { ok: false, status: 400, error: "invalid-entity-id", opIndex: i };
        // PH3 (design Q11): a product delete must leave a pending_cleanup marker, which this
        // transaction deliberately does not write (an unverified write ceiling, see MAX_OPS, and the
        // marker/sweep belong to recordMutation). Rejected on purpose, whole operation, zero writes.
        // No client sends one today. Batches of a deleted product are swept server-side (BC1).
        if (raw.kind === "mutation" && isCascadeEntityDelete(v.entity, v.action)) {
            return { ok: false, status: 400, error: "cascade-delete-not-allowed", opIndex: i };
        }
        // Placeholders exist only in an operation that has a mint op; without one nothing below runs,
        // so completeOrder-style operations are checked and applied exactly as before.
        if (mintCount > 0) {
            const bad = checkPlaceholders(raw.kind, v, i, declaredAt);
            if (bad) return bad;
        }
        ops.push(Object.assign({ kind: raw.kind }, v));
    }

    // Write budget: one working doc + one audit entry per op, one marker, and
    // (conservatively) at least one movement row per op on inventory. A mint op is ONE write (its
    // counter doc), no audit entry (M8).
    let rowBudget = 0;
    let workOps = 0;
    for (const op of ops) {
        if (op.kind === "mint") continue;
        workOps++;
        if (op.entity === "inventory") rowBudget += Math.max(1, op.movements ? op.movements.length : 0);
    }
    if (2 * workOps + mintCount + 1 + rowBudget > MovementLogic.MAX_TXN_WRITES)
        return { ok: false, status: 400, error: "operation-too-large" };

    return { ok: true, requestId: requestId, opType: opType, ops: ops,
             clientTimestamp: (body && body.clientTimestamp) || null };
}

// Placeholder rules for one non-mint op of an operation that has mint ops (M6). Returns an error
// result or null. entityId: strict, create only. `after` strings: a name declared by a LATER mint op
// is a client ordering bug (400); a name nobody declared is user text and stays.
function checkPlaceholders(kind, v, index, declaredAt) {
    const id = v.entityId;
    if (hasBraces(id)) {
        if (kind !== "mutation" || v.action !== "create")
            return { ok: false, status: 400, error: "placeholder-not-allowed", opIndex: index };
        const rest = id.replace(PLACEHOLDER, function (whole, name) {
            return (Object.prototype.hasOwnProperty.call(declaredAt, name) && declaredAt[name] < index) ? "" : whole;
        });
        if (hasBraces(rest)) return { ok: false, status: 400, error: "unbound-placeholder", opIndex: index };
    }
    if (kind === "mutation" && v.after) {
        let bad = false;
        eachString(v.after, function (str) {
            for (const name of placeholderNames(str))
                if (Object.prototype.hasOwnProperty.call(declaredAt, name) && declaredAt[name] >= index) bad = true;
        }, 0);
        if (bad) return { ok: false, status: 400, error: "unbound-placeholder", opIndex: index };
    }
    return null;
}

function opAuditId(requestId, index) { return requestId + "~" + index; }

// Seed for a counter that has no usable doc (M4): the highest number already used for `prefix` in the
// target collection. Listed outside the transaction on purpose: a stale listing is harmless because the
// collision probe in runMints skips any id that exists when the transaction reads it.
async function seedFromIds(db, collectionPath, prefix) {
    const refs = await db.collection(collectionPath).listDocuments();
    return CounterRegistry.maxNumber(prefix, refs.map((r) => r.id));
}

// Reads the counters, assigns one id per mint op in op order (skipping ids already in use, M5), and
// returns the ops with every {{name}} replaced. Writes nothing; the caller writes `counterWrites` only
// after every op was accepted. Returns { ok: true, ops, results, counterWrites } or an error result.
async function runMints(db, txn, load, tenantRoot, params) {
    const year = CounterRegistry.yearFor(params.now || new Date());
    const counters = {};     // counter doc path -> { ref, value, changed }
    const bound = {};
    const results = {};

    for (let i = 0; i < params.ops.length; i++) {
        const op = params.ops[i];
        if (op.kind !== "mint") continue;
        const desc = CounterRegistry.describe(op.counter, year);
        if (!desc) return { ok: false, status: 400, error: "unknown-counter", opIndex: i };

        const counterPath = tenantRoot + "/counters/" + desc.counterName;
        let c = counters[counterPath];
        if (!c) {
            const ref = db.doc(counterPath);
            const snap = await txn.get(ref);
            const stored = snap.exists ? snap.data().value : undefined;
            // A damaged counter doc is re-seeded from the ids, not trusted.
            const value = CounterRegistry.usableCount(stored)
                ? stored : await seedFromIds(db, tenantRoot + "/" + desc.collection, desc.prefix);
            c = counters[counterPath] = { ref: ref, value: value, changed: false };
        }

        let id = "";
        for (let skips = 0; ; skips++) {
            if (skips > MAX_MINT_SKIPS) return { ok: false, status: 409, error: "mint-exhausted", opIndex: i };
            c.value += 1;
            id = CounterRegistry.formatId(desc.prefix, c.value);
            const taken = await load(tenantRoot + "/" + desc.collection + "/" + id);
            if (!taken.exists) break;
        }
        c.changed = true;
        bound[op.bind] = id;
        results[i] = { kind: "mint", counter: op.counter, bind: op.bind, id: id };
    }

    const resolved = [];
    for (let i = 0; i < params.ops.length; i++) {
        const op = params.ops[i];
        if (op.kind === "mint") { resolved.push(op); continue; }
        let next = op;
        if (hasBraces(op.entityId)) {
            const entityId = replaceBound(op.entityId, bound);
            if (hasBraces(entityId)) return { ok: false, status: 400, error: "unbound-placeholder", opIndex: i };
            if (!isSafeDocId(entityId)) return { ok: false, status: 400, error: "invalid-entity-id", opIndex: i };
            next = Object.assign({}, next, { entityId: entityId });
        }
        if (op.kind === "mutation" && op.after) next = Object.assign({}, next, { after: substituteDeep(op.after, bound, 0) });
        resolved.push(next);
    }

    const counterWrites = [];
    for (const path in counters) if (counters[path].changed) counterWrites.push({ ref: counters[path].ref, value: counters[path].value });
    return { ok: true, ops: resolved, results: results, counterWrites: counterWrites };
}

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

        // One read per distinct working doc; later ops see earlier ops' effects. Memoised so the
        // mint phase's collision probe and the op that creates that doc share ONE read.
        const state = {};   // path -> { ref, existed, exists, data }
        const load = async (path) => {
            if (state[path]) return state[path];
            const ref = db.doc(path);
            const snap = await txn.get(ref);
            state[path] = { ref: ref, existed: snap.exists, exists: snap.exists,
                            data: snap.exists ? snap.data() : null };
            return state[path];
        };

        // Mint phase (design M2-M5). Every read happens here, before any write. Nothing below this
        // block runs for an operation without a mint op, so those stay byte-identical to before.
        let ops = params.ops;
        const mintResults = {};     // op index -> result entry
        const counterWrites = [];   // { ref, value }
        if (params.ops.some((op) => op.kind === "mint")) {
            const minted = await runMints(db, txn, load, tenantRoot, params);
            if (!minted.ok) return minted;
            ops = minted.ops;
            for (const k in minted.results) mintResults[k] = minted.results[k];
            for (const w of minted.counterWrites) counterWrites.push(w);
        }

        for (const op of ops) {
            if (op.kind === "mint") continue;
            await load(tenantRoot + "/" + op.collection + "/" + op.entityId);
        }

        const audits = [];
        const results = [];
        for (let i = 0; i < ops.length; i++) {
            const op = ops[i];
            if (op.kind === "mint") { results.push(mintResults[i]); continue; }
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
                let movements = op.movements || [];
                if (movements.length === 0 && op.entity === "inventory" && Object.prototype.hasOwnProperty.call(after, "stock"))
                    movements = MovementLogic.deriveMovement(after.stock - before.stock,
                        MovementLogic.DEFAULT_KIND_BY_OPTYPE[params.opType] || "adjustment");
                if (movements.length > 0 && !MovementLogic.totalsMatch(movements, after.stock - before.stock)) {
                    return { ok: false, status: 409, error: "movement-qty-mismatch",
                             opIndex: i, field: "stock", current: before.stock };
                }
                entry.data = Object.assign({}, entry.data, after);
                audits.push({ i: i, op: op, action: "delta", before: before, after: after, movements: movements });
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
                // Inventory stock changes leave a server-derived ledger row (P1 D11); `before` is proven
                // equal to the running state by the check above.
                const movements = op.entity === "inventory"
                    ? MovementLogic.deriveForMutation(op.action, op.before, op.action === "delete" ? null : (op.after || {})) : [];
                audits.push({ i: i, op: op, action: op.action, before: op.before, after: op.after, movements: movements });
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
            const rows = MovementLogic.buildRows(a.movements, {
                baseId: opAuditId(params.requestId, a.i),
                productId: a.op.entityId,
                actorUid: params.actorUid,
                actorRole: params.actorRole,
                serverTimestamp: params.serverTimestamp,
                clientTimestamp: params.clientTimestamp,
                requestId: opAuditId(params.requestId, a.i),
                operationId: params.requestId,
                opType: params.opType,
                opIndex: a.i
            });
            for (const row of rows) txn.set(db.doc(tenantRoot + "/stock_movements/" + row.id), row.data);
        }
        // Counter docs: written only now, so a rejected operation never burns a number (M10).
        for (const w of counterWrites) txn.set(w.ref, { value: w.value }, { merge: false });
        // The marker is what makes a retry a no-op. Its id IS the requestId,
        // like every other audit_log entry.
        txn.set(markerRef, {
            entryId: params.requestId,
            tenantId: params.tenantId,
            actorUid: params.actorUid,
            actorRole: params.actorRole,
            action: "operation",
            opType: params.opType,
            opCount: ops.length,
            results: results,
            serverTimestamp: params.serverTimestamp,
            clientTimestamp: params.clientTimestamp,
            requestId: params.requestId
        });
        return { ok: true, results: results };
    });
}

module.exports = { MAX_OPS, MAX_MINT_OPS, MAX_MINT_SKIPS, OP_TYPES, validateOperationRequest, applyOperation, opAuditId };
