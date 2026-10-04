import QtQuick
import QtTest
import "../qml/helper/DocLimits.js" as DL

// PR #122: headless tests for the client-side Firestore 1 MiB document guard.
// Pure JS, no singletons. NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "DocLimits"

    function _rep(ch, n) { var s = ""; for (var i = 0; i < n; ++i) s += ch; return s }
    function _doc(desc) { return { productId: "P1", name: "W", stock: 3, taxable: false, description: desc, photoIds: [] } }

    // ── constants ────────────────────────────────────────────────────────

    function test_limit_is_one_mib_minus_reserve() {
        compare(DL.MAX_DOC_BYTES, 1048576)
        compare(DL.LIMIT_BYTES, DL.MAX_DOC_BYTES - DL.RESERVE_BYTES)
        verify(DL.RESERVE_BYTES > 0)
    }

    // ── utf8Bytes ────────────────────────────────────────────────────────

    function test_utf8Bytes_ascii() { compare(DL.utf8Bytes("abc"), 3) }
    function test_utf8Bytes_two_byte_char() { compare(DL.utf8Bytes("é"), 2) }
    function test_utf8Bytes_three_byte_char() { compare(DL.utf8Bytes("€"), 3) }
    function test_utf8Bytes_devanagari_three_bytes_each() { compare(DL.utf8Bytes("क"), 3) }
    function test_utf8Bytes_surrogate_pair_is_four_bytes() { compare(DL.utf8Bytes("😀"), 4) }
    function test_utf8Bytes_lone_high_surrogate_is_three_edge() { compare(DL.utf8Bytes("\uD83D"), 3) }
    function test_utf8Bytes_lone_low_surrogate_is_three_edge() { compare(DL.utf8Bytes("\uDE00"), 3) }
    function test_utf8Bytes_high_surrogate_at_end_after_text_edge() { compare(DL.utf8Bytes("a\uD83D"), 4) }
    function test_utf8Bytes_empty_edge() { compare(DL.utf8Bytes(""), 0) }
    function test_utf8Bytes_null_and_undefined_are_zero_negative() {
        compare(DL.utf8Bytes(null), 0)
        compare(DL.utf8Bytes(undefined), 0)
    }
    function test_utf8Bytes_non_string_is_stringified_edge() { compare(DL.utf8Bytes(12345), 5) }
    function test_utf8Bytes_newline_counts_one_not_two_edge() { compare(DL.utf8Bytes("a\nb"), 3) }

    // ── valueBytes / docBytes ────────────────────────────────────────────

    function test_valueBytes_scalars() {
        compare(DL.valueBytes(null), 1)
        compare(DL.valueBytes(undefined), 1)
        compare(DL.valueBytes(true), 1)
        compare(DL.valueBytes(42), 8)
        compare(DL.valueBytes("ab"), 3)
    }
    function test_valueBytes_array_sums_elements() { compare(DL.valueBytes(["a", "b"]), 4) }
    function test_valueBytes_object_counts_key_plus_one_plus_value() {
        compare(DL.valueBytes({ ab: "c" }), (2 + 1) + (1 + 1))
    }
    function test_valueBytes_undefined_field_is_not_sent_edge() {
        compare(DL.valueBytes({ a: undefined }), 0)
    }
    function test_valueBytes_nested_edge() {
        compare(DL.valueBytes({ k: { n: 1 } }), (1 + 1) + ((1 + 1) + 8))
    }
    function test_valueBytes_function_counts_nothing_negative() { compare(DL.valueBytes(function() {}), 0) }
    function test_docBytes_adds_the_32_byte_overhead() { compare(DL.docBytes({}), 32) }

    // ── exceedsDoc ───────────────────────────────────────────────────────

    function test_small_doc_fits() { verify(!DL.exceedsDoc(_doc("hello"))) }
    function test_empty_description_fits_edge() { verify(!DL.exceedsDoc(_doc(""))) }
    function test_description_over_one_mib_is_refused() {
        verify(DL.exceedsDoc(_doc(_rep("a", 1048577))))
    }
    function test_description_of_exactly_one_mib_is_refused_because_other_fields_need_room_edge() {
        verify(DL.exceedsDoc(_doc(_rep("a", 1048576))))
    }
    function test_boundary_just_under_the_limit_fits_edge() {
        // fixed overhead of this doc, measured, so the test does not hard-code the field sizes
        var base = DL.docBytes(_doc(""))
        var room = DL.LIMIT_BYTES - base
        verify(!DL.exceedsDoc(_doc(_rep("a", room))), "exactly on the limit still fits")
        verify(DL.exceedsDoc(_doc(_rep("a", room + 1))), "one more byte tips it over")
    }
    function test_multibyte_description_is_measured_in_bytes_not_chars_edge() {
        // 400k Devanagari chars = 1.2 MB: under 1 Mi CHARS, over 1 MiB BYTES
        verify(DL.exceedsDoc(_doc(_rep("क", 400000))))
    }
    function test_many_emoji_edge() {
        verify(DL.exceedsDoc(_doc(_rep("😀", 270000)))) // 4 bytes each = 1.08 MB
    }
    function test_large_photoIds_array_counts_edge() {
        var ids = []
        for (var i = 0; i < 5000; ++i) ids.push(_rep("x", 250))
        verify(DL.exceedsDoc({ productId: "P", photoIds: ids }))
    }
    function test_null_undefined_and_non_object_are_never_too_big_negative() {
        verify(!DL.exceedsDoc(null))
        verify(!DL.exceedsDoc(undefined))
        verify(!DL.exceedsDoc("a string"))
        verify(!DL.exceedsDoc(5))
    }
    function test_monkey_random_docs_never_throw() {
        var junk = [undefined, null, 0, -1, NaN, "", "\u0000", "\uD83D", [], {}, [[]], { a: { b: { c: [1, "x", null] } } }, true, false]
        for (var i = 0; i < junk.length; ++i) {
            DL.valueBytes(junk[i])
            DL.exceedsDoc(junk[i])
            DL.docBytes({ k: junk[i] })
        }
        verify(true)
    }
}
