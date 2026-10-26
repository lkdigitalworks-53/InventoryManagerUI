.pragma library

// Pure member-management policy. No QML/singleton deps, so it is unit-testable.
// MIRRORS firestore.rules (canAssignRole, canManageTarget) and functions/index.js canAssignRole.
// Change all three together (Skill 129 rule 11). The rules are the boundary; this only decides what
// the UI offers and refuses early with a clear message.

// Which roles an actor may hand out: owner -> admin/manager/staff, admin -> manager/staff, nobody -> owner.
function canAssignRole(actorRole, targetRole) {
    if (actorRole === "owner")
        return targetRole === "admin" || targetRole === "manager" || targetRole === "staff"
    if (actorRole === "admin")
        return targetRole === "manager" || targetRole === "staff"
    return false
}

// Whose member doc an actor may change or remove, by the target's CURRENT role (decision D-1 b):
// owner -> any non-owner, admin -> manager/staff only (never a peer admin, never the owner).
// A role outside the four is refused for everyone (fail closed).
function canManageMember(actorRole, memberRole) {
    if (actorRole === "owner")
        return memberRole === "admin" || memberRole === "manager" || memberRole === "staff"
    if (actorRole === "admin")
        return memberRole === "manager" || memberRole === "staff"
    return false
}
