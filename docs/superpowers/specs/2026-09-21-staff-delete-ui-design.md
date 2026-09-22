# Staff delete UI — design

**Date:** 2026-09-21
**Branch:** `feat/2026-09-21-staff-delete-ui`
**Source item:** `docs/superpowers/DELETE-FEATURE-ROADMAP.md` item 2 (MEDIUM): staff delete has no row-level button.

## Problem

`StaffPage.deleteStaffClicked`, `Main.qml`'s confirm dialog, `Logic.deleteStaff` and `DataModel.onDeleteStaff`
(owner/admin guard) → `StaffStore.deleteStaff` were already wired end to end — identical gap to what products
and orders had before `feature/product-order-delete-ui`. No visible element in the staff row ever emitted the
signal.

## What the trace found beyond the missing button

- No success toast for staff delete (products and orders have one).
- `StaffStore._onMutationConflicted` still had the pre-`action`-param wording, deliberately left that way
  during the products/orders fix because it was unreachable from the UI (`KNOWN-ISSUES.md`).
- A staff record can carry `appUid` (Firebase Auth uid) once login provisioning is live
  (`Gateway.provisioningAvailable`, currently `false`). `AuthStore.currentStaffId` already resolves the
  caller's own staff record. `firestore.rules` lets a non-owner member remove their own membership doc
  (voluntary leave), and `StaffStore.deleteStaff` cascades to that same doc via
  `AuthService.cleanupStaffAuthDocs` when the deleted record has `appUid`. An admin with their own login could
  therefore delete their own staff record and lock themselves out. Dormant today, live the day provisioning
  ships.
- `recordMutation` (the Cloud Function) derives `actorRole` for the audit trail but performs no role
  authorization for any entity/action — only `provisionMember` checks role. The client-side
  `DataModel.onDeleteStaff` check is not a trust boundary: any signed-in tenant member could call the gateway
  directly and delete a staff record. Systemic across every entity/action, not staff-specific.
- The auth-doc cascade (`AuthService.cleanupStaffAuthDocs`) is fire-and-forget with no retry — already tracked
  (`E2E-TESTING-ROADMAP.md` Medium, P5 in the India compliance roadmap). Left alone.
- Deleted staff are already handled everywhere that references them: Sales analysis groups them under
  "(removed)", orders keep `staffId` as history, exports show a blank name, the order-detail staff picker
  lists active staff only. A hard delete matches the existing design; no schema change needed.

## Decisions (Taher, 2026-09-21)

| # | Question | Chosen |
|---|---|---|
| Q1 | Guard against deleting your own staff record (dormant today) | **Add it now** |
| Q2 | No server-side role check on staff delete (systemic gap) | **Fix for staff/delete now**, scoped narrowly — not a general authorization matrix (that stays a separate, tracked issue) |
| Q3 | Fire-and-forget auth-doc cascade | **Leave alone**, cross-reference the existing tracked issue |

## Design

1. **`StaffPage.qml`** — trash-icon button in the row, the exact `Rectangle` + `Icon` + `MouseArea` idiom used
   by `OrdersPage` / `InventoryPage` (`objectName: "deleteStaffBtn"`, `visible: root.canManageStaff`,
   `mouse.accepted = true` so the tap doesn't bubble to the card's own `onClicked`). Emits the existing
   `deleteStaffClicked(staffId)`. No per-status gating, matching the orders/products precedent — a guard
   rejection explains itself on tap rather than the row re-deriving the rule.
2. **`Main.qml`** — `onStaffDeleted` shows `Toast.show(qsTr("Staff member removed"))`, matching
   `onProductDeleted` / `onOrderDeleted`.
3. **`StaffStore._onMutationConflicted(entity, entityId, current, action)`** — gains the `action` param (already
   sent by `Gateway.mutationConflicted`) and a delete-specific toast, mirroring
   `InventoryStore._onMutationConflicted`.
4. **`DataModel.onDeleteStaff`** — after the existing owner/admin check, reject when
   `staffId === AuthStore.currentStaffId` (non-empty) with `errorOccurred("staff", "You can't delete your own
   staff record — ask another owner or admin")`.
5. **`functions/index.js` `recordMutation`** — after deriving `ctx`, reject `entity === "staff" && action ===
   "delete"` for any role other than `owner` / `admin` with `403 role-not-allowed`. Scoped to this one
   entity/action pair; every other entity/action still has no server-side role check (tracked as a new
   KNOWN-ISSUE, not fixed here).

## Not fixed (follow-ups, tracked separately)

- No general server-side authorization matrix: every entity/action other than staff/delete and
  `provisionMember` still trusts the client's own role check. New `KNOWN-ISSUES.md` entry.
- `AuthService.cleanupStaffAuthDocs` stays fire-and-forget (already tracked, P5 compliance work).
- Server-side self-delete guard: not added. The client guard is sufficient today (no other client exists),
  and adding it server-side would need the server to resolve `entityId` to the caller's own staff record,
  which is more than this ticket's scope — noted, not built.

## Testing approach and limits

- `tests/tst_DataModel_deleteGuards.qml`: extended with the owner/admin guard and the self-delete guard
  (matching-appUid, non-matching, and no-linked-record cases) for `onDeleteStaff`. Runs in CI (no Felgo import
  in `DataModel.qml` / `Logic.qml`).
- `tests/tst_StaffStore_delete.qml` (new): `deleteStaff` (local removal, queued mutation, unknown id, only the
  matching id) and `_onMutationConflicted` (ignores other entities, update vs delete wording, restores on a
  rejected delete, pushes an unknown record). Runs in CI.
- `functions/test/index.handlers.test.js`: the new role check — refused for a non-owner/admin, succeeds for
  admin and owner, and two negative-scope tests proving the check does not leak onto staff/update or
  order/delete. **Run for real in this session** (`npm test` in `functions/`, dependencies installed from the
  network-allowlisted npm registry): 200/200 passing. Confirmed genuinely TDD by reverting the fix and
  re-running — the new refused-role test failed as expected (`199 pass, 1 fail`), then passed again once
  restored.
- `test/felgo-dependent/tst_StaffPage_deleteButton.qml` (new): mirrors
  `tst_OrdersPage_deleteButton.qml` exactly (visibility on/off, status-independent, emits with the right id,
  doesn't bubble to the row's own click). Not runnable under the `QML Tests` CI job — `StaffPage.qml` →
  `GlassHeader` → `Constants.qml` → `import Felgo`, confirmed by that job installing plain Qt only. On-device
  only, same as its two siblings in this directory.
