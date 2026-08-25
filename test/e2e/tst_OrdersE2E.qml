import QtQuick
import QtTest
import "../../qml/model"
import "E2EHelpers.js" as E2EHelpers

// Orders E2E — second E2E scenario (2026-08-16), extending the Phase 1
// pilot (tst_InventoryE2E.qml, Inventory CRUD only) to a richer real
// workflow: create an order -> complete it -> verify the FIFO stock
// deduction actually reached the emulator, not just local optimistic state.
//
// Real code path this exercises that Phase 1 never touched:
//   OrdersStore.addOrder/updateOrder -> Gateway.recordMutation (same
//   emulator wiring Phase 1 already proved out) but ALSO
//   DataModel._tryCompleteOrder -> StockBatchStore.consumeFifo +
//   InventoryStore.deductStock -> Gateway.recordDelta, a SEPARATE Cloud
//   Function/URL (Gateway.deltaFunctionUrl) Phase 1 never wired to the
//   emulator. DataModel.qml is not a pragma Singleton, so it's instantiated
//   directly below as a child item — same pattern
//   tests/tst_DataModel_adjustOrderSyncGuard.qml already established for
//   reaching this orchestration layer.
//
// Both this file's initTestCase() and tst_InventoryE2E.qml's independently
// force AuthService's singleton construction and independently warm up
// whichever Cloud Functions they call — deliberately redundant rather than
// relying on an assumption about qmltestrunner's cross-file execution order
// within one `-input test/e2e` run, which isn't documented and hasn't been
// confirmed here. A repeated warm-up is a harmless extra POST either way.
//
// Scope deliberately excludes (first cut, not an oversight): asserting the
// stock_batch doc's qtyRemaining directly (would need parsing the order
// doc's consumption[].batchId out of Firestore's typed REST field encoding
// — mapValue/arrayValue — an extra layer of untested parsing for this
// file's first CI attempt) and asserting the generated transaction doc
// (its id isn't known ahead of time the way order/product ids are). The
// inventory doc's top-level `stock` field is the signal asserted instead —
// it's what deductStock ultimately moves, and it parses exactly like
// tst_InventoryE2E.qml's existing assertions already do.
//
// NOT RUN IN THIS SANDBOX before its first real CI attempt -- no network
// egress here to Firebase's emulator distribution, same as every other file
// in this suite.

