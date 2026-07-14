# Staff/Manager/Admin Login — Go-Live Prep (Blaze plan now available)

**Date:** 2026-07-14
**Branch:** `feature/staff-login-provisioning`
**Author:** Claude (Anthropic), with Taher
**Status:** Design approved by Taher — pending write-up review before an implementation plan

## Context

Owners can already add staff/manager/admin records via `AddStaffDialog.qml`, and the client
already has a full, role-agnostic login path (`AuthService._loadUserProfile()` routes any
signed-in user into their tenant by reading `users/{uid}`, no owner-only gating in
`LoginPage.qml`). The server side (`functions/index.js: exports.provisionMember`) already
creates the real Firebase Auth account and writes `users/{uid}` + `tenants/{tenantId}/
members/{uid}` under a server-enforced role-assignment matrix.

None of it is live. Deploying any Cloud Function requires the Blaze plan (Cloud Build
dependency), which the project didn't have until now — see `AGENTS.md`, "P0 implementation
status". `qml/model/Gateway.qml:34` hardcodes `provisioningAvailable: false` specifically
because of this. With Blaze now enabled, deployment is unblocked, but deployment itself
(`firebase deploy`) is an action only Taher can take — this working environment has no network
route to any Firebase/GCP domain and no project credentials.

`provisioningAvailable` is independent of `Gateway.mode` (`Gateway.qml:24`, still `"direct"`).
`mode` gates the much larger, irreversible P0 ledger cutover for inventory/stock/orders
(`runCutover`). This design does not touch `mode` or `runCutover` in any way.

## Goals

- Make the existing `provisionMember` Cloud Function safe to deploy and correct in the cases
  that matter once accounts are real and persistent.
- Fix a data-integrity bug in the existing staff-removal cleanup path that the locked
  Firestore rules (required for this feature) would otherwise silently break.
- Leave the actual go-live (deploy + flip `provisioningAvailable`) as a distinct, later,
  explicitly-verified step — not part of this branch.

## Non-goals

- Flipping `Gateway.provisioningAvailable` to `true`. Separate follow-up session, after Taher
  deploys and manually verifies (see Rollout below).
- Any change to `Gateway.mode` or `runCutover` / the P0 ledger cutover.
- Deleting the actual Firebase Auth user record (`admin.auth().deleteUser()`) on staff removal.
  Tracked as a P5 compliance item (PII erasure & retention) in `AGENTS.md`'s roadmap; out of
  scope here.
- Building or running the app, or executing `firebase deploy` — both are Taher's actions.
- The multi-workspace picker UI (`docs/superpowers/plans/2026-06-18-future-improvements-
  multiworkspace-staffstatus-stocknotes-imageviewer.md`, Feature 3). This design makes the
  underlying data safe for that future feature; it does not build it.

## Design

### 1. Extract `provisionMember` into `functions/lib/provisionMember.js`

Currently inline in `functions/index.js:265-390` (plus helpers `canAssignRole` at
`:235-241` and `findOrCreateAuthUser` at `:245-263`). Extract to a pure, DI-style module
matching the existing pattern (`functions/lib/gatewayLogic.js`, `cutoverLogic.js`): no direct
Firebase SDK dependency of its own, `authAdmin`/`db`/`serverTimestamp`-equivalents passed in by
the `index.js` wrapper, so it's unit-testable with plain fakes and no emulator. Behavior-
preserving refactor except for the fix below.

### 2. Password-reset-on-reattach fix

**Bug:** `findOrCreateAuthUser` (`index.js:245-263`) only sets a password on `admin.auth()
.createUser()`. When it instead finds an existing account (`getUserByEmail` succeeds), it
returns immediately — any password the owner just typed into the Add Staff form is silently
ignored. Concretely: remove a staff member, later re-add them with the same email and a new
password, and the *old* password (which they still know) is what actually works.

