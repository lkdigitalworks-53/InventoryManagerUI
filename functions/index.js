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

admin.initializeApp();
const db = admin.firestore();

// P0 scope. `entity` → collection name under the tenant root. `inventory`
// is working-tier (also client-writable); the rest are locked ledger
// collections only this function may write.
const ENTITY_COLLECTIONS = {
    inventory: "inventory",
    stock_batch: "stock_batches",
    stock_movement: "stock_movements",
    transaction: "transactions"
};

const ALLOWED_ACTIONS = ["create", "update", "delete", "opening_balance"];

function send(res, status, body) {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    res.status(status).json(body);
}

async function deriveContext(uid) {
    // Tenant + role come from the server's own records, not the client.
    const userSnap = await db.doc("users/" + uid).get();
    if (!userSnap.exists) return null;
    const user = userSnap.data() || {};
    const tenantId = user.tenantId || "";
    if (!tenantId) return null;

    let role = user.role || "";
    const memberSnap = await db.doc(
        "tenants/" + tenantId + "/members/" + uid).get();
    if (memberSnap.exists) {
        const member = memberSnap.data() || {};
        role = member.role || role;
        if (member.status && member.status !== "active") return null;
    }
    return { tenantId: tenantId, role: role };
}

exports.recordMutation = functions.onRequest(
    { region: "asia-southeast1", cors: true },
    async (req, res) => {
        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
        if (req.method !== "POST") {
            send(res, 405, { ok: false, error: "method-not-allowed" });
            return;
        }

        const authHeader = req.get("Authorization") || "";
        const match = authHeader.match(/^Bearer\s+(.+)$/i);
        if (!match) {
            send(res, 401, { ok: false, error: "missing-token" });
            return;
        }

        let decoded;
        try {
            decoded = await admin.auth().verifyIdToken(match[1]);
        } catch (e) {
            send(res, 401, { ok: false, error: "invalid-token" });
            return;
        }
        const actorUid = decoded.uid;

        const body = req.body || {};
        const entity = String(body.entity || "");
        const entityId = String(body.entityId || "");
        const action = String(body.action || "");
        const requestId = String(body.requestId || "");
        const before = body.before === undefined ? null : body.before;
        const after = body.after === undefined ? null : body.after;
        const clientTimestamp = body.clientTimestamp || null;

        const collection = ENTITY_COLLECTIONS[entity];
        if (!collection) {
            send(res, 400, { ok: false, error: "unsupported-entity" });
            return;
        }
        if (ALLOWED_ACTIONS.indexOf(action) < 0) {
            send(res, 400, { ok: false, error: "unsupported-action" });
            return;
        }
        if (!entityId || !requestId) {
            send(res, 400, { ok: false, error: "missing-fields" });
            return;
        }

        const ctx = await deriveContext(actorUid);
        if (!ctx) {
            send(res, 403, { ok: false, error: "no-tenant-context" });
            return;
        }

        const tenantRoot = "tenants/" + ctx.tenantId;
        const auditRef = db.doc(tenantRoot + "/audit_log/" + requestId);
        const workingRef = db.doc(tenantRoot + "/" + collection + "/" + entityId);

        try {
            await db.runTransaction(async (txn) => {
                const existing = await txn.get(auditRef);
                if (existing.exists) return; // idempotent retry — already applied

                if (action === "delete") {
                    txn.delete(workingRef);
                } else {
                    txn.set(workingRef, after || {}, { merge: false });
                }

                txn.set(auditRef, {
                    entryId: requestId,
                    tenantId: ctx.tenantId,
                    actorUid: actorUid,
                    actorRole: ctx.role,
                    action: action,
                    entity: entity,
                    entityId: entityId,
                    before: before,
                    after: after,
                    serverTimestamp: admin.firestore.FieldValue.serverTimestamp(),
                    clientTimestamp: clientTimestamp,
                    requestId: requestId
                });
            });
        } catch (e) {
            send(res, 500, { ok: false, error: "write-failed" });
            return;
        }

        send(res, 200, { ok: true, entryId: requestId });
    });

// ── One-time fresh-start cutover (P0) ───────────────────────────────────────
// Owner-only, irreversible. Wipes the three ledger collections AND zeroes
// every product's stock, so the immutable regime begins from a clean slate
// (the user re-counts and re-enters stock afterwards, and those entries become
// the first genuine audit_log records). Writes a single "cutover" marker.
//
// Server-side because the ledger collections are locked read-only to clients —
// only the Admin SDK can delete them.

async function deleteCollection(path) {
    const snap = await db.collection(path).get();
    let batch = db.batch();
    let n = 0;
    for (const doc of snap.docs) {
        batch.delete(doc.ref);
        if (++n % 400 === 0) { await batch.commit(); batch = db.batch(); }
    }
    if (n % 400 !== 0) await batch.commit();
    return snap.size;
}

exports.runCutover = functions.onRequest(
    { region: "asia-southeast1", cors: true },
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

        const ctx = await deriveContext(decoded.uid);
        if (!ctx) { send(res, 403, { ok: false, error: "no-tenant-context" }); return; }
        if (ctx.role !== "owner") {
            send(res, 403, { ok: false, error: "owner-only" });
            return;
        }
        if (String((req.body || {}).confirm || "") !== "CUTOVER") {
            send(res, 400, { ok: false, error: "confirmation-required" });
            return;
        }

        const root = "tenants/" + ctx.tenantId;
        try {
            await deleteCollection(root + "/transactions");
            await deleteCollection(root + "/stock_batches");
            await deleteCollection(root + "/stock_movements");

            // Zero every product's stock.
            const inv = await db.collection(root + "/inventory").get();
            let batch = db.batch();
            let n = 0;
            for (const doc of inv.docs) {
                batch.update(doc.ref, { stock: 0 });
                if (++n % 400 === 0) { await batch.commit(); batch = db.batch(); }
            }
            if (n % 400 !== 0) await batch.commit();

            // Single immutable cutover marker.
            const markerId = "cutover-" + Date.now();
            await db.doc(root + "/audit_log/" + markerId).set({
                entryId: markerId,
                tenantId: ctx.tenantId,
                actorUid: decoded.uid,
                actorRole: ctx.role,
                action: "cutover",
                entity: "tenant",
                entityId: ctx.tenantId,
                before: null,
                after: { note: "Fresh-start cutover: ledger wiped, stock zeroed." },
                serverTimestamp: admin.firestore.FieldValue.serverTimestamp(),
                clientTimestamp: (req.body || {}).clientTimestamp || null,
                requestId: markerId
            });
        } catch (e) {
            send(res, 500, { ok: false, error: "cutover-failed" });
            return;
        }

        send(res, 200, { ok: true });
    });
