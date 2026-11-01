.pragma library

// What the app does with the signed-in user's OWN member doc (tenants/{t}/members/{uid}) at profile
// load, and what the access-blocked screen says. Design (S2f-3):
// docs/superpowers/specs/2026-10-28-s2f3-access-wording-design.md
//
// Pure: no QML, no stores, never throws. The member doc is the only authority for tenant access and
// role; the users/{uid} doc is a self-writable pointer and is never used for the role (S2f-1 / S2f-2).
// "Active with a valid role" is the same definition the gateway (deriveContext) and the rules
// (isMember) use. Adding a role means editing VALID_ROLES, functions/index.js VALID_ROLES and the
// rules' roleIsValid together.

var VALID_ROLES = ["owner", "admin", "manager", "staff"]

var STATE_OK = "ok"
var STATE_REMOVED = "removed"
var STATE_SUSPENDED = "suspended"
var STATE_ROLE = "role"
var STATE_UNVERIFIED = "unverified"
// Never produced by classify(): a SILENT re-check of an open session found the account now points at another
// workspace (L3 slice A, PR #180 decision Q2). The screen asks for one tap before the app reloads, so no form
// that was opened for the old workspace can be saved after the stores switched to the new one.
var STATE_MOVED = "moved"

var MAX_NAME = 60
var FALLBACK_NAME = "this shop"
var KEPT = "Changes that were not sent yet stay on this phone until you sign out."

function isValidRole(role) {
    return VALID_ROLES.indexOf(role) >= 0   // strict equality: a non-string never matches
}

function isBlockedState(state) {
    return state === STATE_REMOVED || state === STATE_SUSPENDED
        || state === STATE_ROLE || state === STATE_UNVERIFIED || state === STATE_MOVED
}

// What the owner sees for each role id (PR #180 decision Q4). A value outside the four is never echoed raw
// into a sentence: it reads "a new role", so a corrupted or future role cannot put odd text in a toast.
var ROLE_LABELS = { owner: "Owner", admin: "Admin", manager: "Manager", staff: "Staff" }

function roleLabel(role) {
    return isValidRole(role) ? ROLE_LABELS[role] : "a new role"
}

// ok / status: what FirebaseService.get reports (ok flag, HTTP status). doc: the decoded member doc.
// Returns { state } or, for state "ok", { state, role }.
//   removed    HTTP 404 on the own doc: the member doc does not exist (the rules allow this read, so
//              a missing doc answers 404, not 403)
//   suspended  the doc exists but status is not exactly "active" (missing, empty, odd case: fail closed)
//   role       status is active but the role is not one of VALID_ROLES (fail closed, no default)
//   unverified the answer could not be read (network, 401/403/5xx, empty or non-object body)
function classify(ok, status, doc) {
    try {
        if (status === 404) return { state: STATE_REMOVED }
        if (ok !== true) return { state: STATE_UNVERIFIED }
        if (doc === null || typeof doc !== "object" || Array.isArray(doc)) return { state: STATE_UNVERIFIED }
        if (doc.status !== "active") return { state: STATE_SUSPENDED }
        if (!isValidRole(doc.role)) return { state: STATE_ROLE }
        return { state: STATE_OK, role: doc.role }
    } catch (e) {
        return { state: STATE_UNVERIFIED }
    }
}

// What to do with a classification. heldRole = the role this device already verified for the SAME
// tenant earlier (AuthStore.role when AuthStore.tenantId matches), or "" when there is none.
//   { action: "enter", role, verified }   open the app with `role`; verified=false means the check
//                                          could not run and the held role is reused (the server and
//                                          the rules still decide every request)
//   { action: "block", reason }           show the access-blocked screen
// A failed check never locks out a user who was verified before (flaky networks must not block an
// active member); with no held role there is nothing safe to show, so it blocks with "unverified".
// prevBlock = the reason the blocked screen is showing right now ("" when it is not). A failed check
// (a "Try again" that hit a network error) keeps that block as it is: the held role is the one from
// BEFORE the block, so reusing it would let a member just shown "suspended" back in on a flaky network.
// Only a conclusive answer (ok, removed, suspended, role) changes the screen.
function outcome(cls, heldRole, prevBlock) {
    var state = (cls && typeof cls === "object") ? cls.state : ""
    if (state === STATE_OK && isValidRole(cls.role)) return { action: "enter", role: cls.role, verified: true }
    if (state === STATE_REMOVED || state === STATE_SUSPENDED || state === STATE_ROLE)
        return { action: "block", reason: state }
    if (isBlockedState(prevBlock)) return { action: "block", reason: prevBlock }
    if (isValidRole(heldRole)) return { action: "enter", role: heldRole, verified: false }
    return { action: "block", reason: STATE_UNVERIFIED }
}

// The shop name is typed by an owner: single line, no control characters, capped, never empty.
function _shopName(name) {
    if (typeof name !== "string") return FALLBACK_NAME
    var s = name.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim()
    if (s.length === 0) return FALLBACK_NAME
    return s.length > MAX_NAME ? s.slice(0, MAX_NAME - 1).trim() + "\u2026" : s
}

function _hasName(name) {
    return typeof name === "string" && name.replace(/[\u0000-\u001f\u007f\s]+/g, "").length > 0
}

// { title, body } for a blocked state; both "" for any other value, so a caller can bind without a check.
function copy(state, shopName) {
    var shop = _shopName(shopName)
    switch (state) {
    case STATE_REMOVED:
        return { title: "Your access was removed",
                 body: "You are no longer a member of " + shop + ". " + KEPT
                       + " Ask the shop owner to add you again." }
    case STATE_SUSPENDED:
        return { title: "Your access is suspended",
                 body: "Your access to " + shop + " is suspended or inactive. You cannot see or change shop data until the shop owner or an admin restores it. "
                       + KEPT }
    case STATE_ROLE:
        return { title: "Your role is not valid",
                 body: "Your account in " + shop + " has a role this app does not recognise, so access is blocked. Ask the shop owner or an admin to fix your role." }
    case STATE_MOVED:
        return { title: "Your workspace changed",
                 body: (_hasName(shopName)
                        ? "Your account now uses " + shop + ". "
                        : "Your account now uses a different shop. ")
                       + "Tap Continue to reload the app with it. Anything open for the old shop was closed so it cannot be saved into the new one." }
    case STATE_UNVERIFIED:
        return { title: "Could not check your access",
                 body: "The app could not confirm your access to " + shop + ". Check your internet connection and try again." }
    }
    return { title: "", body: "" }
}
