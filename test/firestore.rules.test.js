"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {
    initializeTestEnvironment,
    assertFails,
    assertSucceeds
} = require("@firebase/rules-unit-testing");
const { doc, collection, getDoc, getDocs, setDoc, updateDoc, deleteDoc } = require("firebase/firestore");

// Firestore security-rules tests for the P0 compliance gateway lockdown.
// Spec requirement (docs/superpowers/specs/2026-06-06-P0-compliance-gateway-
// design.md §6): "a client write to any ledger collection is denied; read
// as member is allowed." Extended here to also cover the working-tier
// collections (orders/staff/suppliers) and the gateway-write-only inventory
// tier (P1 S2c), since the same ruleset governs all of them and a regression
// in the member/non-member boundary is just as serious as a ledger-lockdown
// regression.
//
// NOT RUN IN THIS SANDBOX — no network egress here to Firebase's emulator
// distribution (only npm/GitHub/PyPI/crates domains are allowlisted).
// Written to the standard @firebase/rules-unit-testing convention. Run
// locally or in CI with:
//   firebase emulators:exec --only firestore "node --test test/firestore.rules.test.js"
//
// Must target this file explicitly, not the bare "test/" directory: Node's
// test runner treats every .js/.cjs/.mjs file under any directory literally
// named "test" as a test file, recursively, regardless of naming — which
// sweeps in test/e2e/seed.js too. seed.js is a fixture-seeding script, not
// a test, and requires the Auth emulator (getAuth() calls) that this job
// deliberately doesn't start (--only firestore) — running it here crashes
// immediately and takes the whole `node --test` invocation down with it
// before any real result gets recorded (found via CI, 2026-08-14: exit
// code 1, zero tests in the junit output, no console output at all since
// --test-reporter-destination redirects everything away from stdout).

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

// Reads a document with the rules off, so a test can prove a denied write left the stored data untouched.
async function readAsAdmin(docPath) {
    let data = null;
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
        const snap = await ctx.firestore().doc(docPath).get();
        data = snap.exists ? snap.data() : null;
    });
    return data;
}

