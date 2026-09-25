"use strict";

// Compliance gateway (P0). The ONLY writer to the immutable ledger tier
// (audit_log) and the server-owned working-tier collections in P0 scope
// (inventory, stock_batches, stock_movements).
//
// The QML client posts here with `Authorization: Bearer <firebaseIdToken>`,
// reusing the same XHR pattern it already uses for the Firestore REST API.
// The function verifies the token, derives the actor identity + tenant +
// role SERVER-SIDE (never trusting the client payload for those), stamps a
// server timestamp, and writes the working-tier doc together with one
// append-only audit_log entry in a single Firestore transaction.
//
// Idempotency: the client sends a stable `requestId` per logical mutation.
// The audit_log entry id IS that requestId, so a retried outbox item can
// never double-apply — a second call with the same requestId is a no-op
// that returns the same entryId.

const functions = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const RealisedMath = require("./lib/realisedMath");
const BreakdownMath = require("./lib/breakdownMath");
const GatewayLogic = require("./lib/gatewayLogic");
const CutoverLogic = require("./lib/cutoverLogic");
const BatchMutationLogic = require("./lib/batchMutationLogic");
const OperationLogic = require("./lib/operationLogic");
const LockLogic = require("./lib/lockLogic");
const PhotoValidation = require("./lib/photoValidation");
const { send } = require("./lib/httpResponse");

admin.initializeApp();

// Mirrors qml/helper/EnvConfig.js's stage->env->databaseId resolution chain
// (Skill 30) so the client and every Cloud Function agree on which of the
// three per-env Firestore databases a request is scoped to. Constrained to
// exactly these 3 known values -- never a client-supplied arbitrary database
// id string -- and fails safe to prd on an unknown/missing env, same
// fail-safe EnvConfig.js itself uses. `db` is now resolved PER REQUEST from
// the client-declared `env`, not a module-level global: every handler below
// calls `scopedDb(body.env)` instead of closing over one shared instance,
// closing the gap where recordMutation/provisionMember/runCutover always
// wrote to `(default)` regardless of which env the calling client was built
// for (see README "Environments" / AGENTS SS8).
// "dev" env resolves to Firestore database id "dev1" (not "dev" — Firestore
// requires database ids to be >=4 characters). Must mirror qml/helper/EnvConfig.js.
const DATABASE_ID_FOR_ENV = { dev: "dev1", test: "test", prd: "(default)" };

function scopedDb(env) {
    const databaseId = DATABASE_ID_FOR_ENV[env] || DATABASE_ID_FOR_ENV.prd;
    return getFirestore(admin.app(), databaseId);
}

// Product photos (2026-09-21). Storage object paths use {env}/tenants/{t}/products/{p}/{photoId}.jpg
// -- "prd" spelled out, NOT Firestore's "(default)" database id -- so this is a second, separate
// mapping from DATABASE_ID_FOR_ENV even though the keys are identical. The client (qml/helper/
// PhotoUrl.js) must send/use this same "prd"/"test"/"dev1" form when it builds a download URL for
// a photo this server wrote, or the two will disagree about where an object lives.
// Design: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md
const STORAGE_ENV_PREFIX = { dev: "dev1", test: "test", prd: "prd" };
function storageEnvPrefix(env) {
    return STORAGE_ENV_PREFIX[env] || STORAGE_ENV_PREFIX.prd;
}

const PHOTO_BUCKET_NAME = "inventorymanager-48392.firebasestorage.app";
const MAX_PHOTOS_PER_PRODUCT = 10;
const MAIN_IMAGE_MAX_BYTES = 1_500_000;
const THUMB_IMAGE_MAX_BYTES = 200_000;

function photoStoragePath(envPrefix, tenantId, productId, photoId, thumb) {
    return envPrefix + "/tenants/" + tenantId + "/products/" + productId + "/" +
        photoId + (thumb ? "_t" : "") + ".jpg";
}

async function deriveContext(db, uid) {
    // Tenant + role come from the server's own records, not the client.
    const userSnap = await db.doc("users/" + uid).get();
    if (!userSnap.exists) return null;
    const user = userSnap.data() || {};
    const tenantId = user.tenantId || "";
    if (!tenantId) return null;

    let role = user.role || "";
    let actorName = user.name || user.displayName || "";
    const memberSnap = await db.doc(
        "tenants/" + tenantId + "/members/" + uid).get();
    if (memberSnap.exists) {
        const member = memberSnap.data() || {};
        role = member.role || role;
        actorName = member.name || actorName;
        if (member.status && member.status !== "active") return null;
    }
    // Tenant display name — preferred from the tenant doc, falling back to
    // whatever the user doc cached. Used when stamping new member/user docs.
    let tenantName = user.tenantName || "";
    const tenantSnap = await db.doc("tenants/" + tenantId).get();
    if (tenantSnap.exists) {
        const t = tenantSnap.data() || {};
        tenantName = t.name || t.tenantName || tenantName;
    }
    return { tenantId: tenantId, role: role, tenantName: tenantName, actorName: actorName };
}

