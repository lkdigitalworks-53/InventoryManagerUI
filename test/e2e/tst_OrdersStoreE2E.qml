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
