import QtQuick
import QtTest
import "../qml/helper/StockMovements.js" as SM

// P1 S2d-1: pure helper for explicit stock-movement kinds on client deltas. MIRRORS
// functions/lib/movementLogic.js; the same cases run in Node (functions/test/stockMovementsParity.test.js,
// 11/11 green, 8/8 sweep mutants caught on the floors rule). This file is the Qt-side copy: CI only.
TestCase {
    name: "StockMovements"

    function _ex(n, clamps) {
        var arr = []
        for (var i = 0; i < n; ++i) arr.push({ kind: "adjustment", qty: 1 })
        return { movements: arr, clamps: clamps || ({}) }
    }

    function _exf(floors, n, clamps) {
        var item = _ex(n || 1, clamps)
        item.floors = floors
        return item
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
            compare(SM.validate("inventory", { stock: 3 * dir }, {}, [{ kind: kinds[i], qty: 3 * dir, reason: "water damage" }]), "", kinds[i])
        }
    }

    // ── P1 S2e-1: which kinds need a reason (mirror of functions/lib/movementLogic.js REASON_REQUIRED) ──────
    function test_reason_policy_constants() {
        compare(SM.MIN_REASON_LENGTH, 3)
        compare(SM.REASON_REQUIRED.join(","), "loss,theft,destroyed,write_off,gift")
    }
    function test_reason_required_by_kind() {
        var need = ["loss", "theft", "destroyed", "write_off", "gift"]
        for (var i = 0; i < need.length; ++i) verify(SM.reasonRequired(need[i]), need[i])
        var free = ["receipt", "sales_return", "sale", "free_sample", "adjustment"]
        for (var j = 0; j < free.length; ++j) verify(!SM.reasonRequired(free[j]), free[j])
        verify(!SM.reasonRequired("constructor"))
        verify(!SM.reasonRequired(undefined))
    }
    function test_reason_problem_words_only_when_needed() {
        compare(SM.reasonProblem("theft", ""), "Add a short reason (at least 3 characters).")
        compare(SM.reasonProblem("theft", "  ab "), "Add a short reason (at least 3 characters).")
        compare(SM.reasonProblem("theft", undefined), "Add a short reason (at least 3 characters).")
        compare(SM.reasonProblem("theft", "abc"), "")
        compare(SM.reasonProblem("theft", "  abc  "), "")
        compare(SM.reasonProblem("free_sample", ""), "")
        compare(SM.reasonProblem("adjustment", undefined), "")
    }
    // PR #204 review D-1: text a person cannot see does not count as a reason. Runs on Qt's own JS engine,
    // which is the proof that the phone reads the INVISIBLE pattern exactly like Node does.
    function test_reason_problem_ignores_invisible_characters() {
        var words = "Add a short reason (at least 3 characters)."
        var hidden = ["\u200b\u200b\u200b", "\u00ad\u00ad\u00ad", "\u2060\u2060\u2060", "\u200d\u200d\u200d", "\u200e\u200f\u202e",
                      "\ufeff\ufeff\ufeff", "\u3164\u3164\u3164", "\u2800\u2800\u2800", "\u115f\u1160\uffa0", "\ufe0f\ufe0f\ufe0f",
                      "\u180e\u180e\u180e", "\u17b4\u17b5\u17b4", "\u034f\u034f\u034f", "\u061c\u061c\u061c", "\u2066\u2067\u2069",
                      " \u200b ab \u200b ", "a\u200bb", "\u00a0\u3000\u2003 a b"]
        for (var i = 0; i < hidden.length; i++) compare(SM.reasonProblem("theft", hidden[i]), words, "hidden #" + i)
        var shown = ["\u200babc", "a\u200bb\u200bc", "a...", "...", "---", "\u0a97\u0ac1\u0a9c\u0ab0\u0abe\u0aa4\u0ac0", "\u2764\ufe0f\u2764\ufe0f\u2764\ufe0f"]
        for (var j = 0; j < shown.length; j++) compare(SM.reasonProblem("theft", shown[j]), "", "shown #" + j)
        compare(SM.reasonProblem("adjustment", "\u200b\u200b\u200b"), "")
    }
    // PR #204 second sweep (D-1b): control characters and Unicode TAG characters (two UTF-16 units each, matched by the
    // surrogate-pair branch of the pattern) are invisible too. This is the proof that Qt's engine reads that branch like Node.
    function test_reason_problem_ignores_control_and_tag_characters() {
        var words = "Add a short reason (at least 3 characters)."
        var hidden = ["\u0001\u0002\u0003", "\u001f\u001f\u001f", "\u007f\u007f\u007f", "\u0085\u0085\u0085", "\u0080\u0081\u009f", "\u009f\u009f\u009f",
                      "\udb40\udc20\udb40\udc21\udb40\udc22", "\udb40\udd00\udb40\udd01\udb40\udd02", "\udb40\udc00\udb40\udc00",
                      "\udb40\udfff\udb40\udfff\udb40\udfff", " \u0001 ab \udb40\udc20 "]
        for (var i = 0; i < hidden.length; i++) compare(SM.reasonProblem("theft", hidden[i]), words, "hidden #" + i)
        // visible astral text and text that merely sits next to hidden characters must survive
        var shown = ["\ud835\udc00\ud835\udc01", "\udb41\udc00\udb41\udc00", "\udb40a\udb40b\udb40c", "a\u0001b\u0002c", "\ud83d\ude00\ud83d\ude00", "\u0001abc\udb40\udc20"]
        for (var j = 0; j < shown.length; j++) compare(SM.reasonProblem("theft", shown[j]), "", "shown #" + j)
        compare(SM.validate("inventory", { stock: -1 }, {}, [{ kind: "theft", qty: -1, reason: "\udb40\udc20\udb40\udc21\udb40\udc22" }]), "movement-reason-required")
    }
    // NUL gets its own test: if Qt's string handling ever treated it specially, this one fails alone and says so.
    function test_reason_problem_ignores_nul_characters() {
        var words = "Add a short reason (at least 3 characters)."
        compare(SM.reasonProblem("theft", "\u0000\u0000\u0000"), words)
        compare(SM.reasonProblem("theft", "\u0000abc"), "")
        compare(SM.validate("inventory", { stock: -1 }, {}, [{ kind: "theft", qty: -1, reason: "\u0000\u0000\u0000" }]), "movement-reason-required")
    }
    function test_validate_refuses_an_invisible_reason_on_a_required_kind() {
        compare(SM.validate("inventory", { stock: -1 }, {}, [{ kind: "theft", qty: -1, reason: "\u200b\u200b\u200b" }]), "movement-reason-required")
        compare(SM.validate("inventory", { stock: -1 }, {}, [{ kind: "theft", qty: -1, reason: "a\u200bb\u200bc" }]), "")
        compare(SM.validate("inventory", { stock: -1 }, {}, [{ kind: "adjustment", qty: -1, reason: "\u200b\u200b\u200b" }]), "")
    }
    function test_validate_refuses_a_required_kind_without_a_reason() {
        compare(SM.validate("inventory", { stock: -3 }, {}, [{ kind: "theft", qty: -3 }]), "movement-reason-required")
        compare(SM.validate("inventory", { stock: -3 }, {}, [{ kind: "gift", qty: -3, reason: " " }]), "movement-reason-required")
        compare(SM.validate("inventory", { stock: -3 }, {}, [{ kind: "gift", qty: -3, reason: "ab" }]), "movement-reason-required")
        compare(SM.validate("inventory", { stock: -3 }, {}, [{ kind: "gift", qty: -3, reason: "for staff" }]), "")
        compare(SM.validate("inventory", { stock: -3 }, {}, [{ kind: "free_sample", qty: -3 }]), "")
        // direction is checked before the reason, as on the server
        compare(SM.validate("inventory", { stock: 3 }, {}, [{ kind: "theft", qty: 3 }]), "invalid-movement-qty")
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
    function test_canCoalesce_explicit_pairs_with_equal_floors_merge() {
        compare(SM.canCoalesce(_exf({}), _exf({})), true)
        compare(SM.canCoalesce(_exf(undefined), _exf({})), true)
        compare(SM.canCoalesce(_exf(null), _exf(undefined)), true)
        compare(SM.canCoalesce(_exf({ stock: 0 }), _exf({ stock: 0 })), true)
    }
    function test_canCoalesce_a_non_object_floors_counts_as_empty() {
        compare(SM.canCoalesce(_exf("x"), _exf({})), true)
        compare(SM.canCoalesce(_exf(5), _exf(undefined)), true)
    }
    function test_canCoalesce_explicit_pairs_with_different_floors_never_merge() {
        compare(SM.canCoalesce(_exf({ stock: 0 }), _exf({})), false)
        compare(SM.canCoalesce(_exf({}), _exf({ stock: 0 })), false)
        compare(SM.canCoalesce(_exf({ stock: 0 }), _exf({ stock: 1 })), false)
        compare(SM.canCoalesce(_exf({ stock: 0 }), _exf({ qty: 0 })), false)
        compare(SM.canCoalesce(_exf({ stock: 0, qty: 0 }), _exf({ stock: 0 })), false)
        compare(SM.canCoalesce(_exf({ stock: undefined }), _exf({ qty: undefined })), false)
    }
    function test_canCoalesce_the_other_rules_still_apply_with_equal_floors() {
        compare(SM.canCoalesce(_exf({ stock: 0 }, 1, { stock: 0 }), _exf({ stock: 0 })), false)
        compare(SM.canCoalesce(_exf({ stock: 0 }, 25), _exf({ stock: 0 }, 26)), false)
        compare(SM.canCoalesce(_exf({ stock: 0 }, 25), _exf({ stock: 0 }, 25)), true)
    }
    function test_canCoalesce_derived_pairs_ignore_floors() {
        compare(SM.canCoalesce({ floors: { stock: 0 } }, { floors: {} }), true)
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
