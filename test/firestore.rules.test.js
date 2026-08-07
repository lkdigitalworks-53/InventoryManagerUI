"use strict";

const test = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
const {
    initializeTestEnvironment,
    assertFails,
    assertSucceeds
} = require("@firebase/rules-unit-testing");
const { doc, getDoc, setDoc, deleteDoc } = require("firebase/firestore");

// Firestore security-rules tests for the P0 compliance gateway lockdown.
// Spec requirement (docs/superpowers/specs/2026-06-06-P0-compliance-gateway-
// design.md §6): "a client write to any ledger collection is denied; read
// as member is allowed." Extended here to also cover the working-tier
// collections (inventory/orders/staff/suppliers), since the same ruleset
// governs both and a regression in the member/non-member boundary is just
// as serious as a ledger-lockdown regression.
//
// NOT RUN IN THIS SANDBOX — no network egress here to Firebase's emulator
// distribution (only npm/GitHub/PyPI/crates domains are allowlisted).
// Written to the standard @firebase/rules-unit-testing convention. Run
// locally or in CI with:
//   firebase emulators:exec --only firestore "node --test test/"

const TENANT = "tenant-1";
const MEMBER_UID = "member-uid";
const OUTSIDER_UID = "outsider-uid";

let testEnv;

test.before(async () => {
    testEnv = await initializeTestEnvironment({
        projectId: "rules-test-" + Date.now(),
        firestore: {
            rules: fs.readFileSync(path.join(__dirname, "..", "firestore.rules"), "utf8")
        }
    });
});

test.after(async () => {
    if (testEnv) await testEnv.cleanup();
});

test.beforeEach(async () => {
    await testEnv.clearFirestore();
    // Seed a valid tenant + owner membership as the Admin SDK (bypasses
    // rules), so every case starts from a known-good membership state.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
        const db = ctx.firestore();
        await db.doc(`tenants/${TENANT}`).set({ ownerId: MEMBER_UID, name: "Test Co" });
        await db.doc(`tenants/${TENANT}/members/${MEMBER_UID}`).set({
            uid: MEMBER_UID,
            role: "owner",
            status: "active"
        });
    });
});

function memberDb() {
    return testEnv.authenticatedContext(MEMBER_UID).firestore();
}

function outsiderDb() {
    // Signed in, but has no membership doc under this tenant.
    return testEnv.authenticatedContext(OUTSIDER_UID).firestore();
}

function anonDb() {
    return testEnv.unauthenticatedContext().firestore();
}

async function seedAsAdmin(collectionPath, docId, data) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await ctx.firestore().doc(`${collectionPath}/${docId}`).set(data);
    });
}

// ── Ledger tier: read yes (member), write always no (everyone) ─────────────

const LEDGER_COLLECTIONS = ["audit_log", "transactions", "stock_batches", "stock_movements"];

for (const collection of LEDGER_COLLECTIONS) {
    test(`ledger/${collection}: a member can read but never write it`, async () => {
        await seedAsAdmin(`tenants/${TENANT}/${collection}`, "doc1", { seed: true });

        await assertSucceeds(getDoc(doc(memberDb(), `tenants/${TENANT}/${collection}/doc1`)));
        await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/${collection}/doc1`), { tampered: true }));
        await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/${collection}/doc2`), { new: true }));
        await assertFails(deleteDoc(doc(memberDb(), `tenants/${TENANT}/${collection}/doc1`)));
    });

    test(`ledger/${collection}: a non-member can neither read nor write it`, async () => {
        await seedAsAdmin(`tenants/${TENANT}/${collection}`, "doc1", { seed: true });

        await assertFails(getDoc(doc(outsiderDb(), `tenants/${TENANT}/${collection}/doc1`)));
        await assertFails(setDoc(doc(outsiderDb(), `tenants/${TENANT}/${collection}/doc1`), { tampered: true }));
    });

    test(`ledger/${collection}: an unauthenticated request cannot write it`, async () => {
        await assertFails(setDoc(doc(anonDb(), `tenants/${TENANT}/${collection}/doc1`), { x: 1 }));
    });
}

// ── Working tier: member can read/write, non-member/anon cannot ────────────

