"use strict";

// S2f-7 (2026-10-26): what provisionMember may do when the target already has a member doc.
//
// provisionMember writes with the Admin SDK, so firestore.rules cannot see it. Until this slice it
// merged into whatever member doc existed: an admin could demote the owner (or a peer admin) to
// staff, flip a suspended member back to active, and rewrite joinedAt / invitedBy. The rules and the
// client both say an owner's membership cannot be changed and an admin cannot manage a peer admin
// (D-1); this endpoint bypassed both.
//
// Decision: provisionMember only ADDS. Changing the role or status of an EXISTING member is the
// rules path (canManageTarget, S2f-2 + D-1) and nothing else, so the hierarchy is defined once and
// enforced where the rules can see it. One harmless case stays: an exact repeat of an earlier
// successful call (same role, member already active) is confirmed without a write, so a client retry
// after a lost response still succeeds and joinedAt / invitedBy are not overwritten.
//
// Pure: the transaction in index.js reads the member doc and acts on the verdict.

// existing: the target's member doc data, or null when no such doc exists.
// requestedRole: the role after the endpoint's normalisation (admin | manager | staff).
// Returns { action: "create" } | { action: "unchanged" } | { action: "refuse", reason }.
// `reason` is for the server log only; the HTTP answer is always `member-exists`.
function decideProvision(existing, requestedRole) {
    if (existing === null) return { action: "create" };
    // Fail closed on anything that is not a plain object (a caller bug must not turn into a write).
    if (!existing || typeof existing !== "object" || Array.isArray(existing))
        return { action: "refuse", reason: "unreadable" };
    if (existing.role === "owner") return { action: "refuse", reason: "owner" };
    if (existing.status !== "active") return { action: "refuse", reason: "not-active" };
    if (existing.role !== requestedRole) return { action: "refuse", reason: "role-differs" };
    return { action: "unchanged" };
}

module.exports = { decideProvision };