exports.recordMutation = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const token = GatewayLogic.parseBearerToken(req.get("Authorization"));
        if (!token) {
            send(res, 401, { ok: false, error: "missing-token" });
            return;
        }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(token);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }
        const actorUid = decoded.uid;

        const body = req.body || {};
        const db = scopedDb(body.env);

        const validated = GatewayLogic.validateMutationRequest(body);
        if (!validated.ok) {
            send(res, validated.status, { ok: false, error: validated.error });
            return;
        }

        const ctx = await deriveContext(db, actorUid);
        if (!ctx) {
            send(res, 403, { ok: false, error: "no-tenant-context" });
            return;
        }

        let result;
        try {
            result = await GatewayLogic.applyMutation(db, {
                tenantId: ctx.tenantId,
                actorUid: actorUid,
                actorRole: ctx.role,
                entity: validated.entity,
                entityId: validated.entityId,
                action: validated.action,
                requestId: validated.requestId,
                before: validated.before,
                after: validated.after,
                clientTimestamp: validated.clientTimestamp,
                collection: validated.collection,
                serverTimestamp: FieldValue.serverTimestamp()
            });
        } catch (e) {
            console.error("recordMutation write failed", e);
            send(res, 500, { ok: false, error: "write-failed" });
            return;
        }

        // Component 3 (async-write-sequencing design): applyMutation now
        // returns a result instead of always succeeding — a CAS conflict
        // must actually reach the client as a 409, or the whole backstop
        // is silently inert. That comment was already here, but the fix it
        // describes was itself incomplete: this handler forwarded `current`
        // but silently dropped `result.conflict` -- the exact boolean field
        // Gateway.qml's _parseMutationConflict (qml/model/Gateway.qml) checks
        // for (`body.conflict !== true`). applyMutation's only ok:false
        // branch always sets conflict:true (see functions/lib/gatewayLogic.js),
        // so this was a pure serialization drop, not a logic gap -- the 409
        // arrived, parsed as valid JSON, and was still silently misread as a
        // generic failure, sent through the normal retry/backoff path with a
        // permanently-stale `before`, forever. Confirmed via
        // docs/superpowers/specs (E2E testing phase 2 followup, ninth round)
        // this was neutering mutationConflicted's reconciliation path for
        // every store that connects to it (Orders/Inventory/Staff/Supplier/
        // StockBatch), not just the one test that happened to exercise it.
        // `result.conflict === true` (not a bare `result.conflict` truthy
        // check, and not a hardcoded `true`) so this stays correct if
        // applyMutation ever grows a second, non-conflict ok:false branch.
        if (result && result.ok === false) {
            send(res, result.status || 409, {
                ok: false, error: "conflict", conflict: result.conflict === true, current: result.current
            });
            return;
        }

        send(res, 200, { ok: true, entryId: validated.requestId });
    });

// Component 4 (async-write-sequencing design). Atomic server-side numeric
// deltas — see functions/lib/gatewayLogic.js's applyDelta for why this is a
// separate mutation kind from recordMutation rather than a CAS variant.
exports.recordDelta = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const token = GatewayLogic.parseBearerToken(req.get("Authorization"));
        if (!token) {
            send(res, 401, { ok: false, error: "missing-token" });
            return;
        }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(token);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }
        const actorUid = decoded.uid;

        const body = req.body || {};
        const db = scopedDb(body.env);

        const validated = GatewayLogic.validateDeltaRequest(body);
        if (!validated.ok) {
            send(res, validated.status, { ok: false, error: validated.error });
            return;
        }

        const ctx = await deriveContext(db, actorUid);
        if (!ctx) {
            send(res, 403, { ok: false, error: "no-tenant-context" });
            return;
        }

        let result;
        try {
            result = await GatewayLogic.applyDelta(db, {
                tenantId: ctx.tenantId,
                actorUid: actorUid,
                actorRole: ctx.role,
                entity: validated.entity,
                entityId: validated.entityId,
                requestId: validated.requestId,
                deltas: validated.deltas,
                floors: validated.floors,
                clamps: validated.clamps,
                clientTimestamp: validated.clientTimestamp,
                collection: validated.collection,
                serverTimestamp: FieldValue.serverTimestamp()
            });
        } catch (e) {
            console.error("recordDelta write failed", e);
            send(res, 500, { ok: false, error: "write-failed" });
            return;
        }

        if (result && result.ok === false) {
            send(res, result.status || 409, {
                ok: false, error: result.error, field: result.field, current: result.current
            });
            return;
        }

        send(res, 200, { ok: true, entryId: validated.requestId, after: result.after });
    });

