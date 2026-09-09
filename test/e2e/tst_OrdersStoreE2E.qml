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

    // Bulk-import chunking fix (2026-08-29): counts.chunked is set inside
    // upsertMany's mintCounterBatch callback, which no unit test can reach
    // synchronously (see tst_OrdersStore_mutations.qml's file header on
    // this store's async-minting testability limit) -- this is the only
    // place this specific branch is actually exercised.
    function test_upsertMany_sets_chunked_true_for_more_than_maxBatchSize_new_orders() {
        var records = []
        for (var i = 0; i < 201; ++i) {
            records.push({ orderId: "", customer: "Chunk Order Customer " + i, products: [], _conflictPolicy: "skip" })
        }
        var received = null
        var done = false
        OrdersStore.upsertMany(records, function(counts) { received = counts; done = true })

        tryVerify(function() { return done }, 15000, "upsertMany callback never fired for 201 new orders")
        compare(received.added, 201)
        compare(received.chunked, true, "201 new orders must be flagged as chunked (>Gateway.maxBatchSize=200)")
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

        // Staff (fixture.secondIdToken) writes to the SAME order -- a real
        // second identity's write actually landing on the server, not a
        // simulated one.
        //
        // 6th debugging round (2026-08-23): rerouted through
        // Gateway.recordMutation (temporarily swapping AuthStore.idToken)
        // instead of a raw REST POST, which is what every prior round used.
        // Six things were checked and ruled out as the cause of the owner's
        // persistent transport failure before this change (full trace,
        // CHECKPOINT.md 2026-08-23): wrong URL, wrong/empty token,
        // Gateway.recordMutation's parameter order vs _commit's call site,
        // heavy-test adjacency (reordering had zero effect), a throw in
        // date handling (_normalizeOrder's date field has a safe ||
        // fallback, not .toISOString() on a possibly-invalid Date), and
        // FirebaseService.environment differing between calls (it's a
        // readonly build-time constant, identical for every call). This
        // is a genuinely new, untested angle: the staff write was the one
        // request in this whole test that DIDN'T go through the same
        // Gateway._send code path as everything else -- testing whether a
        // raw POST leaves the emulator's transaction machinery in a state
        // the owner's subsequent db.runTransaction()-based update chokes
        // on. Also just more realistic: a real second user's app would use
        // the same Gateway path too, not a hand-built REST call.
        var plainOrder = _firestoreFieldsToPlain(orderDoc.fields)
        var staffAfter = Object.assign({}, plainOrder, {
            customer: "Changed By Staff",
            updatedAt: new Date().toISOString()
        })
        var savedOwnerToken = AuthStore.idToken
        AuthStore.idToken = fixture.secondIdToken
        Gateway.recordMutation("order", orderId, "update", plainOrder, staffAfter)
        // What matters for this test is only that the SERVER'S current
        // updatedAt actually changed underneath the owner, proving a real
        // second-identity write landed -- confirmed by polling, same as
        // every prior round (Gateway.recordMutation is fire-and-forget,
        // no completion callback to await directly).
        _pollEmulatorDoc(orderDocPath, orderId, function(d) {
            return d !== null && d.fields.updatedAt.stringValue !== serverUpdatedAt
        }, 5000, "staff's write never actually changed the server's updatedAt — conflict setup failed")
        AuthStore.idToken = savedOwnerToken

        // Owner (still fixture.idToken, the QML client under test) now
        // tries to update the SAME order via the normal OrdersStore path,
        // using its own stale local copy as `before` -- exactly the real
        // "I had the order open, someone else already saved a change"
        // scenario.
        //
        // 5th debugging round (2026-08-23): the 4th round's diagnostic
        // logging confirmed Gateway.functionUrl and AuthStore.idToken were
        // BOTH correct at the moment of the failing call -- ruled those
        // out definitively, removed the logging now that it's answered.
        // New leading hypothesis, confirmed by evidence rather than
        // guessed: this test ran immediately after
        // test_syncFromFirebase_assembles_the_full_set_across_multiple_pages
        // (55 real writes + a full multi-page resync, by far the heaviest
        // test in this file) in every run observed -- sorting every test
        // function name in this file alphabetically produced an EXACT
        // match against the real observed execution order across 2
        // separate runs, confirming QtQuickTest executes alphabetically
        // here, not by declaration order. That test is now renamed
        // (test_zz_...) to sort last, removing it as a "ran immediately
        // before" variable for this test. Kept the 500ms settle wait from
        // last round as cheap defense either way.
        wait(500)
        lastConflict = null
        OrdersStore.orders = [OrdersStore._normalizeOrder({
            orderId: orderId, customer: "Conflict Test Customer", products: []
        })]
        OrdersStore.updateOrder(orderId, { notes: "Owner's conflicting edit" })

        // 7th debugging round (2026-08-23): this log included the actual
        // Cloud Functions emulator server-side console output for the
        // first time (Beginning execution / Finished ...ms), not just the
        // qmltestrunner client-side view every prior round was limited to.
        // That's genuinely new information: every single "recordMutation
        // failed 0" on the client had a matching "Finished ... in ~24-29ms"
        // immediately before it server-side -- completely normal timing,
        // matching every successful call elsewhere in the log. The request
        // DOES reach the server and the server DOES complete its logical
        // work every time -- this rules out "never reached the server",
        // "server crashed", and "server hung" definitively. The mystery is
        // now narrowly: why does a normally-completing response never
        // reach the client.
        //
        // tryVerify() fails hard and stops the test immediately on
        // timeout, which meant every prior round's diagnostics could only
        // run BEFORE the failure point, never after -- switched to a
        // manual poll loop here so a diagnostic can run regardless of
        // outcome. Directly checks the actual server document state: if
        // the owner's edit landed despite the client seeing "failed 0",
        // that proves the mutation applied server-side and this is purely
        // a response-transmission issue, not a CAS-logic issue -- the
        // single most useful fact the next log could reveal.
        var elapsed = 0
        var pollInterval = 250
        while (lastConflict === null && elapsed < 45000) {
            wait(pollInterval)
            elapsed += pollInterval
        }
        if (lastConflict === null) {
            var finalDoc = _pollEmulatorDoc(orderDocPath, orderId, function(d) { return d !== null },
                                              5000, "order doc vanished entirely -- unexpected")
            var appliedServerSide = finalDoc.fields.notes !== undefined
                                     && finalDoc.fields.notes.stringValue === "Owner's conflicting edit"
            fail("Gateway.mutationConflicted never fired after 45s. Diagnostic: the order's actual "
                 + "server-side notes field is "
                 + (appliedServerSide
                    ? "'Owner's conflicting edit' -- the mutation DID apply server-side despite the "
                      + "client seeing 'failed 0' every attempt. This is a response-transmission issue, "
                      + "not a CAS-logic issue: the CAS check must have passed (before matched current), "
                      + "meaning this test's own assumption that the owner's stale copy would mismatch "
                      + "the server's current state was wrong, or the response for a real 200 success is "
                      + "somehow not reaching the client."
                    : "'" + (finalDoc.fields.notes ? finalDoc.fields.notes.stringValue : "<missing>")
                      + "' -- NOT the owner's edit. The mutation did NOT apply server-side. Combined with "
                      + "the server-side 'Finished' log entries appearing for every attempt, this means "
                      + "the CAS check is correctly rejecting every time (a real conflict IS being "
                      + "detected, as intended) but the 409 response specifically is what's failing to "
                      + "reach the client -- narrows this to something about the CONFLICT response path "
                      + "specifically (e.g. the `current` field it uniquely carries), not recordMutation "
                      + "responses in general."))
            return
        }
        compare(lastConflict.entity, "order")
        compare(lastConflict.entityId, orderId)

        // _onMutationConflicted must have reconciled OrdersStore's local
        // copy to the server's actual current version.
        var reconciled = OrdersStore.getById(orderId)
        verify(reconciled !== null, "order should still be present locally after reconciliation, not dropped")
        verify(reconciled.customer !== "Conflict Test Customer" || reconciled.notes !== "Owner's conflicting edit",
               "local order still reflects the owner's rejected edit instead of the server's actual current version")
    }

    // Named with a "zz_" prefix deliberately -- QtQuickTest in this CI
    // environment executes test functions alphabetically by name, not
    // declaration order (confirmed: sorting every function name in this
    // file alphabetically produced an exact match against 2 separate
    // real runs' observed execution order, ORD-number by ORD-number).
    // This is the heaviest test in the file by far (55 real writes + a
    // full multi-page resync) -- forcing it to run last, regardless of
    // what other tests get added to this file later, removes it as a
    // "ran immediately before" variable for anything else here. This is
    // the one explicit lever QtQuickTest actually respects for ordering;
    // not a workaround avoiding the real problem, a direct test of the
    // leading hypothesis for the persistent test_two_users_editing_the_
    // same_order_produces_a_real_conflict transport failures (see
    // CHECKPOINT.md, 2026-08-23 entry, for the full evidence trail).
    function test_zz_syncFromFirebase_assembles_the_full_set_across_multiple_pages() {
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
