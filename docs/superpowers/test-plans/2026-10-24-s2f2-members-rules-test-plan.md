# Test plan — S2f-2: `members` rules, active-member status, role assignment

**Branch:** `fix/2026-10-24-s2f2-members-rules`, STACKED on `fix/2026-10-24-s2f1-membership-authority` (PR #159). **Design:** `specs/2026-10-24-s2f-authz-hardening-design.md` (F1, F2, F9, D2, D8).
**Covers:** `firestore.rules` (helpers `isMember`, `isOwner`, `isAdmin`, `memberStatusIsActive`, `canAssignRole`, `isAccessControlCollection`; blocks `members`, wildcard guard) and `test/firestore.rules.test.js` (+31 tests).
**Why:** F1: the wildcard `match /{collection}/{docId}` also matches `members/{uid}`; Firestore ORs matching rules, so any member could rewrite any membership (probe PR #157). F2: `isMember` was `exists()` only, so a suspended member kept direct read/write and a suspended admin kept admin powers. F9 (found while writing the tests): the old create/update rules let an owner mint a second owner and an admin mint admins/owners, which the server (`canAssignRole`) and the client (`_canAssignRole`) both refuse.
**Takes effect on `firebase deploy --only firestore:rules`.** No client or function change. Deploy PR #159 (functions) first.

## 1. Already covered before this change
Rules 52 (ledger, server-only, inventory lock, pending_cleanup pins). **Nothing** covered `users`, `tenants` or `members`.

## 2. Rules tests (CI only, no emulator in the sandbox: the emulator jar host is unreachable)
Rules **83** observed on `853ac8f` (52 + 31). CI total observed there: QML 2104 + Functions 835 + Rules 83 + E2E 96 = **3118**. (The first version of this plan said 3087, built from stale Functions 811 / E2E 89 baselines.) The review sweep (section 2b) adds 11 rules tests and 6 QML tests: predicted Rules **94**, QML **2110**, total **3135**.
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
Unchanged: **96** (observed). The seeded owner and staff identities have `status: "active"`; QML e2e suites write only to collections that stay open.

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
| N3 | Admin picks `admin` in a member's role box | The box offers all four roles; the app refuses with the toast "Role assignment is not allowed" and writes nothing (client `_canAssignRole`). Forced through a REST call: 403 from the rules. |
| N4 | Owner picks `owner` in a member's role box | Same toast, nothing written. Forced through a REST call: 403 from the rules. |
| N5 | (REST/console probe) with a staff ID token, PATCH `members/<own uid>` role=owner | 403. |
| N6 | Admin opens Team Members and looks at another admin's row and the owner's row | Role box is greyed (read-only), no Suspend and no Remove button. The same applies to the admin's own row and to the owner's row for everyone. Forced through a REST call: 403. (D-1 b; client `MemberPolicy.canManageMember`.) |
| N7 | Suspended member (any role) reopens the app | Data lists stay empty / error toasts. The role boxes and menus of their old role may still show, because the client does not read `status` yet (S2f-3). Nothing they tap can write. |

### Edge
| # | Action | Expected |
|---|---|---|
| E4 | Owner demotes an admin to staff, suspends and removes an admin; admin tries the same on a peer admin through REST | Owner: all work. Admin: 403 on every attempt. |
| E1 | Re-activate the suspended user, they reopen the app | Access back with no reinstall. |
| E2 | Remove the member document in the console while they are signed in | Their next load fails, gateway writes refused (PR #159). |
| E3 | Rename the workspace as owner / as admin | Owner works, admin refused (unchanged). |

## 2b. Review sweep additions (2026-10-26, stacked PR #164 on this branch)
| Group | Tests | Proves |
|---|---|---|
| R1 | 6 (5 bad-role docs + 1 control) | an ACTIVE member whose role is `viewer`, empty, `Owner`, a number or missing has no read, write or management power (own doc still readable); every valid role still works. Mirrors `deriveContext` `VALID_ROLES` (Q1 of the PR #159 sweep). |
| R2 | 1 | member `uid` field cannot be rewritten on update (owner and admin), same-uid update works |
| R3 | 1 | tenant `ownerId` immutable: no second owner through the bootstrap rule, no takeover by an outsider; rename still works |
| D-1 (b) | 3 | decided: hierarchy. Matrix actor x target (owner/admin x owner/admin/manager/staff) for update and delete; admin cannot demote/remove a peer admin or itself, owner can; admin can still leave |
| QML `tst_MemberPolicy` | 6 | `MemberPolicy.canAssignRole` and `canManageMember`: 4x4 tables identical to the rules matrix, peer admin and owner refused, unknown actor/target fail closed |
The UI gating (`MemberManagementDialog` hides Suspend/Remove and greys the role box for rows the actor cannot manage; `AuthService` refuses early with "You cannot change a member with this role") has no widget test: the dialog needs the full Felgo context; the logic lives in the tested helper and the rules are the boundary. Device steps N6 and E4 cover the UI.
Happy: controls in R1/R2/R3, owner rows of the matrix. Negative: R1-R3, admin rows of the matrix. Edge: role types, same-value ownerId, self-leave of an admin. Multi-scenario: matrix, R1 loop. Monkey: the existing monkey test covers the tenant doc.

### Affected areas / Regression
Team Members dialogs, login (`_loadMembership` reads the own member doc), workspace bootstrap, leave workspace, every store load (all go through `isMember`).

### Monkey
Suspend / re-activate the staff user 10 times quickly while they browse; no crash, state settles on the last action.
