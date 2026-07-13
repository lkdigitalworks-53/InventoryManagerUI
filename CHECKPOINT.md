# Session Checkpoint — Enlarge product photo + enlarge order product-line detail

**Started:** 2026-07-13
**Branch:** `feature/enlarge-product-photo-and-order-details`
**Status:** Brainstorming in progress — exploring codebase and asking clarifying questions.
No code written yet.

## Step log

1. Cloned `InventoryManagerUI` fresh. Repo reachable with no auth (public, per Taher's
   confirmation this session).
2. Archived stale root `CHECKPOINT.md` (from the already-merged
   `feature/analysis-by-name-chart-all-views` session) to
   `docs/superpowers/specs/2026-07-11-analysis-by-name-chart-CHECKPOINT.md`.
3. Created branch `feature/enlarge-product-photo-and-order-details` off latest `main`
   (tip: `2748d1b`, the P0 gateway gap-closure merge).
4. Explored codebase for the two requested features:

   **Feature A — enlarge product photo ("product page" = `EditProductDialog.qml`, opened
   in view mode from `InventoryPage`'s "View"/"Edit" actions):**
   - Photo shown as an 80x80 thumbnail (`Image` inside a bordered `Rectangle`), lines ~200-231.
   - `AddProductDialog.qml` has an near-identical small photo preview block (its own
     `pendingPhotoSource`, not yet uploaded) — same enlarge question could apply there; need
     to confirm scope with Taher.
   - No existing fullscreen/zoom image viewer anywhere in the codebase (checked for
     `PinchArea`, `ImageViewer`, `fullscreen` — none found). This is new territory, not a
     variation on an existing pattern.

   **Feature B — enlarge product-line detail (order dialogs):**
   - `NewOrderDialog.qml`'s cart line is a raw `Rectangle` delegate (not `ListCard`) with a
     top row (`AvatarBadge` + name/price + qty steppers) and a second row (price field +
     discount). Tapping "the product line" here needs a scoped tap target that doesn't
     collide with the qty stepper buttons — likely just the avatar+name/price column.
   - `OrderDetailDialog.qml`'s line delegate already uses `ListCard` (a `QQC.AbstractButton`
     subclass) with a trailing `RowLayout` of stepper/remove buttons. Since those buttons sit
     in the trailing slot and the title/subtitle/avatar area has no interactive children,
     `ListCard.onClicked` is naturally free to wire up for "tap to enlarge" — no new
     MouseArea needed there.
   - Both dialogs' line items carry `productId` (may be empty for a manually-typed/ad-hoc
     line not matched to any catalog product) — need to decide fallback behavior for that
     case.
   - No existing "read-only product quick-view" component; closest precedent is
     `EditProductDialog`'s own view-mode (BottomSheet, no edit toggle engaged) and
     `StaffDetailDialog`'s identical view/edit BottomSheet pattern.

   **Architecture constraint discovered (affects both features) — Android/hardware Back
   button routing:**
   - `qml/Main.qml`'s `onBackButtonPressedGlobally: app._handleBack()` is the *single* place
     that closes the "top-most" open dialog on Back press. It holds a flat array of dialog
     ids (`photoSourceSheet, addProductDlg, editProductDlg, newOrderDlg, orderDetail, ...`)
     and closes the first one in that array that reports `.opened === true`.
   - Existing precedent: `photoSourceSheet` (an overlay that can appear *on top of* either
     `addProductDlg` or `editProductDlg`) is hoisted to `Main.qml` as a shared, single
     instance, opened via a signal (`photoPickRequested`) from the dialog underneath it, and
     is listed **first** in the `dialogs` array — so Back closes it before the parent dialog
     underneath.
   - Any new popup that can appear on top of an existing dialog (photo viewer over
     `editProductDlg`; product quick-view over `newOrderDlg`/`orderDetail`) MUST follow this
     exact precedent: hoisted to `Main.qml`, opened via signal, and placed *before* its
     parent(s) in the `dialogs` array — otherwise Back would close the wrong (parent) dialog
     first, or close both, or leave the child stuck open. This is an existing-code constraint
     the design must explicitly account for, not an optional nice-to-have.
   - This routing convention isn't written down in `AGENTS.md`/`SKILLS.md` today — worth
     adding once the design is settled, consistent with past sessions updating those docs
     after architectural changes.

