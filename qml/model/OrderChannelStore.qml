pragma Singleton
import QtQuick
import QtCore

// Configurable list of order channels (Online / In-store / Direct …).
// Persisted device-locally via QSettings — same shape as CategoryStore.
// Used by NewOrderDialog / OrderDetailDialog as a picker model and by
// SalesPage's filter chips. The user can add or remove channels through
// ManageOrderChannelsDialog.
QtObject {
    id: root

    readonly property var defaults: [
        qsTr("Online"), qsTr("In-store"), qsTr("Direct")
    ]

    property var channels: defaults.slice()
    // The most recently used channel — pre-selected on the next NewOrderDialog
    // open so a quick succession of the same channel doesn't require re-pick.
    property string lastUsed: ""

    property Settings _settings: Settings {
        category: "OrderChannelStore"
        property string channelsJson: ""
        property string lastUsed: ""
    }

    Component.onCompleted: _load()

    function _load() {
        if (_settings.channelsJson && _settings.channelsJson.length > 2) {
            try {
                var arr = JSON.parse(_settings.channelsJson)
                if (Array.isArray(arr) && arr.length > 0) channels = arr
            } catch (e) {
                channels = defaults.slice()
            }
        }
        lastUsed = _settings.lastUsed || (channels.length > 0 ? channels[0] : "")
    }

    function _save() {
        _settings.channelsJson = JSON.stringify(channels)
        _settings.lastUsed = lastUsed
    }

    function addChannel(name) {
        if (!name) return false
        var trimmed = String(name).trim()
        if (trimmed.length === 0) return false
        for (var i = 0; i < channels.length; ++i)
            if (channels[i].toLowerCase() === trimmed.toLowerCase()) return false
        var arr = channels.slice()
        arr.push(trimmed)
        channels = arr
        _save()
        return true
    }

    function removeChannel(name) {
        var arr = []
        for (var i = 0; i < channels.length; ++i)
            if (channels[i] !== name) arr.push(channels[i])
        channels = arr
        if (lastUsed === name)
            lastUsed = arr.length > 0 ? arr[0] : ""
        _save()
    }

    function setLastUsed(name) {
        if (!name) return
        lastUsed = name
        _save()
    }

    function indexOfDefault() {
        for (var i = 0; i < channels.length; ++i)
            if (channels[i] === lastUsed) return i
        return 0
    }
}
