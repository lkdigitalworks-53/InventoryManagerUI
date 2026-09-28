# Test plan — PR #84 device-test round 2: Cover label on every tile, dialog not refreshing, strip off-screen, no cover in list

**Branch:** `feature/2026-09-21-product-photos-firebase-storage` (PR #84). **Date:** 2026-09-28.
**Status honesty:** NOTHING was run in the sandbox (no Qt toolchain, standing instruction; Node code untouched).
Every test below is written to repo conventions; CI is the proof. Coverage is NOT 100%:
`ProductPhotoGallery.qml`, `EditProductDialog.qml` and `AvatarBadge.qml` import Felgo/app context and cannot load
under `qmltestrunner`. What IS covered is the store logic they stand on, plus stand-in experiments that prove the Qt
semantics the fixes rely on. **Bug 3 (no cover in the inventory list) has NO proven root cause** — see below.

## Root causes (systematic-debugging Phase 1 — from code, not from a running app)

| # | Symptom | Root cause | Status |
|---|---|---|---|
| 1 | "Cover" on every tile | The confirmed-tile delegate declares `required property string modelData` but not `index`. With any required property Qt stops injecting `index`; `visible: index === 0` throws a ReferenceError, the binding never runs, `visible` keeps its default `true`. Fix: `required property int index`. | fixed (CI experiment proves the pattern) |
| 2 | New photo not shown in the open Edit dialog; after reopen it appears | `EditProductDialog.photoIds` is a snapshot copied in `openFor()`. `PhotoQueue` removes the queued tile, then `applyPhotoIds` updates `InventoryStore` only; the dialog never re-reads. Fix: `Connections` on `InventoryStore.revisionChanged` -> `InventoryStore.photoIdsFor(productId)`. | fixed |
| 3 | No cover photo in the Inventory list | **Not proven.** The list reads `InventoryStore` live and uses the same URL builder as the gallery, so the code path looks right. Two candidates: (E1) the remote `_t.jpg` thumbnail fails to load on device on BOTH surfaces (rules / object missing / URL); (E2) list products lack `photoIds`. **Diagnostics added:** `Image.Error` now logs `[AvatarBadge] image failed to load: <url>` and `[ProductPhotoGallery] thumb failed to load: <url>`. | OPEN — needs the log line |
| 4 | 5+ photos run off-screen, + tile hidden, not scrollable | `RowLayout` never wraps or scrolls. Fix: `Flow` (max 10 photos -> <= 4 rows, + tile always visible). Chosen over a horizontal `Flickable` because that would keep the + tile hidden until scrolled. | fixed |

## 1. Unit tests (pure logic)

`tests/tst_InventoryStore_photoIds.qml` (CI): `photoIdsFor` — order, fresh copy, unknown product, empty store, doc
without / non-array / null `photoIds`, monkey ids (undefined/null/""/0/42/{}/[]); `applyPhotoIds` — sets list,
second upload keeps first (bug-2 sequence), replace-not-append, revision bump, unknown product no-op (no revision, no
ledger), other products untouched, non-array -> `[]`, input copied, add/remove ledger rows, no ledger without
`changedPhotoId` or with unknown kind, never enqueues a Gateway mutation, 10-photo list, 200-step monkey.

## 2. Functional / layout (QML stand-ins, CI)

`tests/tst_PhotoGalleryLayout.qml`: cover label on tile 0 only (5 photos, 1 photo, 0 photos, cover removed -> next
tile becomes cover); Flow wraps 5 / 9 tiles without leaving the width, + tile inside the width, row counts, 1-row
and empty cases, read-only empty height 0, 160-wide failed tile wraps, live container resize, 100-step monkey
(counts 0..9, widths 180..339). These prove semantics on a stand-in; they do not load the real gallery.

## 3. Rules / e2e / regression

No rules, function or e2e change. Regression: existing `tst_PhotoQueue`, `tst_PhotoUrl`, `tst_PhotoQueueLogic`,
`tst_InventoryStore_*` must stay green. Known gap: no automated test of the real gallery/dialog (Felgo import).

## 4. On-device (owner)

**Happy**
- [ ] Product with 3 photos: exactly ONE tile shows "Cover" (the first).
- [ ] Edit dialog open, add a photo: spinner, then the confirmed thumbnail appears IN PLACE, no reopen needed.
- [ ] Add photos until 5, 6, 10: tiles wrap to new rows, the + tile stays visible until 10, then disappears.
- [ ] Inventory list: product with photos shows its first photo as the avatar.

**Negative**
- [ ] Airplane mode + add photo: queued tile with spinner, resolves in place after reconnect with the dialog still open.
- [ ] Failed upload: red tile + Retry/Discard below it; the wide failed tile wraps to the next row instead of overflowing.
- [ ] Remove a photo (x): tile disappears; if it was the cover, the next tile becomes "Cover".

**Edge**
- [ ] Rotate / resize (desktop window narrow -> wide): rows re-flow, nothing clipped.
- [ ] Product with legacy `photoUrl` only: list still shows the legacy photo; "Sync old photo" still works.
- [ ] Read-only role (no edit): no x buttons, no + tile, photos still wrap.

**Multi-scenario / monkey**
- [ ] Add 3 photos in quick succession while the dialog stays open: all 3 appear, in order, no duplicates.
- [ ] Open product A, add photo, close, open product B immediately: B's gallery never shows A's photos.
- [ ] Mash + / x / Retry / Discard on a 6-photo product: no crash, no stuck spinner, no gap.

**Bug 3 diagnosis (do this first if the list cover is still missing)**
- [ ] Launch, open Inventory, capture the log. Send any `[AvatarBadge] image failed to load: <url>` line. Open that
      URL in a browser: 404 -> object/path/env mismatch; 403 -> Storage rules not deployed; loads fine -> not E1.
- [ ] No such line and still no cover -> E2; send a `console.log(JSON.stringify(product.photoIds))` result.