// Atomic multi-write operation (order completion today). One request carries a
// list of delta/mutation ops for several working-tier docs; they are applied in
// ONE Firestore transaction, all-or-nothing, keyed by a stable requestId so a
// retry is a no-op. See lib/operationLogic.js and
// docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md.
exports.recordOperation = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const token = GatewayLogic.parseBearerToken(req.get("Authorization"));
        if (!token) {
            send(res, 401, { ok: false, error: "missing-token" });
            return;
        }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(token);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }
        const actorUid = decoded.uid;

        const body = req.body || {};
        const db = scopedDb(body.env);

        const validated = OperationLogic.validateOperationRequest(body);
        if (!validated.ok) {
            send(res, validated.status, { ok: false, error: validated.error, opIndex: validated.opIndex });
            return;
        }

        const ctx = await deriveContext(db, actorUid);
        if (!ctx) {
            send(res, 403, { ok: false, error: "no-tenant-context" });
            return;
        }

        let result;
        try {
            result = await OperationLogic.applyOperation(db, {
                tenantId: ctx.tenantId,
                actorUid: actorUid,
                actorRole: ctx.role,
                requestId: validated.requestId,
                opType: validated.opType,
                ops: validated.ops,
                clientTimestamp: validated.clientTimestamp,
                serverTimestamp: FieldValue.serverTimestamp()
            });
        } catch (e) {
            console.error("recordOperation write failed", e);
            send(res, 500, { ok: false, error: "write-failed" });
            return;
        }

        if (result && result.ok === false) {
            send(res, result.status || 409, {
                ok: false, error: result.error, opIndex: result.opIndex,
                field: result.field, current: result.current, conflict: result.conflict
            });
            return;
        }

        send(res, 200, {
            ok: true, entryId: validated.requestId, results: result.results,
            idempotentReplay: result.idempotentReplay === true
        });
    });

// Component 2 (async-write-sequencing design). Pessimistic record locking —
// see functions/lib/lockLogic.js for the acquire/renew/reject semantics and
// why this needs no cleanup job (TTL expiry is the safety net, not an
// explicit release). Both endpoints are intentionally symmetric with
// recordMutation/recordDelta's auth+parsing shape.
const LOCK_TTL_MS = 90000; // 90s, with a client-side ~30s renewal heartbeat

exports.acquireLock = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const token = GatewayLogic.parseBearerToken(req.get("Authorization"));
        if (!token) {
            send(res, 401, { ok: false, error: "missing-token" });
            return;
        }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(token);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }
        const actorUid = decoded.uid;

        const body = req.body || {};
        const db = scopedDb(body.env);

        // TTL is server-decided, never client-supplied — a client can ask to
        // acquire, but not dictate how long it gets to hold the lock for.
        const validated = LockLogic.validateAcquireRequest(
            Object.assign({}, body, { ttlMs: LOCK_TTL_MS }));
        if (!validated.ok) {
            send(res, validated.status, { ok: false, error: validated.error });
            return;
        }

        const ctx = await deriveContext(db, actorUid);
        if (!ctx) {
            send(res, 403, { ok: false, error: "no-tenant-context" });
            return;
        }

        let result;
        try {
            result = await LockLogic.acquireLock(db, {
                tenantId: ctx.tenantId,
                entity: validated.entity,
                entityId: validated.entityId,
                requestId: validated.requestId,
                ttlMs: validated.ttlMs,
                actorUid: actorUid,
                actorName: ctx.actorName,
                actorRole: ctx.role,
                now: Date.now()
            });
        } catch (e) {
            send(res, 500, { ok: false, error: "lock-failed" });
            return;
        }

        if (!result.ok) {
            send(res, result.status || 409, { ok: false, holder: result.holder });
            return;
        }

        send(res, 200, { ok: true, expiresAt: result.expiresAt });
    });

exports.releaseLock = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const token = GatewayLogic.parseBearerToken(req.get("Authorization"));
        if (!token) {
            send(res, 401, { ok: false, error: "missing-token" });
            return;
        }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(token);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }
        const actorUid = decoded.uid;

        const body = req.body || {};
        const db = scopedDb(body.env);

        const validated = LockLogic.validateReleaseRequest(body);
        if (!validated.ok) {
            send(res, validated.status, { ok: false, error: validated.error });
            return;
        }

        const ctx = await deriveContext(db, actorUid);
        if (!ctx) {
            send(res, 403, { ok: false, error: "no-tenant-context" });
            return;
        }

        try {
            await LockLogic.releaseLock(db, {
                tenantId: ctx.tenantId,
                entity: validated.entity,
                entityId: validated.entityId,
                holderUid: actorUid
            });
        } catch (e) {
            send(res, 500, { ok: false, error: "release-failed" });
            return;
        }

        send(res, 200, { ok: true });
    });

