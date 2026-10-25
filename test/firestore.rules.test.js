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

// ═══ S2f-2 (2026-10-24): access-control tier: users, tenants, members ═════════════════════════════
// Findings F1 (any member could rewrite `members`, probe PR #157), F2 (a suspended member kept direct
// access), plus role assignment aligned with the server and client policy (owner assigns admin/manager/
// staff, admin assigns manager/staff, nobody assigns owner). Status is strict: only 'active' passes.

const mPath = (uid) => `tenants/${TENANT}/members/${uid}`;
const mRef = (db, uid) => doc(db, mPath(uid));
const ROSTER_ROLES = ["owner", "admin", "manager", "staff"];

async function dbWith(uid, role, status) {
    const data = { uid, role };
    if (status !== undefined) data.status = status;
    await seedAsAdmin(`tenants/${TENANT}/members`, uid, data);
    return testEnv.authenticatedContext(uid).firestore();
}

// ---- F1: members cannot be rewritten through the wildcard ----
for (const role of ["staff", "manager"]) {
    test(`F1 ${role}: cannot promote itself to owner or admin (setDoc and updateDoc), doc unchanged`, async () => {
        const db = await dbAs("actor", role);
        await assertFails(setDoc(mRef(db, "actor"), { uid: "actor", role: "owner", status: "active" }));
        await assertFails(setDoc(mRef(db, "actor"), { uid: "actor", role: "admin", status: "active" }));
        await assertFails(updateDoc(mRef(db, "actor"), { role: "owner" }));
        assert.equal((await readAsAdmin(mPath("actor"))).role, role);
    });

    test(`F1 ${role}: cannot create a member doc for anyone (owner/admin accomplice), cannot edit or delete others`, async () => {
        const db = await dbAs("actor", role);
        await seedAsAdmin(`tenants/${TENANT}/members`, "victim", { uid: "victim", role: "staff", status: "active" });
        await assertFails(setDoc(mRef(db, "accomplice"), { uid: "accomplice", role: "owner", status: "active" }));
        await assertFails(setDoc(mRef(db, "accomplice"), { uid: "accomplice", role: "staff", status: "active" }));
        await assertFails(updateDoc(mRef(db, "victim"), { role: "owner" }));
        await assertFails(updateDoc(mRef(db, "victim"), { status: "suspended" }));
        await assertFails(deleteDoc(mRef(db, "victim")));
        await assertFails(deleteDoc(mRef(db, MEMBER_UID)));
        assert.equal(await readAsAdmin(mPath("accomplice")), null);
        assert.equal((await readAsAdmin(mPath("victim"))).role, "staff");
        assert.equal((await readAsAdmin(mPath(MEMBER_UID))).role, "owner");
    });
}

test("F1 admin: cannot make itself owner, cannot touch the owner doc, cannot create admin or owner members", async () => {
    const db = await dbAs("adm", "admin");
    await assertFails(updateDoc(mRef(db, "adm"), { role: "owner" }));
    await assertFails(updateDoc(mRef(db, MEMBER_UID), { role: "staff" }));
    await assertFails(deleteDoc(mRef(db, MEMBER_UID)));
    await assertFails(setDoc(mRef(db, "n1"), { uid: "n1", role: "owner", status: "active" }));
    await assertFails(setDoc(mRef(db, "n2"), { uid: "n2", role: "admin", status: "active" }));
    assert.equal((await readAsAdmin(mPath("adm"))).role, "admin");
    assert.equal((await readAsAdmin(mPath(MEMBER_UID))).role, "owner");
});

test("F1 the wildcard no longer opens members: reads of the roster still work for an active member", async () => {
    const db = await dbAs("st", "staff");
    await assertSucceeds(getDoc(mRef(db, MEMBER_UID)));
    await assertSucceeds(getDocs(collection(db, `tenants/${TENANT}/members`)));
});

// ---- role assignment matrix (policy: Skill 128, canAssignRole) ----
test("assign: owner creates and updates admin / manager / staff", async () => {
    for (const role of ["admin", "manager", "staff"]) {
        await assertSucceeds(setDoc(mRef(memberDb(), "n-" + role), { uid: "n-" + role, role, status: "active" }));
    }
    await assertSucceeds(setDoc(mRef(memberDb(), "n-staff"), { uid: "n-staff", role: "manager", status: "active" }));
    await assertSucceeds(setDoc(mRef(memberDb(), "n-staff"), { uid: "n-staff", role: "manager", status: "suspended" }));
    await assertSucceeds(setDoc(mRef(memberDb(), "n-staff"), { uid: "n-staff", role: "manager", status: "active" }));
});

