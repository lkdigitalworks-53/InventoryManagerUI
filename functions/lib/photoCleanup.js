"use strict";

// Pure logic for the product-photo cascade (PH3, design Q1-Q11, 2026-10-03). No Firebase/Admin SDK
// import here: Firestore/Storage access is injected (`sweepMarker` deps) so every branch is testable
// with plain Node. Design: docs/superpowers/specs/2026-09-30-photos-s3-s4-design.md

const { isSafePathSegment } = require("./photoValidation");

const MAX_LAST_ERROR_CHARS = 200;

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
        lastError: null
    };
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

// Sweeps one marker. deps (all async, injected):
//   productExists(productId) -> boolean   re-read of tenants/{t}/inventory/{p}
//   deleteFiles(prefix)                   bucket.deleteFiles({prefix, force:true})
//   deleteMarker()                        removes the marker doc
//   updateMarker(patch)                   merge-writes {attempts, lastError} onto the marker
// `tenantId` comes from the marker's doc PATH, never from its body. `marker` carries
// {productId, envPrefix, prefix, attempts}.
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
    MAX_LAST_ERROR_CHARS
};