// New in this session (not in the original P0 spec — see
// functions/lib/batchMutationLogic.js for the design rationale/cap).
// One atomic transaction covering up to MAX_BATCH_SIZE items of the same
// entity, e.g. OrdersStore.approveAllPending. One outbox entry on the
// client represents the whole batch.
exports.recordMutationsBatch = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const token = GatewayLogic.parseBearerToken(req.get("Authorization"));
        if (!token) {
            send(res, 401, { ok: false, error: "missing-token" });
            return;
        }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(token);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }
        const actorUid = decoded.uid;

        const body = req.body || {};
        const db = scopedDb(body.env);

        const validated = BatchMutationLogic.validateBatchMutationRequest(body);
        if (!validated.ok) {
            send(res, validated.status, { ok: false, error: validated.error });
            return;
        }

        const ctx = await deriveContext(db, actorUid);
        if (!ctx) {
            send(res, 403, { ok: false, error: "no-tenant-context" });
            return;
        }

        let result;
        try {
            result = await BatchMutationLogic.applyMutationsBatch(db, {
                tenantId: ctx.tenantId,
                actorUid: actorUid,
                actorRole: ctx.role,
                entity: validated.entity,
                collection: validated.collection,
                requestId: validated.requestId,
                items: validated.items,
                serverTimestamp: FieldValue.serverTimestamp()
            });
        } catch (e) {
            console.error("recordMutationsBatch write failed", e);
            send(res, 500, { ok: false, error: "write-failed" });
            return;
        }

        // review I1: applyMutationsBatch's return value used to be ignored
        // entirely here — a CAS conflict (nothing written, transaction
        // correctly refused) would still get reported to the client as
        // `200 {ok:true}`. Actually check it now.
        if (result && result.ok === false) {
            send(res, result.status || 409, { ok: false, error: "conflict", conflicts: result.conflicts });
            return;
        }

        send(res, 200, { ok: true, requestId: validated.requestId, count: validated.items.length });
    });

// ── One-time fresh-start cutover (P0) ───────────────────────────────────────
// Owner-only, irreversible. Wipes the three ledger collections AND zeroes
// every product's stock, so the immutable regime begins from a clean slate
// (the user re-counts and re-enters stock afterwards, and those entries become
// the first genuine audit_log records). Writes a single "cutover" marker.
//
// Server-side because the ledger collections are locked read-only to clients —
// only the Admin SDK can delete them.

// ── Member provisioning (Admin SDK) ─────────────────────────────────────────
// Adds a teammate to the caller's tenant, handling all three cases the client
// cannot do itself:
//   1. brand-new account  — create the Auth user (email + password)
//   2. existing account   — look it up by email (no duplicate signUp)
//   3. invite-by-uid      — caller already has the target's uid
//
// Why server-side: Firestore rules only let a user write their OWN
// users/{uid} doc (request.auth.uid == uid), but login resolves a member's
// tenant/role from THAT doc — so an owner/admin physically cannot grant tenant
// access from the client. The Admin SDK bypasses the rules, so this function
// writes both users/{uid} (tenant context) AND tenants/{t}/members/{uid} in
// one place. The caller's identity, tenant, and role are derived server-side
// (never trusted from the body), mirroring recordMutation.

// Owner may assign admin/manager/staff; admin may assign manager/staff.
// Mirrors AuthService._canAssignRole so client and server agree.
function canAssignRole(actorRole, targetRole) {
    if (actorRole === "owner")
        return ["admin", "manager", "staff"].indexOf(targetRole) >= 0;
    if (actorRole === "admin")
        return ["manager", "staff"].indexOf(targetRole) >= 0;
    return false;
}

// Resolve an email to an existing Auth user, or create one. `password` is only
// used when creating. Returns { uid, created }.
async function findOrCreateAuthUser(email, password, displayName) {
    try {
        const existing = await admin.auth().getUserByEmail(email);
        return { uid: existing.uid, created: false };
    } catch (e) {
        if (e.code !== "auth/user-not-found") throw e;
    }
    if (!password || password.length < 6) {
        const err = new Error("password-required");
        err.code = "password-required";
        throw err;
    }
    const created = await admin.auth().createUser({
        email: email,
        password: password,
        displayName: displayName || undefined
    });
    return { uid: created.uid, created: true };
}