test("assign: nobody assigns owner (create or update), even the owner; unknown roles and statuses fail", async () => {
    await seedAsAdmin(`tenants/${TENANT}/members`, "s1", { uid: "s1", role: "staff", status: "active" });
    await assertFails(setDoc(mRef(memberDb(), "n-owner"), { uid: "n-owner", role: "owner", status: "active" }));
    await assertFails(setDoc(mRef(memberDb(), "s1"), { uid: "s1", role: "owner", status: "active" }));
    await assertFails(setDoc(mRef(memberDb(), "s1"), { uid: "s1", role: "superuser", status: "active" }));
    await assertFails(setDoc(mRef(memberDb(), "s1"), { uid: "s1", role: "staff", status: "banned" }));
    await assertFails(setDoc(mRef(memberDb(), "s1"), { uid: "s1", role: "staff", status: "inactive" }));
    await assertFails(setDoc(mRef(memberDb(), "s1"), { uid: "s1", role: "staff" }));
    await assertFails(setDoc(mRef(memberDb(), "n-bad"), { uid: "someone-else", role: "staff", status: "active" }));
    assert.equal((await readAsAdmin(mPath("s1"))).role, "staff");
});

test("assign: an existing owner doc is never modified, not even by the owner itself", async () => {
    await assertFails(setDoc(mRef(memberDb(), MEMBER_UID), { uid: MEMBER_UID, role: "staff", status: "active" }));
    await assertFails(updateDoc(mRef(memberDb(), MEMBER_UID), { status: "suspended" }));
    assert.deepEqual(await readAsAdmin(mPath(MEMBER_UID)), { uid: MEMBER_UID, role: "owner", status: "active" });
});

test("assign: admin manages manager/staff (create, promote to manager, suspend) but not admin or owner roles", async () => {
    const db = await dbAs("adm", "admin");
    await assertSucceeds(setDoc(mRef(db, "m1"), { uid: "m1", role: "staff", status: "active" }));
    await assertSucceeds(setDoc(mRef(db, "m1"), { uid: "m1", role: "manager", status: "active" }));
    await assertSucceeds(setDoc(mRef(db, "m1"), { uid: "m1", role: "manager", status: "suspended" }));
    await assertFails(setDoc(mRef(db, "m1"), { uid: "m1", role: "admin", status: "active" }));
});

// ---- delete / leave ----
test("delete: owner and admin remove staff; nobody removes the owner; nobody removes themselves via the admin path", async () => {
    await seedAsAdmin(`tenants/${TENANT}/members`, "s1", { uid: "s1", role: "staff", status: "active" });
    await seedAsAdmin(`tenants/${TENANT}/members`, "s2", { uid: "s2", role: "staff", status: "active" });
    const adm = await dbAs("adm", "admin");
    await assertSucceeds(deleteDoc(mRef(adm, "s1")));
    await assertSucceeds(deleteDoc(mRef(memberDb(), "s2")));
    await assertFails(deleteDoc(mRef(adm, MEMBER_UID)));
    await assertFails(deleteDoc(mRef(memberDb(), MEMBER_UID)));
});

test("leave: a staff member (active or suspended) can remove its own membership, the owner cannot", async () => {
    const st = await dbWith("st1", "staff", "active");
    await assertSucceeds(deleteDoc(mRef(st, "st1")));
    const su = await dbWith("st2", "staff", "suspended");
    await assertSucceeds(deleteDoc(mRef(su, "st2")));
    await assertFails(deleteDoc(mRef(memberDb(), MEMBER_UID)));
});