**Fix, and a refinement made during design:** only reset the password when the account is
genuinely orphaned — i.e. `users/{uid}` doesn't exist. Read that once (`db.doc("users/"+uid)
.get()`) *before* the existing transaction, not inside it — side-effecting Auth API calls
shouldn't live inside a Firestore transaction body, which may retry. If the account is an
active member of a *different* tenant (`users/{uid}` exists), leave the password untouched.
Without this refinement, one tenant owner could silently reset another tenant's already-active
staff member's password just by adding that person's email to their own workspace.

```
existingUserDoc = await db.doc("users/" + uid).get()   // read-only, outside any transaction
if (!existingUserDoc.exists && password) {
    await authAdmin.updateUser(uid, { password, displayName: displayName || undefined })
}
// ...then the existing transaction proceeds unchanged
```

### 3. New `deprovisionMember` Cloud Function

**Bug found during design, not previously tracked:** the locked `firestore.rules` (required
for this feature — see `FIRESTORE_RULES.md`) have, for `users/{uid}` (`firestore.rules:51-55`):
`allow update: if request.auth.uid == uid` (self only) and `allow delete: if false` (always,
no exceptions). `AuthService.cleanupStaffAuthDocs()` (`AuthService.qml:911-920`) currently
tries to delete `users/{uid}` directly from the client on staff removal — a call made by the
*owner*, not the target user. That call will start failing silently (`console.warn` only, no
surfaced error) the moment the locked rules deploy, which this feature requires regardless of
anything else in this design.

Separately: the existing cleanup logic deletes the entire `users/{uid}` doc, rather than
pruning just the tenant being left out of its `tenants[]` array. That's incorrect for anyone
who is a member of more than one tenant at once — a real, designed-for state (the `tenants[]`
array exists specifically for it; see the multi-workspace plan referenced above). Not urgent
today only because no staff member currently has a linked `appUid` — provisioning has never
succeeded in production — so the bug is dormant. It must be fixed before
`provisioningAvailable` is ever flipped to `true`, which is exactly why it's in this branch.

**Fix:** `functions/lib/deprovisionMember.js` + `exports.deprovisionMember` in `index.js`,
mirroring `provisionMember`'s authorization pattern: verify the caller's token, derive their
role in the tenant, require `isOwnerOrAdmin`, and require the target's current role isn't
`owner` and the target isn't the caller — mirroring the existing `members/{uid}` delete rule's
own conditions (`firestore.rules:96-98`) exactly, so client rule and server logic stay in
sync the same way `canAssignRole` already mirrors the client's `_canAssignRole`. The target's
current role is read server-side from `tenants/{tenantId}/members/{targetUid}` — never trusted
from client input — the same principle `provisionMember` already applies when deriving the
*caller's* role via `deriveContext`.

On `users/{targetUid}`:
- Remove the departed `tenantId` from `tenants[]`.
- If the scalar `tenantId`/`tenantName`/`role` fields currently point at the departed tenant,
  clear them (empty string / null) — otherwise leave them alone.
- **The doc is never deleted, even if `tenants[]` becomes empty** — per Taher's explicit
  instruction. It also still holds profile fields (phone, address, photo) that belong to the
  person, not to any one tenant.

`tenants/{tenantId}/members/{uid}` deletion is unchanged — the client already does this
directly and the rules already permit it correctly for owner/admin (`firestore.rules:96-98`).
No reason to move that part server-side.

### 4. Client wiring

`AuthService.cleanupStaffAuthDocs(uid)`: replace the `users/{uid}` removal with a call to a
new `Gateway.deprovisionMember(uid, tenantId)` (mirroring the existing `Gateway.
provisionMember()` at `Gateway.qml:300-368`), gated behind the same `Gateway.
provisioningAvailable` flag — skip the call entirely while it's `false`, matching the
graceful-fallback pattern the provisioning side already uses (`Gateway.qml:331`). **Ordering
matters:** call `deprovisionMember` *before* the existing `members/{uid}` delete, not after —
the function reads the target's current role from `members/{uid}` for its authorization check,
so that doc has to still exist when it runs. The `members/{uid}` delete itself is otherwise
unchanged.

### 5. Tests (`node --test`, matching `functions/package.json`'s existing `test` script)

`functions/test/provisionMember.test.js`:
- New-email creates a fresh Auth account with the given password.
- Existing *orphaned* account (`users/{uid}` absent): password is reset to the new value.
- Existing *active-elsewhere* account (`users/{uid}` present, different tenant): password is
  left untouched; new tenant is appended to `tenants[]`; `members/{uid}` created for the new
  tenant.
- Role-assignment matrix: owner can assign admin/manager/staff; admin can assign
  manager/staff but not admin/owner; rejects unknown roles by falling back to `staff`
  (matching current behavior) or explicit rejection where the current code already rejects.
- Missing/malformed input (`no email or uid`, `password too short`, `unauthenticated`).

`functions/test/deprovisionMember.test.js`:
- Pruning one tenant out of a `tenants[]` with several entries: only that tenant removed,
  doc kept, other entries untouched.
- Pruning the last remaining tenant: `tenants[]` ends up empty, **doc is still kept** (not
  deleted), scalar fields cleared only if they matched.
- Scalar `tenantId`/`role`/`tenantName` left alone when they point at a *different* tenant
  than the one being removed.
- Authorization: rejects when caller isn't owner/admin, when target role is `owner`, when
  target is the caller.

I can write and run these myself — no emulator or live project needed, matching how the
existing `gatewayLogic.test.js` / `cutoverLogic.test.js` already work.

### 6. Deployment runbook (new doc, for Taher)

A short doc with the exact `firebase deploy` sequence (functions, then rules) and a manual
post-deploy verification checklist (Firebase console checks; a single test call to
`provisionMember` before touching the app). This is documentation only — I cannot execute any
part of it from this environment.

## Rollout sequence (spans two sessions)

1. **This branch:** the five items above, tests passing, runbook written. `Gateway.
   provisioningAvailable` stays `false`. Commit locally; push only once Taher provides the PAT
   and says go.
2. **Taher, outside any session with Claude:** enables Blaze (done), runs the runbook —
   deploys functions and the locked rules, does the manual verification.
3. **A later, separate session:** flip `Gateway.provisioningAvailable` to `true` (the only
   client change), then an end-to-end manual QA pass — add a staff/manager/admin, log in as
   each, confirm role-scoped access, confirm remove-then-re-add no longer reuses a stale
   password. App build/run still requires Taher's explicit go-ahead, per standing instructions.

## Open follow-ups (not this branch)

- P5: real Firebase Auth account deletion + full PII erasure/retention policy on staff
  removal.
- Feature 3 (multi-workspace picker): this design keeps the underlying `tenants[]`/scalar
  data correct for it, but doesn't build the picker UI or the login-time `workspaceSelection
  Required()` flow.
- A remote-config-style kill switch for `provisioningAvailable`, so it could be disabled
  post-launch without a rebuild if something goes wrong. Named during discussion as a
  reasonable future add-on given this creates real, persistent user accounts; not built here.
