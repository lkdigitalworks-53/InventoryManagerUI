import QtQuick
import QtTest
import "../qml/model"

// Coverage for CategoryStore's local, synchronous behavior -- every function
// and branch EXCEPT the inside of _fetchFromFirebase()'s FirebaseService.get
// callback and _pushToFirebase()'s FirebaseService.put callback. Those two
// are real Firestore network calls with no mock layer available to QML
// singletons anywhere in this codebase (the established pattern for testing
// this class of code -- see tst_TenantContextRaceGuard.qml's comment -- is a
// hand-rolled stand-in object, not the real singleton; building one here
// risked the fake diverging from real behavior for marginal gain, so this
// file tests the real singleton for everything reachable without one).
//
// Concretely: addCategory/removeCategory/setDefault all call _commit(),
// which calls _saveLocal() (synchronous, fully covered below) THEN
// _pushToFirebase() (async, fire-and-forget from the test's perspective --
// it fires a real FirebaseService.put() against whatever backend this
// process can reach, which in an offline/sandboxed qmltestrunner run will
// fail on its own sometime after the test function has already returned).
// That's a known, structural gap, not a shortcut invented here -- flag if
// it produces console noise or flakiness on a real run.
//
// NOT RUN IN THIS SANDBOX -- no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local `qmltestrunner`
// pass before merge (same status as tst_EnvConfig.qml).
TestCase {
    name: "CategoryStore"

    function init() {
        CategoryStore.categories = CategoryStore.defaults.slice()
        CategoryStore.defaultCategory = ""
        CategoryStore.lastUsed = ""
        CategoryStore.revision = 0
        CategoryStore._settings.categoriesJson = ""
        CategoryStore._settings.lastUsed = ""
    }

    // ── _loadLocal ───────────────────────────────────────────────────────

    function test_loadLocal_falls_back_to_defaults_with_no_persisted_data() {
        CategoryStore._loadLocal()

        compare(CategoryStore.categories, CategoryStore.defaults)
        compare(CategoryStore.defaultCategory, CategoryStore.defaults[0])
        compare(CategoryStore.lastUsed, CategoryStore.defaults[0])
    }

    function test_loadLocal_restores_persisted_categories_and_default() {
        CategoryStore._settings.categoriesJson = JSON.stringify(["Books", "Toys"])
        CategoryStore._settings.lastUsed = "Toys"

        CategoryStore._loadLocal()

        compare(CategoryStore.categories, ["Books", "Toys"])
        compare(CategoryStore.defaultCategory, "Toys")
        compare(CategoryStore.lastUsed, "Toys")
    }

    function test_loadLocal_recovers_from_corrupted_json() {
        CategoryStore._settings.categoriesJson = "{not valid json"

        CategoryStore._loadLocal()

        compare(CategoryStore.categories, CategoryStore.defaults,
                "a JSON.parse failure must fall back to defaults, not throw or leave stale state")
    }

    function test_loadLocal_ignores_a_persisted_empty_array() {
        CategoryStore.categories = ["Books"] // pre-existing in-memory state
        CategoryStore._settings.categoriesJson = "[]"

        CategoryStore._loadLocal()

        compare(CategoryStore.categories, ["Books"],
                "an empty persisted array must be ignored (arr.length > 0 guard), not wipe categories")
    }

    function test_loadLocal_with_no_persisted_lastUsed_falls_back_to_first_category() {
        CategoryStore._settings.categoriesJson = JSON.stringify(["Books", "Toys"])
        CategoryStore._settings.lastUsed = ""

        CategoryStore._loadLocal()

        compare(CategoryStore.defaultCategory, "Books")
    }

    // ── addCategory ──────────────────────────────────────────────────────

    function test_addCategory_adds_trimmed_name_and_updates_local_persistence() {
        verify(CategoryStore.addCategory("  Books  "))

        verify(CategoryStore.categories.indexOf("Books") >= 0)
        compare(CategoryStore._settings.categoriesJson, JSON.stringify(CategoryStore.categories),
                "_saveLocal() runs synchronously inside _commit(), before the async Firestore push")
    }

    function test_addCategory_rejects_falsy_or_whitespace_name() {
        verify(!CategoryStore.addCategory(null))
        verify(!CategoryStore.addCategory(""))
        verify(!CategoryStore.addCategory("   "))
    }

    function test_addCategory_rejects_case_insensitive_duplicate() {
        CategoryStore.addCategory("Books")
        verify(!CategoryStore.addCategory("books"))
    }

    function test_addCategory_sets_first_ever_category_as_default() {
        CategoryStore.categories = []
        CategoryStore.defaultCategory = ""

        CategoryStore.addCategory("Books")

        compare(CategoryStore.defaultCategory, "Books")
    }

    function test_addCategory_does_not_override_an_existing_valid_default() {
        CategoryStore.addCategory("Books")
        CategoryStore.setDefault("Books")

        CategoryStore.addCategory("Toys")

        compare(CategoryStore.defaultCategory, "Books", "adding a second category must not steal the default")
    }

    function test_addCategory_bumps_revision() {
        var before = CategoryStore.revision
        CategoryStore.addCategory("Books")
        compare(CategoryStore.revision, before + 1)
    }

    // ── removeCategory ───────────────────────────────────────────────────

    function test_removeCategory_removes_and_persists_locally() {
        CategoryStore.addCategory("Books")
        CategoryStore.addCategory("Toys")

        CategoryStore.removeCategory("Books")

        compare(CategoryStore.categories.indexOf("Books"), -1)
        compare(CategoryStore._settings.categoriesJson, JSON.stringify(CategoryStore.categories))
    }

    function test_removeCategory_reassigns_default_when_removing_the_default() {
        CategoryStore.addCategory("Books")
        CategoryStore.addCategory("Toys")
        CategoryStore.setDefault("Books")

        CategoryStore.removeCategory("Books")

        compare(CategoryStore.defaultCategory, "Toys")
    }

    function test_removeCategory_leaves_default_unchanged_for_a_different_category() {
        CategoryStore.addCategory("Books")
        CategoryStore.addCategory("Toys")
        CategoryStore.setDefault("Books")

        CategoryStore.removeCategory("Toys")

        compare(CategoryStore.defaultCategory, "Books")
    }

    function test_removeCategory_emptying_the_list_sets_default_to_empty_string() {
        CategoryStore.categories = []
        CategoryStore.addCategory("Books")
        CategoryStore.setDefault("Books")

        CategoryStore.removeCategory("Books")

        compare(CategoryStore.categories.length, 0)
        compare(CategoryStore.defaultCategory, "")
    }

    // ── setDefault / setLastUsed ─────────────────────────────────────────

    function test_setDefault_sets_a_valid_existing_category() {
        CategoryStore.addCategory("Books")
        CategoryStore.addCategory("Toys")

        CategoryStore.setDefault("Toys")

        compare(CategoryStore.defaultCategory, "Toys")
        compare(CategoryStore.lastUsed, "Toys")
    }

    function test_setDefault_rejects_a_name_not_in_the_list() {
        CategoryStore.addCategory("Books")
        CategoryStore.setDefault("Books")

        CategoryStore.setDefault("NotInList")

        compare(CategoryStore.defaultCategory, "Books", "must be a no-op for an unknown category")
    }

    function test_setDefault_rejects_falsy_name() {
        CategoryStore.addCategory("Books")
        CategoryStore.setDefault("Books")

        CategoryStore.setDefault(null)
        CategoryStore.setDefault("")

        compare(CategoryStore.defaultCategory, "Books")
    }

    function test_setLastUsed_is_an_alias_for_setDefault() {
        CategoryStore.addCategory("Books")
        CategoryStore.addCategory("Toys")

        CategoryStore.setLastUsed("Toys")

        compare(CategoryStore.defaultCategory, "Toys", "setLastUsed must produce the identical effect as setDefault")
    }

    // ── indexOfDefault ───────────────────────────────────────────────────

    function test_indexOfDefault_returns_the_matching_index() {
        CategoryStore.categories = ["Books", "Toys", "Games"]
        CategoryStore.defaultCategory = "Toys"

        compare(CategoryStore.indexOfDefault(), 1)
    }

    function test_indexOfDefault_returns_zero_when_default_matches_nothing() {
        CategoryStore.categories = ["Books"]
        CategoryStore.defaultCategory = "NotInList"

        compare(CategoryStore.indexOfDefault(), 0)
    }

    // ── syncFromFirebase ─────────────────────────────────────────────────
    // Confirms only that the alias dispatches without throwing -- the
    // callback logic inside _fetchFromFirebase() itself is the documented
    // gap at the top of this file.

    function test_syncFromFirebase_dispatches_without_throwing() {
        CategoryStore.syncFromFirebase()
        verify(true)
    }
}
