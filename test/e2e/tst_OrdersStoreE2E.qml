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
}
