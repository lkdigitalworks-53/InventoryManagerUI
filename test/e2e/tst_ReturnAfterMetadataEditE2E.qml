import QtQuick
import QtTest
import "../../qml/model"
import "../../qml/helper/OrderAdjust.js" as OrderAdjust
import "../../qml/helper/RealisedMath.js" as RealisedMath
import "E2EHelpers.js" as E2EHelpers

// Returns/analysis-revenue E2E — third E2E scenario (2026-08-20), extending
// tst_OrdersE2E.qml (order completion) to the exact sequence Taher's device
// repro used: complete an order, edit it (customer-name-only, no line
// changes), THEN return the item, and confirm Revenue/Profit actually net
// to zero — against the REAL Cloud Functions emulator, not local-only
// fixtures. Full root-cause writeup: SKILLS.md Skill 42.
//
// Real code path this exercises that tst_OrdersE2E.qml never touched:
//   OrderDetailDialog._save()'s fix (OrderAdjust.reconcileConsumptionOnSave)
//   -> OrdersStore.updateOrder's full products replace -> a REAL
//   Gateway.recordMutation POST to the emulator (Gateway.mode="gateway" +
//   a real fixture.idToken here, unlike tests/tst_OrderMetadataEditPreserves
//   Consumption.qml's local-only equivalent, which deliberately keeps
//   AuthStore.idToken empty to guarantee no network call) -> then
//   DataModel._tryAdjustOrder's return path, ALSO a real recordMutation
//   POST for the "transaction" entity.
//
// Deliberately does NOT parse the order doc's products[].consumption out of
// Firestore's typed REST encoding (mapValue/arrayValue nesting) — same
// scope decision tst_OrdersE2E.qml already made and documented for the
// stock_batch doc, for the same reason (untested parsing layer, not worth
// the fragility for this file's first CI attempt). The bug this file
// guards against is a CLIENT-SIDE computed value (InventoryStore.
// realisedTotals reads the local TransactionStore.entries array, never a
// re-fetched/re-parsed Firestore document), so the core assertion is a
// plain local property read — the emulator round trips exist here to prove
// the REAL write path (Gateway -> Cloud Functions emulator -> Firestore)
// doesn't reject or silently drop either the metadata edit or the return,
// which a purely local test can't prove. The order doc's simple scalar
// fields (customer, status) ARE polled directly, using the exact same
// parsing tst_OrdersE2E.qml already established as safe.
//
// NOT RUN IN THIS SANDBOX before its first real CI attempt -- no network
// egress here to Firebase's emulator distribution, same as every other file
// in this suite.

