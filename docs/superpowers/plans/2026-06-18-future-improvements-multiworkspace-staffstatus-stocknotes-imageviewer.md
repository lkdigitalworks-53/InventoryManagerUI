# Future Improvements — Backlog (captured 2026-06-18)

> **Status:** NOT YET IMPLEMENTED. These four items were requested alongside two
> bug fixes on 2026-06-18. The two bugs (Android free-drag, notifications clearing
> dashboard history) were fixed in the same session; see "Shipped alongside" below.
> Each item here is a **net-new feature**, recorded for future implementation.
>
> **For agentic workers:** when you pick one of these up, first run
> `superpowers:brainstorming` to confirm scope with the user, then
> `superpowers:writing-plans` to expand the chosen item into a task-by-task plan
> in its own dated file. The sections below are scoping notes, not yet a final plan.

**Tech stack:** Felgo / Qt 6 QML, `pragma Singleton` stores, Firebase (Firestore +
Cloud Functions in `functions/index.js`), `qmltestrunner.exe` for pure-logic tests.

**Conventions to honor (verified this session + from memory):**
- New `.qml`/`.js` under `qml/` are auto-globbed via `CONFIGURE_DEPENDS` (CMakeLists.txt:36);
  a brand-new file may need a one-time `cmake --preset` reconfigure before the build
  picks it up. Without the glob, files are silently dropped from the Android package
  and the app SIGSEGVs on launch.
- **Nested-popup gotcha:** a `Popup`/`Dialog`/`BottomSheet` declared inside another
  BottomSheet's body opens off-screen. Declare new sheets/dialogs at the App root
  (`Main.qml`) and trigger via signal.
- **RBAC:** cross-store orchestration + role gates live in `DataModel`
  (`_hasAnyRole([...])`); pages stay prop-driven. Gate every sibling surface
  (exports, notification sheet, activity feed, "see all"), not just the visible list.
- **Button alignment:** center icon+text in any tappable control.
- **Activity/notification split (new this session):** `ActivityLog.entries` is the
  full history (dashboard + Activity page read it); `ActivityLog.notifications` is the
  dismissable view (Notifications sheet reads it). Dismissing a notification flips a
  `dismissed` flag — it does NOT delete history. Only sign-out hard-wipes via `clear()`.

---

## Shipped alongside (2026-06-18 bug fixes — context, already done)

1. **Android free-drag fix.** `QQC.ScrollView` enables flicking on touch but not for
   a mouse; its internal Flickable defaulted to `DragAndOvershootBounds`, so on Android
   every page could be press-held and free-dragged/rubber-banded even when content fit.
   Fixed by a new `qml/components/AppScrollView.qml` wrapper that pins the internal
   Flickable (`contentItem`) to `Flickable.StopAtBounds`; all 9 page-level ScrollViews
   now use it, and `BottomSheet.qml` got the same inline pin.
2. **Notifications no longer wipe dashboard history.** `ActivityLog` is one shared
   singleton; the sheet's "Clear all" called `ActivityLog.clear()` and swipe/tap called
   `remove()`, both nuking the array the dashboard reads. Replaced with
   `dismiss()` / `dismissAll()` + a `dismissed` flag and a `notifications` view.

---

## Feature 3 — Multi-workspace / role switching

**Request:** When a user has created their own workspace AND been invited as staff into
another, on login show a screen to pick which workspace/role to enter. Also expose a
"Switch workspace" option in Profile. Applies whenever a user belongs to >1 workspace
(including same role, different workspace).

### Current state (verified)
- **The backend ALREADY models multi-membership.** `users/{uid}` carries a `tenants: []`
  array of all workspace ids plus scalar `tenantId`/`tenantName`/`role` for the *current*
  one (`functions/index.js:322-334`; array grows in `provisionMember` at lines 313-315;
  `leaveCurrentTenant` prunes it at AuthService.qml:854). Per-workspace role lives in
  `tenants/{tenantId}/members/{uid}` (`functions/index.js:337-346`).
- **The client only ever reads the single `tenantId`.** `AuthService._loadUserProfile`
  (AuthService.qml:225-294) reads `data.tenantId` and ignores `data.tenants`. `AuthStore`
  has only scalar `tenantId`/`tenantName`/`role` (AuthStore.qml:20-22). No picker UI, no
  "switch workspace" row. `setTenantContext()` (AuthService.qml:447) already exists and
  can switch contexts — it just needs UI + a re-sync.

### Scope of work
- **Data model:** none server-side. Client: add `property var memberships: []` to
  `AuthStore` (each `{ tenantId, tenantName, role }`).
- **AuthService:** in `_loadUserProfile`, when `data.tenants.length > 1`, resolve each
  membership's role by reading `tenants/{tid}/members/{uid}`, populate `AuthStore.memberships`,
  and emit a new `workspaceSelectionRequired()` signal instead of going straight to
  Dashboard. A `chooseWorkspace(tenantId)` function applies context via the existing
  `setTenantContext` path. **Re-sync all stores on switch** — `Main.qml`'s
  `onTenantContextReady` already re-syncs Orders/Inventory/Sales/Staff/Transaction/
  Supplier/StockBatch stores (Main.qml:231-259); switching must run the same wipe+resync
  (and `Gateway.clear()` / `MigrationService.reset()`) so workspace A's data never bleeds
  into B.