// A signed-in member of TENANT with the given role (beforeEach only seeds the owner).
async function dbAs(uid, role) {
    await seedAsAdmin(`tenants/${TENANT}/members`, uid, { uid, role, status: "active" });
    return testEnv.authenticatedContext(uid).firestore();
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

// inventory is NOT here any more: since S2c it is gateway-write-only (own section below).
const WORKING_COLLECTIONS = ["orders", "staff", "suppliers"];

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

// ── Gateway-write-only tier: inventory (P1 S2c) ────────────────────────────
// Members read products for display; only the gateway Cloud Functions (Admin SDK, rules skipped) write
// them. A lone `match /inventory/{id} { allow write: if false }` would not deny (the wildcard would
// still allow), so isGatewayWriteOnlyCollection + the wildcard's write guard is what these tests pin.

const INVENTORY = `tenants/${TENANT}/inventory`;
const MEMBER_ROLES = ["owner", "admin", "manager", "staff"];

test("S2c inventory: a member can read one product and list the collection", async () => {
    await seedAsAdmin(INVENTORY, "PRD-1", { name: "Widget", stock: 5 });
    await assertSucceeds(getDoc(doc(memberDb(), `${INVENTORY}/PRD-1`)));
    await assertSucceeds(getDocs(collection(memberDb(), INVENTORY)));
});

test("S2c inventory: a member cannot create, overwrite, update or delete a product, and the stored data is untouched", async () => {
    await seedAsAdmin(INVENTORY, "PRD-1", { name: "Widget", stock: 5 });
    const db = memberDb();
    await assertFails(setDoc(doc(db, `${INVENTORY}/PRD-2`), { name: "New" }));
    await assertFails(setDoc(doc(db, `${INVENTORY}/PRD-1`), { name: "Tampered", stock: 999 }));
    await assertFails(updateDoc(doc(db, `${INVENTORY}/PRD-1`), { stock: 999 }));
    await assertFails(deleteDoc(doc(db, `${INVENTORY}/PRD-1`)));
    assert.deepEqual(await readAsAdmin(`${INVENTORY}/PRD-1`), { name: "Widget", stock: 5 });
    assert.equal(await readAsAdmin(`${INVENTORY}/PRD-2`), null);
});

for (const role of MEMBER_ROLES) {
    test(`S2c inventory: a ${role} can read but never write it (no role bypasses the lock)`, async () => {
        const db = await dbAs(`uid-${role}`, role);
        await seedAsAdmin(INVENTORY, "PRD-1", { name: "Widget" });
        await assertSucceeds(getDoc(doc(db, `${INVENTORY}/PRD-1`)));
        await assertFails(setDoc(doc(db, `${INVENTORY}/PRD-9`), { name: "x" }));
        await assertFails(updateDoc(doc(db, `${INVENTORY}/PRD-1`), { name: "y" }));
        await assertFails(deleteDoc(doc(db, `${INVENTORY}/PRD-1`)));
    });
}

test("S2c inventory: a signed-in non-member can neither read nor write it", async () => {
    await seedAsAdmin(INVENTORY, "PRD-1", { name: "Widget" });
    await assertFails(getDoc(doc(outsiderDb(), `${INVENTORY}/PRD-1`)));
    await assertFails(getDocs(collection(outsiderDb(), INVENTORY)));
    await assertFails(setDoc(doc(outsiderDb(), `${INVENTORY}/PRD-1`), { tampered: true }));
    await assertFails(deleteDoc(doc(outsiderDb(), `${INVENTORY}/PRD-1`)));
});

test("S2c inventory: an unauthenticated request can neither read nor write it", async () => {
    await seedAsAdmin(INVENTORY, "PRD-1", { name: "Widget" });
    await assertFails(getDoc(doc(anonDb(), `${INVENTORY}/PRD-1`)));
    await assertFails(setDoc(doc(anonDb(), `${INVENTORY}/PRD-1`), { x: 1 }));
    await assertFails(deleteDoc(doc(anonDb(), `${INVENTORY}/PRD-1`)));
});

test("S2c inventory: a sub-collection under a product is denied by default (no rule matches it)", async () => {
    await assertFails(setDoc(doc(memberDb(), `${INVENTORY}/PRD-1/notes/n1`), { text: "x" }));
});

test("S2c PIN: the lock is by exact collection name; a look-alike name is still an ordinary working collection", async () => {
    // Documents the limit instead of leaving it to be assumed. Nothing in the app uses these names.
    await assertSucceeds(setDoc(doc(memberDb(), `tenants/${TENANT}/inventory_archive/x1`), { name: "x" }));
    await assertSucceeds(setDoc(doc(memberDb(), `tenants/${TENANT}/Inventory/x1`), { name: "x" }));
});

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

// -- Server-only tier: pending_cleanup (PH3 photo cascade markers; test plan R01-R09, R11) -----------
// Written and removed only by recordMutation (Admin SDK). `pending_cleanup` MUST be in
// isServerOnlyCollection: a lone `match /pending_cleanup/{id} { allow ...: if false }` would NOT deny,
// because Firestore allows a request if ANY matching rule allows it and the wildcard still would.
const MARKER = { productId: "PRD-1", envPrefix: "dev1", prefix: "dev1/tenants/tenant-1/products/PRD-1/", attempts: 0, lastError: null };

test("R01 pending_cleanup: a member cannot read a marker", async () => {
    await seedAsAdmin(`tenants/${TENANT}/pending_cleanup`, "PRD-1", MARKER);
    await assertFails(getDoc(doc(memberDb(), `tenants/${TENANT}/pending_cleanup/PRD-1`)));
});

test("R02 pending_cleanup: a member cannot create a marker", async () => {
    await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/pending_cleanup/PRD-9`), MARKER));
});

test("R03 pending_cleanup: a member cannot update a marker", async () => {
    await seedAsAdmin(`tenants/${TENANT}/pending_cleanup`, "PRD-1", MARKER);
    await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/pending_cleanup/PRD-1`), { attempts: 99 }, { merge: true }));
});

