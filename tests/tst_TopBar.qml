import QtQuick
import QtTest
import "../qml/desktop"

TestCase {
    id: testCase
    name: "TopBar"

    TopBar {
        id: topBar
        width: 700
        workspaceName: "Riverside store"
        userName: "Taher"
        userRole: "owner"
    }

    SignalSpy {
        id: searchSpy
        target: topBar
        signalName: "searchRequested"
    }

    function init() {
        searchSpy.clear()
    }

    function test_properties_are_exposed_as_set() {
        compare(topBar.workspaceName, "Riverside store")
        compare(topBar.userName, "Taher")
        compare(topBar.userRole, "owner")
    }

    function test_search_field_exists() {
        var field = findChild(topBar, "topBarSearchField")
        verify(field !== null)
    }

    function test_accepting_search_emits_searchRequested() {
        var field = findChild(topBar, "topBarSearchField")
        field.text = "priya"
        field.accepted()
        compare(searchSpy.count, 1)
        compare(searchSpy.signalArguments[0][0], "priya")
    }
}
