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
    readonly property string realBatchFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutationsBatch"
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
        Gateway.batchFunctionUrl = emulatorFunctionsBase + "/recordMutationsBatch"
        Gateway.deltaFunctionUrl = emulatorFunctionsBase + "/recordDelta"
        Gateway.mode = "gateway"
        AuthStore.idToken = fixture.idToken
        AuthStore.tenantId = fixture.tenantId
        SupplierStore.suppliers = [{ supplierId: fixture.supplierId, name: fixture.supplierName }]
        InventoryStore.products = []
        OrdersStore.orders = []
        OutboxStore.clear() // this file was the one gap in the suite that never reset this -- a
                             // failed/queued mutation from an earlier test (or an earlier E2E FILE
                             // in the same qmltestrunner process -- OutboxStore is a shared
                             // singleton) could otherwise get retried mid-test via Gateway.drainNow(),
                             // which every recordMutation call triggers internally, adding real
                             // network contention at exactly the moments this file's own timing-
                             // sensitive tests (concurrent addOrder, the conflict test) most need
                             // a clean, uncontended run
        lastConflict = null
        Gateway.mutationConflicted.connect(_onMutationConflicted)
    }

    function cleanup() {
        Gateway.mutationConflicted.disconnect(_onMutationConflicted)
        FirebaseService.emulatorHost = ""
        Gateway.functionUrl = realFunctionUrl
        Gateway.batchFunctionUrl = realBatchFunctionUrl
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
            { orderId: "", customer: "Brand New Row", products: [], _conflictPolicy: "skip" } // no orderId -> always new, per source comment
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

        // Overwrite goes through updateOrder separately -- upsertMany
        // itself only reports the intent via updatedOrderFields; this
        // order's status is still "pending" (not "completed"), so it's a
        // non-ledger-aware envelope-field update, applied directly.
        OrdersStore.updateOrder(existingId, received.updatedOrderFields[0].fields)
        var updated = _pollEmulatorDoc(existingDocPath, existingId, function(d) {
            return d !== null && d.fields.customer.stringValue === "Overwritten Name"
        }, 5000, "order was never actually overwritten in the emulator")
        compare(updated.fields.customer.stringValue, "Overwritten Name")
    }

    // postDirect (E2EHelpers.js) hardcodes tc.fixture.idToken -- no way to
    // send as a different identity. Local variant, same shape, explicit
    // token parameter. Needed for the multi-user conflict test below: the
    // whole point is a genuinely different identity's write landing on the
    // server, not the owner writing to itself twice.
    function _postDirectAs(idToken, url, payload, timeoutMs, timeoutMessage) {
        var status = -1, text = "", done = false
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                status = xhr.status
                text = xhr.responseText
                done = true
            }
        }
        xhr.open("POST", url, true)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + idToken)
        xhr.send(JSON.stringify(payload))
        tryVerify(function() { return done }, timeoutMs, timeoutMessage)
        return { status: status, text: text }
    }

    // functions/lib/gatewayLogic.js's applyMutation does
    // _deepEqual(current, params.before) where `current` comes from the
    // Admin SDK (plain JS values: {customer: "x", total: 100}) -- but
    // Firestore's REST API (what pollEmulatorDoc reads, via
    // emulatorFirestoreHost) returns typed-value-wrapped fields
    // ({customer: {stringValue: "x"}, total: {doubleValue: 100}}). Those
    // two shapes can never deep-equal each other. Converts REST-shaped
    // `fields` into the plain values applyMutation's CAS check actually
    // compares against. Handles the value types OrdersStore documents
    // actually use; not a general-purpose Firestore value parser.
    function _firestoreFieldsToPlain(fields) {
        function convertValue(v) {
            if (v.stringValue !== undefined) return v.stringValue
            if (v.integerValue !== undefined) return Number(v.integerValue)
            if (v.doubleValue !== undefined) return v.doubleValue
            if (v.booleanValue !== undefined) return v.booleanValue
            if (v.nullValue !== undefined) return null
            if (v.timestampValue !== undefined) return v.timestampValue
            if (v.arrayValue !== undefined) {
                var arr = (v.arrayValue.values || [])
                var out = []
                for (var i = 0; i < arr.length; ++i) out.push(convertValue(arr[i]))
                return out
            }
            if (v.mapValue !== undefined) return _firestoreFieldsToPlain(v.mapValue.fields || {})
            return null
        }
        var plain = {}
        for (var key in fields) plain[key] = convertValue(fields[key])
        return plain
    }

    function test_two_users_editing_the_same_order_produces_a_real_conflict() {
        // Owner (fixture.idToken) creates and reads back an order.
        var orderId = _addOrder("Conflict Test Customer", 1, 100)
        var orderDocPath = "tenants/" + fixture.tenantId + "/orders/" + orderId
        var orderDoc = _pollEmulatorDoc(orderDocPath, orderId, function(d) { return d !== null }, 5000,
                                          "order doc never appeared before the conflict test")
        var serverUpdatedAt = orderDoc.fields.updatedAt.stringValue

        // Staff (fixture.secondIdToken) writes to the SAME order directly
        // via a raw POST -- a real second identity's write actually
        // landing on the server, not a simulated one.
        //
        // Two things that were wrong here before being fixed (see
        // CHECKPOINT.md, 2026-08-21 debugging entry, for the full trace):
        // 1. Must use fixture.secondIdToken, not the owner's -- this test
        //    is meaningless as a MULTI-user conflict otherwise.
        // 2. applyMutation's CAS check (functions/lib/gatewayLogic.js)
        //    compares against `current`, read server-side via the Admin
        //    SDK as plain JS values -- but orderDoc.fields is Firestore's
        //    REST typed-value wire format ({customer: {stringValue: "x"}}).
        //    Sending REST-shaped fields as `before` could never deep-equal
        //    plain Admin SDK values. _firestoreFieldsToPlain converts.
        var plainOrder = _firestoreFieldsToPlain(orderDoc.fields)
        var staffAfter = Object.assign({}, plainOrder, {
            customer: "Changed By Staff",
            updatedAt: new Date().toISOString()
        })
        var staffWinResult = _postDirectAs(fixture.secondIdToken,
            emulatorFunctionsBase + "/recordMutation",
            {
                env: "prd", entity: "order", entityId: orderId, action: "update",
                before: plainOrder,
                after: staffAfter,
                requestId: "staff-conflict-" + Date.now(),
                clientTimestamp: new Date().toISOString()
            }, 5000, "staff's raw recordMutation call never responded")
        compare(staffWinResult.status, 200,
                "staff's recordMutation call was rejected — response body: " + staffWinResult.text)
        // What matters for this test is only that the SERVER'S current
        // updatedAt actually changed underneath the owner, proving a real
        // second-identity write landed -- confirmed by polling below, not by
        // asserting this POST's own status, since a rejected-but-uncaught
        // write would otherwise fail silently right up until this point.
        _pollEmulatorDoc(orderDocPath, orderId, function(d) {
            return d !== null && d.fields.updatedAt.stringValue !== serverUpdatedAt
        }, 5000, "staff's write never actually changed the server's updatedAt — conflict setup failed")

        // Owner (still fixture.idToken, the QML client under test) now
        // tries to update the SAME order via the normal OrdersStore path,
        // using its own stale local copy as `before` -- exactly the real
        // "I had the order open, someone else already saved a change"
        // scenario.
        //
        // DIAGNOSTIC, not a confirmed fix (2026-08-22, 4th debugging round):
        // three prior rounds (Toast import, OutboxStore.clear(), 45s
        // timeout) were each real, evidence-based fixes for what they
        // targeted, but this specific failure persists -- now 4/4 retry
        // attempts across 40+ seconds, all instant, all status 0. That
        // rules out simple transient contention (a real network blip
        // wouldn't reproduce identically 4 times spanning almost a
        // minute) but I don't have a confirmed cause for what's left.
        // Logging functionUrl right before the call -- if it's NOT the
        // emulator URL, that's the answer. If it IS correct and this still
        // fails, the next log needs to come back here, not get guessed at
        // a fifth time.
        console.warn("[DEBUG conflict test] Gateway.functionUrl =", Gateway.functionUrl,
                      "AuthStore.idToken.length =", AuthStore.idToken.length)
        wait(500) // cheap, defensive: rules out any rapid-fire connection-reuse
                  // issue between the staff write (~100ms earlier) and this call,
                  // even though it doesn't explain why later retries (2s/8s/30s
                  // later, long past any such race) would ALSO fail identically
        lastConflict = null
        OrdersStore.orders = [OrdersStore._normalizeOrder({
            orderId: orderId, customer: "Conflict Test Customer", products: []
        })]
        OrdersStore.updateOrder(orderId, { notes: "Owner's conflicting edit" })

        // 10s was too tight against OutboxStore's real backoff schedule
        // (qml/model/OutboxStore.qml:54, _backoffMs: [2000, 8000, 30000, ...]).
        // Confirmed by two real runs: both showed the owner's first send
        // attempt fail at the transport level (status 0, not a real HTTP
        // response -- transient emulator contention, most likely from the
        // concurrent-addOrder test's own counter-mint retry storm landing
        // moments earlier), then a second attempt ~2s later (matches
        // backoffMs[0] exactly) also failing. A third attempt needs
        // 2000+8000=10000ms from the first failure, right at the OLD
        // timeout's edge -- a coin-flip, not a real margin. 45s gives real
        // room past a 4th attempt (10s+30s=40s) for Gateway's own retry
        // mechanism to actually do its job, rather than the test racing
        // against it. This is the system's designed resilience working as
        // intended, not something to route around.
        tryVerify(function() { return lastConflict !== null }, 45000,
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
}
