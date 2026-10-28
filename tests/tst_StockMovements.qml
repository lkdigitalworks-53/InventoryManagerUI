import QtQuick
import QtTest
import "../qml/helper/StockMovements.js" as SM

// P1 S2d-1: pure helper for explicit stock-movement kinds on client deltas. MIRRORS
// functions/lib/movementLogic.js; the same cases run in Node (functions/test/stockMovementsParity.test.js,
// 10/10 green, helper 100% line/branch, 16/16 mutants caught). This file is the Qt-side copy: CI only.
TestCase {
    name: "StockMovements"

    function _ex(n, clamps) {
        var arr = []
        for (var i = 0; i < n; ++i) arr.push({ kind: "adjustment", qty: 1 })
        return { movements: arr, clamps: clamps || ({}) }
    }

    // ── constants ────────────────────────────────────────────────────────
    function test_constants_match_the_server_caps() {
        compare(SM.MAX_MOVEMENTS, 50)
        compare(SM.MAX_REASON, 500)
        compare(Object.keys(SM.KIND_DIRECTION).length, 10)
        compare(SM.KIND_DIRECTION.receipt, 1)
        compare(SM.KIND_DIRECTION.sales_return, 1)
        compare(SM.KIND_DIRECTION.sale, -1)
        compare(SM.KIND_DIRECTION.adjustment, 0)
    }

    // ── make ─────────────────────────────────────────────────────────────
    function test_make_trims_the_reason() {
        var m = SM.make("receipt", 5, "  hello  ")
        compare(m.kind, "receipt"); compare(m.qty, 5); compare(m.reason, "hello")
    }
    function test_make_defaults_a_missing_or_non_string_reason_to_empty() {
        compare(SM.make("receipt", 5).reason, "")
        compare(SM.make("receipt", 5, null).reason, "")
        compare(SM.make("receipt", 5, 42).reason, "")
    }
    function test_make_cuts_a_long_reason_to_the_server_limit_and_stays_valid() {
        var m = SM.make("receipt", 5, new Array(901).join("x"))
        compare(m.reason.length, 500)
        compare(SM.validate("inventory", { stock: 5 }, {}, [m]), "")
    }
    function test_make_never_carries_valueAtCost() {
        compare(SM.make("sale", -1, "r").valueAtCost, undefined)
    }

    // ── validate ─────────────────────────────────────────────────────────
    function test_validate_without_movements_is_always_fine() {
        compare(SM.validate("inventory", { stock: 5 }, {}, undefined), "")
        compare(SM.validate("inventory", { stock: 5 }, { stock: 0 }, null), "")
        compare(SM.validate("stock_batch", { qtyRemaining: -1 }, {}, undefined), "")
    }
    function test_validate_error_codes_one_per_fault() {
        var ok = [{ kind: "receipt", qty: 5, reason: "" }]
        compare(SM.validate("inventory", { stock: 5 }, {}, []), "invalid-movements")
        compare(SM.validate("inventory", { stock: 5 }, {}, "x"), "invalid-movements")
        compare(SM.validate("inventory", { stock: 5 }, {}, [null]), "invalid-movements")
        compare(SM.validate("inventory", { stock: 5 }, {}, _ex(51).movements), "too-many-movements")
        compare(SM.validate("stock_batch", { stock: 5 }, {}, ok), "movements-require-inventory")
        compare(SM.validate("inventory", { qty: 5 }, {}, ok), "movements-require-stock-delta")
        compare(SM.validate("inventory", undefined, {}, ok), "movements-require-stock-delta")
        compare(SM.validate("inventory", { stock: "5" }, {}, ok), "movements-require-stock-delta")
        compare(SM.validate("inventory", { stock: 5 }, {}, [{ kind: "bogus", qty: 5 }]), "invalid-movement-kind")
        compare(SM.validate("inventory", { stock: 5 }, {}, [{ kind: "toString", qty: 5 }]), "invalid-movement-kind")
        compare(SM.validate("inventory", { stock: 0 }, {}, [{ kind: "adjustment", qty: 0 }]), "invalid-movement-qty")
        compare(SM.validate("inventory", { stock: 5 }, {}, [{ kind: "receipt", qty: "5" }]), "invalid-movement-qty")
        compare(SM.validate("inventory", { stock: -5 }, {}, [{ kind: "receipt", qty: -5 }]), "invalid-movement-qty")
        compare(SM.validate("inventory", { stock: 5 }, {}, [{ kind: "sale", qty: 5 }]), "invalid-movement-qty")
        compare(SM.validate("inventory", { stock: 5 }, {}, [{ kind: "receipt", qty: 5, reason: 7 }]), "invalid-movement-reason")
        compare(SM.validate("inventory", { stock: 5 }, { stock: 0 }, ok), "movements-with-clamps")
        compare(SM.validate("inventory", { stock: 6 }, {}, ok), "movement-qty-mismatch")
    }
    function test_validate_accepts_every_kind_with_its_own_direction() {
        var kinds = Object.keys(SM.KIND_DIRECTION)
        for (var i = 0; i < kinds.length; ++i) {
            var dir = SM.KIND_DIRECTION[kinds[i]] || 1
            compare(SM.validate("inventory", { stock: 3 * dir }, {}, [{ kind: kinds[i], qty: 3 * dir }]), "", kinds[i])
        }
    }
    function test_validate_accepts_a_split_float_noise_null_reason_and_the_cap() {
        compare(SM.validate("inventory", { stock: 7 }, {}, [{ kind: "receipt", qty: 10 }, { kind: "sale", qty: -3 }]), "")
        compare(SM.validate("inventory", { stock: 0.3 }, {}, [{ kind: "receipt", qty: 0.1 }, { kind: "receipt", qty: 0.2 }]), "")
        compare(SM.validate("inventory", { stock: 5 }, {}, [{ kind: "receipt", qty: 5, reason: null }]), "")
        compare(SM.validate("inventory", { stock: 50 }, {}, _ex(50).movements), "")
    }
    function test_validate_ignores_a_non_object_clamps_like_the_server() {
        compare(SM.validate("inventory", { stock: 5 }, "x", [{ kind: "receipt", qty: 5 }]), "")
        compare(SM.validate("inventory", { stock: 5 }, null, [{ kind: "receipt", qty: 5 }]), "")
    }

    // ── hasMovements / canCoalesce / mergeMovements ──────────────────────
    function test_hasMovements_only_for_a_non_empty_array() {
        compare(SM.hasMovements([{}]), true)
        compare(SM.hasMovements([]), false)
        compare(SM.hasMovements(undefined), false)
        compare(SM.hasMovements(null), false)
        compare(SM.hasMovements({}), false)
        compare(SM.hasMovements("x"), false)
    }
    function test_canCoalesce_derived_pairs_keep_the_old_rule() {
        compare(SM.canCoalesce({}, {}), true)
        compare(SM.canCoalesce({ clamps: { stock: 0 } }, { clamps: {} }), true)
        compare(SM.canCoalesce(undefined, undefined), true)
    }
    function test_canCoalesce_explicit_never_mixes_with_derived() {
        compare(SM.canCoalesce(_ex(1), {}), false)
        compare(SM.canCoalesce({}, _ex(1)), false)
        compare(SM.canCoalesce(_ex(1), { movements: [] }), false)
    }
    function test_canCoalesce_explicit_pairs_respect_cap_and_clamps() {
        compare(SM.canCoalesce(_ex(1), _ex(1)), true)
        compare(SM.canCoalesce(_ex(25), _ex(25)), true)
        compare(SM.canCoalesce(_ex(25), _ex(26)), false)
        compare(SM.canCoalesce(_ex(1, { stock: 0 }), _ex(1)), false)
        compare(SM.canCoalesce(_ex(1), _ex(1, { stock: 0 })), false)
    }
    function test_mergeMovements_keeps_call_order_and_does_not_mutate() {
        var a = [{ kind: "receipt", qty: 10 }]
        var b = [{ kind: "sale", qty: -3 }]
        var m = SM.mergeMovements(a, b)
        compare(m.length, 2); compare(m[0].kind, "receipt"); compare(m[1].kind, "sale")
        compare(a.length, 1); compare(b.length, 1)
        compare(SM.mergeMovements(undefined, b).length, 1)
        compare(SM.mergeMovements(a, undefined).length, 1)
        compare(SM.mergeMovements(undefined, undefined).length, 0)
    }
}
