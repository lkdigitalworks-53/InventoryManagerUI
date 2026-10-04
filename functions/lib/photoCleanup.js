"use strict";

// Pure logic for the product-photo cascade (PH3, design Q1-Q11, 2026-10-03). No Firebase/Admin SDK
// import here: Firestore/Storage access is injected (`sweepMarker` deps) so every branch is testable
// with plain Node. Design: docs/superpowers/specs/2026-09-30-photos-s3-s4-design.md

const { isSafePathSegment } = require("./photoValidation");

const MAX_LAST_ERROR_CHARS = 200;

// Max stock_batch docs per sweep chunk. Each doc costs 2 writes (delete + audit entry), so a chunk is
// 200 writes, 300 if serverTimestamp() counted as an extra write. Firestore's per-commit ceiling is
// UNVERIFIED (repo assumes 500), so stay well under it. BC1 design R3.
const SWEEP_CHUNK = 100;

// Reserved audit_log id namespace of the per-batch cascade entries (see isReservedAuditId).
const CASCADE_AUDIT_PREFIX = "cascade~";

// Photos are managed by owner/admin only, mirroring the client's AuthStore.canManageInventory.
// Exact, case-sensitive match: "OWNER", "Owner ", "", null, undefined and "viewer" (no such role
// exists) are all denied.
function canManagePhotos(role) {
    return role === "owner" || role === "admin";
}

// The one mutation shape that must leave a cleanup marker: an inventory (product) delete.
// ENTITY_COLLECTIONS maps one entity per collection, so entity "inventory" == collection "inventory".
function isCascadeEntityDelete(entity, action) {
    return entity === "inventory" && action === "delete";
}

// Storage prefix holding every photo of one product: `{env}/tenants/{t}/products/{p}/`.
// Returns null unless EVERY segment passes the whitelist. This is the safety guard of the whole
// cascade: an empty productId would otherwise widen the prefix to `.../products/` and delete every
// product's photos in the tenant. The trailing "/" stops `PRD-1` from also matching `PRD-10`.
function buildSweepPrefix(envPrefix, tenantId, productId) {
    if (!isSafePathSegment(envPrefix) || !isSafePathSegment(tenantId) || !isSafePathSegment(productId)) {
        return null;
    }
    return envPrefix + "/tenants/" + tenantId + "/products/" + productId + "/";
}

// Marker doc written in the SAME Firestore transaction as a product delete
// (`tenants/{t}/pending_cleanup/{productId}`). Returns null when the prefix is missing/unsafe so a
// caller can never persist a marker that the sweep guard would refuse anyway.
// `envPrefix` is stored so the sweep guard can rebuild the prefix (review I2); tenantId is NOT
// stored: the sweep takes it from the doc path.
// BC1 (R2): also carries the delete's actorUid / actorRole / requestId so the sweep (and the PH3b
// scheduler, which has no request context) can attribute the per-batch audit entries. A missing or
// non-string value is stored as null (Firestore rejects undefined) and read back as "system".
function buildMarker(params) {
    const p = params || {};
    if (typeof p.prefix !== "string" || p.prefix === "") return null;
    if (buildSweepPrefix(p.envPrefix, p.tenantId, p.productId) !== p.prefix) return null;
    return {
        productId: p.productId,
        envPrefix: p.envPrefix,
        prefix: p.prefix,
        createdAt: p.createdAt,
        attempts: 0,
        lastError: null,
        actorUid: _strOrNull(p.actorUid),
        actorRole: _strOrNull(p.actorRole),
        requestId: _strOrNull(p.requestId)
    };
}

function _strOrNull(v) {
    return typeof v === "string" && v !== "" ? v : null;
}

// Upload preflight (F3, Q1): decides from the product doc read BEFORE any Storage write, so a 404 or
// a 409 never leaves orphan objects. `product` is the doc's data, or null when the doc is missing.
// The in-transaction checks in uploadProductPhoto stay the final authority. A replay of a photoId
// that is already confirmed passes even at the cap.
function evaluateUploadPreflight(product, photoId, maxPhotos) {
    if (product === null || product === undefined) {
        return { ok: false, status: 404, error: "product-not-found" };
    }
    const photoIds = Array.isArray(product.photoIds) ? product.photoIds : [];
    if (photoIds.indexOf(photoId) === -1 && photoIds.length >= maxPhotos) {
        return { ok: false, status: 409, error: "photo-limit" };
    }
    return { ok: true };
}

function _errorText(e) {
    const text = String((e && e.message) || e || "unknown-error");
    return text.length > MAX_LAST_ERROR_CHARS ? text.slice(0, MAX_LAST_ERROR_CHARS) : text;
}

// Deterministic audit id for one cascaded batch delete. Two overlapping sweeps (handler + PH3b
// scheduler) or a retry write the SAME doc, so the audit never duplicates (Q-BC-2 A, R4).
function buildCascadeAuditId(productId, batchId) {
    return CASCADE_AUDIT_PREFIX + productId + "~" + batchId;
}

// Review fix (PR #118): the cascade audit ids live in the SAME audit_log keyspace as the client-chosen
// requestIds of recordMutation / recordDelta / recordMutationsBatch / the photo endpoints, none of which
// restricted the charset. A caller could pick a requestId equal to a future cascade id: the sweep's
// unconditional `set` would then overwrite that (their own) audit entry, or the sweep's entry would make
// their write answer as an idempotent replay. The prefix is therefore RESERVED: every endpoint that takes a
// client requestId rejects it (400 invalid-request-id).
function isReservedAuditId(id) {
    return typeof id === "string" && id.indexOf(CASCADE_AUDIT_PREFIX) === 0;
}