exports.provisionMember = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const authHeader = req.get("Authorization") || "";
        const match = authHeader.match(/^Bearer\s+(.+)$/i);
        if (!match) { send(res, 401, { ok: false, error: "missing-token" }); return; }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(match[1]);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }

        const body = req.body || {};
        const db = scopedDb(body.env);
        const ctx = await deriveContext(db, decoded.uid);
        if (!ctx) { send(res, 403, { ok: false, error: "no-tenant-context" }); return; }
        if (ctx.role !== "owner" && ctx.role !== "admin") {
            send(res, 403, { ok: false, error: "not-authorized" });
            return;
        }

        const email = String(body.email || "").trim().toLowerCase();
        const displayName = String(body.displayName || "").trim();
        const password = body.password ? String(body.password) : "";
        const targetUid = String(body.uid || "").trim();
        let role = String(body.role || "staff");
        if (["admin", "manager", "staff"].indexOf(role) < 0) role = "staff";

        if (!canAssignRole(ctx.role, role)) {
            send(res, 403, { ok: false, error: "role-not-allowed" });
            return;
        }
        if (!email && !targetUid) {
            send(res, 400, { ok: false, error: "email-or-uid-required" });
            return;
        }

        // Resolve the target uid: explicit uid wins (invite-by-uid), else
        // find-or-create by email (add-staff). Surface the two recoverable
        // cases — duplicate email vs. missing password — with clear codes.
        let uid, created = false, resolvedEmail = email;
        try {
            if (targetUid) {
                uid = targetUid;
                const u = await admin.auth().getUser(targetUid);
                resolvedEmail = u.email || email;
            } else {
                const r = await findOrCreateAuthUser(email, password, displayName);
                uid = r.uid;
                created = r.created;
            }
        } catch (e) {
            if (e.code === "password-required") {
                send(res, 400, { ok: false, error: "password-required" });
                return;
            }
            if (e.code === "auth/user-not-found") {
                send(res, 404, { ok: false, error: "user-not-found" });
                return;
            }
            console.error("provisionMember auth resolve failed", e);
            send(res, 500, { ok: false, error: "auth-failed" });
            return;
        }

        const nowIso = new Date().toISOString();
        const userRef = db.doc("users/" + uid);
        const memberRef = db.doc(
            "tenants/" + ctx.tenantId + "/members/" + uid);

        try {
            await db.runTransaction(async (txn) => {
                const userSnap = await txn.get(userRef);
                const existing = userSnap.exists ? (userSnap.data() || {}) : {};
                const tenants = Array.isArray(existing.tenants)
                    ? existing.tenants.slice() : [];
                if (tenants.indexOf(ctx.tenantId) < 0) tenants.push(ctx.tenantId);

                // Land the member in this tenant on next login. We set the
                // active tenant context to the inviting tenant for a brand-new
                // account; for an existing account we only add to tenants[] and
                // fill role/tenant if absent, so we never yank a user out of
                // a workspace they're already active in.
                const userDoc = {
                    uid: uid,
                    email: existing.email || resolvedEmail,
                    displayName: existing.displayName || displayName,
                    photoUrl: existing.photoUrl || "",
                    tenants: tenants,
                    tenantId: created ? ctx.tenantId : (existing.tenantId || ctx.tenantId),
                    tenantName: created ? ctx.tenantName : (existing.tenantName || ctx.tenantName),
                    role: created ? role : (existing.role || role),
                    createdAt: existing.createdAt || nowIso,
                    lastLoginAt: existing.lastLoginAt || nowIso,
                    status: "active"
                };
                txn.set(userRef, userDoc, { merge: true });

                txn.set(memberRef, {
                    uid: uid,
                    role: role,
                    email: resolvedEmail,
                    displayName: displayName,
                    tenantName: ctx.tenantName,
                    joinedAt: nowIso,
                    invitedBy: decoded.uid,
                    status: "active"
                }, { merge: true });
            });
        } catch (e) {
            console.error("provisionMember write failed", e);
            send(res, 500, { ok: false, error: "write-failed" });
            return;
        }

        send(res, 200, { ok: true, uid: uid, created: created });
    });

exports.runCutover = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const authHeader = req.get("Authorization") || "";
        const match = authHeader.match(/^Bearer\s+(.+)$/i);
        if (!match) { send(res, 401, { ok: false, error: "missing-token" }); return; }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(match[1]);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }

        const body = req.body || {};
        const db = scopedDb(body.env);
        const ctx = await deriveContext(db, decoded.uid);

        const validated = CutoverLogic.validateCutoverRequest(ctx, body);
        if (!validated.ok) {
            send(res, validated.status, { ok: false, error: validated.error });
            return;
        }

        const root = "tenants/" + ctx.tenantId;
        try {
            await CutoverLogic.deleteCollection(db, root + "/transactions");
            await CutoverLogic.deleteCollection(db, root + "/stock_batches");
            await CutoverLogic.deleteCollection(db, root + "/stock_movements");
            await CutoverLogic.zeroInventoryStock(db, root);

            const markerId = "cutover-" + Date.now();
            const marker = CutoverLogic.buildCutoverMarker({
                markerId: markerId,
                tenantId: ctx.tenantId,
                actorUid: decoded.uid,
                actorRole: ctx.role,
                serverTimestamp: FieldValue.serverTimestamp(),
                clientTimestamp: body.clientTimestamp || null
            });
            await db.doc(root + "/audit_log/" + markerId).set(marker);
        } catch (e) {
            send(res, 500, { ok: false, error: "cutover-failed" });
            return;
        }

        send(res, 200, { ok: true });
    });

// ── Analysis compute (Phase 2 of the scale-reads-writes-analytics design) ──
// Runs the Revenue/Profit/Sold/Purchased aggregation server-side instead of
// requiring the full transaction ledger resident in the QML client. Reuses
// the SAME math as the client -- functions/lib/{orderMath,realisedMath,
// breakdownMath}.js are ports of qml/helper/{OrderMath,RealisedMath,
// BreakdownMath}.js, parity-tested against shared fixtures (functions/test/).
//
// Honest note on "paginated, not streaming": readAllPaged() below paginates
// the READS (Admin SDK, <=500 docs per internal page) so a huge ledger never
// hits a single-query response-size/timeout limit -- but the accumulated
// result is still one in-memory array by the time RealisedMath/BreakdownMath
// run, because those functions take a full `entries` array as their contract
// (same as the QML originals). This is a deliberate, simpler first cut: even
// fully materialized, a tenant's lifetime transaction history fits
// comfortably in a Cloud Function's memory (far more headroom than a phone),
// and the actual failure mode this fixes -- an unbounded read tripping
// Firestore's response limits -- is solved either way. A true streaming/
// incremental-reducer version of the math is a possible future refinement if
// a ledger ever grows large enough for even server-side memory to matter;
// not needed for this pass.

