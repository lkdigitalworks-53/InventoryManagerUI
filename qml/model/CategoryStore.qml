pragma Singleton
import QtQuick
import QtCore

QtObject {
    id: root

    readonly property var defaults: [
        "Electronics", "Accessories", "Office", "Furniture", "Clothes", "Other"
    ]

    property var categories: defaults.slice()
    property string lastUsed: ""

    property Settings _settings: Settings {
        category: "CategoryStore"
        property string categoriesJson: ""
        property string lastUsed: ""
    }

    Component.onCompleted: _load()

    function _load() {
        if (_settings.categoriesJson && _settings.categoriesJson.length > 2) {
            try {
                var arr = JSON.parse(_settings.categoriesJson)
                if (Array.isArray(arr) && arr.length > 0) {
                    categories = arr
                }
            } catch (e) {
                categories = defaults.slice()
            }
        }
        lastUsed = _settings.lastUsed || (categories.length > 0 ? categories[0] : "")
    }

    function _save() {
        _settings.categoriesJson = JSON.stringify(categories)
        _settings.lastUsed = lastUsed
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
        _save()
        return true
    }

    function removeCategory(name) {
        var arr = []
        for (var i = 0; i < categories.length; ++i)
            if (categories[i] !== name) arr.push(categories[i])
        categories = arr
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
        for (var i = 0; i < categories.length; ++i)
            if (categories[i] === lastUsed) return i
        return 0
    }
}
