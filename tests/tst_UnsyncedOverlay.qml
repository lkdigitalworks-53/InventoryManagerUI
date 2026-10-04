import QtQuick
import QtTest
import "../qml/helper/UnsyncedOverlay.js" as UO

// PR #122 S4: headless tests for the pure overlay helpers (diff of before/after, overlay one
// product, overlay a page, state map). No singletons, so nothing here can be polluted by another
// test file. NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "UnsyncedOverlay"

    function _p(extra) {
        return Object.assign({ productId: "P1", name: "Widget", sellingPrice: 25, stock: 10, description: "d",
                               photoIds: [], taxable: false }, extra || {})
    }
    function _edit(before, after, action) {
        return { requestId: "e1", entity: "inventory", entityId: "P1", action: action || "update",
                 before: before, after: after }
    }

    // ── changedFields ────────────────────────────────────────────────────

    function test_changedFields_returns_only_the_changed_keys() {
        var f = UO.changedFields(_p(), _p({ sellingPrice: 30 }))
        compare(JSON.stringify(f), JSON.stringify({ sellingPrice: 30 }))
    }
    function test_changedFields_multiple_fields() {
        var f = UO.changedFields(_p(), _p({ sellingPrice: 30, name: "Gadget", taxable: true }))
        compare(Object.keys(f).sort().join(), "name,sellingPrice,taxable")
    }
    function test_changedFields_identical_docs_give_nothing_edge() {
        compare(Object.keys(UO.changedFields(_p(), _p())).length, 0)
    }
    function test_changedFields_never_replays_productId_edge() {
        var f = UO.changedFields(_p(), _p({ productId: "P2" }))
        verify(!("productId" in f))
    }
    function test_changedFields_array_field_compared_by_value_edge() {
        compare(Object.keys(UO.changedFields(_p({ photoIds: ["a"] }), _p({ photoIds: ["a"] }))).length, 0)
        compare(Object.keys(UO.changedFields(_p({ photoIds: ["a"] }), _p({ photoIds: ["a", "b"] }))).join(), "photoIds")
    }
    function test_changedFields_empty_string_is_a_real_change_edge() {
        var f = UO.changedFields(_p({ description: "d" }), _p({ description: "" }))
        compare(f.description, "")
    }
    function test_changedFields_zero_is_a_real_change_edge() {
        var f = UO.changedFields(_p({ stock: 10 }), _p({ stock: 0 }))
        compare(f.stock, 0)
    }
    function test_changedFields_null_before_replays_whole_after_edge() {
        var f = UO.changedFields(null, _p({ sellingPrice: 30 }))
        compare(f.sellingPrice, 30)
        compare(f.name, "Widget")
        verify(!("productId" in f))
    }
    function test_changedFields_non_object_before_treated_as_missing_edge() {
        compare(UO.changedFields("junk", { a: 1 }).a, 1)
    }
    function test_changedFields_missing_after_gives_nothing_negative() {
        compare(Object.keys(UO.changedFields(_p(), null)).length, 0)
        compare(Object.keys(UO.changedFields(_p(), undefined)).length, 0)
        compare(Object.keys(UO.changedFields(_p(), "x")).length, 0)
    }
    function test_changedFields_undefined_value_is_skipped_edge() {
        var f = UO.changedFields({ a: 1 }, { a: undefined, b: 2 })
        verify(!("a" in f))
        compare(f.b, 2)
    }
    function test_changedFields_field_added_in_after_edge() {
        compare(UO.changedFields({ a: 1 }, { a: 1, b: 2 }).b, 2)
    }

    // ── overlay ──────────────────────────────────────────────────────────

    function test_overlay_applies_the_user_change_to_the_server_copy() {
        var server = _p()                               // server still says 25
        var o = UO.overlay(server, _edit(_p(), _p({ sellingPrice: 30 })))
        compare(o.sellingPrice, 30)
        compare(o.name, "Widget")
    }
    function test_overlay_does_not_mutate_the_input() {
        var server = _p()
        UO.overlay(server, _edit(_p(), _p({ sellingPrice: 30 })))
        compare(server.sellingPrice, 25)
    }
    function test_overlay_keeps_a_server_side_stock_change_the_user_did_not_touch() {
        // user edited price at stock 10; meanwhile the server stock became 7 (sale elsewhere).
        var server = _p({ stock: 7 })
        var o = UO.overlay(server, _edit(_p({ stock: 10 }), _p({ stock: 10, sellingPrice: 30 })))
        compare(o.stock, 7, "replaying the whole `after` would resurrect stock 10")
        compare(o.sellingPrice, 30)
    }
    function test_overlay_user_changed_stock_wins_edge() {
        var o = UO.overlay(_p({ stock: 7 }), _edit(_p({ stock: 10 }), _p({ stock: 4 })))
        compare(o.stock, 4)
    }
    function test_overlay_merged_edit_net_change_edge() {
        // outbox merge keeps the earliest before and the latest after
        var o = UO.overlay(_p(), _edit(_p(), _p({ sellingPrice: 40, name: "B" })))
        compare(o.sellingPrice, 40)
        compare(o.name, "B")
    }
    function test_overlay_edit_that_nets_to_nothing_changes_nothing_edge() {
        var o = UO.overlay(_p(), _edit(_p(), _p()))
        compare(JSON.stringify(o), JSON.stringify(_p()))
    }
    function test_overlay_ignores_non_update_actions_negative() {
        compare(UO.overlay(_p(), _edit(null, _p({ sellingPrice: 99 }), "create")).sellingPrice, 25)
        compare(UO.overlay(_p(), _edit(_p(), null, "delete")).sellingPrice, 25)
    }
    function test_overlay_missing_edit_returns_copy_negative() {
        var s = _p()
        var o = UO.overlay(s, null)
        compare(JSON.stringify(o), JSON.stringify(s))
        verify(o !== s)
        compare(UO.overlay(s, undefined).name, "Widget")
    }
    function test_overlay_edit_without_after_changes_nothing_negative() {
        compare(UO.overlay(_p(), { action: "update", before: _p(), after: null }).sellingPrice, 25)
    }

    // ── overlayAll ───────────────────────────────────────────────────────

    function test_overlayAll_replaces_only_products_with_an_edit() {
        var page = [_p({ productId: "P1" }), _p({ productId: "P2", sellingPrice: 11 })]
        var snap = { P1: { state: "pending", edit: _edit(_p(), _p({ sellingPrice: 30 })) } }
        var out = UO.overlayAll(page, snap)
        compare(out.length, 2)
        compare(out[0].sellingPrice, 30)
        compare(out[1].sellingPrice, 11)
        verify(out[1] === page[1], "untouched products are passed through as-is")
    }
    function test_overlayAll_state_without_edit_leaves_product_alone_edge() {
        // e.g. a queued create/delete/delta gives a state but no replayable edit
        var page = [_p()]
        var out = UO.overlayAll(page, { P1: { state: "pending", edit: null } })
        compare(out[0].sellingPrice, 25)
    }
    function test_overlayAll_keeps_order_and_length() {
        var page = [_p({ productId: "A" }), _p({ productId: "B" }), _p({ productId: "C" })]
        var out = UO.overlayAll(page, {})
        compare(out.map(function(p) { return p.productId }).join(), "A,B,C")
    }
    function test_overlayAll_empty_page_edge() { compare(UO.overlayAll([], { P1: { edit: null } }).length, 0) }
    function test_overlayAll_null_snapshot_negative() {
        compare(UO.overlayAll([_p()], null).length, 1)
        compare(UO.overlayAll([_p()], undefined)[0].name, "Widget")
    }
    function test_overlayAll_snapshot_for_unknown_product_is_ignored_edge() {
        var out = UO.overlayAll([_p()], { GONE: { state: "pending", edit: _edit(_p(), _p({ name: "x" })) } })
        compare(out[0].name, "Widget")
    }
    function test_overlayAll_parked_edit_is_overlaid_too() {
        var out = UO.overlayAll([_p()], { P1: { state: "parked", edit: _edit(_p(), _p({ sellingPrice: 30 })) } })
        compare(out[0].sellingPrice, 30)
    }

    // ── statesOf ─────────────────────────────────────────────────────────

    function test_statesOf_maps_each_product_to_its_state() {
        var m = UO.statesOf({ P1: { state: "pending", edit: null }, P2: { state: "parked", edit: null } })
        compare(m.P1, "pending")
        compare(m.P2, "parked")
    }
    function test_statesOf_empty_and_null_edge() {
        compare(Object.keys(UO.statesOf({})).length, 0)
        compare(Object.keys(UO.statesOf(null)).length, 0)
        compare(Object.keys(UO.statesOf(undefined)).length, 0)
    }
}
