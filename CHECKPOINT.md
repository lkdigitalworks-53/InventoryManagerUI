# CHECKPOINT — 2026-09-21: staff delete UI (DELETE-FEATURE-ROADMAP item 2) — DONE, PR open

**Session date:** 2026-09-21
**Branch:** `feat/2026-09-21-staff-delete-ui`, off `main` @ `55451b3` (PR #75/#76 merged), later merged forward
to `d6f74eb` (PR #78/#79 merged) before opening a PR.
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-CHECKPOINT.md`
**PR:** #80 (draft), commit `4092029`.
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
- [x] 4. Grilled 3 adjacent findings (self-delete lockout, no server-side role check, fire-and-forget auth-doc
      cascade). Taher: fix the self-delete guard now; fix the server-side role check now too (declined my
      "log it, separate session" recommendation — pushed back once, he held the decision, proceeded narrowly
      scoped to staff/delete only, not a general authorization matrix); leave the cascade alone.
- [x] 5. Wrote and committed the design spec
      (`docs/superpowers/specs/2026-09-21-staff-delete-ui-design.md`).
- [x] 6. Implemented: `StaffPage.qml` trash button, `Main.qml` toast, `StaffStore._onMutationConflicted`
      action-aware wording, `DataModel.onDeleteStaff` self-delete guard, `functions/index.js` narrow
      staff/delete role check (403 `role-not-allowed`).
- [x] 7. Tests: 19 new/extended QML cases across 3 files (10 new `tst_StaffStore_delete.qml`, 4 new in
      `tst_DataModel_deleteGuards.qml`, 5 on-device-only in `test/felgo-dependent/`). Functions: 5 new cases in
      `index.handlers.test.js`, installed `functions/node_modules` from the sandbox's npm allowlist and ran
      `npm test` for real. Confirmed genuinely TDD by reverting the `functions/index.js` fix and rerunning
      (199 pass, 1 fail — exactly the new refused-role test), then restoring it.
- [x] 8. Docs: test plan (Skill 49 structure), test-plans index row, `SKILLS.md` Skill 68, `AGENTS.md` note,
      README update paragraph, `KNOWN-ISSUES.md` (resolved the staff entry, added a new entry for the
      server-side authorization gap), roadmap item 2 marked resolved.
- [x] 9. Committed the docs batch, pushed. `main` had moved again (PR #78/#79, atomic-operation-outbox work)
      before a PR existed for this branch, so merged it in before opening one: `functions/index.js` auto-merged
      cleanly (main's new `recordOperation` endpoint doesn't touch `recordMutation`'s body); `CHECKPOINT.md`
      and `test-plans/README.md` conflicts resolved the same way as the previous session (kept this checkpoint,
      archived the incoming one; kept both test-plan index rows).
- [x] 10. Opened PR #80 (draft). CI on the final merged commit `4092029`: **all four jobs green, 1210/1210**
      (QML 970, Functions 171, Rules 28, E2E 41).
- [x] 11. Found and recorded a genuine discrepancy: this session's local `functions/` runs (Node 22.22.2, no
      pinned version) reported 200 then 237, but CI (Node 20, per `engines.node` and the workflow) reports 171
      for the identical final commit and command. Reproduced 237 locally again to confirm it wasn't a fluke.
      Both runs are 0 failures — a `node:test` Node 20 vs 22 counting/reporting difference, not a hidden bug.
      Corrected the test plan's stale local numbers to CI's authoritative 171, and added Skill 69 so a future
      session doesn't compare a local Node-22 count against a CI Node-20 count and conclude something's wrong.
- [ ] 12. On-device pass by Taher using the test plan's On-Device section (only coverage for the rendered
      button, self-delete guard in a real app, and the server-side role check end-to-end). PR #80 is still a
      draft; Taher marks it ready.

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
  staff), and `StaffStore._onMutationConflicted` had no `action` parameter, so a rejected delete would say "your
  change didn't save" (products and orders got delete-specific wording).
- No test referenced `StaffStore.deleteStaff`, `DataModel.onDeleteStaff` or `StaffStore._onMutationConflicted`
  before this session. Existing staff tests: `tst_AddStaffSyncClose.qml`, `tst_StaffScope.qml`. Page-level button
  tests live in `test/felgo-dependent/` and are not run by CI.
- Removed staff are already handled by history: Sales analysis shows "(removed)", orders keep `staffId`, exports
  show a blank name, the order picker lists active staff only. A hard delete matches the existing design.
- Self-delete: `firestore.rules` lets a non-owner member delete their own membership (voluntary leave). Deleting
  your own staff record (if it has `appUid`) cascades to your own membership and locks you out. Reachable only
  once provisioning is on: `Gateway.provisioningAvailable` is `false` and `AuthService.qml:820` is the only
  `setAppUid` caller.
- Cascade `AuthService.cleanupStaffAuthDocs` (already tracked: `E2E-TESTING-ROADMAP.md` Medium, P5 in the India
  compliance roadmap): the `users/{uid}` remove is always denied by rules (`allow delete: if false`) and also
  contradicts the standing "never hard-delete `users/{uid}`" constraint; the `members/{uid}` remove is a direct,
  fire-and-forget client write with no retry and no signal. The confirm dialog promises access is revoked.
- Server: `recordMutation` derives `actorRole` for the audit entry but did no role authorization; only
  `provisionMember` checked owner / admin. Any active member could delete staff through the gateway directly;
  `DataModel`'s check was the only barrier. Systemic across every entity/action, not staff-specific — logged as
  its own KNOWN-ISSUES entry, fixed narrowly for staff/delete only.

## Decisions (all answered)

Q1 add the self-delete guard now. Q2 fix the server-side role check now too, scoped narrowly to staff/delete
(declined my "log it, separate session" recommendation after one pushback). Q3 leave the auth-doc cascade
alone. Rejected alternatives and full reasoning: `docs/superpowers/specs/2026-09-21-staff-delete-ui-design.md`.

## Not done / follow-ups (stated in the spec, test plan, KNOWN-ISSUES and Skill 68)

- General server-side authorization matrix for every entity/action other than staff/delete: new KNOWN-ISSUES
  entry with a concrete design pointer, not built.
- `AuthService.cleanupStaffAuthDocs` stays fire-and-forget (already tracked under P5 compliance work).
- No server-side self-delete guard (client guard judged sufficient; no other client exists today).
- `StaffPage.qml`'s rendered button has no automated coverage (Felgo dependency, same as its two siblings) —
  on-device plan only.
- No sandbox build or app run (standing instruction); no Qt tooling installed.
