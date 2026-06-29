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
}
