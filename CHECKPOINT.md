# CHECKPOINT — 2026-09-21: staff delete UI (DELETE-FEATURE-ROADMAP item 2) — design gate, no code yet

**Session date:** 2026-09-21
**Branch:** `feat/2026-09-21-staff-delete-ui`, off `main` @ `55451b3` (PR #75 and #76 merged)
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-CHECKPOINT.md`
**Skills invoked by Taher:** `superpowers:brainstorming` (design gate before code), `qt-development-skills:qt-qml`,
`ponytail:ponytail`. Caveman mode FULL applies to chat replies only; repo docs and commits are normal prose.
**Commit identity:** `Taher (via Claude session) <dextran52@gmail.com>`.

## Compliance status vs master spec (`specs/2026-06-06-india-compliance-roadmap-design.md`)

"Take staff delete first and complete it e2e. Then we will take the next item as a separate session."

## Standing instructions from Taher

- Branch only, never `main`; push when the work is done without asking (Taher reviews in the GitHub PR).
- Do not build or run the app; no Qt tooling in the sandbox; CI is the only signal for QML.
- Every change: tests aiming at 100% coverage (unit, functional, rules, e2e, regression; happy path, negative, edge,
  multi-scenario, monkey), a test plan from the template (Skill 49), and `SKILLS.md` / `AGENTS.md` / `README.md`
  updated as needed.
- Honest advisor: show trade-offs, grill before deciding, do not simply agree.
- The GitHub PAT is used for `git push` and the PR API only; never written into the repo.

## Step log (append-only; resume from the last ticked step)

- [x] 1. Read project notes and the invoked skills; updated `main` (@ `55451b3`), created this branch.
- [x] 2. Read roadmap item 2 and the KNOWN-ISSUES staff entry, then traced the whole flow (findings below).
- [x] 3. Archived the previous checkpoint, wrote this file.
- [ ] 4. **Awaiting Taher:** Q1 scope, Q2 server-side guard, Q3 approval and pace. Then spec, plan, implement, tests,
      test plan, docs, push, read CI.

## Findings (all verified in code this session)

- The wiring the roadmap describes exists: `StaffPage.deleteStaffClicked`, the `confirmDlg` handler in `Main.qml`
  (~line 1048), `Logic.deleteStaff`, `DataModel.onDeleteStaff` (owner / admin only), `StaffStore.deleteStaff`
  (optimistic local removal, `Gateway.recordMutation("staff", id, "delete", removed, null)`, `ActivityLog`
  `staff_deleted`, cascade if `appUid`).
- The proven button idiom is on `OrdersPage` / `InventoryPage`: `Rectangle` + `Icon "trash"` + `MouseArea` with an
  `objectName`, `visible:` bound to a permission property, and `mouse.accepted = true` so the tap does not also
  open the card. `StaffPage.canManageStaff` already exists and `Main.qml` binds it to `AuthStore.canManageStaff`
  (owner / admin). `ListCard`'s default slot is a `RowLayout`, so a second child sits next to the `StatusPill`.
- Missing besides the button: a success toast (`Main.qml` has `onProductDeleted` / `onOrderDeleted`, nothing for
  staff), and `StaffStore._onMutationConflicted` has no `action` parameter, so a rejected delete would say "your
  change didn't save" (products and orders got delete-specific wording).
- No test references `StaffStore.deleteStaff`, `DataModel.onDeleteStaff` or `StaffStore._onMutationConflicted`.
  Existing staff tests: `tst_AddStaffSyncClose.qml`, `tst_StaffScope.qml`. Page-level button tests live in
  `test/felgo-dependent/` and are not run by CI.
- Removed staff are already handled by history: Sales analysis shows "(removed)", orders keep `staffId`, exports show a
  blank name, the order picker lists active staff only. A hard delete matches the existing design.
- Self-delete: `firestore.rules` lets a non-owner member delete their own membership (voluntary leave). Deleting
  your own staff record (if it has `appUid`) would cascade-delete your own membership and lock you out. Reachable
  only once provisioning is on: `Gateway.provisioningAvailable` is `false` and `AuthService.qml:820` is the only
  `setAppUid` caller.
- Cascade `AuthService.cleanupStaffAuthDocs` (already tracked: `E2E-TESTING-ROADMAP.md` Medium, P5 in the India
  compliance roadmap): the `users/{uid}` remove is always denied by rules (`allow delete: if false`) and also
  contradicts the standing "never hard-delete `users/{uid}`" constraint; the `members/{uid}` remove is a direct,
  fire-and-forget client write with no retry and no signal. The confirm dialog promises access is revoked.
- Server: `recordMutation` derives `actorRole` for the audit entry but does no role authorization; only
  `provisionMember` checks owner / admin. Any active member can delete staff through the gateway; the
  `DataModel` check is the only barrier. Not in KNOWN-ISSUES today. Systemic across entities, not staff-specific.

## Draft design (awaiting approval)

1. `StaffPage.qml`: trash button in the row, same idiom, `objectName: "deleteStaffBtn"`,
   `visible: root.canManageStaff`, emits the existing `deleteStaffClicked`.
2. `Main.qml`: `onStaffDeleted` toast ("Staff member removed").
3. `StaffStore._onMutationConflicted(entity, entityId, current, action)`: delete-specific wording, same as
   products / orders.
4. `DataModel.onDeleteStaff`: reject deleting your own staff record with `errorOccurred("staff", ...)` (option B).
5. Tests: headless for `StaffStore.deleteStaff`, `_onMutationConflicted`, `DataModel.onDeleteStaff`; a
   Felgo-dependent button test mirroring `tst_OrdersPage_deleteButton.qml`.
6. Docs: test plan, README, SKILLS, KNOWN-ISSUES (resolve the staff entry; add the server role finding), roadmap,
   E2E roadmap note about the `users/{uid}` denial.

## Not done, deliberately

No code, tests or test plan yet: the brainstorming design gate is open. App not built or run; no Qt tooling installed.