// ---- F2: suspended / status-less members lose direct access, strictly ----
for (const status of ["suspended", undefined]) {
    const label = status === undefined ? "missing status" : status;
    for (const role of ROSTER_ROLES) {
        test(`F2 ${role} with ${label}: no read, no write on tenant data, roster or tenant doc`, async () => {
            const db = await dbWith("sx", role, status);
            await seedAsAdmin(`tenants/${TENANT}/inventory`, "PRD-1", { name: "W" });
            await seedAsAdmin(`tenants/${TENANT}/orders`, "ORD-1", { total: 1 });
            await assertFails(getDoc(doc(db, `tenants/${TENANT}/inventory/PRD-1`)));
            await assertFails(getDoc(doc(db, `tenants/${TENANT}/orders/ORD-1`)));
            await assertFails(setDoc(doc(db, `tenants/${TENANT}/orders/ORD-2`), { total: 2 }));
            await assertFails(setDoc(doc(db, `tenants/${TENANT}/orders/ORD-1`), { total: 99 }));
            await assertFails(deleteDoc(doc(db, `tenants/${TENANT}/orders/ORD-1`)));
            await assertFails(getDoc(doc(db, `tenants/${TENANT}`)));
            await assertFails(getDoc(mRef(db, MEMBER_UID)));
            await assertFails(getDocs(collection(db, `tenants/${TENANT}/members`)));
            assert.equal((await readAsAdmin(`tenants/${TENANT}/orders/ORD-1`)).total, 1);
        });
    }

    test(`F2 ${label}: a locked-out admin or owner keeps no management power`, async () => {
        await seedAsAdmin(`tenants/${TENANT}/members`, "s1", { uid: "s1", role: "staff", status: "active" });
        for (const role of ["admin", "owner"]) {
            const db = await dbWith("sx", role, status);
            await assertFails(setDoc(mRef(db, "s1"), { uid: "s1", role: "manager", status: "active" }));
            await assertFails(setDoc(mRef(db, "n1"), { uid: "n1", role: "staff", status: "active" }));
            await assertFails(deleteDoc(mRef(db, "s1")));
            await assertFails(updateDoc(doc(db, `tenants/${TENANT}`), { name: "Hijacked" }));
        }
        assert.equal((await readAsAdmin(mPath("s1"))).role, "staff");
        assert.equal((await readAsAdmin(`tenants/${TENANT}`)).name, "Test Co");
    });

    test(`F2 ${label}: the member can still read ITS OWN member doc (the app learns why it is locked out), nobody else's`, async () => {
        const db = await dbWith("sx", "staff", status);
        await assertSucceeds(getDoc(mRef(db, "sx")));
        await assertFails(getDoc(mRef(db, MEMBER_UID)));
    });
}

test("F2 control: re-activating the member restores access at once (no caching across requests)", async () => {
    const su = await dbWith("sx", "staff", "suspended");
    await assertFails(getDoc(doc(su, `tenants/${TENANT}/orders/ORD-1`)));
    await assertSucceeds(setDoc(mRef(memberDb(), "sx"), { uid: "sx", role: "staff", status: "active" }));
    const st = testEnv.authenticatedContext("sx").firestore();
    await seedAsAdmin(`tenants/${TENANT}/orders`, "ORD-1", { total: 1 });
    await assertSucceeds(getDoc(doc(st, `tenants/${TENANT}/orders/ORD-1`)));
});

test("F2 outsider and anonymous: the self-read exception does not apply to other uids or to signed-out callers", async () => {
    await assertFails(getDoc(mRef(outsiderDb(), MEMBER_UID)));
    await assertFails(getDoc(mRef(anonDb(), MEMBER_UID)));
    await assertFails(setDoc(mRef(anonDb(), "x"), { uid: "x", role: "owner", status: "active" }));
});

// ---- bootstrap: tenant + own owner membership ----
test("bootstrap: a new user creates a tenant and its own owner membership, once", async () => {
    const db = testEnv.authenticatedContext("newbie").firestore();
    await assertSucceeds(setDoc(doc(db, "tenants/t-new"), { ownerId: "newbie", name: "New Co" }));
    await assertSucceeds(setDoc(doc(db, "tenants/t-new/members/newbie"), { uid: "newbie", role: "owner", status: "active" }));
    await assertSucceeds(getDoc(doc(db, "tenants/t-new")));
    // already exists now: a second bootstrap is an update of an owner doc, which is denied
    await assertFails(setDoc(doc(db, "tenants/t-new/members/newbie"), { uid: "newbie", role: "owner", status: "active" }));
});

