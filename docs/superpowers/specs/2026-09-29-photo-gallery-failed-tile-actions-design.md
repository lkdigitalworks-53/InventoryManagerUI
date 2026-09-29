# Design — failed-upload tile: in-tile Retry / Discard (PR #84 follow-up)

**Date:** 2026-09-29. **Status:** approved by the owner in chat (layout A, Retry = filled brand gradient).
**Scope:** UI only. `PhotoQueue.retry()` / `discard()` semantics, `PhotoQueueLogic.js`, storage and rules are untouched.

## Problem

When an upload gives up, `ProductPhotoGallery.qml` widened that tile from 72dp to 160dp, grew *every*
tile's row 48dp taller, and drew two hand-rolled outlined text boxes ("Retry" blue, "Discard" red)
underneath. Owner feedback (device test): the buttons look bad. The real ugliness was the layout jump
plus flat boxes with no press feedback and no accessibility names.

## Options considered

| | A in-tile overlay | B capsule under tile | C tap tile → sheet |
|---|---|---|---|
| Layout shift | none | height jump stays | none |
| Retry effort | 1 tap | 1 tap | 2 taps |
| Explains the failure | no | no | yes |
| Cost | small | small | sheet wiring + tests |

**Chosen: A.** Only option that removes the jump *and* keeps one-tap retry. B keeps the jump (the main
complaint). C is safest for Discard but adds a tap to the most common action.

## Design

- Failed tile stays `tileSize` (72dp) square: no widening, no strip-height change. Removed from the
  gallery: `_hasFailedQueued`, `_failedExtra`, `_rowHeight`, the Retry/Discard `RowLayout`, the centred
  warning icon.
- New `qml/components/FailedTileOverlay.qml` (signals `retryRequested()`, `discardRequested()`),
  instantiated by a `Loader { active: tile.isFailed }` in the delegate.
- Scrim: slate-900 @ 62% over the local thumbnail, inset to match `RoundedThumb`'s radius. Translucent
  fill, **not** live blur (per-tile GPU cost, cannot be verified without running the app).
- **Retry:** 36dp circle, brand gradient (`Constants.gradPrimary`, indigo → violet), white refresh glyph,
  1px translucent white ring. Horizontally centred; pushed down only as far as needed to clear Discard.
- **Discard:** 22dp frosted chip (white 22% wash), white ×, top-right; touch target is the 28dp square
  around it.
- Tile border goes 2px `Constants.danger`. State is carried by shape (refresh + ×) and border, not colour
  alone. No caption text: 72dp cannot hold a caption plus two targets without overlap.
- Feedback: press scales the pressed control (0.92 / 0.9), transform only. `Accessible.role: Button`,
  names "Retry upload" / "Discard photo".
- Geometry, contrast and the none/busy/failed rule live in `qml/helper/FailedTileGeometry.js`
  (pure, headless-tested). Tiles smaller than 72 units scale everything down proportionally; larger tiles
  keep target size (retry centres vertically). Hit boxes never overlap at any size.
- Icon map: `retry` → `IconType.refresh` (existing glyph, already used by `restocked`).

## Trade-offs accepted (be honest about these)

- **Targets are 36dp / 28dp, below the 44–48dp mobile guideline.** Two targets in a 72dp tile cannot be
  bigger without overlap. Both clear WCAG 2.2's 24px minimum. Only a bigger tile (changes the whole
  gallery) fixes it; not proposed here.
- **Discard is one tap, no confirm, no undo** (unchanged behaviour). It deletes the only copy of the
  local file. Follow-up candidate: undo toast.
- **No failure reason on the tile.** `PhotoQueueLogic` sends 400/404/409/413 straight to `failed`.
  Retry is futile for 400/404/413 (same file / product gone) but valid for 409 (photo limit) once another
  photo is deleted — so Retry must stay visible. Showing the reason ("Too large", "Photo limit") is a
  follow-up.
- **Entrance fade-in dropped** from the approved draft: the gallery's model is a JS array reassigned on
  every `PhotoQueue.revisionChanged`, which resets the ListView, so a creation-time animation would
  replay on every unrelated queue change. Reasoned from the code, not observed on device.
- Touch-first (Android/iOS): no keyboard focus ring added. Revisit if the desktop build matters.

## Testing

See `docs/superpowers/test-plans/2026-09-29-photo-gallery-failed-tile-actions-test-plan.md`.
