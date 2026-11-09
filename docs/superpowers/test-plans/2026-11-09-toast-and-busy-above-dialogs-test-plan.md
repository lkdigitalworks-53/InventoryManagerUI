# Test plan — Toasts drawn under dialogs, Restock busy overlay missing (device test after #188/#189)

**Branch:** `fix/2026-11-09-toast-and-busy-above-dialogs`, from `main` @ `eb6391b`. **Found:** on-device test of PR #188 and #189, 2026-11-09.
**Covers:** `qml/components/ToastHost.qml`, `qml/pages/RestockDialog.qml`, `functions/test/toastHostLayer.test.js` (new), `functions/test/restockBusyOverlay.test.js` (new).
**No server change, no deploy. The app was not built or run in this session (standing rule).**

## Root cause (read from code and from Qt's source, not guessed)
1. **Busy overlay.** `BottomSheet` turns its full-sheet `BusyOverlay` on only when `busy` is true and `busyMessage` is not empty. `RestockDialog._confirm` sets `busy` and never a message, so only the small spinner inside the Confirm button ran. `OrderDetailDialog` and `ImportPreviewDialog` do set a message, which is why they looked right.
2. **Toasts under dialogs.** Every dialog and sheet is a Popup, and Qt draws popups in the window Overlay. In Qt 6.8's `qquickoverlay.cpp` the Overlay has `z = 1000001`, above the whole window item tree. `ToastHost` is a normal item in that tree (z 999 only orders it among its siblings in `Main.qml`), so no value of `z` could ever put it above a popup. This is why it showed under every dialog, not only Restock.
The same Qt source answers the two safety questions of the fix: the Overlay **ignores** presses and touches that no popup claims (`handlePress` ends in `event->ignore()`), so a toast in it does not block the app; and the Overlay is **visible whenever it has a child item** (`itemChange`), which is why the pill is only in it while a toast shows.
Read from the Qt 6.8 branch of qtdeclarative; the Qt version Felgo ships was not checked.

## The change
1. `ToastHost.qml`: `readonly property Item _layer: QQC.Overlay.overlay`. `_showInternal` puts the pill in `_layer` (host if there is none yet), z 10000, and stops a slide-away still running. `_release()` (called when the slide-away finishes) hides the pill and returns it to the host. The pill is centred by an `x` binding because an anchor to `parent` does not survive a reparent.
2. `RestockDialog.qml`: `busyMessage: qsTr("Restocking — this can take a few seconds")` at the root. `BottomSheet` then shows `BusyOverlay` exactly while the sheet is busy.

## Decisions (vetoable in the PR)
| # | Decision | For | Against |
|---|---|---|---|
| D-1 | Pill in the Overlay only while a toast shows | Idle app never takes the "Overlay visible with a child" path; a mistake is limited to about 5 s | A reparent per toast |
| | Rejected: pill always in the Overlay | Simplest code | Overlay always visible and first to see every press; cannot be device-checked here, and an error would be app-wide |
| | Rejected: toast as a `Popup` | Native layering | A popup item takes presses in its area and changes focus and close rules; bigger rewrite |
| D-2 | `busyMessage` is a constant on `RestockDialog` | Cannot be stale, empty or skipped by an early return | None found |
| | Rejected: set at the tap | Same as the other sheets | An early return or a new path can leave it empty again |
| | Rejected: `BottomSheet` shows the overlay on every `busy` | One central fix for all sheets | Changes every sheet; a flash on sub-second saves |
| D-3 | Toast position unchanged | No design change in a bug fix | On a bottom sheet the pill lies over the lower part of the footer buttons (taps pass through it). A top-anchored toast while a dialog is open is a design call for Taher |
| D-4 | `slideDown.stop()` on each new toast | Without it a toast arriving during the previous one's slide-away was hidden when that slide finished (existing race, made worse by reparenting) | One more line in the function |