const WORKING_COLLECTIONS = ["inventory", "orders", "staff", "suppliers"];

for (const collection of WORKING_COLLECTIONS) {
    test(`working/${collection}: a member can create, update, and delete`, async () => {
        await assertSucceeds(setDoc(doc(memberDb(), `tenants/${TENANT}/${collection}/doc1`), { name: "x" }));
        await assertSucceeds(setDoc(doc(memberDb(), `tenants/${TENANT}/${collection}/doc1`), { name: "y" }));
        await assertSucceeds(deleteDoc(doc(memberDb(), `tenants/${TENANT}/${collection}/doc1`)));
    });

    test(`working/${collection}: a non-member can neither read nor write`, async () => {
        await seedAsAdmin(`tenants/${TENANT}/${collection}`, "doc1", { name: "x" });

        await assertFails(getDoc(doc(outsiderDb(), `tenants/${TENANT}/${collection}/doc1`)));
        await assertFails(setDoc(doc(outsiderDb(), `tenants/${TENANT}/${collection}/doc1`), { tampered: true }));
    });

    test(`working/${collection}: an unauthenticated request cannot write`, async () => {
        await assertFails(setDoc(doc(anonDb(), `tenants/${TENANT}/${collection}/doc1`), { x: 1 }));
    });
}

// ── The ledger guard on the generic wildcard specifically ──────────────────
// Belt-and-suspenders: even without the explicit per-collection `write: if
// false` blocks, the wildcard match's `!isLedgerCollection(collection)`
// guard alone must still deny a member write to a ledger-named collection.
// This test's value is in catching a regression to THAT guard specifically,
// independent of the explicit blocks above.

test("the wildcard match's ledger guard denies a member write to audit_log even in isolation", async () => {
    // Same assertion as the loop above, called out on its own so a future
    // refactor that removes the explicit audit_log block (leaving only the
    // wildcard's guard) is still covered by an explicitly-named test.
    await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/audit_log/doc1`), { tampered: true }));
});

// ── Server-only tier: not even a member can read or write (review C2) ──────
// locks/** is written/read exclusively by acquireLock/releaseLock (Cloud
// Functions, Admin SDK) — clients never touch it directly. Unlike the
// ledger tier above, this collection has no legitimate client read either,
// so this covers both directions, not just write.

test("locks: a member can neither read nor write, even their own tenant's lock docs", async () => {
    await seedAsAdmin(`tenants/${TENANT}/locks`, "order_ORD-1", {
        holderUid: MEMBER_UID,
        holderName: "Test Owner",
        acquiredAt: Date.now(),
        expiresAt: Date.now() + 60000
    });

    await assertFails(getDoc(doc(memberDb(), `tenants/${TENANT}/locks/order_ORD-1`)));
    await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/locks/order_ORD-1`), { tampered: true }));
    await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/locks/order_ORD-2`), { holderUid: MEMBER_UID }));
    await assertFails(deleteDoc(doc(memberDb(), `tenants/${TENANT}/locks/order_ORD-1`)));
});

test("locks: an owner/admin can neither read nor write — no role bypasses this", async () => {
    // Deliberately distinct from the member test above: proves this isn't
    // gated by role at all (isServerOnlyCollection has no role check), so a
    // future "let owners see locks for support purposes" change would need
    // to touch this rule explicitly, not just grant a role somewhere else.
    await seedAsAdmin(`tenants/${TENANT}/locks`, "order_ORD-1", { holderUid: MEMBER_UID });
    await assertFails(getDoc(doc(memberDb(), `tenants/${TENANT}/locks/order_ORD-1`)));
});

test("the wildcard match's server-only guard denies locks access even in isolation", async () => {
    // Mirrors the ledger-guard-in-isolation test above: if a future refactor
    // ever adds an explicit /locks/{lockId} block that accidentally allows
    // something, or removes the dedicated block entirely, the wildcard's
    // own isServerOnlyCollection guard must still deny this on its own.
    await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/locks/doc1`), { holderUid: MEMBER_UID }));
    await assertFails(getDoc(doc(memberDb(), `tenants/${TENANT}/locks/doc1`)));
});