test("bootstrap negatives: someone else's tenant, role admin, status suspended, other uid, tenant ownerId mismatch", async () => {
    const db = testEnv.authenticatedContext("newbie").firestore();
    await assertFails(setDoc(doc(db, `tenants/${TENANT}/members/newbie`), { uid: "newbie", role: "owner", status: "active" }));
    await assertSucceeds(setDoc(doc(db, "tenants/t-new"), { ownerId: "newbie", name: "New Co" }));
    await assertFails(setDoc(doc(db, "tenants/t-new/members/newbie"), { uid: "newbie", role: "admin", status: "active" }));
    await assertFails(setDoc(doc(db, "tenants/t-new/members/newbie"), { uid: "newbie", role: "owner", status: "suspended" }));
    await assertFails(setDoc(doc(db, "tenants/t-new/members/other"), { uid: "other", role: "owner", status: "active" }));
    await assertFails(setDoc(doc(db, "tenants/t-bad"), { ownerId: "someone-else", name: "X" }));
    await assertFails(setDoc(doc(db, "tenants/t-bad2"), { ownerId: "newbie", name: 5 }));
});

// ---- tenants ----
test("tenants: active members read, outsiders and anon do not; only an active owner updates or deletes", async () => {
    await assertSucceeds(getDoc(doc(memberDb(), `tenants/${TENANT}`)));
    await assertFails(getDoc(doc(outsiderDb(), `tenants/${TENANT}`)));
    await assertFails(getDoc(doc(anonDb(), `tenants/${TENANT}`)));
    const adm = await dbAs("adm", "admin");
    const st = await dbAs("st", "staff");
    await assertFails(updateDoc(doc(adm, `tenants/${TENANT}`), { name: "A" }));
    await assertFails(updateDoc(doc(st, `tenants/${TENANT}`), { name: "S" }));
    await assertFails(deleteDoc(doc(st, `tenants/${TENANT}`)));
    await assertSucceeds(updateDoc(doc(memberDb(), `tenants/${TENANT}`), { name: "Renamed" }));
});

// ---- users ----
// PIN: a user can write ANY field of its own users doc (onboarding and leave-workspace need it). That is why
// the gateway must never read tenant/role from it (functions/index.js deriveContext, S2f-1, Skill 128).
test("users: own doc readable and writable (pinned, incl. tenantId/role); other users' docs and deletes are denied", async () => {
    const db = testEnv.authenticatedContext("u1").firestore();
    await assertSucceeds(setDoc(doc(db, "users/u1"), { uid: "u1", tenantId: TENANT, role: "owner" }));
    await assertSucceeds(getDoc(doc(db, "users/u1")));
    await assertFails(getDoc(doc(db, "users/u2")));
    await assertFails(setDoc(doc(db, "users/u2"), { uid: "u2" }));
    await assertFails(deleteDoc(doc(db, "users/u1")));
    await assertFails(getDoc(doc(anonDb(), "users/u1")));
    await assertFails(setDoc(doc(anonDb(), "users/u1"), { uid: "u1" }));
    // the pinned claim buys nothing in Firestore: a users doc naming TENANT does not make u1 a member
    await assertFails(getDoc(doc(db, `tenants/${TENANT}/orders/ORD-1`)));
});

// ---- cross-cutting monkey: every role x status x collection x op never reaches members or tenant doc ----
test("monkey: no non-owner member in any status can change the owner doc or the tenant doc, in any order", async () => {
    const attackers = [];
    for (const role of ["admin", "manager", "staff"]) for (const status of ["active", "suspended", undefined]) attackers.push([role, status]);
    for (let pass = 0; pass < 2; pass++) {
        for (const [role, status] of attackers.slice().reverse()) {
            const db = await dbWith("mk", role, status);
            await setDoc(mRef(db, MEMBER_UID), { uid: MEMBER_UID, role: "staff", status: "active" }).then(() => assert.fail("owner doc overwritten"), () => {});
            await deleteDoc(mRef(db, MEMBER_UID)).then(() => assert.fail("owner doc deleted"), () => {});
            await updateDoc(doc(db, `tenants/${TENANT}`), { ownerId: "mk" }).then(() => assert.fail("tenant hijacked"), () => {});
            await setDoc(mRef(db, "mk"), { uid: "mk", role: "owner", status: "active" }).then(() => assert.fail("self-promoted"), () => {});
        }
    }
    assert.deepEqual(await readAsAdmin(mPath(MEMBER_UID)), { uid: MEMBER_UID, role: "owner", status: "active" });
    assert.equal((await readAsAdmin(`tenants/${TENANT}`)).ownerId, MEMBER_UID);
});