- **New UI:** `qml/pages/WorkspaceSelectorPage.qml` (full-screen, same overlay pattern as
  LoginPage/TenantSetupPage in Main.qml; `visible` gated on `workspaceSelectionRequired`).
  Tiles: workspace name + role badge + "Enter". Add a "Switch workspace" `SettingsRow`
  in `ProfilePage.qml` (between "Team members" ~line 206 and "Security"), `visible:
  AuthStore.memberships.length > 1`, that re-opens the selector.
- **Edge cases:** single-membership users skip the picker entirely (current behavior).
  After `leaveCurrentTenant`, memberships shrink — re-fetch. A user who is *owner* of one
  and *staff* of another must get the correct RBAC flags per workspace (already derived
  from `role`, so this falls out once `role` is set on switch).

### Acceptance criteria
- A user in exactly one workspace logs straight into Dashboard (no picker).
- A user in ≥2 workspaces sees the selector after auth; picking one loads only that
  workspace's data with the correct role/permissions.
- Profile shows "Switch workspace" only for multi-workspace users; switching fully
  re-syncs stores with no cross-workspace data bleed.

---

## Feature 4 — Staff active/on-leave status request → owner approval

**Request:** Staff can request changing their own status (active ↔ on leave) with a
reason/description. This creates a PENDING REQUEST notification on the owner/manager
account. On acceptance: status updates, staff is notified, and it appears in the activity
feed.

### Current state (verified)
- Staff `status` is `"active"` | `"on_leave"` | `"suspended"` (StaffStore.qml; counters
  `activeCount()`/`onLeaveCount()` at lines 78-90). Today only **owner/admin** changes it,
  immediately, via `StaffDetailDialog` (gated by `canManageStaff`, line 18) →
  `logic.updateStaff` → `DataModel.onUpdateStaff` (DataModel.qml:220-226, owner/admin gate)
  → `StaffStore.updateStaff`. No request/pending step exists.
- **Reusable infra:** the Orders "approve pending" pattern (OrdersPage.qml banner
  lines 164-237; `OrdersStore.approveAllPending` 484-491; role flags `canApprovePending`/
  `canApproveAll` in AuthStore.qml:31-60) is a good UI template. `ActivityLog.record(kind,
  title, subtitle, entityId)` already drives notifications + activity feed and click-routes
  via `Main.qml:_routeActivity` (759-782).
- **Key gap:** `ActivityLog` has **no recipient targeting** — every entry is global to the
  session. A pending request that should appear on the owner's device (and the resolution
  on the staff's) needs targeting that the current in-memory log can't express.

### Scope of work
- **New Firestore collection** `tenants/{tid}/staff_status_requests/{requestId}`:
  `{ staffId, requestedBy(uid), requestedStatus, reason, status:"pending"|"accepted"|
  "rejected", createdAt, respondedAt, respondedBy, response }`. Add `firestore.rules`:
  staff may create a request for their own `staffId`; owner/admin/manager may update
  status; members may read their tenant's requests.
- **New store** `qml/model/StaffStatusRequestStore.qml` (`pragma Singleton`, Firebase-backed
  like the other stores) with `createRequest()`, `approveRequest()`, `rejectRequest()`,
  `pendingForApprover()`, `revision`.
- **Orchestration** in `DataModel`: `onRequestStaffStatus(staffId, status, reason)` (staff
  self-scope gate via `AuthStore.currentStaffId`); `onResolveStaffStatusRequest(reqId,
  approve)` (gate `_hasAnyRole(["owner","admin","manager"])`) → on approve, call
  `StaffStore.updateStaff(staffId, {status})` then `ActivityLog.record("staff_updated", …)`.
- **UI:** a "Request status change" action in the staff member's own view (status dropdown
  + reason `AuthTextField`); an approvals surface for owner/manager — either a new
  notification kind `"staff_status_request"` with Accept/Reject in `NotificationsSheet`, or
  a banner mirroring Orders. New `_routeActivity` branch for the new kind.
- **Targeting:** since `ActivityLog` is global/in-memory, drive the actual pending list from
  `StaffStatusRequestStore` (Firestore, queryable by approver/tenant) rather than the log;
  use `ActivityLog` only for the transient toast/feed entries scoped to the current session.

### Acceptance criteria
- Staff submitting a status request does NOT change their status immediately; a pending
  request is persisted with the reason.
- Owner/manager sees the pending request with the reason and can Accept/Reject.
- Accept updates status, notifies the staff member, and writes an activity entry; Reject
  records the outcome and leaves status unchanged.