5. Asked Taher clarifying questions across two rounds and got the design fully settled:
   - Photo viewer: NOT full-screen, NOT a reused `BottomSheet` either — a centered card,
     width = screen width minus side padding, height ≈ 1/3 of screen height, image
     `PreserveAspectFit` inside. Scope expanded to 5 trigger points: `InventoryPage` product
     list, `AddProductDialog`, `EditProductDialog`, `NewOrderDialog` cart line,
     `OrderDetailDialog` line item.
   - Zoom: static fit-to-screen only (no pinch/pan) for v1.
   - Order-line avatar: upgrade to show the real product photo (currently initials-only);
     tapping the avatar directly opens the photo viewer; tapping elsewhere on the row opens
     a new read-only `ProductQuickViewDialog` (photo, name, product ID, SKU, cost price,
     selling price, tax info, size) with a "View full product" button that closes the
     quick-view and opens `editProductDlg` in view mode.
   - Ad-hoc/unmatched line items (no `productId`): row stays fully non-tappable, no visual
     affordance.
   - `AvatarBadge` (used in 13+ places app-wide) will get one new **opt-in** property
     (`enlargeOnTap`, default `false`) rather than a blanket change, to avoid silently
     breaking click behavior on unrelated screens (staff/notifications/sales rows etc.) that
     already nest it inside a clickable `ListCard`.
   - Animation: simple scale+fade from center (~0.6× → 1.0×, existing `BottomSheet` easing/
     duration conventions), not a true origin-anchored "grow from the tapped thumbnail"
     transition — recommended for lower risk given zero existing precedent for either in this
     codebase; Taher agreed.
   - Verification: on-device test-plan doc (this is view/animation-heavy work, not meaningfully
     covered by `qmltestrunner`).
   - Design presented and approved by Taher.
6. Taher asked to keep on-device test-plan docs in their own folder rather than mixed into
   `specs/`/`plans/`. Created `docs/superpowers/test-plans/` and moved:
   - `2026-06-19-on-device-test-plan-revenue-reconciliation.md`
   - `2026-06-21-custome-device-test-plan.md`
   - `2026-07-10-on-device-test-plan-tax-size.md`
   - `2026-07-11-on-device-test-plan-adjustment-reason.md`
   - `2026-07-11-p0-gateway-test-plan.md` (originally in `specs/`; Taher confirmed moving this
     one too despite it being a mixed unit-test/on-device plan tied to that feature's other docs)
   Found and fixed 4 stale path references to the moved files in older plan/spec/checkpoint
   docs (`2026-07-10-product-tax-export-size-field.md`/`-CHECKPOINT.md`/`-design.md`,
   `2026-07-11-product-adjustment-reason.md`) so no dead links remain. Bare filename mentions
   in prose (no path prefix) were left as-is — harmless.

## Open decisions
- None outstanding on design. Next: write the spec doc.

## Next steps
- Write spec to `docs/superpowers/specs/2026-07-13-enlarge-photo-and-order-detail-design.md`,
  self-review it, then ask Taher to review before moving to the `writing-plans` skill.
- On-device test plan for this feature will go in the new
  `docs/superpowers/test-plans/` folder once implementation is planned.
- Nothing committed yet — branch creation, checkpoint archive/creation, and the test-plans
  reorg (5 moves + 4 stale-link fixes) are all local-only, pending Taher's go-ahead to commit
  this housekeeping (separately from the feature work itself).
