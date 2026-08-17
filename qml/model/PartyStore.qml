pragma Singleton
import QtQuick
import QtCore

import "../helper/SettingsPath.js" as SettingsPath

// Device-local list of parties (dealers / wholesalers / suppliers) that the
// user buys stock from. Persisted via QSettings — the same shape as
// CategoryStore — so it survives relaunches without needing a Firestore
// round-trip. Parties are written onto each purchase/created transaction
// and used by the Analysis page for per-party breakdowns.
QtObject {
    id: root

    readonly property var defaults: []   // start empty — user adds their own
    property var parties: defaults.slice()
    property string lastUsed: ""

    property Settings _settings: Settings {
        category: "PartyStore"
        // See qml/helper/SettingsPath.js (SKILLS Skill 41).
        fileName: SettingsPath.settingsFileNameOverride(
                      Application.organization,
                      StandardPaths.writableLocation(StandardPaths.TempLocation))
        property string partiesJson: ""
        property string lastUsed: ""
    }

    Component.onCompleted: _load()

    function _load() {
        if (_settings.partiesJson && _settings.partiesJson.length > 2) {
            try {
                var arr = JSON.parse(_settings.partiesJson)
                if (Array.isArray(arr)) parties = arr
            } catch (e) {
                parties = defaults.slice()
            }
        }
        lastUsed = _settings.lastUsed || (parties.length > 0 ? parties[0] : "")
    }

    function _save() {
        _settings.partiesJson = JSON.stringify(parties)
        _settings.lastUsed = lastUsed
    }

    function addParty(name) {
        if (!name) return false
        var trimmed = String(name).trim()
        if (trimmed.length === 0) return false
        for (var i = 0; i < parties.length; ++i)
            if (parties[i].toLowerCase() === trimmed.toLowerCase()) return false
        var arr = parties.slice()
        arr.push(trimmed)
        parties = arr
        _save()
        return true
    }

    function removeParty(name) {
        var arr = []
        for (var i = 0; i < parties.length; ++i)
            if (parties[i] !== name) arr.push(parties[i])
        parties = arr
        if (lastUsed === name)
            lastUsed = arr.length > 0 ? arr[0] : ""
        _save()
    }

    function setLastUsed(name) {
        if (!name) return
        lastUsed = name
        _save()
    }

    // Drop the QSettings-backed list. Called on sign-out so the next
    // account doesn't see the previous tenant's party names — historically
    // the migration promoted these into Supplier records, leaking data
    // across tenants.
    function clear() {
        parties = defaults.slice()
        lastUsed = ""
        _settings.partiesJson = ""
        _settings.lastUsed = ""
    }

    function indexOfDefault() {
        for (var i = 0; i < parties.length; ++i)
            if (parties[i] === lastUsed) return i
        return 0
    }
}
