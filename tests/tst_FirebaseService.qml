import QtQuick
import QtTest
import "../qml/model"

// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local
// `qmltestrunner` pass before merge (same status as tst_Gateway.qml,
// tst_EnvConfig.qml).
TestCase {
    name: "FirebaseService"

    function cleanup() {
        FirebaseService.emulatorHost = "" // never leak an override into the next test file
    }

    function test_databaseUrl_defaults_to_real_firestore() {
        compare(FirebaseService.emulatorHost, "")
        verify(FirebaseService.databaseUrl.indexOf("https://firestore.googleapis.com/v1/projects/") === 0,
               "databaseUrl should default to real Firestore when emulatorHost is unset")
    }

    function test_emulatorHost_override_redirects_databaseUrl() {
        FirebaseService.emulatorHost = "http://127.0.0.1:8080"
        var expected = "http://127.0.0.1:8080/v1/projects/" + FirebaseService.projectId
                        + "/databases/" + FirebaseService.databaseId + "/documents"
        compare(FirebaseService.databaseUrl, expected)
    }

    function test_emulatorHost_reset_restores_real_firestore() {
        FirebaseService.emulatorHost = "http://127.0.0.1:8080"
        FirebaseService.emulatorHost = ""
        verify(FirebaseService.databaseUrl.indexOf("https://firestore.googleapis.com/v1/projects/") === 0)
    }
}
