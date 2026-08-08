.pragma library

var STACK_SECTIONS = {
    "dashboard": 0,
    "orders": 1,
    "inventory": 2,
    "analysis": 3
}

var OVERLAY_SECTIONS = {
    "staff": "staffPageOverlay",
    "activity": "activityPageOverlay",
    "settings": "profilePage"
}

function navigationIndexForSection(section) {
    if (Object.prototype.hasOwnProperty.call(STACK_SECTIONS, section))
        return STACK_SECTIONS[section]
    return -1
}

function overlayIdForSection(section) {
    if (Object.prototype.hasOwnProperty.call(OVERLAY_SECTIONS, section))
        return OVERLAY_SECTIONS[section]
    return ""
}
