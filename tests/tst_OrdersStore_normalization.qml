import QtQuick
import QtTest
import "../qml/model"

// Regression test for a severe bug found by Taher's own testing (2026-07-30):
// OrdersStore._clone()'s field-reconstruction whitelist didn't match
// addOrder's create payload (adjustments defaulted by _clone() but never
// sent at creation; updatedAt sent at creation but dropped by _clone()'s
// whitelist). Every clone after creation silently reshaped the local cache
// away from the real Firestore document, so Component 3's CAS check
// (applyMutation's _deepEqual) would reject a completely ordinary,
// single-user edit as a false conflict on the second touch of ANY order.
//
// _normalizeOrder(o) is the fix: the one place both addOrder and _clone()
// pull the canonical shape from, so they can never drift apart again. This
// file locks that invariant down directly, not just by inspection.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local
// `qmltestrunner` pass before merge, same status as every other client-
// side file this session.
TestCase {
    name: "OrdersStore_normalization"

    // Regression coverage for a second bug (2026-08-06 review, fixed same
    // session): _normalizeOrder was reading FIFO consumption lineage off
    // `inv` (the InventoryStore/product record via getById) instead of
    // `lp` (the raw order line being normalized). InventoryStore product
    // records never carry a `consumption` field — only order lines do — so
    // this silently wiped FIFO lineage on every single order (consClone
    // always []), and threw a TypeError whenever getById returned null
    // (line item's product deleted from inventory, or productId missing).
    // Isolate InventoryStore's global state per test so these don't leak
    // into the other tests above/below or into each other.
    function init() { InventoryStore.products = [] }
    function cleanup() { InventoryStore.products = [] }

    function test_normalizeOrder_preserves_line_item_consumption_lineage() {
        // Product exists in inventory but — correctly — has no
        // `consumption` field of its own; only the order line does.
        InventoryStore.products = [{ productId: "SKU-1", taxable: false, taxPercent: 0 }]
        var raw = _rawNewOrder()
        raw.products[0].consumption = [
            { batchId: "BATCH-1", supplierId: "SUP-1", qtyConsumed: 2, unitCost: 5 }
        ]

        var normalized = OrdersStore._normalizeOrder(raw)

        compare(normalized.products[0].consumption.length, 1,
                "FIFO consumption lineage must survive normalization, not be silently dropped")
        compare(normalized.products[0].consumption[0].batchId, "BATCH-1")
        compare(normalized.products[0].consumption[0].qtyConsumed, 2)
    }

    function test_normalizeOrder_does_not_throw_when_line_items_product_is_missing_from_inventory() {
        // Simulates a historical order whose product was later deleted
        // from inventory (InventoryStore.deleteProduct), or a legacy line
        // that never had a productId — InventoryStore.getById returns null
        // in both cases. Normalization must degrade gracefully, not crash.
        InventoryStore.products = [] // product is NOT present
        var raw = _rawNewOrder()
        raw.products[0].productId = "SKU-DELETED"
        raw.products[0].consumption = [{ batchId: "BATCH-2", supplierId: "SUP-2", qtyConsumed: 1, unitCost: 3 }]

        var normalized
        var threw = false
        try {
            normalized = OrdersStore._normalizeOrder(raw)
        } catch (e) {
            threw = true
        }

        verify(!threw, "_normalizeOrder must not throw when a line item's product is absent from InventoryStore")
        compare(normalized.products[0].consumption.length, 1,
                "consumption lineage must still come from the line item itself, not the (absent) inventory record")
    }

    // A freshly-created order's raw shape, as addOrder would build it
    // BEFORE running it through _normalizeOrder — deliberately omits
    // `adjustments` (addOrder never included it) to prove normalization
    // adds it consistently rather than leaving it to drift in later.
    function _rawNewOrder() {
        return {
            orderId: "ORD-001", customer: "Test Customer", items: 1,
            subtotal: 100, discount: 0, tax: 0, taxBreakdown: [],
            total: 100, status: "pending", date: "2026-07-30", notes: "",
            email: "", phone: "", orderChannel: "", staffId: "",
            updatedAt: "2026-07-30T00:00:00.000Z",
            products: [{ productId: "SKU-1", name: "Widget", price: 100, quantity: 1 }]
        }
    }

    function test_normalizeOrder_adds_adjustments_even_when_the_raw_object_lacks_it() {
        var normalized = OrdersStore._normalizeOrder(_rawNewOrder())
        verify(Array.isArray(normalized.adjustments),
               "a freshly-created order must get adjustments:[] from normalization, not undefined")
        compare(normalized.adjustments.length, 0)
    }

    function test_normalizeOrder_preserves_updatedAt_sent_at_creation() {
        var normalized = OrdersStore._normalizeOrder(_rawNewOrder())
        compare(normalized.updatedAt, "2026-07-30T00:00:00.000Z",
                "updatedAt must survive normalization, not be silently dropped")
    }

    function test_normalizeOrder_is_idempotent_key_shape() {
        // The actual invariant that matters: running the SAME object through
        // normalization twice must produce the identical set of keys, since
        // that's exactly what happens in practice — addOrder normalizes
        // once to build the create payload, then every subsequent _clone()
        // normalizes again when rebuilding the local cache. If a second
        // pass ever changed the key set, the CAS mismatch bug is back.
        var once = OrdersStore._normalizeOrder(_rawNewOrder())
        var twice = OrdersStore._normalizeOrder(once)
        var onceKeys = Object.keys(once).sort()
        var twiceKeys = Object.keys(twice).sort()
        compare(JSON.stringify(onceKeys), JSON.stringify(twiceKeys))
    }

    function test_normalizeOrder_on_a_raw_object_missing_adjustments_matches_shape_of_one_that_has_it() {
        // The exact failure mode: two objects that represent the "same"
        // order at different points (one never touched adjustments, one
        // already has an empty array) must normalize to the SAME key set —
        // otherwise a before/current pair straddling that difference would
        // still spuriously mismatch.
        var withoutField = _rawNewOrder()
        delete withoutField.adjustments // already absent, but explicit for clarity
        var withEmptyArray = _rawNewOrder()
        withEmptyArray.adjustments = []

        var normA = OrdersStore._normalizeOrder(withoutField)
        var normB = OrdersStore._normalizeOrder(withEmptyArray)
        compare(JSON.stringify(Object.keys(normA).sort()), JSON.stringify(Object.keys(normB).sort()))
    }
}