TestCase {
    name: "ReturnAfterMetadataEditE2E"

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

        // Same warm-up story as tst_OrdersE2E.qml's initTestCase() — see
        // that file's header comment for the full explanation of why this
        // ordering matters (AuthService construction, per-function cold
        // starts). Deliberately redundant across E2E files rather than
        // relying on cross-file execution order.
        AuthService.ensureFreshToken()

        var mutationResult = E2EHelpers.postDirect(this, emulatorFunctionsBase + "/recordMutation", {
            env: "prd",
            entity: "inventory",
            entityId: "warmup-returnmeta-" + Date.now(),
            action: "create",
            before: null,
            after: { name: "Warmup Widget", sku: "SKU-WARMUP-RM", price: 1, stock: 1 },
            requestId: "warmup-returnmeta-req-" + Date.now(),
            clientTimestamp: new Date().toISOString()
        }, 15000, "Cloud Functions emulator never responded to the recordMutation warm-up call")
        compare(mutationResult.status, 200,
                "warm-up recordMutation call was rejected — response body: " + mutationResult.text)

        var deltaResult = E2EHelpers.postDirect(this, emulatorFunctionsBase + "/recordDelta", {
            env: "prd",
            entity: "stock_batch",
            entityId: "warmup-delta-rm-" + Date.now(),
            deltas: { qtyRemaining: 0 },
            floors: {},
            clamps: {},
            requestId: "warmup-delta-rm-req-" + Date.now(),
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
        TransactionStore.hasMore = false   // Skill 38 guard — no pagination in this scenario,
                                            // everything is seeded/created fresh within the test
        dm.stockErrorMsg = ""
        lastConflict = null
        // See tst_OrdersE2E.qml's init() -- same shared-singleton contamination
        // fix, same reasoning (CHECKPOINT.md, second run).
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

    // Same shape as tst_OrdersE2E.qml's local helpers — kept local per that
    // file's own established convention (thin one-line Store wrappers,
    // not shared machinery).
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
            productId: productId, name: "E2E Return Widget", price: 100, quantity: qty,
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

    // The emulator is shared across every E2E test FILE in one CI run — no
    // reset between files, so by the time this file runs, TransactionStore
    // syncs back transactions other files already wrote (confirmed by the
    // actual CI failure: an unscoped realisedTotals(null) returned 400, not
    // 100, on a brand-new order — the other 300 was leftover from earlier
    // E2E files' own fixtures in the same emulator instance). Scope every
    // assertion in this file to THIS test's own orderId, not a global sum.
    // RealisedMath has no scope.orderId (checked _passesScope directly —
    // it only supports window/channel/staffId/category), so filter entries
    // by hand before handing them to RealisedMath.totals.
    function _entriesForOrder(orderId) {
        var out = []
        for (var i = 0; i < TransactionStore.entries.length; ++i)
            if (TransactionStore.entries[i].orderId === orderId) out.push(TransactionStore.entries[i])
        return out
    }

    function test_metadata_edit_then_return_nets_revenue_and_profit_to_zero() {
        var productId = _createProduct("E2E Return Widget", "SKU-E2E-RM-1", 10)
        var productDocPath = "tenants/" + fixture.tenantId + "/inventory/" + productId
        _pollEmulatorDoc(productDocPath, productId, function(d) { return d !== null }, 5000,
                          "seeded product doc never appeared before creating the order")

        var orderId = _addOrder(productId, 1)
        var orderDocPath = "tenants/" + fixture.tenantId + "/orders/" + orderId
        _pollEmulatorDoc(orderDocPath, orderId, function(d) { return d !== null }, 5000,
                          "order doc never appeared before completing it")

        // ── 1. complete the order ───────────────────────────────────────
        lastConflict = null
        var completed = false, completedOk = false
        dm._tryCompleteOrder(orderId, function(success) { completed = true; completedOk = success })
        tryVerify(function() { return completed }, 5000, "_tryCompleteOrder callback never fired")
        verify(completedOk, "order completion reported failure — stockErrorMsg: " + dm.stockErrorMsg)

        _pollEmulatorDoc(orderDocPath, orderId, function(d) {
            return d !== null && d.fields.status.stringValue === "completed"
        }, 5000, "order status never reached 'completed' in the emulator")

        var revenueAfterSale = RealisedMath.totals(_entriesForOrder(orderId), null, {})
        compare(revenueAfterSale.net, 100,
                "sanity check: THIS order's own revenue must be 100 right after completion")

        // ── 2. metadata-only edit (customer name), through the FIXED path ──
        var originalLines = OrdersStore.getById(orderId).products
        verify(originalLines[0].consumption.length > 0,
               "sanity check: completion must have stamped consumption before the edit")

        var rebuiltFromDialog = [{ productId: productId, name: "E2E Return Widget", price: 100, quantity: 1,
                                    discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }]
        var reconciled = OrderAdjust.reconcileConsumptionOnSave(rebuiltFromDialog, originalLines)

        lastConflict = null
        OrdersStore.updateOrder(orderId, {
            customer: "E2E Renamed Customer", email: "", phone: "",
            status: "completed", items: 1,
            products: reconciled, orderChannel: "e2e", staffId: ""
        })

        _pollEmulatorDoc(orderDocPath, orderId, function(d) {
            return d !== null && d.fields.customer.stringValue === "E2E Renamed Customer"
        }, 5000, "metadata edit (customer name) never reached the emulator")

        // Confirm LOCALLY (post-fix) that consumption is still intact —
        // the exact fact TEMPDBGLogs.txt showed was empty pre-fix.
        var afterEditLines = OrdersStore.getById(orderId).products
        verify(afterEditLines[0].consumption.length > 0,
               "THE regression: consumption must survive a metadata-only edit")

        // ── 3. return the item ──────────────────────────────────────────
        lastConflict = null
        var returned = false
        dm._tryAdjustOrder(orderId, [], "return", "resellable", "", function(ok) { returned = true })
        tryVerify(function() { return returned }, 5000, "_tryAdjustOrder callback never fired")

        // The return's own recordMutation ("transaction" entity) round trip —
        // poll the order doc's total, which applyAdjustment also updates,
        // as the emulator-reachable signal that the adjustment persisted
        // (same simple-scalar-only parsing tst_OrdersE2E.qml established).
        _pollEmulatorDoc(orderDocPath, orderId, function(d) {
            return d !== null && Number(d.fields.total.doubleValue || d.fields.total.integerValue || 0) === 0
        }, 5000, "order total never reached 0 in the emulator after the full return")

        // ── 4. THE regression check ─────────────────────────────────────
        var totals = RealisedMath.totals(_entriesForOrder(orderId), null, {})
        compare(totals.net, 0, "Revenue must net to 0 after a full return following a metadata " +
                "edit — this is the exact bug Taher reported: it silently stayed at 100")
        compare(totals.profit, 0, "Profit must net to 0 after the same sequence")

        // Sold/Purchased (bucketsFor) never had this bug — confirm it still
        // nets correctly too, scoped to THIS order via bucketsForFiltered's
        // predicate (plain bucketsFor has no scoping — same shared-emulator
        // pollution risk the unscoped realisedTotals call above had).
        var soldBuckets = TransactionStore.bucketsForFiltered("sale", 0,
            function(e) { return e.orderId === orderId })
        var totalSold = 0
        for (var b = 0; b < soldBuckets.length; ++b) totalSold += (soldBuckets[b].value || 0)
        compare(totalSold, 0, "net Sold quantity for THIS order must also be 0 after a full return")
    }
}
