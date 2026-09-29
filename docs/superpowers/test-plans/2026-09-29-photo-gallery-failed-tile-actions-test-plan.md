# Test plan — photo gallery failed tile: in-tile Retry / Discard redesign

**Branch:** `feature/2026-09-29-photo-gallery-retry-discard-redesign` (stacked on PR #84).
**Spec:** `docs/superpowers/specs/2026-09-29-photo-gallery-failed-tile-actions-design.md`.

## What was genuinely run vs only written (read this first)

- **Run for real in the authoring sandbox:** a throwaway Node harness over the pure math in
  `qml/helper/FailedTileGeometry.js` (pragma line stripped): 200,000 random (tile, dp-scale) cases —
  0 overlap/bounds violations; design-tile numbers exact; scrim contrast min 5.02:1, chip 3.25:1; a 30%
  scrim fails the 4.5 check (so the check bites). Not committed as a mirror.
- **Written, NOT run here:** every `tests/*.qml` below (no Qt toolchain in the sandbox, standing
  instruction). CI (`qml-tests` job) is the proof.
- **Never runnable in CI:** `FailedTileOverlay.qml` and `ProductPhotoGallery.qml` import Felgo-provided
  `dp()/sp()/Icon` — rendering, gradient, press feel and real taps are on-device only (section 5).

## 1. Unit tests (pure logic) — `tests/tst_FailedTileGeometry.qml`, 22 tests

- Design tile 72/1 exact numbers (retry 36 @ 18,28; discard hit 28 @ 44,0; chip 22).
- Retry horizontally centred and discard chip centred in its hit square, at dp scales 1–3.5.
- **Hit boxes never overlap** at the design tile for every dp scale; everything stays inside the tile.
- Touch-target floors (retry ≥ 36, discard ≥ 28, WCAG ≥ 24) at tiles 72–200.
- Larger tile keeps target size and centres retry vertically; mid-size tile (80) pushes retry down to
  clear Discard; smaller tile (36, 1) scales proportionally and stays disjoint.
- Negative: 0, negative, NaN, Infinity, undefined, null, string, object for tile size and for unit →
  zero-size rects, never throws.
- `overlayMode`: confirmed → none (even with a stray `failed` state); queued+failed → failed;
  enqueued/uploading/retrying → busy; missing/unknown/wrong-case state → busy (never failed); unknown
  kind → none.
- Contrast: white on scrim ≥ 4.5 over every grey backdrop 0–255; worst case is white; a 30% scrim
  fails; white glyph on chip ≥ 3 over every backdrop.
- Monkey: 1000 deterministic pseudo-random (tile, scale) cases keep every invariant; every
  kind/state pair returns only a known mode and `failed` only for queued+failed.

## 2. Functional / layout (QML stand-in) — `tests/tst_PhotoGalleryLayout.qml`, 16 tests

- Replaced the four `test_row_height_*` tests (they pinned the OLD +48dp growth) with four composition
  tests that pin the NEW invariant: mixed failed/normal models keep 72dp tiles, 72dp height and
  `5×72+4×8` content width; all-failed equals all-normal; empty and single-failed rows; monkey over
  60 random state mixes. Unchanged: combined-array ordering/cover tests, fixed `+` tile tests.

## 3. Rules / e2e / regression

- Firestore/Storage rules, Cloud Functions, E2E: **not affected** (UI only; no rules, function or
  queue semantics changed). No new tests there.
- Regression: `tst_PhotoQueue.qml`, `tst_PhotoQueueLogic.qml`, `tst_PhotoUrl.qml`,
  `tst_InventoryStore_photoIds.qml` must stay green untouched — retry/discard behaviour is unchanged.

## 4. Affected areas

- `qml/components/ProductPhotoGallery.qml` (delegate, sizing), new `qml/components/FailedTileOverlay.qml`,
  new `qml/helper/FailedTileGeometry.js`, `qml/helper/Constants.qml` (`retry` icon).
- Anywhere the gallery is embedded (Edit Product dialog, and Add Product if it uses the gallery).
- Older plan `2026-09-29-photo-gallery-filmstrip-rearrange-test-plan.md`: its "failed tile is 160px wide
  with a Retry/Discard row below" on-device line is superseded by this plan.

## 5. On-device test plan (owner)

**Happy path**
- [ ] Airplane mode, add a photo, wait for it to give up: tile stays 72dp, red 2px border, dark scrim over
      the photo, gradient Retry circle centred low, small frosted × top-right. Neighbour tiles do not move;
      strip height does not change.
- [ ] Turn network on, tap Retry: circle visibly shrinks on press, tile flips to spinner, photo uploads and
      becomes a normal tile.
- [ ] Tap × on a failed tile: tile disappears with the normal removal animation; local file gone.

**Negative**
- [ ] Retry while still offline: goes back to spinner, eventually returns to the failed overlay.
- [ ] 11th photo (server photo limit): fails; delete another photo; Retry now succeeds.
- [ ] Oversized file (if reproducible): fails; Retry fails again (known, follow-up); Discard works.

**Edge cases (incl. multi-scenario / monkey)**
- [ ] Two or three failed tiles in one strip: all 72dp, targets not confused between neighbours.
- [ ] Failed tile scrolled half off-screen, then Retry: no crash.
- [ ] Very bright and very dark photos: Retry ring and × visible, scrim keeps glyphs readable.
- [ ] System font size Large, and a small-screen phone: targets still tappable, no overlap.
- [ ] Mash Retry / Discard / `+` / remove-cover on a 6-photo product: no crash, no stuck spinner, no
      leftover overlay, no tile stuck in a half state.
- [ ] Try to hit Discard when aiming for Retry (thumb error rate): note how often; if high, size feedback
      goes into the follow-up (bigger tile).
- [ ] TalkBack: both controls announce as buttons with the names "Retry upload" / "Discard photo".

**Affected areas**
- [ ] Edit Product photo strip; Add Product (if it embeds the gallery); confirmed tiles' × badge and cover
      star unchanged; the fixed `+` tile still visible without scrolling.

**Regression**
- [ ] Round-3/5 fixes still hold: rounded corners on every tile, photos actually render, cover badge on
      first tile only.
- [ ] Sync/upload of a normal photo end to end unchanged.
- [ ] If the gradient or press scale looks wrong: check console for QML warnings on first open of a failed
      tile (Gradient inside a radius Rectangle is standard Qt 6; nothing exotic used).