## Findings not fixed (for Taher)
- `AddProductDialog`, `AddStaffDialog` and `NewOrderDialog` set `busy = true` with no `busyMessage`: same missing overlay as Restock. Listed in `docs/superpowers/KNOWN-ISSUES.md`.
- The toast text is one unwrapped line; the longest toast ("Stock wasn't restored — ...") may overflow the pill. Existing; see device case E2.

## What was actually executed in the session (honest)
- **Node, not Qt.** `toastHostLayer.test.js` 17 tests, `restockBusyOverlay.test.js` 6 tests. Full `functions/` and `.github/scripts` suites: see the PR (recount from CI, do not trust this line).
- **Mutation check:** 19 hand mutants, all run against both new files plus `restockDialogConfirm.test.js`: no reparent; no fallback; no `slideDown.stop()`; release keeps the Overlay parent; release keeps opacity; fallback swapped; empty text not ignored; layer is not the Overlay; pill z 0; anchor back; finish no longer releases; Controls import dropped; slide started before the reparent; busyMessage removed; busyMessage empty; tap writes busyMessage; gate ignores the message; gate uses OR; a sibling declared after the overlay. **19/19 killed.**
- **Not run:** the dialogs, `ToastHost` and `BottomSheet` themselves (Felgo), CI, anything on a device. There is deliberately NO new QML test: none of the three files can load under `qmltestrunner`, a stand-in would test the stand-in.

## 1. Unit tests
| Kind | Cases |
|---|---|
| `ToastHost._showInternal` / `_release` real bodies (`toastHostLayer.test.js`) | TL-1 into the Overlay, in order (stop slide, reparent, slide up, timer); TL-2 no Overlay yet: pill stays in the host, null and undefined; TL-3 empty, null, undefined, 0, false text: nothing happens; TL-4 release: hidden and back in the host; TL-4b release when idle, twice; TL-5 a new toast during the slide-away is not hidden by its finish; TL-5b without a new toast the finish releases; TL-6 Overlay appears late then goes away: never parentless; TL-6b two toasts in a row |
| Gate and message (`restockBusyOverlay.test.js`) | BO-1 message present, 60 characters or fewer, no braces; BO-2 BottomSheet's own gate expression evaluated for busy x message (4 combinations) and for the Restock case |

## 2. Functional (Node, real function bodies, fakes)
`_showInternal` and `_release` are cut out of the `.qml` with `extractFunction` and run in a `vm` with a fake pill whose `parent` is a setter that logs every assignment, fake animations (`slideDown` can be "running" and "finish" later) and a fake Overlay. TL-7 monkey: 3000 random operations (show, empty show, release, Overlay present or gone, slide-away start, slide-away finish) with a fixed seed; after each, the parent is the host or the Overlay, a shown toast is lit and in the right layer, a release leaves it hidden in the host.

## 3. Rules / E2E
None. View-only change; nothing reaches Firestore rules, functions or the emulator.

## 4. Regression (automated, source shape)
TS-1 Controls imported as `QQC`; TS-2 `_layer` is `QQC.Overlay.overlay`; TS-3 slide finish calls `_release` and nothing else sets opacity 0; TS-4 pill centred by `x`, no anchor; TS-5 pill z is at least 1000; TS-6 exactly one `ToastHost` in `Main.qml`, driven only by the `Toast` singleton; TS-7 no popup root in the tree (more than 20 files scanned) sets a root `z` that could out-rank the pill. BO-3 `BusyOverlay` is the last child of the sheet content, after and outside the layout; BO-4 the tap never writes `busyMessage`; BO-5 `busy = true` once, before `InventoryStore.restock(`, early refusals return before it; BO-6 the other overlay users and the `BottomSheet` properties are still there. Existing suites unchanged and must stay green: `restockDialogConfirm` (18), `restockSurface`, `qmlHelperImports.guard`, `qmlTreeResolution.guard`.

## 5. Counts
Recount from the CI comment on the PR after the push. Expected delta: functions +23 (17 + 6). QML, Rules, E2E: +0.

---