// Deletes every stock_batch of one deleted product, one audit entry per batch (Q-BC-2 A), in chunks
// of at most SWEEP_CHUNK docs, each chunk ONE atomic commit. io (async, injected):
//   listBatches(productId) -> [{id, data}]   server-side query: tenants/{t}/stock_batches where
//                                            productId == id. The tenant is bound in the io, which
//                                            comes from the marker's doc PATH.
//   commitChunk(entries)                     entries: [{batchId, auditId, audit}]; deletes each batch
//                                            doc and sets each audit doc in ONE write batch. The
//                                            binding adds serverTimestamp to every audit entry.
// `actor` = {actorUid, actorRole, requestId} from the marker; absent => "system" / no back-link.
// Defence in depth: docs whose own productId differs are skipped even if the query returned them
// (a wrong query must never delete another product's cost layers). Throws on any io failure: the
// caller (sweepMarker) keeps the marker and retries. Returns the number of batches deleted.
async function sweepStockBatches(io, tenantId, productId, actor) {
    const a = actor || {};
    const found = await io.listBatches(productId);
    const docs = (found || []).filter((d) => d && d.data && d.data.productId === productId);
    for (let i = 0; i < docs.length; i += SWEEP_CHUNK) {
        const entries = docs.slice(i, i + SWEEP_CHUNK).map((d) => ({
            batchId: d.id,
            auditId: buildCascadeAuditId(productId, d.id),
            audit: {
                entryId: buildCascadeAuditId(productId, d.id),
                tenantId: tenantId,
                actorUid: _strOrNull(a.actorUid) || "system",
                actorRole: _strOrNull(a.actorRole) || "system",
                action: "delete",
                entity: "stock_batch",
                entityId: d.id,
                before: d.data,
                after: null,
                clientTimestamp: null,
                requestId: buildCascadeAuditId(productId, d.id),
                cascadeOf: _strOrNull(a.requestId)
            }
        }));
        await io.commitChunk(entries);
    }
    return docs.length;
}

// Sweeps one marker. deps (all async, injected):
//   productExists(productId) -> boolean   re-read of tenants/{t}/inventory/{p}
//   sweepBatches(productId, actor)        deletes the product's stock_batches + audits (BC1, via
//                                         sweepStockBatches); REQUIRED, a missing dep fails the
//                                         sweep loudly instead of silently skipping money data
//   deleteFiles(prefix)                   bucket.deleteFiles({prefix, force:true})
//   deleteMarker()                        removes the marker doc
//   updateMarker(patch)                   merge-writes {attempts, lastError} onto the marker
// `tenantId` comes from the marker's doc PATH, never from its body. `marker` carries
// {productId, envPrefix, prefix, attempts} plus optional {actorUid, actorRole, requestId} (absent on
// markers written by #113: swept with actor "system").
// Never throws. Returns {ok:true, swept:true} | {ok:true, dropped:true} (id reused, nothing swept)
// | {ok:false, error}. On any failure the marker is kept with attempts+1 and a truncated lastError;
// the attempts cap (Q12) is enforced by the PH3b scheduler, not here.
async function sweepMarker(deps, tenantId, marker) {
    const m = marker || {};

    async function fail(reason) {
        const lastError = _errorText(reason);
        try {
            await deps.updateMarker({ attempts: (Number(m.attempts) || 0) + 1, lastError: lastError });
        } catch (e) {
            // The marker stays as it was; the next pass retries. Nothing more to do here.
        }
        return { ok: false, error: lastError };
    }

    // Guard: refuse unless the stored prefix equals the one rebuilt from the whitelisted parts.
    const expected = buildSweepPrefix(m.envPrefix, tenantId, m.productId);
    if (expected === null || m.prefix !== expected || expected.slice(-1) !== "/") {
        return fail("unsafe-sweep-prefix");
    }

    let exists;
    try {
        exists = await deps.productExists(m.productId);
    } catch (e) {
        return fail(e); // unsure whether the product is back: never sweep when unsure
    }

    if (exists) {
        // Product id was reused before the sweep ran: its photos are live. Drop the marker only.
        try { await deps.deleteMarker(); } catch (e) { /* swallowed: harmless stale marker */ }
        return { ok: true, dropped: true };
    }

    // Batches first: they carry the money. Order vs the Storage prefix matters little; each step is
    // idempotent and a failure of either keeps the marker.
    try {
        await deps.sweepBatches(m.productId, {
            actorUid: m.actorUid, actorRole: m.actorRole, requestId: m.requestId
        });
    } catch (e) {
        return fail(e);
    }

    try {
        await deps.deleteFiles(expected);
    } catch (e) {
        return fail(e);
    }
    try { await deps.deleteMarker(); } catch (e) { /* swallowed: next pass re-sweeps an empty prefix */ }
    return { ok: true, swept: true };
}

module.exports = {
    canManagePhotos,
    isCascadeEntityDelete,
    buildSweepPrefix,
    buildMarker,
    evaluateUploadPreflight,
    sweepMarker,
    sweepStockBatches,
    buildCascadeAuditId,
    isReservedAuditId,
    CASCADE_AUDIT_PREFIX,
    SWEEP_CHUNK,
    MAX_LAST_ERROR_CHARS
};