const ANALYSIS_PAGE_SIZE = 500;

async function readAllPaged(db, collectionPath, pageSize) {
    pageSize = pageSize || ANALYSIS_PAGE_SIZE;
    const out = [];
    const base = db.collection(collectionPath).orderBy("__name__").limit(pageSize);
    let lastDoc = null;
    for (;;) {
        const q = lastDoc ? base.startAfter(lastDoc) : base;
        const snap = await q.get();
        if (snap.empty) break;
        for (const doc of snap.docs) out.push(doc.data());
        if (snap.docs.length < pageSize) break;
        lastDoc = snap.docs[snap.docs.length - 1];
    }
    return out;
}

function buildProductCategoryMap(products) {
    const map = {};
    for (const p of products) if (p && p.productId) map[p.productId] = p.category || "";
    return map;
}

function buildSupplierNameMap(suppliers) {
    const map = {};
    for (const s of suppliers) if (s && s.supplierId) map[s.supplierId] = s.name || "";
    return map;
}

function buildOrderLookup(orders) {
    const map = {};
    for (const o of orders) if (o && o.orderId) map[o.orderId] = o;
    return function(orderId) { return map[orderId] || null; };
}

const ANALYSIS_VIEW_MODES = ["revenue", "profit", "sold", "purchased"];

exports.computeAnalysis = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const authHeader = req.get("Authorization") || "";
        const match = authHeader.match(/^Bearer\s+(.+)$/i);
        if (!match) { send(res, 401, { ok: false, error: "missing-token" }); return; }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(match[1]);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }

        const body = req.body || {};
        const db = scopedDb(body.env);
        const ctx = await deriveContext(db, decoded.uid);
        if (!ctx) { send(res, 403, { ok: false, error: "no-tenant-context" }); return; }

        const viewMode = String(body.viewMode || "");
        if (ANALYSIS_VIEW_MODES.indexOf(viewMode) < 0) {
            send(res, 400, { ok: false, error: "unsupported-view-mode" });
            return;
        }
        const period = Number.isInteger(body.period) ? body.period : 0;
        const dims = Array.isArray(body.dims) && body.dims.length > 0
            ? body.dims : ["category", "supplier"];
        const scope = body.scope || {};
        const periodScoped = !!body.periodScoped;

        const tenantRoot = "tenants/" + ctx.tenantId;
        const needsOrders = (viewMode === "revenue" || viewMode === "profit");

        try {
            const [entries, orders, products, suppliers] = await Promise.all([
                readAllPaged(db, tenantRoot + "/transactions"),
                needsOrders ? readAllPaged(db, tenantRoot + "/orders") : Promise.resolve([]),
                readAllPaged(db, tenantRoot + "/inventory"),
                readAllPaged(db, tenantRoot + "/suppliers")
            ]);

            const productCategoryMap = buildProductCategoryMap(products);
            const supplierNameMap = buildSupplierNameMap(suppliers);
            const categoryOf = function(pid) { return productCategoryMap[pid] || ""; };
            const orderLookup = buildOrderLookup(orders);

            const now = new Date();
            const periodWin = BreakdownMath.periodWindow(period, now);
            const explicitWin = (scope.window && scope.window.from && scope.window.to)
                ? { from: new Date(scope.window.from), to: new Date(scope.window.to) }
                : null;
            const win = periodScoped
                ? BreakdownMath.intersect(periodWin, explicitWin)
                : explicitWin;

            const realisedScope = {
                window: win,
                channel: scope.channel || "",
                staffId: scope.staffId || "",
                category: scope.category || "",
                supplierId: scope.supplierId || ""
            };
            const lookups = { categoryOf: categoryOf, orderLookup: orderLookup };

            let totals = null;
            const byDimension = {};
            const bucketWalk = {};

            if (viewMode === "revenue" || viewMode === "profit") {
                totals = RealisedMath.totals(entries, realisedScope, lookups);
                for (const dim of dims) {
                    const field = (dim === "supplier") ? "supplierId" : dim;
                    byDimension[dim] = RealisedMath.byDimension(field, entries, realisedScope, lookups);
                }
                const metric = (viewMode === "revenue") ? "net" : "profit";
                bucketWalk[metric] = RealisedMath.bucketWalk(
                    metric, period, entries, realisedScope, now, lookups);
            } else {
                // sold / purchased -- unit metrics via BreakdownMath.
                for (const dim of dims) {
                    byDimension[dim] = BreakdownMath.breakdown({
                        metric: viewMode, dim: dim,
                        orders: orders, entries: entries, window: win,
                        channel: realisedScope.channel, staffId: realisedScope.staffId,
                        category: realisedScope.category, supplierId: realisedScope.supplierId,
                        productCategory: productCategoryMap,
                        supplierName: supplierNameMap
                    });
                }
            }

            send(res, 200, { ok: true, totals: totals, byDimension: byDimension, bucketWalk: bucketWalk });
        } catch (e) {
            console.error("computeAnalysis failed", e);
            send(res, 500, { ok: false, error: "compute-failed" });
        }
    });

