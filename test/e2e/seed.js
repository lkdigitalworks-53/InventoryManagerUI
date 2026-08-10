"use strict";

// Seeds a minimal tenant + membership + auth user directly into the
// Firebase Local Emulator Suite (Firestore + Auth), then mints a real
// (emulator-signed) ID token for that user and writes it — plus the ids
// the QML e2e test needs — to test/e2e/.fixture.json.
//
// Must run BEFORE qmltestrunner, inside the same `firebase emulators:exec`
// invocation that starts firestore+auth+functions — see
// .github/workflows/checks.yml's e2e-tests job, or run locally with:
//   firebase emulators:exec --only firestore,auth,functions \
//     "node test/e2e/seed.js && qmltestrunner -input tests/e2e -platform offscreen"
//
// NOT RUN IN THIS SANDBOX — no network egress here to Firebase's emulator
// distribution. Written to documented Local Emulator Suite REST/Admin SDK
// conventions; needs a real emulator pass (CI or Taher's machine) before
// the e2e-tests job can be trusted. Specifically unverified: whether
// `firebase emulators:exec` sets FIREBASE_AUTH_EMULATOR_HOST for child
// processes exactly as documented for this firebase-tools version — if
// this script exits early with the guard below, that's the first thing to
// check.

const fs = require("node:fs");
const path = require("node:path");
const admin = require("firebase-admin");

const PROJECT_ID = "inventorymanager-48392"; // MUST match FirebaseService.qml's
                                              // hardcoded projectId — the emulator
                                              // namespaces data by projectId, and
                                              // the QML client can't override that,
                                              // only which host it talks to.
const TENANT_ID = "e2e-tenant";
const TEST_UID = "e2e-owner";
const SUPPLIER_ID = "SUP-001";
const SUPPLIER_NAME = "E2E Supplier";
const AUTH_EMULATOR_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || "";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
    console.error("seed.js: FIRESTORE_EMULATOR_HOST is not set — refusing to run " +
                   "against what might be real Firestore.");
    process.exit(1);
}
if (!AUTH_EMULATOR_HOST) {
    console.error("seed.js: FIREBASE_AUTH_EMULATOR_HOST is not set — refusing to run " +
                   "against what might be real Firebase Auth.");
    process.exit(1);
}

admin.initializeApp({ projectId: PROJECT_ID });

async function mintIdToken(uid) {
    // Admin SDK can only mint a *custom* token. Exchanging it for a real ID
    // token that Cloud Functions' verifyIdToken() and the Firestore
    // emulator's rules evaluation will both accept is done via the Auth
    // emulator's identitytoolkit-compatible REST endpoint — documented
    // Local Emulator Suite behavior; any non-empty string works as the API
    // key, the emulator doesn't check it.
    const customToken = await admin.auth().createCustomToken(uid);
    const url = "http://" + AUTH_EMULATOR_HOST
        + "/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=fake-api-key";
    const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token: customToken, returnSecureToken: true })
    });
    if (!res.ok) {
        throw new Error("signInWithCustomToken failed: " + res.status + " " + await res.text());
    }
    const data = await res.json();
    return data.idToken;
}

async function main() {
    const db = admin.firestore();

    await admin.auth().createUser({ uid: TEST_UID, email: "e2e@example.com" })
        .catch((e) => {
            if (e.code !== "auth/uid-already-exists") throw e;
        });

    await db.doc("users/" + TEST_UID).set({
        tenantId: TENANT_ID,
        tenantName: "E2E Test Co",
        role: "owner",
        name: "E2E Owner"
    });
    await db.doc("tenants/" + TENANT_ID).set({
        ownerId: TEST_UID,
        name: "E2E Test Co"
    });
    await db.doc("tenants/" + TENANT_ID + "/members/" + TEST_UID).set({
        uid: TEST_UID,
        role: "owner",
        status: "active",
        name: "E2E Owner"
    });
    // Pre-seeded so the pilot's addProduct() call resolves the supplier
    // name synchronously (InventoryStore._resolveSupplierId ->
    // SupplierStore.findByName) instead of also exercising supplier
    // creation through the gateway — keeps the pilot scoped to inventory
    // CRUD only, per the approved spec.
    await db.doc("tenants/" + TENANT_ID + "/suppliers/" + SUPPLIER_ID).set({
        supplierId: SUPPLIER_ID,
        name: SUPPLIER_NAME
    });

    const idToken = await mintIdToken(TEST_UID);

    const fixture = {
        idToken: idToken,
        uid: TEST_UID,
        tenantId: TENANT_ID,
        supplierId: SUPPLIER_ID,
        supplierName: SUPPLIER_NAME
    };
    const outPath = path.join(__dirname, ".fixture.json");
    fs.writeFileSync(outPath, JSON.stringify(fixture, null, 2));
    console.log("seed.js: wrote", outPath);
}

main().catch((e) => {
    console.error("seed.js failed:", e);
    process.exit(1);
});
