import QtQuick
import QtTest
import "../qml/model"

// Coverage for OrderChannelStore's local, synchronous behavior -- every
// function and branch EXCEPT the inside of _fetchFromFirebase()'s
// FirebaseService.get callback and _pushToFirebase()'s FirebaseService.put
// callback. See tst_CategoryStore.qml's header comment (identical shape,
// same store pattern) for why: no FirebaseService mock layer exists for QML
// singletons in this codebase, and _commit()'s _pushToFirebase() call is a
// real, async, fire-and-forget Firestore write from the test's perspective.
//
// NOT RUN IN THIS SANDBOX -- no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local `qmltestrunner`
// pass before merge (same status as tst_EnvConfig.qml).
TestCase {
    name: "OrderChannelStore"

    function init() {
        OrderChannelStore.channels = OrderChannelStore.defaults.slice()
        OrderChannelStore.defaultChannel = ""
        OrderChannelStore.lastUsed = ""
        OrderChannelStore.revision = 0
        OrderChannelStore._settings.channelsJson = ""
        OrderChannelStore._settings.lastUsed = ""
    }

    // ── _loadLocal ───────────────────────────────────────────────────────

    function test_loadLocal_falls_back_to_defaults_with_no_persisted_data() {
        OrderChannelStore._loadLocal()

        compare(OrderChannelStore.channels, OrderChannelStore.defaults)
        compare(OrderChannelStore.defaultChannel, OrderChannelStore.defaults[0])
    }

    function test_loadLocal_restores_persisted_channels_and_default() {
        OrderChannelStore._settings.channelsJson = JSON.stringify(["Online", "Phone"])
        OrderChannelStore._settings.lastUsed = "Phone"

        OrderChannelStore._loadLocal()

        compare(OrderChannelStore.channels, ["Online", "Phone"])
        compare(OrderChannelStore.defaultChannel, "Phone")
        compare(OrderChannelStore.lastUsed, "Phone")
    }

    function test_loadLocal_recovers_from_corrupted_json() {
        OrderChannelStore._settings.channelsJson = "{not valid json"

        OrderChannelStore._loadLocal()

        compare(OrderChannelStore.channels, OrderChannelStore.defaults)
    }

    function test_loadLocal_ignores_a_persisted_empty_array() {
        OrderChannelStore.channels = ["Online"]
        OrderChannelStore._settings.channelsJson = "[]"

        OrderChannelStore._loadLocal()

        compare(OrderChannelStore.channels, ["Online"])
    }

    function test_loadLocal_with_no_persisted_lastUsed_falls_back_to_first_channel() {
        OrderChannelStore._settings.channelsJson = JSON.stringify(["Online", "Phone"])
        OrderChannelStore._settings.lastUsed = ""

        OrderChannelStore._loadLocal()

        compare(OrderChannelStore.defaultChannel, "Online")
    }

    // ── addChannel ───────────────────────────────────────────────────────

    function test_addChannel_adds_trimmed_name_and_updates_local_persistence() {
        verify(OrderChannelStore.addChannel("  WhatsApp  "))

        verify(OrderChannelStore.channels.indexOf("WhatsApp") >= 0)
        compare(OrderChannelStore._settings.channelsJson, JSON.stringify(OrderChannelStore.channels))
    }

    function test_addChannel_rejects_falsy_or_whitespace_name() {
        verify(!OrderChannelStore.addChannel(null))
        verify(!OrderChannelStore.addChannel(""))
        verify(!OrderChannelStore.addChannel("   "))
    }

    function test_addChannel_rejects_case_insensitive_duplicate() {
        OrderChannelStore.addChannel("WhatsApp")
        verify(!OrderChannelStore.addChannel("whatsapp"))
    }

    function test_addChannel_sets_first_ever_channel_as_default() {
        OrderChannelStore.channels = []
        OrderChannelStore.defaultChannel = ""

        OrderChannelStore.addChannel("WhatsApp")

        compare(OrderChannelStore.defaultChannel, "WhatsApp")
    }

    function test_addChannel_does_not_override_an_existing_valid_default() {
        OrderChannelStore.addChannel("WhatsApp")
        OrderChannelStore.setDefault("WhatsApp")

        OrderChannelStore.addChannel("Instagram")

        compare(OrderChannelStore.defaultChannel, "WhatsApp")
    }

    function test_addChannel_bumps_revision() {
        var before = OrderChannelStore.revision
        OrderChannelStore.addChannel("WhatsApp")
        compare(OrderChannelStore.revision, before + 1)
    }

    // ── removeChannel ────────────────────────────────────────────────────

    function test_removeChannel_removes_and_persists_locally() {
        OrderChannelStore.addChannel("WhatsApp")
        OrderChannelStore.addChannel("Instagram")

        OrderChannelStore.removeChannel("WhatsApp")

        compare(OrderChannelStore.channels.indexOf("WhatsApp"), -1)
        compare(OrderChannelStore._settings.channelsJson, JSON.stringify(OrderChannelStore.channels))
    }

    function test_removeChannel_reassigns_default_when_removing_the_default() {
        OrderChannelStore.addChannel("WhatsApp")
        OrderChannelStore.addChannel("Instagram")
        OrderChannelStore.setDefault("WhatsApp")

        OrderChannelStore.removeChannel("WhatsApp")

        compare(OrderChannelStore.defaultChannel, "Instagram")
    }

    function test_removeChannel_leaves_default_unchanged_for_a_different_channel() {
        OrderChannelStore.addChannel("WhatsApp")
        OrderChannelStore.addChannel("Instagram")
        OrderChannelStore.setDefault("WhatsApp")

        OrderChannelStore.removeChannel("Instagram")

        compare(OrderChannelStore.defaultChannel, "WhatsApp")
    }

    function test_removeChannel_emptying_the_list_sets_default_to_empty_string() {
        OrderChannelStore.channels = []
        OrderChannelStore.addChannel("WhatsApp")
        OrderChannelStore.setDefault("WhatsApp")

        OrderChannelStore.removeChannel("WhatsApp")

        compare(OrderChannelStore.channels.length, 0)
        compare(OrderChannelStore.defaultChannel, "")
    }

    // ── setDefault / setLastUsed ─────────────────────────────────────────

    function test_setDefault_sets_a_valid_existing_channel() {
        OrderChannelStore.addChannel("WhatsApp")
        OrderChannelStore.addChannel("Instagram")

        OrderChannelStore.setDefault("Instagram")

        compare(OrderChannelStore.defaultChannel, "Instagram")
        compare(OrderChannelStore.lastUsed, "Instagram")
    }

    function test_setDefault_rejects_a_name_not_in_the_list() {
        OrderChannelStore.addChannel("WhatsApp")
        OrderChannelStore.setDefault("WhatsApp")

        OrderChannelStore.setDefault("NotInList")

        compare(OrderChannelStore.defaultChannel, "WhatsApp")
    }

    function test_setDefault_rejects_falsy_name() {
        OrderChannelStore.addChannel("WhatsApp")
        OrderChannelStore.setDefault("WhatsApp")

        OrderChannelStore.setDefault(null)
        OrderChannelStore.setDefault("")

        compare(OrderChannelStore.defaultChannel, "WhatsApp")
    }

    function test_setLastUsed_is_an_alias_for_setDefault() {
        OrderChannelStore.addChannel("WhatsApp")
        OrderChannelStore.addChannel("Instagram")

        OrderChannelStore.setLastUsed("Instagram")

        compare(OrderChannelStore.defaultChannel, "Instagram")
    }

    // ── indexOfDefault ───────────────────────────────────────────────────

    function test_indexOfDefault_returns_the_matching_index() {
        OrderChannelStore.channels = ["Online", "In-store", "Direct"]
        OrderChannelStore.defaultChannel = "In-store"

        compare(OrderChannelStore.indexOfDefault(), 1)
    }

    function test_indexOfDefault_returns_zero_when_default_matches_nothing() {
        OrderChannelStore.channels = ["Online"]
        OrderChannelStore.defaultChannel = "NotInList"

        compare(OrderChannelStore.indexOfDefault(), 0)
    }

    // ── syncFromFirebase ─────────────────────────────────────────────────

    function test_syncFromFirebase_dispatches_without_throwing() {
        OrderChannelStore.syncFromFirebase()
        verify(true)
    }
}