// Product photos (2026-09-21). Two handlers: uploadProductPhoto writes both Storage objects then
// appends the id in one Firestore transaction; deleteProductPhoto removes the id and best-effort
// deletes the objects. Neither goes through GatewayLogic.applyMutation -- that helper replaces a
// whole working-tier doc from a client-supplied `after`, which doesn't fit an array-append/remove
// against a doc this handler itself reads. The idempotency mechanism (audit_log/{requestId}) and
// overall shape still mirror applyMutation deliberately.
// Design: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md

exports.uploadProductPhoto = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const token = GatewayLogic.parseBearerToken(req.get("Authorization"));
        if (!token) {
            send(res, 401, { ok: false, error: "missing-token" });
            return;
        }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(token);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }
        const actorUid = decoded.uid;

        const body = req.body || {};
        const db = scopedDb(body.env);

        const productId = String(body.productId || "");
        const photoId = String(body.photoId || "");
        const requestId = String(body.requestId || photoId || "");
        if (!productId || !photoId || !requestId) {
            send(res, 400, { ok: false, error: "invalid-request" });
            return;
        }
        if (!PhotoValidation.isSafePathSegment(productId) || !PhotoValidation.isSafePathSegment(photoId)) {
            send(res, 400, { ok: false, error: "invalid-request" });
            return;
        }

        const ctx = await deriveContext(db, actorUid);
        if (!ctx) {
            send(res, 403, { ok: false, error: "no-tenant-context" });
            return;
        }

        const mainBuf = Buffer.from(String(body.imageBase64 || ""), "base64");
        const thumbBuf = Buffer.from(String(body.thumbBase64 || ""), "base64");

        const mainCheck = PhotoValidation.validateImage(mainBuf, { maxBytes: MAIN_IMAGE_MAX_BYTES });
        if (!mainCheck.ok) {
            send(res, mainCheck.code === "image-too-large" ? 413 : 400, { ok: false, error: mainCheck.code });
            return;
        }
        const thumbCheck = PhotoValidation.validateImage(thumbBuf, { maxBytes: THUMB_IMAGE_MAX_BYTES });
        if (!thumbCheck.ok) {
            send(res, thumbCheck.code === "image-too-large" ? 413 : 400, { ok: false, error: thumbCheck.code });
            return;
        }

        const tenantRoot = "tenants/" + ctx.tenantId;
        const auditRef = db.doc(tenantRoot + "/audit_log/" + requestId);
        const productRef = db.doc(tenantRoot + "/inventory/" + productId);

        // Idempotency check up front, before touching Storage at all -- a retried call with the
        // same requestId must not re-upload.
        const existingAudit = await auditRef.get();
        if (existingAudit.exists) {
            const productSnap = await productRef.get();
            const photoIds = productSnap.exists ? (productSnap.data().photoIds || []) : [];
            send(res, 200, { ok: true, already: true, photoId: photoId, photoIds: photoIds });
            return;
        }

        const envPrefix = storageEnvPrefix(body.env);
        const mainPath = photoStoragePath(envPrefix, ctx.tenantId, productId, photoId, false);
        const thumbPath = photoStoragePath(envPrefix, ctx.tenantId, productId, photoId, true);
        const bucket = admin.storage().bucket(PHOTO_BUCKET_NAME);

        try {
            await bucket.file(mainPath).save(mainBuf, { contentType: "image/jpeg" });
            await bucket.file(thumbPath).save(thumbBuf, { contentType: "image/jpeg" });
        } catch (e) {
            console.error("uploadProductPhoto: Storage write failed", e);
            send(res, 500, { ok: false, error: "storage-write-failed" });
            return;
        }

        // Storage writes above are outside this transaction -- Storage has no transactional join
        // with Firestore. If this transaction throws after the writes above succeeded, the objects
        // are orphaned but unreferenced (no id points at missing bytes, only the reverse) --
        // accepted risk, see the design spec.
        let txnResult;
        try {
            txnResult = await db.runTransaction(async (txn) => {
                const existing = await txn.get(auditRef);
                if (existing.exists) {
                    const productSnap = await txn.get(productRef);
                    const photoIds = productSnap.exists ? (productSnap.data().photoIds || []) : [];
                    return { ok: true, already: true, photoIds: photoIds };
                }

                const productSnap = await txn.get(productRef);
                if (!productSnap.exists) return { ok: false, status: 404, error: "product-not-found" };
                const product = productSnap.data() || {};
                const photoIds = Array.isArray(product.photoIds) ? product.photoIds.slice() : [];
                if (photoIds.indexOf(photoId) === -1) {
                    if (photoIds.length >= MAX_PHOTOS_PER_PRODUCT) {
                        return { ok: false, status: 409, error: "photo-limit" };
                    }
                    photoIds.push(photoId);
                }

                txn.set(productRef, Object.assign({}, product, { photoIds: photoIds }), { merge: true });
                txn.set(auditRef, {
                    entryId: requestId, tenantId: ctx.tenantId, actorUid: actorUid, actorRole: ctx.role,
                    action: "photo-upload", entity: "product-photo", entityId: productId,
                    before: null, after: { photoId: photoId },
                    serverTimestamp: FieldValue.serverTimestamp(),
                    clientTimestamp: body.clientTimestamp || null, requestId: requestId
                });
                return { ok: true, photoIds: photoIds };
            });
        } catch (e) {
            console.error("uploadProductPhoto write failed", e);
            send(res, 500, { ok: false, error: "write-failed" });
            return;
        }

        if (txnResult && txnResult.ok === false) {
            send(res, txnResult.status || 500, { ok: false, error: txnResult.error });
            return;
        }

        send(res, 200, {
            ok: true, already: !!txnResult.already, photoId: photoId, photoIds: txnResult.photoIds
        });
    });

