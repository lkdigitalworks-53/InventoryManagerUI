# Plan: Row-level delete UI for Products and Orders

Spec: `docs/superpowers/specs/2026-08-30-product-order-delete-ui.md`

## Tasks (each its own commit)

1. **Icon token** — `qml/helper/Constants.qml`: add `"trash": IconType.trash`
   to `iconMap`. Distinct from the existing `"delete"` key, which is a
   full-color Twemoji SVG (used for activity/history entries) and can't be
   tinted — wrong fit for a small destructive row action that needs
   `Constants.danger` tinting.

2. **Product delete button** — `qml/pages/InventoryPage.qml`: add a
   trash icon-button to `ProductCard`'s bottom row, mirroring the existing
   Restock Rectangle+MouseArea idiom exactly (`mouse.accepted = true` to
   stop the tap reaching the card's own `onClicked`/`viewClicked`).
   `visible: card.canManage` (same gate as Restock — both require
   `canManageInventory`). Calls `card.deleteClicked()`, which is already
   wired all the way to `Main.qml`'s confirm dialog.

3. **Order delete button** — `qml/pages/OrdersPage.qml`: same idiom, added
   to the `ListCard` trailing `ColumnLayout` (next to price/status).
   `visible: root.canDeleteOrders` (already piped in from `Main.qml`).
   Calls `root.deleteOrderClicked(modelData.orderId)`.

4. **Conflict-message threading** — `qml/model/Gateway.qml`: add `action` as
   a 4th param to `mutationConflicted`, pass `item.action` at the emit site
   in `_send`. Additive — existing 3-arg listeners unaffected.

5. **Delete-specific conflict wording** — `qml/model/InventoryStore.qml`
   and `qml/model/OrdersStore.qml`: accept the new `action` param in
   `_onMutationConflicted`, branch the `Toast.show(...)` message when
   `action === "delete"`.

6. **Success toasts** — `qml/Main.qml`: add `onProductDeleted` /
   `onOrderDeleted` to the existing `Connections { target: logic }` block,
   next to `onErrorOccurred`.

## Test plan

See `docs/superpowers/test-plans/2026-08-30-product-order-delete-ui.md`.
QML test files written to convention, not executed in-session (no Qt
toolchain in this sandbox per standing rule) — coverage claims in the test
plan describe what's covered structurally, not a measured percentage; that
confirmation happens on Taher's machine or CI.

## Order of operations

Constants → ProductCard → OrdersPage → Gateway signal → store handlers →
Main.qml toasts → tests → test plan → checkpoint → commit each task →
push.
