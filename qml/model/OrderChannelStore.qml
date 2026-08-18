pragma Singleton
import QtQuick
import QtCore

import "../helper/SettingsPath.js" as SettingsPath

// Configurable list of order channels (Online / In-store / Direct …).
// Persisted to Firestore (tenant-scoped) AND cached device-locally via
// QSettings. Used by NewOrderDialog / OrderDetailDialog as a picker model and
// by SalesPage's filter chips. The user can add/remove channels and pin ONE
// default through ManageOrderChannelsDialog; the default pre-fills the picker.
QtObject {
    id: root

    readonly property var defaults: [
        qsTr("Online"), qsTr("In-store"), qsTr("Direct")
    ]

    property var channels: defaults.slice()
    // The single default channel — pre-selected on every NewOrderDialog open so
    // the user doesn't re-pick. Exactly one default at a time (set via
    // setDefault). `lastUsed` kept as an alias for back-compat with callers.
    property string defaultChannel: ""
    // revision bump lets QML bindings (the picker model) react to add/remove/
    // default changes WITHOUT reopening the dialog — fixes the stale dropdown.
    property int revision: 0

    // Back-compat alias: older call sites referenced `lastUsed`.
    property string lastUsed: defaultChannel

    property Settings _settings: Settings {
        category: "OrderChannelStore"
        // See qml/helper/SettingsPath.js (SKILLS Skill 41).
        location: SettingsPath.settingsLocationOverride(
                      Application.organization,
                      StandardPaths.writableLocation(StandardPaths.TempLocation))
        property string channelsJson: ""
        property string lastUsed: ""
    }

    // _loadLocal() is device-local (QSettings), no tenant dependency, always
    // safe. _fetchFromFirebase() was unconditional -- fired on every creation
    // regardless of whether AuthStore.tenantId was known yet, hitting
    // Firestore with an unscoped path on a cold start. Every other Firestore-
    // backed store in this app guards this the same way -- see SKILLS Skill 39.
    Component.onCompleted: {
        _loadLocal()
        if (AuthStore.tenantId.length > 0)
            _fetchFromFirebase()
    }

    function _loadLocal() {
        if (_settings.channelsJson && _settings.channelsJson.length > 2) {
            try {
                var arr = JSON.parse(_settings.channelsJson)
                if (Array.isArray(arr) && arr.length > 0) channels = arr
            } catch (e) {
                channels = defaults.slice()
            }
        }
        defaultChannel = _settings.lastUsed || (channels.length > 0 ? channels[0] : "")
        lastUsed = defaultChannel
    }

    // Firestore is the source of truth across devices/reinstalls. The config is
    // a single doc { channels: [...], defaultChannel: "..." } under "config".
    function _fetchFromFirebase() {
        FirebaseService.get("config/orderChannels", function(ok, data) {
            if (!ok || !data) return   // keep local defaults on miss/first run
            if (Array.isArray(data.channels) && data.channels.length > 0)
                channels = data.channels
            var def = data.defaultChannel || ""
            // Validate the stored default still exists in the list.
            defaultChannel = (def && channels.indexOf(def) >= 0)
                    ? def : (channels.length > 0 ? channels[0] : "")
            lastUsed = defaultChannel
            revision++
            _saveLocal()
        })
    }

    function syncFromFirebase() { _fetchFromFirebase() }

    function _saveLocal() {
        _settings.channelsJson = JSON.stringify(channels)
        _settings.lastUsed = defaultChannel
    }

    function _pushToFirebase() {
        FirebaseService.put("config/orderChannels",
                            { channels: channels, defaultChannel: defaultChannel },
                            function(ok) {
            if (!ok) console.warn("[OrderChannelStore] Firestore write failed",
                                  FirebaseService.lastStatusCode, FirebaseService.lastError)
        })
    }

    // Persist everywhere + notify bindings.
    function _commit() {
        lastUsed = defaultChannel
        revision++
        _saveLocal()
        _pushToFirebase()
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
        // First channel ever becomes the default automatically.
        if (!defaultChannel || channels.indexOf(defaultChannel) < 0)
            defaultChannel = trimmed
        _commit()
        return true
    }

    function removeChannel(name) {
        var arr = []
        for (var i = 0; i < channels.length; ++i)
            if (channels[i] !== name) arr.push(channels[i])
        channels = arr
        // Removing the default reassigns it to the first remaining channel so
        // there's always exactly one valid default.
        if (defaultChannel === name)
            defaultChannel = arr.length > 0 ? arr[0] : ""
        _commit()
    }

    // Pin a single channel as the default. Enforces "only one default".
    function setDefault(name) {
        if (!name || channels.indexOf(name) < 0) return
        defaultChannel = name
        _commit()
    }

    // Back-compat alias for the old API name used by some callers.
    function setLastUsed(name) { setDefault(name) }

    function indexOfDefault() {
        for (var i = 0; i < channels.length; ++i)
            if (channels[i] === defaultChannel) return i
        return 0
    }
}
