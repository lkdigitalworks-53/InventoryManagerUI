.pragma library

// Pure staff-scoping helpers. No QML/singleton deps so they're unit-testable.
// StaffStore.findByAppUid and the page-level own-scoping delegate here.

// Resolve a Firebase Auth uid to its staffId via the roster's appUid field.
// Returns "" when roster is empty/null, uid is empty, or no record matches.
function findByAppUid(roster, uid) {
    if (!uid || !roster) return ""
    for (var i = 0; i < roster.length; ++i)
        if (roster[i].appUid === uid) return roster[i].staffId || ""
    return ""
}

// Keep only orders belonging to staffId. Fail-closed: an empty staffId yields
// an empty list (an unlinked staff sees nothing, never everything).
function ownOrders(orders, staffId) {
    if (!orders || !staffId) return []
    var out = []
    for (var i = 0; i < orders.length; ++i)
        if ((orders[i].staffId || "") === staffId) out.push(orders[i])
    return out
}
