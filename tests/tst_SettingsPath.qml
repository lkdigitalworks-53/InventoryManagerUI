import QtQuick
import QtTest
import "../qml/helper/SettingsPath.js" as SettingsPath

// NOT RUN IN THIS SANDBOX -- no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local `qmltestrunner`
// pass before merge (same status as tst_EnvConfig.qml).
TestCase {
    name: "SettingsPath"

    function test_real_app_with_org_set_defers_to_default_resolution() {
        compare(SettingsPath.settingsFileNameOverride("LKDigitalWorks", "/tmp"), "",
                "a real app build (org identifier set) must get an untouched \"\" -- " +
                "changing this would relocate where real user session/outbox data lives on-device")
    }

    function test_qmltestrunner_with_empty_org_gets_an_explicit_temp_path() {
        var result = SettingsPath.settingsFileNameOverride("", "/tmp")
        verify(result.length > 0, "must return a real path when the org identifier is unset")
        verify(result.indexOf("/tmp") === 0, "must be rooted at the caller-supplied writable dir")
    }

    function test_undefined_or_null_org_is_treated_the_same_as_empty() {
        verify(SettingsPath.settingsFileNameOverride(undefined, "/tmp").length > 0)
        verify(SettingsPath.settingsFileNameOverride(null, "/tmp").length > 0)
    }

    function test_the_same_shared_filename_is_returned_every_call() {
        // One file, not one per store -- mirrors production, where every
        // Settings block using this pattern already resolves to the same
        // default QSettings file, differentiated only by `category`.
        var a = SettingsPath.settingsFileNameOverride("", "/tmp")
        var b = SettingsPath.settingsFileNameOverride("", "/tmp")
        compare(a, b)
    }
}
