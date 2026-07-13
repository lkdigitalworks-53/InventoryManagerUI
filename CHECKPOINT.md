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

## Open decisions (asked, awaiting answers)
- Q1: Has Blaze actually been turned on + anything deployed yet, or is that still fully pending?
  (Shapes whether this session's output is "get you deploy-ready" vs. "post-deploy verification.")

## Next steps
- Get Taher's answer to Q1 (and follow-ups on scope: test coverage for `provisionMember`, Auth
  cleanup-on-removal, whether to touch `Gateway.mode`/cutover — explicitly not by default).
- Propose 2-3 approaches once scope is clear, then write the design spec per the brainstorming
  skill (`docs/superpowers/specs/2026-07-14-staff-login-provisioning-design.md`).

## Not yet done
- No code changes yet (hard gate: brainstorming skill blocks implementation until design is
  approved).
- Nothing pushed. Working tree has: this checkpoint file (new) + the archived old checkpoint
  (renamed/moved). Both are local commits only — see note to Taher about session-reset risk.
