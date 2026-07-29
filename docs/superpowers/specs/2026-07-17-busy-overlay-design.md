# Design: reusable "unmistakable busy" overlay for BottomSheet dialogs

**Date:** 2026-07-17
**Status:** Approved by Taher in chat. Not yet implemented.
**Scope:** Sub-project 1 of 2 from the "pending scenarios" brainstorm — import feedback/progress.
Sub-project 2 (counter/import-failure atomicity) is a separate, not-yet-started effort.

## Context

`ImportPreviewDialog` (and every other dialog extending `BottomSheet` — `AddStaffDialog`,
`AddProductDialog`, `RestockDialog`, `NewOrderDialog`) already gets a real button-level spinner
for free via `BottomSheet`'s `loading: root.busy` → `PrimaryButton`'s `BusyIndicator`. Confirmed
this exists before assuming a gap — an earlier claim in this session that there was "no progress
indicator at all" was wrong. The actual gap: for a genuinely multi-second bulk operation, a small
spinner on a button that's otherwise indistinguishable from its normal state isn't reassuring
enough, and nothing warns against navigating away mid-operation.

## Design

### 1. New component — `qml/components/BusyOverlay.qml`
Full-sheet, semi-transparent overlay. Centered, larger `BusyIndicator` than the button-level one.
Two lines of text below it: an optional custom line (dialog-supplied), and a fixed, always-shown
line — "Don't close the app or press back." Blocks taps on whatever's beneath it (the row list,
warnings, etc.) while visible.

### 2. `BottomSheet.qml`
- New property: `property string busyMessage: ""`.
- `BusyOverlay` is only shown when **both** `busy` is true **and** `busyMessage` is non-empty —
  deliberately opt-in. Quick dialogs (Add Product, Restock, Add Staff — all sub-second to
  low-single-digit-seconds after this session's batching fixes) keep their existing button-only
  spinner unless they explicitly set a message; any dialog can opt in later with one property.
- `closePolicy` becomes busy-aware: `busy ? QQC.Popup.NoAutoClose : <the existing default,
  currently implicit/unset>`. Today nothing overrides `closePolicy` at all, so tap-outside/escape
  *can* currently dismiss a dialog mid-operation — this closes that gap for every dialog using it,
  not just Import.

### 3. `Main.qml`'s `_handleBack()`
- Adds `importDlg` to the router's `dialogs` array — currently missing entirely, a separate
  pre-existing gap, fixed here as a prerequisite (blocking can't work for a dialog the router
  doesn't know about).
- Loop behavior changes: if the top-most open dialog is `busy`, the back press is swallowed
  entirely (no fallthrough to close something else or navigate to Home) — the busy dialog stays
  in the way, matching "prevent dismissal" rather than "warn and hope."

### 4. `ImportPreviewDialog.qml`
Sets `busyMessage: "Importing " + _effectiveCount() + " rows — this may take a moment"` at the
same point `busy = true` already gets set in `_apply()`.

## Explicitly out of scope
- Real step-by-step progress ("150 of 300") — considered and rejected per Taher's own choice;
  would need re-chunking the writes this session's batching fixes deliberately consolidated.
- Force-quitting the whole app (not just in-app navigation) — no in-app mechanism can prevent
  this; that's what sub-project 2 (counter/atomicity) exists to make safe, not this one.
- Retrofitting `busyMessage` onto the quick dialogs (Add Product/Staff/Restock) — the
  infrastructure supports it trivially later, but doing it now wasn't asked for and those
  operations are quick enough that the existing button spinner is plausibly sufficient.

## Files touched
`qml/components/BusyOverlay.qml` (new), `qml/components/BottomSheet.qml`,
`qml/Main.qml`, `qml/pages/ImportPreviewDialog.qml`.

## Testing
This is pure QML visual/interaction behavior (an overlay's visibility, a `closePolicy` binding, a
back-router's loop condition) — no pure JS logic exists here to Node-extract the way this
session's other fixes had. Verified via careful static reading and brace/structure checks only;
on-device confirmation (the overlay actually appears, back button is actually swallowed while
busy, tap-outside is actually blocked) is genuinely required and can't be substituted for here.

Ran the qt-qml-review lint script against all 4 files, filtered to only the lines actually
added/changed (same methodology as this session's earlier lint passes). All 14 filtered hits
checked individually rather than dismissed as a batch: confirmed each is either pre-existing code
that was only reindented (not textually changed) during the `contentItem` restructuring — the
drag-handle's plain `width`/`height`, the ScrollView's `clip: true`, one loose-equality flag that
turned out to already be strict (`!==`) on inspection — or a lint-tool default property-ordering
preference (attached `Layout.*` properties before plain properties) that contradicts this file's
own actual, consistently-followed convention throughout, including in code untouched by this
change. Nothing new introduced.

Applied `/qt-development-skills:qt-ui-design`, `/qt-development-skills:qt-qml`, and
`/qt-development-skills:qt-figma-component-generation` per Taher's explicit request while
designing `BusyOverlay.qml`: token-based sizing/duration throughout (no magic numbers), an
opacity fade using the project's own `Constants.durMed` token (reasoned explicitly about the
"avoid animating opacity on a complex subtree" caution from qt-qml — accepted here since this is
a one-shot, infrequent transition, not a continuously-running one), `Accessible.role`/
`Accessible.name` set, declaration-order z-stacking instead of an explicit `z` value, and
`qsTr("...").arg(...)` with a `%1` placeholder instead of string concatenation for the one
user-visible message that's built at runtime. No Figma source exists for this component (nothing
to extract), so the figma-generation skill's transferable conventions were applied (token-first
sizing, documented usage header) rather than its literal Figma-extraction workflow.

Re-reading `BottomSheet.qml`'s actual structure surfaced two things the original design (as
approved in chat) didn't account for: an X close button and a Cancel/secondary button, both
calling `close()` directly with no busy-guard at all — a bigger gap than "just back button and
tap-outside." Both are now guarded too, alongside the originally-discussed back-router and
`closePolicy` changes.