- A staff member cannot approve their own (or anyone's) request.

---

## Feature 5 — Reason/description on product edit & restock, elided in history + expand popup

**Request:** Allow a reason/description when editing product details and when restocking.
Show that text in the product history elided (…), tappable to a popup with the full text.

### Current state (verified)
- **Edit:** `EditProductDialog.qml` submits via `productUpdateRequested(pid, fields)`
  (`_submit` ~lines 909-949) → Logic → `DataModel.onUpdateProduct` → `InventoryStore.updateProduct`,
  which writes per-field `TransactionStore.recordFieldChange` events. There's a permanent
  product `description` field, but **no per-edit reason**.
- **Restock:** `RestockDialog.qml` calls `InventoryStore.restock(pid, qty, supplierId, unitCost)`
  → `TransactionStore.recordPurchase` + `StockBatchStore.addBatch(... note="")`. No reason input.
- **History UI already exists** in `EditProductDialog.qml` (lines 633-906): a Repeater over
  `TransactionStore.forProduct(productId)` rendering icon + title + detail per event. The
  `note`/`reason` pattern is **already established** — `TransactionStore.recordReturn` and
  `recordPriceAdjust` carry `.note` and render it inline (detail formatters ~lines 893-901);
  `StockBatchStore.addBatch` already accepts a `note` param. **No tap-to-expand popup exists** —
  only `elide: Text.ElideRight` on titles.

### Scope of work
- **Data model:** add a `note` param to `TransactionStore.recordPurchase`, `recordFieldChange`,
  and `recordStockAdjustment` (mirror the existing `recordReturn`/`recordPriceAdjust` shape),
  and store it on the doc. Thread `note` through `InventoryStore.updateProduct`/`restock`,
  `DataModel`, and `Logic` signals.
- **UI inputs:** add a reason `AuthTextField` to `RestockDialog` and to `EditProductDialog`
  (edit mode only); pass into the existing submit paths.
- **History elide + expand:** make the history detail text elided past a threshold and
  tappable. Reuse the `AlertDialog` modal pattern (or a small `NoteViewerDialog` hoisted to
  the App root per the nested-popup gotcha) to show the full note with `wrapMode: Text.Wrap`.
  Apply to kinds `purchase`, `field_change`, `stock_adjustment` (and keep `return`/`price_adjust`
  which already show notes).

### Acceptance criteria
- Editing a product and restocking each accept an optional reason that is persisted on the
  corresponding history event.
- History rows with a long note show it elided; tapping opens a popup with the full text.
- Existing return/price-adjust notes continue to render unchanged.

---

## Feature 6 — Enlarge product photos & avatars

**Request:** Give the option to enlarge photos of products and avatars.

### Current state (verified)
- **Product photos** show as small thumbnails: `EditProductDialog.qml:198-207` (80×80),
  `AddProductDialog.qml:86-98` (64×64 preview), and in the Inventory product card via
  `AvatarBadge` (`InventoryPage.qml:237-245`). Source is the product `photoUrl` string
  (local `file://` today via `StorageService`/`ImageProcessor`; Firebase Storage URLs when
  `StorageService.useCloud` flips true). None are tappable to enlarge.
- **Avatars** (`AvatarBadge.qml`) currently render initials/icons everywhere (Profile hero,
  StaffPage list, StaffDetailDialog, notifications); only the product card passes a real
  `imageSource`. User/staff avatar *photos* are not uploaded yet.
- **No enlarge/zoom infra exists** — no `PinchHandler`, lightbox, or full-screen viewer
  anywhere. Reusable popup bases: `BottomSheet`, `AlertDialog`, `PhotoSourceSheet` (all
  `parent: QQC.Overlay.overlay`).

### Scope of work
- **New component** `qml/components/ImageViewerPopup.qml` — full-screen `QQC.Popup`/`Dialog`
  (`parent: QQC.Overlay.overlay`), semi-transparent backdrop, `Image` with
  `fillMode: PreserveAspectFit` and an explicit `sourceSize` cap, `asynchronous: true`,
  and `Image.status` error handling. Add `PinchHandler` (+ a `DragHandler` while zoomed) for
  pinch-zoom with min/max scale; tap-outside / Escape / a close button to dismiss; fade in/out.
  Hoist to the App root (Main.qml) per the nested-popup gotcha; open via a function like
  `imageViewer.show(url)`.
- **Wire tap targets:** product thumbnail in `EditProductDialog` and the product card in
  `InventoryPage` (stop event propagation so it doesn't also open the detail dialog), plus
  the Profile hero avatar and staff avatars **once** those carry a real `imageSource`
  (guard: only open when a non-empty image source exists, else no-op).
- **Perf:** honor the qt-qml skill rules — always set `sourceSize`, `asynchronous: true`,
  prefer animating `scale`/`transform` over geometry.

### Acceptance criteria
- Tapping a product photo opens a full-screen viewer showing the full-resolution image with
  pinch-to-zoom; closing returns to the prior screen.
- Avatars with a real photo are tappable to enlarge; initials-only avatars are not (no-op).
- No regression to the existing tap-to-open-detail behavior on product cards.
