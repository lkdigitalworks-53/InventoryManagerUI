pragma Singleton
import QtQuick
import QtCore

import "../helper/SettingsPath.js" as SettingsPath

// Product categories. Persisted to Firestore (tenant-scoped) AND cached
// device-locally via QSettings. Exposes a single default category that
// pre-selects in the AddProductDialog picker. Edited via ManageCategoriesDialog.
QtObject {
    id: root

    readonly property var defaults: [
        "Electronics", "Accessories", "Office", "Furniture", "Clothes", "Other"
    ]

    property var categories: defaults.slice()
    // Single default category. `lastUsed` kept as a back-compat alias.
    property string defaultCategory: ""
    property string lastUsed: defaultCategory
    property int revision: 0

    property Settings _settings: Settings {
        category: "CategoryStore"
        // See qml/helper/SettingsPath.js (SKILLS Skill 41).
        location: SettingsPath.settingsLocationOverride(
                      Application.organization,
                      StandardPaths.writableLocation(StandardPaths.TempLocation))
        property string categoriesJson: ""
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
        if (_settings.categoriesJson && _settings.categoriesJson.length > 2) {
            try {
                var arr = JSON.parse(_settings.categoriesJson)
                if (Array.isArray(arr) && arr.length > 0) categories = arr
            } catch (e) {
                categories = defaults.slice()
            }
        }
        defaultCategory = _settings.lastUsed || (categories.length > 0 ? categories[0] : "")
        lastUsed = defaultCategory
    }

    function _fetchFromFirebase() {
        FirebaseService.get("config/categories", function(ok, data) {
            if (!ok || !data) return
            if (Array.isArray(data.categories) && data.categories.length > 0)
                categories = data.categories
            var def = data.defaultCategory || ""
            defaultCategory = (def && categories.indexOf(def) >= 0)
                    ? def : (categories.length > 0 ? categories[0] : "")
            lastUsed = defaultCategory
            revision++
            _saveLocal()
        })
    }

    function syncFromFirebase() { _fetchFromFirebase() }

    function _saveLocal() {
        _settings.categoriesJson = JSON.stringify(categories)
        _settings.lastUsed = defaultCategory
    }

    function _pushToFirebase() {
        FirebaseService.put("config/categories",
                            { categories: categories, defaultCategory: defaultCategory },
                            function(ok) {
            if (!ok) console.warn("[CategoryStore] Firestore write failed",
                                  FirebaseService.lastStatusCode, FirebaseService.lastError)
        })
    }

    function _commit() {
        lastUsed = defaultCategory
        revision++
        _saveLocal()
        _pushToFirebase()
    }

    function addCategory(name) {
        if (!name) return false
        var trimmed = String(name).trim()
        if (trimmed.length === 0) return false
        for (var i = 0; i < categories.length; ++i)
            if (categories[i].toLowerCase() === trimmed.toLowerCase()) return false
        var arr = categories.slice()
        arr.push(trimmed)
        categories = arr
        if (!defaultCategory || categories.indexOf(defaultCategory) < 0)
            defaultCategory = trimmed
        _commit()
        return true
    }

    function removeCategory(name) {
        var arr = []
        for (var i = 0; i < categories.length; ++i)
            if (categories[i] !== name) arr.push(categories[i])
        categories = arr
        if (defaultCategory === name)
            defaultCategory = arr.length > 0 ? arr[0] : ""
        _commit()
    }

    function setDefault(name) {
        if (!name || categories.indexOf(name) < 0) return
        defaultCategory = name
        _commit()
    }

    function setLastUsed(name) { setDefault(name) }

    function indexOfDefault() {
        for (var i = 0; i < categories.length; ++i)
            if (categories[i] === defaultCategory) return i
        return 0
    }
}
