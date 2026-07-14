# Session Checkpoint — Staff/Manager/Admin Login (Blaze go-live)

**Started:** 2026-07-14
**Branch:** `feature/staff-login-provisioning`
**Status:** Brainstorming phase (superpowers:brainstorming). No feature code written yet — exploring
existing codebase and clarifying scope with Taher.

## Step log

1. Cloned `InventoryManagerUI` fresh (public, no auth needed).
2. Archived stale root `CHECKPOINT.md` (2026-07-11 "by-name chart" session — that feature is
   already merged into `main` via PR #31, and PR #32 (P0 gateway) merged since; the file was never
   archived) to
   `docs/superpowers/specs/2026-07-11-analysis-by-name-chart-all-views-CHECKPOINT.md`.
3. Created branch `feature/staff-login-provisioning` off `main`.
4. Explored existing staff/auth/login architecture. **Key finding: this is almost entirely already
   built.** Summary:
   - `AuthService.provisionStaffCredentials()` (client) → `Gateway.provisionMember()` →
     `functions/index.js exports.provisionMember` (Admin SDK Cloud Function, `asia-south1`).
     Creates the real Firebase Auth account (or attaches an existing one), then writes
     `users/{uid}` (tenant/role pointer) and `tenants/{tenantId}/members/{uid}` (RBAC record) in
     one Firestore transaction. Role assignment matrix (`canAssignRole`) already enforced
     server-side: owner→admin/manager/staff, admin→manager/staff.
   - `AuthService._loadUserProfile()` (client, used on every sign-in) is already **role-agnostic**:
     it reads `users/{uid}`, pulls `tenantId`/`role`, and routes into that tenant's workspace
     accordingly. `LoginPage.qml` has no owner-only gating. So once a staff/manager account
     exists, signing in with their email+password already lands them in the right workspace with
     the right role — no login-flow code changes appear to be needed.
   - `firestore.rules` (root, deployed-config path per `firebase.json`) already contains the
     "locked" 4-role RBAC rules matching `FIRESTORE_RULES.md`'s canonical version.
   - **The actual gate:** `Gateway.provisioningAvailable` is hardcoded `false` client-side (see
     `qml/model/Gateway.qml` ~L34) specifically because `functions/` has never been deployed —
     Cloud Function deployment (any function, via Cloud Build) requires the Blaze plan, which is
     why this was blocked until now. Confirmed via `AGENTS.md` "P0 implementation status": *"None
     of that has happened yet; treat this whole subsystem as inert until a session explicitly does
     that sequence with real Firebase project access."*
   - `provisioningAvailable` is **independent of** `Gateway.mode` (still `"direct"`, governs the
     much bigger/riskier P0 ledger cutover for inventory/stock/orders). Enabling staff login does
     **not** require flipping `mode` or running `runCutover` — these are separate levers. Flagged
     as an explicit scope boundary to confirm with Taher (don't want to conflate the two).
   - Gaps found: (a) `provisionMember` has **zero automated test coverage** — unlike
     `recordMutation`/`runCutover`/batch, it was never extracted to `functions/lib/` with a Node
     test suite. (b) `AuthService.cleanupStaffAuthDocs()` deletes only the Firestore docs on staff
     removal, not the Firebase Auth account itself — explicit `TODO` in source, tracked as P5 in
     the compliance roadmap. Neither blocks "staff can log in" but both are worth a decision.
   - **Deployment itself (`firebase deploy`) is an action only Taher can take** — this sandbox has
     no network route to any Firebase/GCP domain (confirmed against the allowed-domains list) and
     no project credentials. Same constraint prior sessions hit for the P0 rules/emulator tests.

## Decisions made
- **Deploy status:** Blaze is on; nothing deployed yet (functions or rules).
- **Approach:** A — this branch preps + hardens + writes a deploy runbook; `Gateway.
  provisioningAvailable` stays `false`. Flipping it is a separate, later session, run only
  after Taher deploys and verifies. Not touching `Gateway.mode`/`runCutover` at all.
- **Stale-password bug** (`findOrCreateAuthUser` never updates password when it finds an
  existing Auth account): fix now. Refined during design: only reset the password when
  `users/{uid}` doesn't exist (a truly orphaned identity) — if the account is an active member
  of another tenant, leave their password alone. Otherwise Owner B could silently reset Owner
  A's already-active staff member's password just by adding that email to Owner B's workspace.
  Read `userSnap` once outside the transaction to decide, call `admin.auth().updateUser()` if
  warranted, *then* run the transaction (side-effecting Auth calls don't belong inside a
  Firestore transaction body).
- **New finding, not previously tracked anywhere:** the locked `firestore.rules` have
  `users/{uid}`: `allow delete: if false` (always) and `allow update: if request.auth.uid ==
  uid` (self only). `AuthService.cleanupStaffAuthDocs()` tries to delete `users/{uid}` directly
  from the client — that will start silently failing (only `console.warn`s) the instant the
  locked rules deploy, which this feature requires regardless. Separately, the existing logic
  deletes the whole `users/{uid}` doc rather than pruning just the departed tenant from
  `tenants[]` — wrong for anyone in ≥2 workspaces at once (a real, designed-for state; see
  `docs/superpowers/plans/2026-06-18-...multiworkspace...md` Feature 3). Not urgent today only
  because no staff currently have a linked `appUid` (provisioning has never succeeded), so the
  bug is dormant until `provisioningAvailable` flips — but must be fixed in this branch, before
  that flip ever happens.
- **Fix, scoped:** new `deprovisionMember` Cloud Function (Admin SDK, mirrors `provisionMember`'s
  auth pattern: verify token, `isOwnerOrAdmin`, target role != owner, target != self — mirrors
  the existing `members/{uid}` delete rule's own conditions). Prunes the departed tenant out of
  `users/{uid}`.`tenants[]`, clears scalar `tenantId`/`tenantName`/`role` only if they matched
  the removed tenant. **Taher's explicit instruction: never delete the whole `users/{uid}` doc,
  even if `tenants[]` becomes empty.** `members/{uid}` deletion stays client-side, unchanged —
  rules already permit it correctly, no need to touch it.
- **Auth account (the actual Firebase Auth user record) deletion on removal:** deferred to P5,
  as already tracked on the roadmap. Not part of this branch.

## Next steps
- ✅ Full design presented, Taher approved.
- ✅ Design doc written, self-reviewed, committed, pushed to origin (Taher supplied PAT).
- ✅ Implementation plan written to
  `docs/superpowers/plans/2026-07-14-staff-login-provisioning.md` (7 tasks, TDD steps, full
  code, self-reviewed). No subagent-dispatch tool available in this environment, so execution
  will be inline (superpowers:executing-plans) rather than subagent-driven — noted to Taher.
- **Waiting on Taher's explicit go-ahead before executing any task.** Do not start Task 1 until
  told.
- Everything through the plan doc is committed locally; pushing on this turn per Taher's
  instruction.

## Not yet done
- No code changes yet (hard gate: brainstorming skill blocks implementation until design is
  approved).
- Nothing pushed. Working tree has: this checkpoint file (new) + the archived old checkpoint
  (renamed/moved). Both are local commits only — see note to Taher about session-reset risk.
