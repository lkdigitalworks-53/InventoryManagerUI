"use strict";

const test = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
const {
    initializeTestEnvironment,
    assertFails,
    assertSucceeds
} = require("@firebase/rules-unit-testing");

// Storage security-rules tests for product photos.
// Spec: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md, "Storage rules".
// Public-by-unguessable-path reads (design decision Q2); all writes are server-only (the Admin SDK,
// used by functions/index.js's uploadProductPhoto/deleteProductPhoto, bypasses these rules entirely --
// nothing here needs to exercise that side, only that no client-side caller can write or delete).
//
// NOT RUN IN THIS SANDBOX -- confirmed this session (not assumed): `firebase emulators:exec` fails
// downloading the emulator jar because storage.googleapis.com is not in the sandbox's network egress
// allowlist. Written to the standard @firebase/rules-unit-testing convention, matching
// test/firestore.rules.test.js's own style. Run locally or in CI with:
//   firebase emulators:exec --only firestore,storage \
//     "node --test test/firestore.rules.test.js test/storage.rules.test.js"

let testEnv;

const PHOTO_PATH = "prd/tenants/tenant1/products/prod1/photo1.jpg";
const OTHER_PATH = "some/other/path.jpg";

test.before(async () => {
    testEnv = await initializeTestEnvironment({
        projectId: "storage-rules-test-" + Date.now(),
        storage: {
            rules: fs.readFileSync(path.join(__dirname, "..", "storage.rules"), "utf8")
        }
    });
    // getDownloadURL()/getMetadata() need the object to actually exist to succeed on a rules-allowed
    // read -- seed one object with security rules bypassed (withSecurityRulesDisabled), the same
    // technique this package documents for seeding fixture data before asserting on rules.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await ctx.storage().ref(PHOTO_PATH).put(Buffer.from("fake-jpeg-bytes"));
    });
});

test.after(async () => {
    if (testEnv) await testEnv.cleanup();
});

test("storage rules: anyone, including unauthenticated, can read a product photo", async () => {
    const unauth = testEnv.unauthenticatedContext().storage();
    await assertSucceeds(unauth.ref(PHOTO_PATH).getDownloadURL());
});

test("storage rules: an authenticated tenant owner can read a product photo too (read is unconditional)", async () => {
    const owner = testEnv.authenticatedContext("owner-uid").storage();
    await assertSucceeds(owner.ref(PHOTO_PATH).getMetadata());
});

test("storage rules: an unauthenticated client cannot write a product photo", async () => {
    const unauth = testEnv.unauthenticatedContext().storage();
    await assertFails(unauth.ref(PHOTO_PATH).put(Buffer.from("x")));
});

test("storage rules: an authenticated client cannot write a product photo, even the tenant owner", async () => {
    const owner = testEnv.authenticatedContext("owner-uid").storage();
    await assertFails(owner.ref(PHOTO_PATH).put(Buffer.from("x")));
});

test("storage rules: an authenticated client cannot delete a product photo", async () => {
    const owner = testEnv.authenticatedContext("owner-uid").storage();
    await assertFails(owner.ref(PHOTO_PATH).delete());
});

test("storage rules: an unmapped path denies both read and write, for anyone", async () => {
    const unauth = testEnv.unauthenticatedContext().storage();
    const owner = testEnv.authenticatedContext("owner-uid").storage();
    await assertFails(unauth.ref(OTHER_PATH).getMetadata());
    await assertFails(owner.ref(OTHER_PATH).put(Buffer.from("x")));
});

test("storage rules: a different tenant's/product's path is governed by the same public-read rule (path shape, not tenant identity, gates access)", async () => {
    // Documents the actual access model: there is no per-tenant authorization check in
    // storage.rules at all (see design spec Q2 -- "public by unguessable path", not "private to
    // the tenant"). This test exists so that invariant is asserted, not merely implied by the
    // absence of a rule -- if storage.rules ever grows tenant-membership logic, this test's
    // premise (any path under the pattern reads successfully) must be revisited deliberately.
    const unauth = testEnv.unauthenticatedContext().storage();
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await ctx.storage().ref("prd/tenants/tenant2/products/prod9/photo9.jpg").put(Buffer.from("x"));
    });
    await assertSucceeds(unauth.ref("prd/tenants/tenant2/products/prod9/photo9.jpg").getMetadata());
});
