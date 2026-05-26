pragma Singleton
import QtQuick

QtObject {
    id: root
    signal showRequested(string text)
    function show(msg) { showRequested(msg || "") }
}