exports.deleteProductPhoto = functions.onRequest(
    { region: "asia-south1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const token = GatewayLogic.parseBearerToken(req.get("Authorization"));
        if (!token) {
            send(res, 401, { ok: false, error: "missing-token" });
            return;
        }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(token);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }
        const actorUid = decoded.uid;

        const body = req.body || {};
        const db = scopedDb(body.env);

        const productId = String(body.productId || "");
        const photoId = String(body.photoId || "");
        const requestId = String(body.requestId || (photoId ? "del-" + photoId : ""));
        if (!productId || !photoId || !requestId) {
            send(res, 400, { ok: false, error: "invalid-request" });
            return;
        }
        if (!PhotoValidation.isSafePathSegment(productId) || !PhotoValidation.isSafePathSegment(photoId)) {
            send(res, 400, { ok: false, error: "invalid-request" });
            return;
        }

        const ctx = await deriveContext(db, actorUid);
        if (!ctx) {
            send(res, 403, { ok: false, error: "no-tenant-context" });
            return;
        }

        const tenantRoot = "tenants/" + ctx.tenantId;
        const auditRef = db.doc(tenantRoot + "/audit_log/" + requestId);
        const productRef = db.doc(tenantRoot + "/inventory/" + productId);

        // Deliberately tolerant of a missing product doc, unlike uploadProductPhoto's 404 --
        // the product-delete cascade (InventoryStore.deleteProduct) may call this either before
        // or after the product's own delete mutation has landed, and Storage cleanup should
        // proceed either way. Removing an id that's already absent from the array is a no-op,
        // not an error, for the same "best-effort" reason.
        let txnResult;
        try {
            txnResult = await db.runTransaction(async (txn) => {
                const existing = await txn.get(auditRef);
                if (existing.exists) return { ok: true, already: true };

                const productSnap = await txn.get(productRef);
                let photoIds = null;
                if (productSnap.exists) {
                    const product = productSnap.data() || {};
                    photoIds = (Array.isArray(product.photoIds) ? product.photoIds : [])
                        .filter((id) => id !== photoId);
                    txn.set(productRef, Object.assign({}, product, { photoIds: photoIds }), { merge: true });
                }
                txn.set(auditRef, {
                    entryId: requestId, tenantId: ctx.tenantId, actorUid: actorUid, actorRole: ctx.role,
                    action: "photo-delete", entity: "product-photo", entityId: productId,
                    before: { photoId: photoId }, after: null,
                    serverTimestamp: FieldValue.serverTimestamp(),
                    clientTimestamp: body.clientTimestamp || null, requestId: requestId
                });
                return { ok: true, photoIds: photoIds };
            });
        } catch (e) {
            console.error("deleteProductPhoto write failed", e);
            send(res, 500, { ok: false, error: "write-failed" });
            return;
        }

        // Best-effort Storage cleanup -- errors are logged and swallowed. A leftover unreferenced
        // object is a storage-cost issue, not a correctness one (design spec). Skipped entirely on
        // an idempotent replay (txnResult.already) -- the first call already deleted these objects;
        // deleting again is harmless to Storage itself but pointless work, and more importantly
        // was firing on EVERY replay call with no bound, which a retried outbox item could do
        // indefinitely (caught by the "idempotent retry ... no re-delete on replay" test below).
        if (!txnResult.already) {
            const envPrefix = storageEnvPrefix(body.env);
            const mainPath = photoStoragePath(envPrefix, ctx.tenantId, productId, photoId, false);
            const thumbPath = photoStoragePath(envPrefix, ctx.tenantId, productId, photoId, true);
            const bucket = admin.storage().bucket(PHOTO_BUCKET_NAME);
            try { await bucket.file(mainPath).delete(); } catch (e) { console.error("deleteProductPhoto: main object delete failed", e); }
            try { await bucket.file(thumbPath).delete(); } catch (e) { console.error("deleteProductPhoto: thumb object delete failed", e); }
        }

        send(res, 200, { ok: true, already: !!txnResult.already, photoIds: txnResult.photoIds });
    });
