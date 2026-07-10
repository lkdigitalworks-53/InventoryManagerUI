import QtQuick
import QtTest
import "../qml/helper/ImportMath.js" as IM

// Bug E: the SKU rename suffix was string-concatenated as
//   sku + "-" + counts.added + 1
// which, by left-associativity, is ((sku + "-" + counts.added) + 1) →
// "ABC-" + 0 + 1 = "ABC-01". The fix parenthesises the increment.
TestCase {
    name: "ImportMath"

    function test_rename_first_added_is_dash_one() {
        compare(IM.renameSku("ABC", 0), "ABC-1")   // NOT "ABC-01"
    }

    function test_rename_uses_incremented_counter() {
        compare(IM.renameSku("ABC", 4), "ABC-5")   // NOT "ABC-41"
    }

    function test_rename_double_digit() {
        compare(IM.renameSku("SKU", 11), "SKU-12")
    }

    function test_taxable_yes_is_true() {
        compare(IM.parseTaxableCell("Yes"), true)
    }

    function test_taxable_case_insensitive() {
        compare(IM.parseTaxableCell("yES"), true)
        compare(IM.parseTaxableCell("TRUE"), true)
        compare(IM.parseTaxableCell("1"), true)
    }

    function test_taxable_no_is_false() {
        compare(IM.parseTaxableCell("No"), false)
    }

    function test_taxable_blank_is_false() {
        compare(IM.parseTaxableCell(""), false)
        compare(IM.parseTaxableCell(undefined), false)
    }

    function test_taxable_unrecognized_defaults_false() {
        compare(IM.parseTaxableCell("maybe"), false)
    }

    function test_taxable_trims_whitespace() {
        compare(IM.parseTaxableCell("  Yes  "), true)
    }

    function test_taxpercent_zero_when_not_taxable() {
        compare(IM.parseTaxPercentCell("18", false), 0)
    }

    function test_taxpercent_parses_number_when_taxable() {
        compare(IM.parseTaxPercentCell("18", true), 18)
    }

    function test_taxpercent_blank_when_taxable_is_zero() {
        compare(IM.parseTaxPercentCell("", true), 0)
    }

    function test_taxpercent_invalid_when_taxable_is_zero() {
        compare(IM.parseTaxPercentCell("not a number", true), 0)
    }
}
