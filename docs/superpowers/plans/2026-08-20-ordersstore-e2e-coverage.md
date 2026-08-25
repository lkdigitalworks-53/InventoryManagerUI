# OrdersStore E2E Coverage — Implementation Plan (Slice 5 of 5, final)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Real, emulator-backed coverage for the seven functions Slices 1–4 could only smoke-test:
`addOrder`, `upsertMany`, `nextOrderId` (exercised indirectly through both), `_fetchFromFirebase`/
`syncFromFirebase` (pagination), and the standout scenario nothing in this file has any coverage
for at all today — a genuine multi-user conflict, two different identities racing an edit on the
same order, `_onMutationConflicted` firing for real.

**Architecture:** New file, `test/e2e/tst_OrdersStoreE2E.qml` — per Taher's decision (spec §7.2),
**not** an extension of the existing `tst_OrdersE2E.qml` (which covers `DataModel.completeOrder`'s
stock-deduction path, a different concern). Follows that file's exact established conventions:
`initTestCase()`/`init()`/`cleanup()` structure, `E2EHelpers.js` for fixture loading and doc
polling, raw-POST warm-up before the first real test. One genuinely new piece of shared
infrastructure: `test/e2e/seed.js` currently mints only one user — the multi-user conflict scenario
(Task 5) needs a second, real identity, not a simulated one, so this plan extends `seed.js` rather
than fake a second user with the same token. Flagged as its own task specifically because it
touches infrastructure `tst_InventoryE2E.qml` and `tst_OrdersE2E.qml` also depend on.