TestCase {
    name: "OrdersE2E"

    readonly property string emulatorFirestoreHost: "http://127.0.0.1:8080"
    readonly property string emulatorFunctionsBase: "http://127.0.0.1:5001/inventorymanager-48392/asia-south1"
    readonly property string realFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutation"
    readonly property string realDeltaFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordDelta"
    readonly property string fixtureUrl: Qt.resolvedUrl("../../test/e2e/.fixture.json")

    property var fixture: null
    property var lastConflict: null

    DataModel { id: dm }

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

        // See tst_InventoryE2E.qml's initTestCase() for the full story of
        // why this has to happen before any test references Gateway —
        // referencing AuthService for the first time triggers its
        // Component.onCompleted, which unconditionally wipes AuthStore, and
        // that first reference happens implicitly inside Gateway.drainNow().
        AuthService.ensureFreshToken() // no-op (not authenticated yet); forces construction only

        var mutationResult = E2EHelpers.postDirect(this, emulatorFunctionsBase + "/recordMutation", {
            env: "prd",
            entity: "inventory",
            entityId: "warmup-orders-" + Date.now(),
            action: "create",
            before: null,
            after: { name: "Warmup Widget", sku: "SKU-WARMUP-ORD", price: 1, stock: 1 },
            requestId: "warmup-orders-req-" + Date.now(),
            clientTimestamp: new Date().toISOString()
        }, 15000, "Cloud Functions emulator never responded to the recordMutation warm-up call")
        compare(mutationResult.status, 200,
                "warm-up recordMutation call was rejected — response body: " + mutationResult.text)

        // recordDelta against a nonexistent entityId is EXPECTED to come
        // back 404 ("not-found"), not 200 — confirmed by reading
        // functions/lib/gatewayLogic.js's applyDelta(), which returns
        // {ok:false, status:404} for a missing document before it ever
        // touches serverTimestamp/FieldValue. A real 404 still proves the
        // recordDelta worker is warm; only "never responded at all" is a
        // real failure here.
        var deltaResult = E2EHelpers.postDirect(this, emulatorFunctionsBase + "/recordDelta", {
            env: "prd",
            entity: "stock_batch",
            entityId: "warmup-delta-" + Date.now(),
            deltas: { qtyRemaining: 0 },
            floors: {},
            clamps: {},
            requestId: "warmup-delta-req-" + Date.now(),
            clientTimestamp: new Date().toISOString()
        }, 15000, "Cloud Functions emulator never responded to the recordDelta warm-up call")
        verify(deltaResult.status === 200 || deltaResult.status === 404,
               "warm-up recordDelta call got an unexpected status " + deltaResult.status
               + " — response body: " + deltaResult.text)
    }

    function init() {
        fixture = _loadFixture()
        FirebaseService.emulatorHost = emulatorFirestoreHost
        Gateway.functionUrl = emulatorFunctionsBase + "/recordMutation"
        Gateway.deltaFunctionUrl = emulatorFunctionsBase + "/recordDelta"
        Gateway.mode = "gateway" // the real production default — see Gateway.qml
        AuthStore.idToken = fixture.idToken
        AuthStore.tenantId = fixture.tenantId
        SupplierStore.suppliers = [{ supplierId: fixture.supplierId, name: fixture.supplierName }]
        InventoryStore.products = []
        StockBatchStore.batches = []
        OrdersStore.orders = []
        TransactionStore.entries = []
        dm.stockErrorMsg = ""
        lastConflict = null
        // OutboxStore is a singleton shared across the whole test/e2e process
        // (CHECKPOINT.md, second run) — this file's own negative-path test
        // (test_completeOrder_rejects_when_stock_insufficient) leaves a
        // stock_batch item queued, which then gets retried by every
        // subsequent recordMutation call system-wide, including in OTHER
        // files' tests. tst_OrdersStoreE2E.qml already had this fix; this
        // file was the other half of the gap.
        OutboxStore.clear()
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

    // Same helper shape as tst_InventoryE2E.qml's _createProduct — kept
    // local rather than moved into E2EHelpers.js since, unlike fixture
    // loading/polling/warm-up, this is a thin one-line wrapper around a
    // single Store call, not shared machinery.
    function _createProduct(name, sku, stock) {
        var createdId = ""
        var done = false
        InventoryStore.addProduct(
            name, sku, "General", "", 100, "pc", stock, 2,
            120, false, 0, fixture.supplierName, 80, "",
            function(ok, id) { done = true; createdId = ok ? id : "" }
        )
        tryVerify(function() { return done }, 5000, "addProduct callback never fired")
        verify(createdId.length > 0, "addProduct did not return a productId")
        return createdId
    }

    function _addOrder(productId, qty) {
        var products = [{
            productId: productId, name: "E2E Order Widget", price: 100, quantity: qty,
            taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0
        }]
        var totals = OrdersStore.computeOrderTotals(products)
        var createdId = ""
        var done = false
        OrdersStore.addOrder(
            "E2E Customer", totals.itemCount, totals.total, "pending", new Date(),
            "", "", products, "e2e", "",
            function(ok, id) { done = true; createdId = ok ? id : "" }
        )
        tryVerify(function() { return done }, 5000, "addOrder callback never fired")
        verify(createdId.length > 0, "addOrder did not return an orderId")
        return createdId
    }

    function test_completeOrder_deducts_stock_in_emulator() {
        var productId = _createProduct("E2E Order Widget", "SKU-E2E-ORD-1", 10)
        var productDocPath = "tenants/" + fixture.tenantId + "/inventory/" + productId
        _pollEmulatorDoc(productDocPath, productId, function(d) { return d !== null }, 5000,
                          "seeded product doc never appeared before creating the order")

        var orderId = _addOrder(productId, 3)
        var orderDocPath = "tenants/" + fixture.tenantId + "/orders/" + orderId
        _pollEmulatorDoc(orderDocPath, orderId, function(d) { return d !== null }, 5000,
                          "order doc never appeared before completing it")

        lastConflict = null // isolate completion's own conflict signal from the creates above
        var completed = false
        var succeeded = false
        dm._tryCompleteOrder(orderId, function(success) { completed = true; succeeded = success })
        tryVerify(function() { return completed }, 5000, "_tryCompleteOrder callback never fired")
        verify(succeeded, "order completion reported failure — stockErrorMsg: " + dm.stockErrorMsg)

        var orderDoc = _pollEmulatorDoc(orderDocPath, orderId, function(d) {
            return d !== null && d.fields.status.stringValue === "completed"
        }, 5000, "order status never reached 'completed' in the emulator")
        compare(orderDoc.fields.status.stringValue, "completed")

        var productDoc = _pollEmulatorDoc(productDocPath, productId, function(d) {
            return d !== null && Number(d.fields.stock.integerValue) === 7
        }, 5000, "inventory stock was never deducted to 7 in the emulator")
        compare(Number(productDoc.fields.stock.integerValue), 7)
    }

    function test_completeOrder_rejects_when_stock_insufficient() {
        var productId = _createProduct("E2E Order Widget Short", "SKU-E2E-ORD-2", 10)
        var productDocPath = "tenants/" + fixture.tenantId + "/inventory/" + productId
        _pollEmulatorDoc(productDocPath, productId, function(d) { return d !== null }, 5000,
                          "seeded product doc never appeared before creating the order")

        var orderId = _addOrder(productId, 15) // more than the 10 in stock
        var orderDocPath = "tenants/" + fixture.tenantId + "/orders/" + orderId
        _pollEmulatorDoc(orderDocPath, orderId, function(d) { return d !== null }, 5000,
                          "order doc never appeared before completing it")

        lastConflict = null
        var completed = false
        var succeeded = true
        dm._tryCompleteOrder(orderId, function(success) { completed = true; succeeded = success })
        tryVerify(function() { return completed }, 5000, "_tryCompleteOrder callback never fired")
        verify(!succeeded, "order completion should have failed for insufficient stock")
        verify(dm.stockErrorMsg.length > 0, "stockErrorMsg should be set on a stock-validation failure")

        var orderDoc = _pollEmulatorDoc(orderDocPath, orderId, function(d) {
            return d !== null && d.fields.status.stringValue === "out of stock"
        }, 5000, "order status never reached 'out of stock' in the emulator")
        compare(orderDoc.fields.status.stringValue, "out of stock")

        // Stock validation fails before any deductStock/recordDelta call is
        // made (see DataModel._tryCompleteOrder's step 1), so this should
        // already be true — a short poll rather than trusting that without
        // checking the server's own state.
        var productDoc = _pollEmulatorDoc(productDocPath, productId, function(d) {
            return d !== null && Number(d.fields.stock.integerValue) === 10
        }, 5000, "inventory stock changed even though completion was rejected")
        compare(Number(productDoc.fields.stock.integerValue), 10)
    }
}
