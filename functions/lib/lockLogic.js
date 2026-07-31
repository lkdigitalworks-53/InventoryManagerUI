"use strict";

// Pessimistic record locking (Component 2, async-write-sequencing design
// §4). A lock is just another Firestore document, acquired/released via the
// same transaction primitive as everything else in this file's siblings
// (gatewayLogic.js) — no special Firestore capability needed. TTL + client-
// side renewal heartbeat (not implemented here — that's the QML side) makes
// an abandoned/crashed session self-heal via expiry, without any cleanup
// job: acquireLock grants over an expired lock exactly like it would over a
// missing one.

function _ref(db, params) {
    return db.doc("tenants/" + params.tenantId + "/locks/" + params.entity + "_" + params.entityId);
}

async function acquireLock(db, params) {
    const ref = _ref(db, params);

    return db.runTransaction(async (txn) => {
        const snap = await txn.get(ref);

        if (snap.exists) {
            const current = snap.data();
            const expired = current.expiresAt <= params.now;
            const sameHolder = current.holderUid === params.actorUid;
            if (!expired && !sameHolder) {
                return {
                    ok: false,
                    status: 409,
                    holder: { name: current.holderName, role: current.holderRole, expiresAt: current.expiresAt }
                };
            }
        }

        const expiresAt = params.now + params.ttlMs;
        txn.set(ref, {
            entity: params.entity,
            entityId: params.entityId,
            holderUid: params.actorUid,
            holderName: params.actorName,
            holderRole: params.actorRole,
            acquiredAt: params.now,
            expiresAt: expiresAt,
            requestId: params.requestId
        });
        return { ok: true, acquiredAt: params.now, expiresAt: expiresAt };
    });
}

// Deletes the lock only if the caller's holderUid still matches what's
// stored — a stale/duplicate release call (e.g. from a session whose lock
// already expired and was re-acquired by someone else) is a silent no-op,
// never an error, and never touches the new holder's lock.
async function releaseLock(db, params) {
    const ref = _ref(db, params);

    return db.runTransaction(async (txn) => {
        const snap = await txn.get(ref);
        if (!snap.exists) return { ok: true };

        const current = snap.data();
        if (current.holderUid !== params.holderUid) return { ok: true, skipped: true };

        txn.delete(ref);
        return { ok: true };
    });
}

module.exports = { acquireLock, releaseLock };