test("R04 pending_cleanup: a member cannot delete a marker", async () => {
    await seedAsAdmin(`tenants/${TENANT}/pending_cleanup`, "PRD-1", MARKER);
    await assertFails(deleteDoc(doc(memberDb(), `tenants/${TENANT}/pending_cleanup/PRD-1`)));
});

test("R05 pending_cleanup: the owner is denied all four operations (no role bypass)", async () => {
    // memberDb() IS the seeded owner (members/{MEMBER_UID}.role = owner).
    await seedAsAdmin(`tenants/${TENANT}/pending_cleanup`, "PRD-1", MARKER);
    await assertFails(getDoc(doc(memberDb(), `tenants/${TENANT}/pending_cleanup/PRD-1`)));
    await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/pending_cleanup/PRD-2`), MARKER));
    await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/pending_cleanup/PRD-1`), { attempts: 1 }, { merge: true }));
    await assertFails(deleteDoc(doc(memberDb(), `tenants/${TENANT}/pending_cleanup/PRD-1`)));
});

test("R06 pending_cleanup: unauthenticated is denied", async () => {
    await seedAsAdmin(`tenants/${TENANT}/pending_cleanup`, "PRD-1", MARKER);
    await assertFails(getDoc(doc(anonDb(), `tenants/${TENANT}/pending_cleanup/PRD-1`)));
    await assertFails(setDoc(doc(anonDb(), `tenants/${TENANT}/pending_cleanup/PRD-2`), MARKER));
    await assertFails(deleteDoc(doc(anonDb(), `tenants/${TENANT}/pending_cleanup/PRD-1`)));
});

test("R07 pending_cleanup: a signed-in non-member (other tenant) is denied", async () => {
    await seedAsAdmin(`tenants/${TENANT}/pending_cleanup`, "PRD-1", MARKER);
    await assertFails(getDoc(doc(outsiderDb(), `tenants/${TENANT}/pending_cleanup/PRD-1`)));
    await assertFails(setDoc(doc(outsiderDb(), `tenants/${TENANT}/pending_cleanup/PRD-2`), MARKER));
    await assertFails(deleteDoc(doc(outsiderDb(), `tenants/${TENANT}/pending_cleanup/PRD-1`)));
});

test("R08 PIN: ordinary wildcard collections are unchanged (a member still reads inventory, and still reads and writes orders)", async () => {
    // Re-pointed in S2c: inventory writes are now denied (see the S2c tests above), so the write half of this pin
    // moved to orders. The read half still proves the wildcard did not get too broad an exclusion.
    await seedAsAdmin(`tenants/${TENANT}/inventory`, "PRD-1", { name: "Widget" });
    await seedAsAdmin(`tenants/${TENANT}/orders`, "ORD-1", { total: 10 });
    await assertSucceeds(getDoc(doc(memberDb(), `tenants/${TENANT}/inventory/PRD-1`)));
    await assertSucceeds(getDoc(doc(memberDb(), `tenants/${TENANT}/orders/ORD-1`)));
    await assertSucceeds(setDoc(doc(memberDb(), `tenants/${TENANT}/orders/ORD-2`), { total: 20 }));
});

test("R09 PIN: locks and audit_log are still denied to members", async () => {
    await seedAsAdmin(`tenants/${TENANT}/locks`, "order_ORD-1", { holderUid: MEMBER_UID });
    await seedAsAdmin(`tenants/${TENANT}/audit_log`, "a1", { seed: true });
    await assertFails(getDoc(doc(memberDb(), `tenants/${TENANT}/locks/order_ORD-1`)));
    await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/audit_log/a1`), { tampered: true }));
});

test("R11 a forged marker attempt by a member leaves no marker behind", async () => {
    await assertFails(setDoc(doc(memberDb(), `tenants/${TENANT}/pending_cleanup/PRD-7`), MARKER));
    let exists = true;
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
        const snap = await ctx.firestore().doc(`tenants/${TENANT}/pending_cleanup/PRD-7`).get();
        exists = snap.exists;
    });
    assert.equal(exists, false);
});
