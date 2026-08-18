import QtQuick
import QtTest
import "../qml/model"

// Comprehensive coverage for PartyStore -- every function, every branch.
// Fully achievable at 100%: PartyStore is pure QSettings, no Firestore/
// FirebaseService calls anywhere in it, unlike CategoryStore/OrderChannelStore.
//
// NOT RUN IN THIS SANDBOX -- no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local `qmltestrunner`
// pass before merge (same status as tst_EnvConfig.qml).
TestCase {
    name: "PartyStore"

    function init() {
        PartyStore.clear() // resets memory AND the persisted settings file
    }

    // ── addParty ─────────────────────────────────────────────────────────

    function test_addParty_adds_and_persists() {
        verify(PartyStore.addParty("Acme Wholesale"))
        compare(PartyStore.parties.length, 1)
        compare(PartyStore.parties[0], "Acme Wholesale")
    }

    function test_addParty_trims_surrounding_whitespace_before_storing() {
        PartyStore.addParty("  Acme Wholesale  ")
        compare(PartyStore.parties[0], "Acme Wholesale")
    }

    function test_addParty_rejects_falsy_name() {
        verify(!PartyStore.addParty(null))
        verify(!PartyStore.addParty(undefined))
        verify(!PartyStore.addParty(""))
        compare(PartyStore.parties.length, 0)
    }

    function test_addParty_rejects_whitespace_only_name() {
        verify(!PartyStore.addParty("   "))
        compare(PartyStore.parties.length, 0)
    }

    function test_addParty_rejects_case_insensitive_duplicate() {
        PartyStore.addParty("Acme Wholesale")
        verify(!PartyStore.addParty("acme wholesale"))
        verify(!PartyStore.addParty("ACME WHOLESALE"))
        compare(PartyStore.parties.length, 1)
    }

    function test_addParty_persists_across_a_simulated_relaunch() {
        PartyStore.addParty("Acme Wholesale")

        PartyStore.parties = [] // simulate pre-_load() in-memory state
        PartyStore._load()      // simulate Component.onCompleted on relaunch

        compare(PartyStore.parties.length, 1,
                "must reload the persisted party after a simulated relaunch -- if this is 0, " +
                "Settings never actually wrote to a real file")
        compare(PartyStore.parties[0], "Acme Wholesale")
    }

    // ── removeParty ──────────────────────────────────────────────────────

    function test_removeParty_removes_matching_name_and_persists() {
        PartyStore.addParty("Acme")
        PartyStore.addParty("Beta")
        PartyStore.removeParty("Acme")

        compare(PartyStore.parties.length, 1)
        compare(PartyStore.parties[0], "Beta")

        PartyStore.parties = []
        PartyStore._load()
        compare(PartyStore.parties.length, 1, "removal must persist across a simulated relaunch too")
    }

    function test_removeParty_of_nonexistent_name_is_a_noop() {
        PartyStore.addParty("Acme")
        PartyStore.removeParty("DoesNotExist")
        compare(PartyStore.parties.length, 1)
    }

    function test_removeParty_reassigns_lastUsed_when_removing_the_lastUsed_party() {
        PartyStore.addParty("Acme")
        PartyStore.addParty("Beta")
        PartyStore.setLastUsed("Acme")

        PartyStore.removeParty("Acme")

        compare(PartyStore.lastUsed, "Beta", "must fall back to the first remaining party")
    }

    function test_removeParty_leaves_lastUsed_unchanged_when_removing_a_different_party() {
        PartyStore.addParty("Acme")
        PartyStore.addParty("Beta")
        PartyStore.setLastUsed("Acme")

        PartyStore.removeParty("Beta")

        compare(PartyStore.lastUsed, "Acme")
    }

    function test_removeParty_emptying_the_list_sets_lastUsed_to_empty_string() {
        PartyStore.addParty("Acme")
        PartyStore.setLastUsed("Acme")

        PartyStore.removeParty("Acme")

        compare(PartyStore.parties.length, 0)
        compare(PartyStore.lastUsed, "")
    }

    // ── setLastUsed ──────────────────────────────────────────────────────

    function test_setLastUsed_sets_and_persists() {
        PartyStore.addParty("Acme")
        PartyStore.setLastUsed("Acme")

        compare(PartyStore.lastUsed, "Acme")

        PartyStore.lastUsed = ""
        PartyStore._load()
        compare(PartyStore.lastUsed, "Acme", "lastUsed must persist across a simulated relaunch")
    }

    function test_setLastUsed_with_falsy_name_is_a_noop() {
        PartyStore.addParty("Acme")
        PartyStore.setLastUsed("Acme")

        PartyStore.setLastUsed(null)
        compare(PartyStore.lastUsed, "Acme", "a falsy name must not clobber the existing lastUsed")

        PartyStore.setLastUsed("")
        compare(PartyStore.lastUsed, "Acme")
    }

    // ── clear ────────────────────────────────────────────────────────────

    function test_clear_resets_memory_and_the_persisted_file() {
        PartyStore.addParty("Acme")
        PartyStore.setLastUsed("Acme")

        PartyStore.clear()

        compare(PartyStore.parties.length, 0)
        compare(PartyStore.lastUsed, "")

        // Not just in-memory -- the persisted file too, or a relaunch would
        // silently bring the "cleared" party back.
        PartyStore._load()
        compare(PartyStore.parties.length, 0,
                "clear() must wipe the persisted file, not just in-memory state")
    }

    // ── indexOfDefault ───────────────────────────────────────────────────

    function test_indexOfDefault_returns_the_matching_index() {
        PartyStore.addParty("Acme")
        PartyStore.addParty("Beta")
        PartyStore.addParty("Gamma")
        PartyStore.setLastUsed("Beta")

        compare(PartyStore.indexOfDefault(), 1)
    }

    function test_indexOfDefault_returns_zero_when_lastUsed_matches_nothing() {
        PartyStore.addParty("Acme")
        PartyStore.lastUsed = "NotInList"

        compare(PartyStore.indexOfDefault(), 0)
    }

    function test_indexOfDefault_returns_zero_on_an_empty_list() {
        compare(PartyStore.indexOfDefault(), 0)
    }
}