**Tech Stack:** QML/Qt Quick Test (`qmltestrunner`) against the Firebase Local Emulator Suite
(Firestore + Auth + Functions), same as the two existing E2E files.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-20-ordersstore-full-coverage-design.md` §5's async/
  multi-user scenario requirements, and §6/§7's decision to use a separate new file.
- **This sandbox has no network egress to Firebase's emulator distribution** — same standing
  constraint every existing `test/e2e/*.qml` file in this project states in its own header. Nothing
  in this plan has been run; every step is written to match documented Local Emulator Suite
  behavior and this codebase's own established conventions (verified by reading
  `tst_OrdersE2E.qml`, `tst_InventoryE2E.qml`, and `E2EHelpers.js` directly while writing this
  plan), not by execution.
- **Deliberately conservative field assertions**, matching `tst_OrdersE2E.qml`'s own stated
  precedent (`:29-37` in that file): assert top-level, simply-typed fields (`status`, presence/
  count, numeric `total`/`subtotal`) rather than parsing Firestore's typed REST encoding
  (`mapValue`/`arrayValue`) for nested arrays like `products`/`taxBreakdown` — that's "an extra
  layer of untested parsing for this file's first CI attempt," in that file's own words, and the
  same reasoning applies here.
- One commit per task.

## File Structure

- `test/e2e/seed.js` — modified (Task 1): adds a second seeded user.
- `test/e2e/tst_OrdersStoreE2E.qml` — new. Created in Task 2, extended in Tasks 3–5.

---

## Task 1: Extend `seed.js` with a second identity, for the multi-user scenario

**Files:**
- Modify: `test/e2e/seed.js`

**Interfaces:**
- Consumes: Firebase Admin SDK (`firebase-admin/auth`, `firebase-admin/firestore`), same as the
  rest of this file.
- Produces: `.fixture.json` gains two new fields — `secondIdToken`, `secondUid` — additive only,
  every existing field (`idToken`, `uid`, `tenantId`, `supplierId`, `supplierName`) stays exactly
  as-is, so `tst_InventoryE2E.qml` and `tst_OrdersE2E.qml` are unaffected.

- [ ] **Step 1: Add a second user, seeded as a tenant member with a distinct role, and mint their token**

In `test/e2e/seed.js`, add a second constant near the existing ones:

```js
const SECOND_UID = "e2e-staff";
```

Then, inside `main()`, after the existing `TEST_UID` user/member setup and before the `idToken`
mint, add:

```js
    await auth.createUser({ uid: SECOND_UID, email: "e2e-staff@example.com" })
        .catch((e) => {
            if (e.code !== "auth/uid-already-exists") throw e;
        });

    await db.doc("users/" + SECOND_UID).set({
        tenantId: TENANT_ID,
        tenantName: "E2E Test Co",
        role: "staff",
        name: "E2E Staff"
    });
    await db.doc("tenants/" + TENANT_ID + "/members/" + SECOND_UID).set({
        uid: SECOND_UID,
        role: "staff",
        status: "active",
        name: "E2E Staff"
    });
```

And change the fixture-writing block from:

```js
    const idToken = await mintIdToken(TEST_UID);

    const fixture = {
        idToken: idToken,
        uid: TEST_UID,
        tenantId: TENANT_ID,
        supplierId: SUPPLIER_ID,
        supplierName: SUPPLIER_NAME
    };
```

to:

```js
    const idToken = await mintIdToken(TEST_UID);
    const secondIdToken = await mintIdToken(SECOND_UID);

    const fixture = {
        idToken: idToken,
        uid: TEST_UID,
        secondIdToken: secondIdToken,
        secondUid: SECOND_UID,
        tenantId: TENANT_ID,
        supplierId: SUPPLIER_ID,
        supplierName: SUPPLIER_NAME
    };
```

- [ ] **Step 2: Run locally/CI (Taher) and confirm existing E2E tests are unaffected**

This can't be verified standalone in this sandbox (needs the emulator). Run the full `e2e-tests`
CI job (or locally: `firebase emulators:exec --only firestore,auth,functions "node test/e2e/seed.js
&& qmltestrunner -input test/e2e -platform offscreen -o -,txt"`) and confirm `tst_InventoryE2E.qml`
and `tst_OrdersE2E.qml`'s existing tests still pass — they only read `fixture.idToken` and the
other pre-existing fields, so this should be a pure addition, but confirming rather than assuming.

- [ ] **Step 3: Commit**

```bash
git add test/e2e/seed.js
git commit -m "test(e2e): seed a second user for the multi-user conflict scenario

Adds e2e-staff (role: staff) alongside the existing e2e-owner, with
their own minted idToken (fixture.secondIdToken/secondUid). Additive
only -- every existing fixture field and both existing E2E test files
are unaffected. Needed for tst_OrdersStoreE2E.qml's genuine multi-user
conflict test (Slice 5, Task 5) -- a real second identity, not two
requests from the same session standing in for one."
```

---

## Task 2: New file scaffolding + `addOrder` against the real emulator

**Files:**
- Create: `test/e2e/tst_OrdersStoreE2E.qml`

**Interfaces:**
- Consumes: `OrdersStore.addOrder(...)`, `OrdersStore.computeOrderTotals(...)` (Slice 1-verified
  math, reused here for the expected values), `E2EHelpers.loadFixture`/`postDirect`/
  `pollEmulatorDoc`.

- [ ] **Step 1: Create the file with scaffolding and the first real test**

```qml
import QtQuick
import QtTest
import "../../qml/model"
import "E2EHelpers.js" as E2EHelpers

// OrdersStore E2E — the async/Firebase-touching surface of OrdersStore.qml
// itself: addOrder (real id minting), upsertMany (bulk import), sync/
// pagination, and a genuine multi-user conflict. Deliberately a separate
// file from tst_OrdersE2E.qml (which covers DataModel.completeOrder's
// stock-deduction path) -- Taher's explicit call, see
// docs/superpowers/specs/2026-08-20-ordersstore-full-coverage-design.md §7.
//
// NOT RUN IN THIS SANDBOX before its first real CI attempt -- no network
// egress here to Firebase's emulator distribution, same as every other file
// in this suite.

TestCase {
    name: "OrdersStoreE2E"

    readonly property string emulatorFirestoreHost: "http://127.0.0.1:8080"
    readonly property string emulatorFunctionsBase: "http://127.0.0.1:5001/inventorymanager-48392/asia-south1"
    readonly property string realFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutation"
    readonly property string realDeltaFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordDelta"
    readonly property string fixtureUrl: Qt.resolvedUrl("../../test/e2e/.fixture.json")

    property var fixture: null
    property var lastConflict: null

    function _loadFixture() {
        return E2EHelpers.loadFixture(this, fixtureUrl)
    }

    function _onMutationConflicted(entity, entityId, current) {
        lastConflict = { entity: entity, entityId: entityId, current: current }
    }

    function _pollEmulatorDoc(docPath, entityId, predicateFn, timeoutMs, message) {
        return E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, docPath, entityId,
                                           predicateFn, timeoutMs, message)
    }

    function initTestCase() {
        fixture = _loadFixture()

        // Same reasoning as tst_OrdersE2E.qml/tst_InventoryE2E.qml's own
        // initTestCase(): referencing AuthService for the first time
        // triggers its Component.onCompleted, which unconditionally wipes
        // AuthStore -- and that first reference happens implicitly inside
        // Gateway.drainNow(). Forcing it here, before any real token is
        // set, is a no-op today but keeps this file safe if that ever
        // changes.
        AuthService.ensureFreshToken()

        var mutationResult = E2EHelpers.postDirect(this, emulatorFunctionsBase + "/recordMutation", {
            env: "prd",
            entity: "order",
            entityId: "warmup-ordersstore-" + Date.now(),
            action: "create",
            before: null,
            after: { orderId: "warmup-ordersstore-" + Date.now(), customer: "Warmup", total: 0 },
            requestId: "warmup-ordersstore-req-" + Date.now(),
            clientTimestamp: new Date().toISOString()
        }, 15000, "Cloud Functions emulator never responded to the recordMutation warm-up call")
        compare(mutationResult.status, 200,
                "warm-up recordMutation call was rejected — response body: " + mutationResult.text)
    }

    function init() {
        fixture = _loadFixture()
        FirebaseService.emulatorHost = emulatorFirestoreHost
        Gateway.functionUrl = emulatorFunctionsBase + "/recordMutation"
        Gateway.deltaFunctionUrl = emulatorFunctionsBase + "/recordDelta"
        Gateway.mode = "gateway"
        AuthStore.idToken = fixture.idToken
        AuthStore.tenantId = fixture.tenantId
        SupplierStore.suppliers = [{ supplierId: fixture.supplierId, name: fixture.supplierName }]
        InventoryStore.products = []
        OrdersStore.orders = []
        lastConflict = null
        Gateway.mutationConflicted.connect(_onMutationConflicted)
    }

    function cleanup() {
        Gateway.mutationConflicted.disconnect(_onMutationConflicted)
        FirebaseService.emulatorHost = ""
        Gateway.functionUrl = realFunctionUrl
        Gateway.deltaFunctionUrl = realDeltaFunctionUrl
        AuthStore.idToken = ""
        AuthStore.tenantId = ""
    }

    // Kept local rather than moved into E2EHelpers.js, matching that file's
    // own stated convention (thin one-line Store-call wrappers stay local).
    // Same shape as tst_OrdersE2E.qml's _addOrder — deliberately duplicated
    // rather than shared, to avoid touching that already-passing file as
    // part of this slice.
    function _addOrder(customer, qty, price, idToken) {
        var products = [{
            productId: "", name: "OrdersStoreE2E Widget", price: price, quantity: qty,
            taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0
        }]
        var totals = OrdersStore.computeOrderTotals(products)
        if (idToken !== undefined) AuthStore.idToken = idToken
        var createdId = ""
        var done = false
        OrdersStore.addOrder(
            customer, totals.itemCount, totals.total, "pending", new Date(),
            "", "", products, "e2e", "",
            function(ok, id) { done = true; createdId = ok ? id : "" }
        )
        tryVerify(function() { return done }, 5000, "addOrder callback never fired")
        verify(createdId.length > 0, "addOrder did not return an orderId")
        return createdId
    }

    function test_addOrder_persists_a_real_order_with_correct_totals() {
        var orderId = _addOrder("OrdersStoreE2E Customer", 2, 100)
        var orderDocPath = "tenants/" + fixture.tenantId + "/orders/" + orderId
        var orderDoc = _pollEmulatorDoc(orderDocPath, orderId, function(d) { return d !== null }, 5000,
                                          "order doc never appeared in the emulator")
        compare(orderDoc.fields.customer.stringValue, "OrdersStoreE2E Customer")
        compare(orderDoc.fields.status.stringValue, "pending")
        // gross 200, no discount/tax -- same verified case as Slice 1/3.
        compare(Number(orderDoc.fields.total.doubleValue || orderDoc.fields.total.integerValue), 200)
    }
}
```

- [ ] **Step 2: Run locally/CI (Taher) and confirm the new test passes**

Run the `e2e-tests` CI job, or locally per Task 1 Step 2's command (swap the `qmltestrunner -input`
path to `test/e2e`, already the default for that job). Expected:
`OrdersStoreE2E::test_addOrder_persists_a_real_order_with_correct_totals` shows `PASS`.

- [ ] **Step 3: Commit**

```bash
git add test/e2e/tst_OrdersStoreE2E.qml
git commit -m "test(e2e): new tst_OrdersStoreE2E.qml, addOrder against the real emulator

New file, per Taher's decision to keep this separate from the existing
tst_OrdersE2E.qml (spec §7.2). First real test: addOrder persists a
correctly-shaped, correctly-totaled order to the emulator -- the first
genuine (non-smoke) coverage this codebase has ever had for addOrder's
network path."
```

---

## Task 3: Concurrent `addOrder` — no ID collision

**Files:**
- Modify: `test/e2e/tst_OrdersStoreE2E.qml`

**Interfaces:**
- Consumes: `OrdersStore.addOrder`, fired twice without awaiting between calls — the actual reason
  `nextOrderId`/`mintCounterValue` exist instead of a naive `max(existing)+1` (source comment,
  `qml/model/OrdersStore.qml:167-170`): concurrent-add collision safety. This is the first test in
  this codebase that actually exercises concurrent requests rather than trusting the comment's
  stated intent.

- [ ] **Step 1: Append the concurrency test**

Add this function inside the same `TestCase { ... }` block, after
`test_addOrder_persists_a_real_order_with_correct_totals`:

```qml

    function test_concurrent_addOrder_calls_do_not_collide_on_id() {
        var products = [{
            productId: "", name: "Concurrent Widget", price: 50, quantity: 1,
            taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0
        }]
        var totals = OrdersStore.computeOrderTotals(products)

        var firstDone = false, firstId = ""
        var secondDone = false, secondId = ""

        // Fired back-to-back, deliberately not awaited between calls --
        // both nextOrderId->mintCounterValue requests are in flight at the
        // same time. A naive max(existing)+1 approach would be prone to
        // exactly this race; mintCounterValue's whole reason for existing
        // is to not be.
        OrdersStore.addOrder(
            "Concurrent Customer A", totals.itemCount, totals.total, "pending", new Date(),
            "", "", products, "e2e", "",
            function(ok, id) { firstDone = true; firstId = ok ? id : "" }
        )
        OrdersStore.addOrder(
            "Concurrent Customer B", totals.itemCount, totals.total, "pending", new Date(),
            "", "", products, "e2e", "",
            function(ok, id) { secondDone = true; secondId = ok ? id : "" }
        )

        tryVerify(function() { return firstDone && secondDone }, 10000,
                   "one or both concurrent addOrder callbacks never fired")
        verify(firstId.length > 0, "first concurrent addOrder did not return an orderId")
        verify(secondId.length > 0, "second concurrent addOrder did not return an orderId")
        verify(firstId !== secondId,
               "concurrent addOrder calls minted the SAME orderId (" + firstId
               + ") -- mintCounterValue's collision-avoidance failed under real concurrency")

        // Both orders must actually exist in the emulator under their
        // distinct ids, not just have returned distinct-looking strings
        // locally.
        var firstDocPath = "tenants/" + fixture.tenantId + "/orders/" + firstId
        _pollEmulatorDoc(firstDocPath, firstId, function(d) { return d !== null }, 5000,
                          "first concurrent order never appeared in the emulator")
        var secondDocPath = "tenants/" + fixture.tenantId + "/orders/" + secondId
        _pollEmulatorDoc(secondDocPath, secondId, function(d) { return d !== null }, 5000,
                          "second concurrent order never appeared in the emulator")
    }
```

- [ ] **Step 2: Run locally/CI (Taher) and confirm the new test passes**

Run the `e2e-tests` CI job. Expected: `OrdersStoreE2E::test_concurrent_addOrder_calls_do_not_collide_on_id`
shows `PASS`. **If it fails with matching ids**, that's a real product bug in `mintCounterValue`'s
transaction, not a test-writing error — report the exact ids back.

- [ ] **Step 3: Commit**

```bash
git add test/e2e/tst_OrdersStoreE2E.qml
git commit -m "test(e2e): concurrent addOrder calls do not collide on id

Fires two addOrder calls back-to-back without awaiting between them,
confirms both mint distinct orderIds and both orders actually land in
the emulator. First test anywhere in this codebase that exercises real
request concurrency for order-id minting, rather than trusting the
source comment's stated collision-avoidance intent."
```

---

## Task 4: `upsertMany` bulk import — real conflict-policy coverage

**Files:**
- Modify: `test/e2e/tst_OrdersStoreE2E.qml`

**Interfaces:**
- Consumes: `OrdersStore.upsertMany(records, callback)`'s non-empty-records path — real coverage
  for the `skip`/`rename`/`overwrite` `_conflictPolicy` branches (`qml/model/OrdersStore.qml:236-289`),
  which Slice 3 could only smoke-test.

- [ ] **Step 1: Append the bulk-import test**

Add this function inside the same `TestCase { ... }` block, after
`test_concurrent_addOrder_calls_do_not_collide_on_id`:

```qml

    function test_upsertMany_skip_and_rename_policies_against_real_state() {
        // Seed one existing order the batch will collide with.
        var existingId = _addOrder("Existing Customer", 1, 20)
        var existingDocPath = "tenants/" + fixture.tenantId + "/orders/" + existingId
        _pollEmulatorDoc(existingDocPath, existingId, function(d) { return d !== null }, 5000,
                          "seeded existing order never appeared before the import")

        var received = null
        var done = false
        OrdersStore.upsertMany([
            { orderId: existingId, customer: "Should Be Skipped", products: [], _conflictPolicy: "skip" },
            { orderId: existingId, customer: "Should Be Renamed", products: [], _conflictPolicy: "rename" },
            { orderId: "", customer: "Brand New Row", products: [], _conflictPolicy: "skip" } // no orderId -> always new, per source comment :198-203
        ], function(counts) { received = counts; done = true })

        tryVerify(function() { return done }, 10000, "upsertMany callback never fired")
        compare(received.skipped, 1)
        compare(received.added, 2) // the rename + the brand-new row
        compare(received.addedIds.length, 2)

        // The skip must not have touched the existing order's customer.
        var stillExisting = _pollEmulatorDoc(existingDocPath, existingId, function(d) {
            return d !== null && d.fields.customer.stringValue === "Existing Customer"
        }, 5000, "skipped row's target order was modified — skip policy did not hold")
        compare(stillExisting.fields.customer.stringValue, "Existing Customer")

        // The renamed row must have landed under a NEW id, not overwritten
        // the existing one, and be findable in the emulator under that id.
        var renamedId = received.addedIds.filter(function(id) { return id !== existingId })[0]
        verify(renamedId !== undefined, "no distinct renamed id found in addedIds")
        var renamedDocPath = "tenants/" + fixture.tenantId + "/orders/" + renamedId
        var renamedDoc = _pollEmulatorDoc(renamedDocPath, renamedId, function(d) {
            return d !== null && d.fields.customer.stringValue === "Should Be Renamed"
        }, 5000, "renamed order never appeared under its new id")
        compare(renamedDoc.fields.customer.stringValue, "Should Be Renamed")
    }

    function test_upsertMany_overwrite_policy_updates_envelope_fields_in_place() {
        var existingId = _addOrder("Original Name", 1, 20)
        var existingDocPath = "tenants/" + fixture.tenantId + "/orders/" + existingId
        _pollEmulatorDoc(existingDocPath, existingId, function(d) { return d !== null }, 5000,
                          "seeded existing order never appeared before the import")

        var received = null
        var done = false
        OrdersStore.upsertMany([
            { orderId: existingId, customer: "Overwritten Name", email: "new@x.com",
              phone: "", date: "", notes: "", orderChannel: "", products: [],
              _conflictPolicy: "overwrite" }
        ], function(counts) { received = counts; done = true })

        tryVerify(function() { return done }, 10000, "upsertMany callback never fired")
        compare(received.updated, 1)
        compare(received.updatedOrderFields.length, 1)
        compare(received.updatedOrderFields[0].orderId, existingId)

        // Overwrite goes through updateOrder separately (see the source
        // comment at :253-265) -- upsertMany itself only reports the
        // intent via updatedOrderFields; this order's status is still
        // "pending" (not "completed"), so it's a non-ledger-aware
        // envelope-field update, applied directly.
        OrdersStore.updateOrder(existingId, received.updatedOrderFields[0].fields)
        var updated = _pollEmulatorDoc(existingDocPath, existingId, function(d) {
            return d !== null && d.fields.customer.stringValue === "Overwritten Name"
        }, 5000, "order was never actually overwritten in the emulator")
        compare(updated.fields.customer.stringValue, "Overwritten Name")
    }
```

- [ ] **Step 2: Run locally/CI (Taher) and confirm both new tests pass**

Run the `e2e-tests` CI job. Expected: both
`OrdersStoreE2E::test_upsertMany_skip_and_rename_policies_against_real_state` and
`test_upsertMany_overwrite_policy_updates_envelope_fields_in_place` show `PASS`.

- [ ] **Step 3: Commit**

```bash
git add test/e2e/tst_OrdersStoreE2E.qml
git commit -m "test(e2e): upsertMany conflict-policy coverage against the real emulator

2 tests: skip/rename together (skip leaves the target untouched, rename
lands under a genuinely new id, a brand-new no-orderId row is always
added), and overwrite (envelope fields applied via the follow-up
updateOrder call the source's own comment documents as the intended
flow for a non-completed order). Real coverage for the three
_conflictPolicy branches Slice 3 could only smoke-test."
```

---

## Task 5: Multi-user conflict — the standout scenario, complete this slice

**Files:**
- Modify: `test/e2e/tst_OrdersStoreE2E.qml`

**Interfaces:**
- Consumes: two real identities (`fixture.idToken` / `fixture.secondIdToken`, from Task 1),
  `E2EHelpers.postDirect` (a raw POST bypassing `Gateway`/`OutboxStore`, used here to simulate the
  "other user's" write landing first — reaching straight for `Gateway.recordMutation` from a second
  QML `Gateway` instance isn't practical within one `TestCase`, since `Gateway` is a
  `pragma Singleton`; a raw POST from the second identity's token is the real, direct way to make
  the server see an actual competing write, not a simulated one), then
  `OrdersStore.updateOrder`/`_onMutationConflicted` from the first identity's perspective.

- [ ] **Step 1: Append the multi-user conflict test**

Add this function inside the same `TestCase { ... }` block, after
`test_upsertMany_overwrite_policy_updates_envelope_fields_in_place`:

```qml

    function test_two_users_editing_the_same_order_produces_a_real_conflict() {
        // Owner (fixture.idToken) creates and reads back an order.
        var orderId = _addOrder("Conflict Test Customer", 1, 100)
        var orderDocPath = "tenants/" + fixture.tenantId + "/orders/" + orderId
        var orderDoc = _pollEmulatorDoc(orderDocPath, orderId, function(d) { return d !== null }, 5000,
                                          "order doc never appeared before the conflict test")
        var serverUpdatedAt = orderDoc.fields.updatedAt.stringValue

        // Staff (fixture.secondIdToken) writes to the SAME order directly
        // via a raw POST -- a real second identity's write actually
        // landing on the server, not a simulated one. Sends a full doc:
        // functions/lib/gatewayLogic.js's applyMutation does a whole-
        // record CAS compare (_deepEqual(current, before)), and the
        // client-derived `before` this test builds only approximates what
        // OrdersStore._clone()/_normalizeOrder would have produced -- the
        // owner-side write below is what actually needs the accurate
        // before, since it's the one whose rejection this test asserts on.
        var staffWinResult = E2EHelpers.postDirect(this,
            emulatorFunctionsBase + "/recordMutation",
            {
                env: "prd", entity: "order", entityId: orderId, action: "update",
                before: orderDoc.fields, // best-effort -- see comment above; this write's own success isn't what's asserted, only that it lands before the owner's write below
                after: Object.assign({}, orderDoc.fields, {
                    customer: { stringValue: "Changed By Staff" },
                    updatedAt: { stringValue: new Date().toISOString() }
                }),
                requestId: "staff-conflict-" + Date.now(),
                clientTimestamp: new Date().toISOString()
            }, 5000, "staff's raw recordMutation call never responded")
        // This raw POST's own before/after field-shape isn't guaranteed to
        // exactly match applyMutation's expected wire format (Firestore's
        // mapValue/arrayValue typed encoding is intricate -- see this
        // plan's Global Constraints on deliberately conservative field
        // assertions). What matters for this test is only that the
        // SERVER'S current updatedAt actually changed underneath the
        // owner, proving a real second-identity write landed -- confirmed
        // by polling below, not by asserting this POST's own status.
        _pollEmulatorDoc(orderDocPath, orderId, function(d) {
            return d !== null && d.fields.updatedAt.stringValue !== serverUpdatedAt
        }, 5000, "staff's write never actually changed the server's updatedAt — conflict setup failed")

        // Owner (still fixture.idToken, the QML client under test) now
        // tries to update the SAME order via the normal OrdersStore path,
        // using its own stale local copy as `before` -- exactly the real
        // "I had the order open, someone else already saved a change"
        // scenario Taher asked for.
        lastConflict = null
        OrdersStore.orders = [OrdersStore._normalizeOrder({
            orderId: orderId, customer: "Conflict Test Customer", products: []
        })]
        OrdersStore.updateOrder(orderId, { notes: "Owner's conflicting edit" })

        tryVerify(function() { return lastConflict !== null }, 10000,
                   "Gateway.mutationConflicted never fired — owner's stale write should have been rejected by the server's CAS check")
        compare(lastConflict.entity, "order")
        compare(lastConflict.entityId, orderId)

        // _onMutationConflicted must have reconciled OrdersStore's local
        // copy to the server's actual current version.
        var reconciled = OrdersStore.getById(orderId)
        verify(reconciled !== null, "order should still be present locally after reconciliation, not dropped")
        verify(reconciled.customer !== "Conflict Test Customer" || reconciled.notes !== "Owner's conflicting edit",
               "local order still reflects the owner's rejected edit instead of the server's actual current version")
    }
```

- [ ] **Step 2: Run locally/CI (Taher) and confirm the new test passes**

Run the `e2e-tests` CI job. Expected: `OrdersStoreE2E::test_two_users_editing_the_same_order_produces_a_real_conflict`
shows `PASS`. **This is the least certain test in this whole plan series** — it depends on the raw
staff POST's field encoding being close enough to what `applyMutation`'s CAS check expects for the
owner's subsequent write to genuinely fail the compare, which wasn't executable to confirm in this
sandbox. **If it fails**, the most likely first thing to check is whether `staffWinResult.status`
was actually 200 (paste it back) — a rejected staff write would mean the conflict was never
actually set up, not that the reconciliation logic itself is broken.

- [ ] **Step 3: Commit**

```bash
git add test/e2e/tst_OrdersStoreE2E.qml
git commit -m "test(e2e): genuine multi-user conflict via two real identities

The standout scenario from the spec (SS5.2/§7): a real second identity
(fixture.secondIdToken, from Task 1's seed.js extension) writes to an
order via a raw POST, the owner's subsequent OrdersStore.updateOrder
call against its now-stale local copy gets rejected by the server's CAS
check, and Gateway.mutationConflicted -> OrdersStore._onMutationConflicted
reconciles the local state to the server's real current version.

Flagged as the least certain test in this whole plan series -- depends
on the raw POST's field encoding being close enough to what
applyMutation's CAS compare expects, which this sandbox has no way to
confirm before a real run. Slice 5 of 5 complete -- all five OrdersStore
coverage plans written."
```

---

## Self-review (per writing-plans skill)

**Spec coverage:** Spec's Group B rows for `addOrder`, `upsertMany`, `nextOrderId` (exercised
indirectly), `_fetchFromFirebase`/`syncFromFirebase` — **partial**: `addOrder`, `upsertMany`, and
concurrent-mint safety are covered; explicit pagination coverage (seed >50 orders, confirm
multi-page assembly) from spec §5's async-behavior bullet is **not yet in this plan** — a real gap,
not silently dropped. §5's multi-user scenario — fully covered, Task 5.

**Gap found in this self-review**: pagination testing (spec §5, "seed >50 orders... confirm the
recursive `_fetchFromFirebase` call assembles the full set") isn't in Tasks 1–5 above. This plan is
being submitted with that gap explicitly flagged rather than silently incomplete — see Task 6 below,
added to close it, same as Slice 3's addendum pattern for the `addOrder` smoke test.

**Placeholder scan (Tasks 1–5)**: No "TBD"/"similar to Task N" — every step has complete code.

**Biggest real uncertainty**: Task 5's raw-POST field encoding, flagged explicitly in that task
rather than presented as more certain than it is.

## Task 6: Sync pagination — closing the gap found above

**Files:**
- Modify: `test/e2e/tst_OrdersStoreE2E.qml`

**Interfaces:**
- Consumes: `OrdersStore.syncFromFirebase()`, seeded against >`_pageSize` (50) orders so the
  recursive `_fetchFromFirebase` call (`qml/model/OrdersStore.qml:128-151`) must page more than
  once to assemble the full set.

- [ ] **Step 1: Append the pagination test**

Add this function inside the same `TestCase { ... }` block, after
`test_two_users_editing_the_same_order_produces_a_real_conflict`:

```qml

    function test_syncFromFirebase_assembles_the_full_set_across_multiple_pages() {
        // _pageSize is 50 -- seed 55 so a real multi-page fetch is
        // required, not just exercised in a way a single page could
        // satisfy by coincidence.
        var seedCount = 55
        var lastId = ""
        for (var i = 0; i < seedCount; ++i) {
            lastId = _addOrder("Pagination Customer " + i, 1, 10)
        }
        var lastDocPath = "tenants/" + fixture.tenantId + "/orders/" + lastId
        _pollEmulatorDoc(lastDocPath, lastId, function(d) { return d !== null }, 10000,
                          "last seeded order never appeared before starting the sync")

        OrdersStore.orders = [] // local cache reset -- syncFromFirebase must repopulate it from the server, not from what's already here
        OrdersStore.hasMore = true
        OrdersStore.syncFromFirebase()

        tryVerify(function() {
            return !OrdersStore.loadingMore && OrdersStore.orders.length >= seedCount
        }, 20000, "syncFromFirebase never assembled the full seeded set across pages "
                  + "(stuck at " + OrdersStore.orders.length + " of " + seedCount + ")")

        compare(OrdersStore.hasMore, false)
        verify(OrdersStore.getById(lastId) !== null,
               "the last-seeded order specifically must be present -- proves the LAST page landed, not just enough total count by coincidence")
    }
```

- [ ] **Step 2: Run locally/CI (Taher) and confirm the new test passes**

Run the `e2e-tests` CI job. Expected: `OrdersStoreE2E::test_syncFromFirebase_assembles_the_full_set_across_multiple_pages`
shows `PASS`. Slower than the other tests in this file (55 real writes) — if it times out, check
whether it's a genuine pagination bug or just needs a longer `tryVerify` window on Taher's machine
before concluding anything's actually wrong.

- [ ] **Step 3: Commit**

```bash
git add test/e2e/tst_OrdersStoreE2E.qml
git commit -m "test(e2e): syncFromFirebase pagination across multiple real pages

Closes the gap flagged in this slice's own self-review. Seeds 55 orders
(> _pageSize's 50) and confirms syncFromFirebase's recursive
_fetchFromFirebase call assembles the complete set, hasMore correctly
reaches false, and specifically the LAST-seeded order is present --
proves the last page actually landed, not just a coincidentally-correct
total count. Slice 5 of 5 genuinely complete now: all five OrdersStore
coverage plans written, spec's async/multi-user requirements fully
covered."
```
