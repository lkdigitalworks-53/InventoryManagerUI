# Test plan — PR #84 arrangement rework: Flow grid → horizontal filmstrip, rounded-corner mask

**Branch:** `feature/2026-09-21-product-photos-firebase-storage` (PR #84). **Date:** 2026-09-29.
**Status honesty:** NOTHING was run in the sandbox (no Qt toolchain, standing instruction). Every
test below is written to repo conventions; CI is the proof. Coverage is NOT 100%:
`ProductPhotoGallery.qml` and `RoundedThumb.qml` import Felgo (or are only reachable from a file
that does) and cannot load under `qmltestrunner` — see "Affected areas" below. What IS covered is
the pure-logic pieces the redesign relies on, plus a stand-in that reproduces the real
RowLayout+ListView composition at the gallery's own sizes.

## Root cause (why this round exists)

| # | Symptom (Taher, testing PR #84, 2026-09-29) | Root cause | Status |
|---|---|---|---|
| 1 | "Photos goes out of the rectangle" | `clip: true` on a `Rectangle` clips children to the axis-aligned bounding box, not the `radius`. The tile's `Image` (`PreserveAspectCrop`, filling the box) is a plain rectangle, so its square corners sit past the rounded frame's arc at all four corners. The 2026-09-28 Flow-wrap fix solved the *different* overflow bug (tiles running off the right edge) but never touched this — no code before this round attempted rounded-corner clipping at all. | fixed — `RoundedThumb.qml`, `MultiEffect` mask (on-device/visual verification only, see below) |
| 2 | "I don't like the UI arrangement of the photos" | Wrapping grid of uniform squares reflowing into uneven rows doesn't match the established pattern for multi-photo product management (a horizontal filmstrip with a prominent first/cover tile) and grows vertically as photos are added, pushing the rest of the edit form down. | addressed — horizontal filmstrip, cover marked with a small corner badge instead of a full-width banner |

## 1. Unit tests (pure logic, mirrors of `ProductPhotoGallery.qml`'s own functions)

`tests/tst_PhotoGalleryLayout.qml`: `buildCombined` (mirrors `_refreshAll`'s array construction) —
confirmed photos first with cover flagged on index 0, exactly one cover for counts 1 through 10,
cover moves to the new first photo after the caller drops the old one, queued items appended after
every confirmed photo, queued-only (no confirmed photos), fully empty. `rowHeight`/`hasFailedQueued`
(mirrors the `_rowHeight`/`_hasFailedQueued` properties) — no failed items, one failed item,
multiple failed items still only add one row's worth of height (it's a boolean, not a count, since
failed tiles sit side by side in the same row), empty queue.

## 2. Functional / layout (QML stand-in, CI)

`tests/tst_PhotoGalleryLayout.qml`: reproduces the gallery's own `RowLayout { ListView
Layout.fillWidth ; Rectangle Layout.preferredWidth }` composition at real tile sizes (72px, 8px
spacing) — the `+` tile stays fully inside the container width regardless of photo count (1 vs 9),
its position never changes as the count changes (it's allocated by the layout, not by scroll
position), the `ListView`'s `contentWidth` genuinely exceeds its `width` once there's more content
than fits (proving it's scrolling, not wrapping or pushing anything off), read-only hides it, a
narrow (160px) container still keeps it inside, and a 100-iteration monkey test over random photo
counts / visibility / container widths (180–339px) never finds it outside the container.

## 3. Rules / e2e / regression

No rules, function, or e2e change — this is a pure QML presentation change over the same
`photoIds`/`PhotoQueue` data the existing store logic already covers. Regression: existing
`tst_PhotoQueue`, `tst_PhotoUrl`, `tst_PhotoQueueLogic`, `tst_InventoryStore_photoIds`,
`test/e2e/tst_ProductPhotosE2E.qml` must stay green — none of them reference gallery-internal
structure (`ProductPhotoGallery.qml` is only embedded once, in `EditProductDialog.qml`, and that
embed's own properties/signals — `productId`, `photoIds`, `editable`,
`addPhotoRequested`/`removeFailed` — are unchanged).

## 4. Affected areas (file-by-file)

| File | Change | Automated coverage | On-device only for |
|---|---|---|---|
| `qml/components/ProductPhotoGallery.qml` | Rewritten: Flow → RowLayout+ListView+pinned add tile, combined-array model, corner cover badge | Logic/layout mirrored in `tst_PhotoGalleryLayout.qml` (Felgo import blocks direct load) | Real rendering, scroll gesture, spinner/failed states, remove/cover-badge visuals |
| `qml/components/RoundedThumb.qml` (new) | `MultiEffect` rounded-corner mask, wraps an `Image` | None — no pure-logic surface, and only reachable from a Felgo-importing file | Whether the rounded mask actually renders (this is the whole point of the change); watch the console for any `QtQuick.Effects`/shader warnings on first run |
| `qml/pages/EditProductDialog.qml` | No change | n/a (existing coverage unaffected) | n/a |
| `README.md`, design spec | Docs updated to match | n/a | n/a |

## 5. On-device (owner)

**Happy**
- [ ] Product with 3+ photos: no square corner visible past the rounded tile frame, on any tile.
- [ ] Cover tile shows a small star badge, top-left, on the first tile only; no full-width bottom banner.
- [ ] Photos fit within one row and scroll horizontally past ~4–5 tiles (phone-width dependent); nothing wraps to a second row.
- [ ] The `+` tile is visible and tappable without scrolling, at every photo count from 0 to 9.
- [ ] Add a photo until 10: `+` tile disappears exactly at 10.

**Negative**
- [ ] Airplane mode + add photo: spinner tile scrolls with the strip like any other tile, resolves in place.
- [ ] ~~Failed upload: red-bordered tile with a warning icon, Retry/Discard row below, tile widened to 160px.~~ **Superseded 2026-09-29** by `2026-09-29-photo-gallery-failed-tile-actions-test-plan.md`: Retry/Discard are now inside the normal 72dp tile.
- [ ] Remove the cover photo: badge moves to the new first tile; smooth removal animation, no flash/jump.

**Edge cases**
- [ ] Rotate / resize (desktop window narrow ↔ wide): the `+` tile stays put; the scrollable region just gets narrower or wider.
- [ ] Product with legacy `photoUrl` only (no `photoIds` yet): unaffected — same "Sync old photo" affordance as before.
- [ ] Read-only role (no edit): no remove buttons, no `+` tile, strip still scrolls to view all photos.
- [ ] Exactly 1 photo, exactly 10 photos: no layout glitch at either boundary.

**Multi-scenario / monkey**
- [ ] Add 3 photos in quick succession with the dialog open: each appears via the enter animation, in order, no duplicates, no stuck spinner.
- [ ] Scroll the strip while a photo is mid-upload: spinner keeps running, doesn't reset or jump.
- [ ] Mash `+` / remove / Retry / Discard on a 6-photo product: no crash, no stuck spinner, no tile left behind.
- [ ] Open product A, add a photo, close, open product B immediately: B's strip never shows A's photos (regression check on the existing `_refreshAll` reactivity, now combined-model rather than two Repeaters).

**If corners still look square on-device**
- [ ] Check the console for a `QtQuick.Effects` / shader compile warning on first launch — if present, the Qt install is missing the `qtshadertools` module (CI's `qmltestrunner` job never exercises this file at all, Felgo-gated — see "Affected areas" — so this is genuinely first-verified on your machine).

**Round 5 addendum (2026-09-29):** the first on-device check found no photo at all, not just square
corners — `visible: false` on the source/mask items wasn't enough to feed `MultiEffect` (no
scenegraph node = nothing to sample); fixed with `layer.enabled: true` on both, see CHECKPOINT.md
round 5 and SKILLS.md Skill 80. Re-check the "Happy" section above (corners AND that a photo shows
at all) rather than assuming Bug 1 alone.
