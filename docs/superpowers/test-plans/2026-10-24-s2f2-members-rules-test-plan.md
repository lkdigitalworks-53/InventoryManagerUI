# Test plan — S2f-2: `members` rules, active-member status, role assignment

**Branch:** `fix/2026-10-24-s2f2-members-rules`, STACKED on `fix/2026-10-24-s2f1-membership-authority` (PR #159). **Design:** `specs/2026-10-24-s2f-authz-hardening-design.md` (F1, F2, F9, D2, D8).
**Covers:** `firestore.rules` (helpers `isMember`, `isOwner`, `isAdmin`, `memberStatusIsActive`, `canAssignRole`, `isAccessControlCollection`; blocks `members`, wildcard guard) and `test/firestore.rules.test.js` (+31 tests).
**Why:** F1: the wildcard `match /{collection}/{docId}` also matches `members/{uid}`; Firestore ORs matching rules, so any member could rewrite any membership (probe PR #157). F2: `isMember` was `exists()` only, so a suspended member kept direct read/write and a suspended admin kept admin powers. F9 (found while writing the tests): the old create/update rules let an owner mint a second owner and an admin mint admins/owners, which the server (`canAssignRole`) and the client (`_canAssignRole`) both refuse.
**Takes effect on `firebase deploy --only firestore:rules`.** No client or function change. Deploy PR #159 (functions) first.

## 1. Already covered before this change
Rules 52 (ledger, server-only, inventory lock, pending_cleanup pins). **Nothing** covered `users`, `tenants` or `members`.

## 2. Rules tests (CI only, no emulator in the sandbox: the emulator jar host is unreachable)
Predicted Rules **83** (52 + 31). Total predicted: QML 2104 + Functions 811 + Rules 83 + E2E 89 = **3087**.
| Group | Tests | Proves |
|---|---|---|
| F1 | 6 (staff and manager x2, admin, roster read) | no member can promote itself, create, edit or delete a membership; owner doc untouched; roster still readable |
| Assign matrix | 4 | owner assigns admin/manager/staff; nobody assigns owner; unknown role/status, missing status, uid mismatch denied; owner doc immutable; admin limited to manager/staff |
| Delete / leave | 2 | owner/admin remove staff, nobody removes the owner; staff leaves (active or suspended), owner cannot |
| F2 | 14 (4 roles x 2 states + 2 per state + control + outsider) | suspended or status-less member: no read/write of data, tenant doc or roster; locked-out admin/owner keep no power; self-read kept; re-activation works at once |
| Bootstrap | 2 | tenant + own owner membership once; foreign tenant, role admin, suspended, other uid, ownerId mismatch denied |
| Tenants | 1 | members read; only an active owner updates |
| Users | 1 | own doc read/write incl. tenantId/role (PINNED, why the gateway must not trust it); others, delete, anon denied |
| Monkey | 1 | admin/manager/staff x active/suspended/no-status x 2 passes never change the owner doc or the tenant |
Happy path: assign matrix, bootstrap, leave. Negative: F1, F2. Edge: missing status, own-doc read, uid mismatch, role `superuser`. Multi-scenario: F2 roles x states. Monkey: last test.
**Not run here** (CI is the oracle). If CI shows a syntax error in `firestore.rules`, it is in the new helpers; the rules emulator output names the line.

## 3. E2E (CI)
Unchanged: **89**. The seeded owner and staff identities have `status: "active"`; QML e2e suites write only to collections that stay open.

## Deploy and rollback (Taher)
1. Merge #159, deploy functions. 2. Merge this PR when CI is green. 3. `firebase deploy --only firestore:rules`. 4. Rollback: revert, redeploy rules. No data migration.

## On-device test plan (after the rules deploy; new tenant + users each time)
**Prerequisites:** owner on device A; an admin, a manager and a staff user created from Team Members; Firestore console open on `tenants/<T>/members`.

### Happy path
| # | Action | Expected |
|---|---|---|
| H1 | Fresh signup: create a workspace | Tenant and owner membership created; Inventory opens. |
| H2 | Owner: invite admin, manager, staff; change a staff to manager; suspend and re-activate | All work (invites go through `provisionMember`, role/status changes are direct writes). |
| H3 | Staff: leave workspace (Settings) | Works; user returns to onboarding. |
| H4 | Everyday use as each role: inventory, orders, suppliers, staff list | Unchanged. |

### Negative
| # | Action | Expected |
|---|---|---|
| N1 | Suspend the staff user. On their device pull to refresh / reopen | The app cannot load data (permission denied); no crash. They can still sign out. |
| N2 | Suspended admin tries Team Members changes | Refused. |
| N3 | Admin tries to set a member to admin from Team Members | The UI does not offer it; if forced through the console REST call, denied. |
| N4 | Owner tries to promote someone to owner | Not offered; denied by rules. |
| N5 | (REST/console probe) with a staff ID token, PATCH `members/<own uid>` role=owner | 403. |

### Edge
| # | Action | Expected |
|---|---|---|
| E1 | Re-activate the suspended user, they reopen the app | Access back with no reinstall. |
| E2 | Remove the member document in the console while they are signed in | Their next load fails, gateway writes refused (PR #159). |
| E3 | Rename the workspace as owner / as admin | Owner works, admin refused (unchanged). |

### Affected areas / Regression
Team Members dialogs, login (`_loadMembership` reads the own member doc), workspace bootstrap, leave workspace, every store load (all go through `isMember`).

### Monkey
Suspend / re-activate the staff user 10 times quickly while they browse; no crash, state settles on the last action.
