import QtQuick
import QtTest
import "../qml/model"

// SupplierStore.addLocalSupplier: the local-only hook a restock's new supplier goes through after the
// server created it (atomic-ops R3). Sends nothing; a repeated id is a no-op so a replayed operation
// cannot duplicate the supplier. Node twin: functions/test/restockSurface.test.js (H-1, H-2).
//
// NOT RUN IN THIS SANDBOX: no Qt/qmltestrunner toolchain here. CI is the oracle.
TestCase {
    name: "SupplierStore_addLocal"

    function init() { SupplierStore.suppliers = [] }
    function cleanup() { SupplierStore.suppliers = [] }

    function test_adds_a_new_supplier_and_returns_true() {
        verify(SupplierStore.addLocalSupplier({ supplierId: "SUP-001", name: "Acme" }))
        compare(SupplierStore.suppliers.length, 1)
        compare(SupplierStore.suppliers[0].supplierId, "SUP-001")
    }

    function test_keeps_the_list_sorted_by_name() {
        SupplierStore.suppliers = [{ supplierId: "SUP-001", name: "Mango" }]
        verify(SupplierStore.addLocalSupplier({ supplierId: "SUP-002", name: "Apple" }))
        compare(SupplierStore.suppliers[0].name, "Apple")
        compare(SupplierStore.suppliers[1].name, "Mango")
    }

    function test_a_repeated_id_is_a_no_op() {
        SupplierStore.suppliers = [{ supplierId: "SUP-001", name: "Mango" }]
        compare(SupplierStore.addLocalSupplier({ supplierId: "SUP-001", name: "Other" }), false)
        compare(SupplierStore.suppliers.length, 1)
        compare(SupplierStore.suppliers[0].name, "Mango", "the existing doc is not overwritten")
    }

    function test_a_doc_without_an_id_is_refused_data() {
        return [
            { tag: "null", doc: null }, { tag: "undefined", doc: undefined }, { tag: "empty object", doc: {} },
            { tag: "empty id", doc: { supplierId: "" } }, { tag: "name only", doc: { name: "x" } },
            { tag: "number", doc: 5 }, { tag: "string", doc: "SUP-9" }
        ]
    }

    function test_a_doc_without_an_id_is_refused(data) {
        compare(SupplierStore.addLocalSupplier(data.doc), false)
        compare(SupplierStore.suppliers.length, 0)
    }

    function test_the_array_is_replaced_not_changed_in_place() {
        var before = [{ supplierId: "SUP-001", name: "Mango" }]
        SupplierStore.suppliers = before
        SupplierStore.addLocalSupplier({ supplierId: "SUP-002", name: "Apple" })
        compare(before.length, 1, "a binding only reacts to a new array")
    }
}