## On-device test plan (Taher, needs a build of this branch)
**Prerequisites:** owner or admin login; a product with stock; one supplier; the app online (and airplane mode for N5). Use a phone, not only the desktop build: touch is where the Overlay behaviour matters.

### Happy path
| # | Action | Expected |
|---|---|---|
| H1 | Inventory, open a product, Restock, Confirm with quantity 10 | A solid card covers the sheet: spinner, "Restocking — this can take a few seconds", "Don't close the app or press back". Then the card fades, a toast "Restocked +10 units" is drawn ABOVE the closing sheet and is fully readable, the sheet closes, stock is +10 |
| H2 | Restock, cost "abc", Confirm | Toast "Unit cost is not a valid amount" is drawn ABOVE the open sheet; no busy card (refused before busy); sheet stays usable |
| H3 | Provoke a toast from each: Add product (empty name), New order, Add staff, Manage categories (duplicate name), Order detail save, Sign-out sheet, a confirm dialog (delete), an alert dialog | Every toast is above its dialog or sheet, never under it |
| H4 | With no dialog open (Inventory page) trigger a toast (for example Back on Home: "Press back again to exit") | Toast appears in its usual place, above the tab bar, as before |
| H5 | No toast, no dialog: tap tabs, product cards, the search field, scroll lists for a minute | Everything responds, nothing is dead or delayed (regression check for the Overlay) |
| H6 | While a toast is on screen with no dialog open, tap a button or tab that is under or near the pill | The tap works; the toast does not swallow it |

### Negative
| # | Action | Expected |
|---|---|---|
| N1 | Tap Confirm with a bad cost twice in a row, quickly | The second text replaces the first; the pill is not cut short by the first one's timer |
| N2 | Trigger a toast, then open a dialog while it is still showing | The toast stays visible, above the dialog, and leaves on time |
| N3 | Wait for a toast to leave, then open a dialog | No leftover pill or ghost strip above or under it |
| N4 | Rotate the device while a toast shows (if the app allows it) | The pill stays at the bottom, centred; no crash |
| N5 | Airplane mode, Restock, Confirm | Busy card, then toast "Restock saved. Stock updates when it syncs" above the sheet as it closes |
| N6 | Staff (non-owner/admin) account | No Restock button; toasts from other sheets still above them |

### Edge cases
| # | Action | Expected |
|---|---|---|
| E1 | On a bottom sheet with a toast showing, tap the Cancel or Confirm button under the pill | The tap reaches the button (the pill lies over its lower part, D-3) |
| E2 | Trigger the longest toast you know ("Stock wasn't restored — a product on this order was deleted...") | Note whether the text fits the pill. If it overflows, that is the existing issue listed above, not new |
| E3 | Confirm a restock, then press Back or tap outside while the busy card shows | Sheet does not close while busy; closes after the answer |
| E4 | Type a quantity with the keyboard open, tap Confirm | Busy card covers the sheet; no crash; toast above on completion |
| E5 | Put the app in the background while a toast shows, return | Toast gone or finishing normally; no stuck pill |

### Multiple scenarios
Restock three products in a row (online): each shows the busy card, then a toast above the sheet. Then two offline, reconnect: each shows its own toast above whatever is open. Open and close five different dialogs with a toast triggered in each.

### Monkey (manual)
For 2 minutes: open and close dialogs at random, trigger toasts (bad inputs, Back on Home), switch tabs, background and foreground the app twice, toggle airplane mode twice. No crash, no pill stuck on screen, no pill under a dialog, no dead area on screen, taps always reach buttons.

### Affected areas
| File | Automated coverage | Where to look on device |
|---|---|---|
| `qml/components/ToastHost.qml` | 17 tests, 13 of the 19 mutants | every toast in the app: H1 to H6, N1 to N5, E1, E2, E5 |
| `qml/pages/RestockDialog.qml` | 6 tests, 3 of the 19 mutants | H1, H2, N5, E3, E4 |
| `qml/components/BottomSheet.qml` (read only, pinned) | gate and order pinned, 3 of the 19 mutants | busy card on the other sheets: Order detail save, Import: unchanged |
