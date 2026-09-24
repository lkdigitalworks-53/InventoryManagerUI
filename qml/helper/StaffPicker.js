.pragma library

// Pure builder for the "Sold by" picker in the order detail dialog. No QML /
// singleton deps so it is unit-testable (tests/tst_StaffPicker.qml).
//
// Only ACTIVE staff are offered for (re)assignment, but the order's CURRENT
// attribution must always stay selectable: if `preferredId` isn't among the
// active staff (the member was deleted, or is on leave / suspended), a row
// for it is appended and selected. Without that row the combo falls back to
// "none" and saving the order silently wipes who sold it.
//
//   roster      [{ staffId, name, status }]
//   preferredId the order's current staffId ("" = unattributed)
//   opts        { noneLabel, unnamedLabel, removedLabel,
//                 labelFor(staffId) -> string }   // labelFor may return ""
// Returns { ids, labels, index } — parallel arrays plus the row to select.
function build(roster, preferredId, opts) {
    var o = opts || {}
    var ids = [""]
    var labels = [o.noneLabel || ""]
    var src = roster || []
    for (var i = 0; i < src.length; ++i) {
        var s = src[i]
        if (s.status && s.status !== "active") continue
        ids.push(s.staffId || s.id || "")
        labels.push(s.name || o.unnamedLabel || "")
    }
    var index = 0
    if (preferredId) {
        index = ids.indexOf(preferredId)
        if (index < 0) {
            var label = (typeof o.labelFor === "function") ? o.labelFor(preferredId) : ""
            ids.push(preferredId)
            labels.push(label || o.removedLabel || "")
            index = ids.length - 1
        }
    }
    return { ids: ids, labels: labels, index: index }
}
