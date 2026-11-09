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
- (Fixed in session 2, see the addendum at the end.) `AddProductDialog`, `AddStaffDialog` and `NewOrderDialog` set `busy = true` with no `busyMessage`.
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

---

# Addendum, session 2 (same PR #190, 2026-11-09): busy card on Add Product, Add Staff, New Order + review sweep

**Covers:** `qml/pages/AddProductDialog.qml`, `qml/pages/AddStaffDialog.qml`, `qml/pages/NewOrderDialog.qml` (one constant `busyMessage` each), `functions/test/sheetBusyOverlay.test.js` (new, 10 tests).
**No server change, no deploy. The app was not built or run (standing rule); CI is the QML oracle.**

## Decisions (vetoable in the PR)
| # | Decision | For | Against |
|---|---|---|---|
| D-5 | A constant `busyMessage` on each of the three sheets (same as D-2) | Cannot go stale or empty on an early return; same shape as Restock | Wording says "a few seconds": a stalled network can hold longer (KNOWN-ISSUES) |
| | Rejected: overlay on every `busy` in `BottomSheet` | One central change | Every sheet changes, flash on sub-second saves, would also cover `StuckWritesSheet` |
| D-6 | `StuckWritesSheet` gets no overlay; `ProfileSettingsDialog` deferred | Stuck-writes `busy` is a modal lock while a confirm is open: an overlay would cover the list; Profile `busy` is `AuthService.busy`, shared with other flows | Profile saves still show only the button spinner |
| D-7 | One test file for the three sheets plus a repo-wide ratchet | A new sheet cannot forget the message; the ratchet already found two sheets a plain grep missed | Reads source text, so it pins shape, not pixels |
| D-8 | Wording kept in Restock's style ("... this can take a few seconds") | Consistent | Promises a duration; neutral "please wait" would be more honest offline. Taher to choose |

## 1. Unit tests (`sheetBusyOverlay.test.js`)
SB-1 each message present at the root, 60 characters or fewer, no braces, all three distinct. SB-2 BottomSheet's own `active:` expression evaluated with each real message, busy x message (4 combinations each). SB-3 ratchet: every root-`BottomSheet` file in `qml/` that turns `busy` on has a message or a reasoned `NO_OVERLAY` entry. SB-3b the `NO_OVERLAY` list is not stale (entry exists, is a root sheet, turns busy on, has no message, reason of 40 characters or more). SB-4 `AddProductDialog.trySubmit`: validation returns before `busy = true`, one `busy = true`, before the store call, and the store callback's first statement is `busy = false`. SB-8 no sheet writes `busyMessage` at runtime, declared once. SB-9 scanner sanity (the six known overlay sheets are found; turn-off lines are not turn-ons; a binding counts).

## 2. Functional (real function bodies in a `vm`)
SB-5 `AddStaffDialog` `onMemberOperationSucceeded`, `onAuthFailed` (reason and empty reason), `onErrorOccurred` (message and empty): each drops `busy` and `_provisioning` before any text, success closes, failures stay open. SB-6 `NewOrderDialog` `onOrderAdded`, `onOrderCreationFailed` (message and empty): drop `busy`, close or show the error; a stray answer while idle neither closes nor writes text.

## 3. Rules / E2E
None: view-only change.

## 4. Regression and monkey
SB-7 seeded monkey, 200 seeds x 40 steps over the NewOrder and AddStaff handlers (tap, tap, success, failure, error in random order, answers while idle): after any answer `busy` is false. Existing suites unchanged and green: functions 1290/1290 (1280 before + 10), `.github/scripts` 905/905, both run in the session.

## 5. Hand mutants (20, all killed)
No message on each sheet (3); empty message; message too long; duplicate message; product callback writes error text before `busy = false`; staff `onAuthFailed`, `onMemberOperationSucceeded`, `onErrorOccurred` keep busy (3); order `onOrderAdded`, `onOrderCreationFailed` keep busy (2); order handlers lose the idle guard (2); runtime `busyMessage` write; `BottomSheet` gate widened to OR; `StuckWritesSheet` gains a message (stale list); staff `_provisioning` kept on failure; product sets busy before validation; a new sheet with busy and no message. **20/20 killed** (`/tmp/mut.py`, not committed: each mutant is one `old -> new` text swap listed here).

## 6. Counts
Expected delta from this addendum: functions +10 (total +33 for the PR). QML, Rules, E2E: +0. Recount from the CI comment.

## 7. Review sweep (requesting-code-review, ponytail-audit, qt-qml-review)
Run inline (no sub-agent tool in this chat). Python linter of `qt-qml-review` on the five touched QML files: only style rules on untouched lines (the repo's own `id: dlg`, `var`, imperative field resets) and nothing on changed lines; not acted on. Findings and what was done are in the PR description and `KNOWN-ISSUES.md`: ratchet gap (fixed), ProfileSettings busy (deferred), no escape from a stalled busy (noted), ToastHost `y` binding (noted, device check D1), wording promise (D-8).

---

## On-device test plan, session 2 additions (Taher, needs a build of this branch)
**Prerequisites:** owner login; online and airplane-mode phases; one supplier.

### Happy path
| # | Action | Expected |
|---|---|---|
| S2-H1 | Add product with valid data, Save | Solid card over the sheet: spinner, "Adding product — this can take a few seconds", "Don't close the app or press back". Then it fades, toast "Product added" is above the closing sheet, product is in the list |
| S2-H2 | Add staff (name, role, login password), Save | Card "Adding staff and login — ...". Then toast "Staff added" above the sheet, sheet closes, person in the list and in Team Members |
| S2-H3 | New order with one product, Place order | Card "Placing order — ...". Then sheet closes, order in the list, stock as expected |
| S2-H4 | Restock still shows its own card (regression of D-2) | Unchanged |

### Negative
| # | Action | Expected |
|---|---|---|
| S2-N1 | Add product with an empty name, Save | Error text under the form, NO card (refused before busy), button usable |
| S2-N2 | Add staff with a weak password or an email that exists | Card, then it goes away and the red error text is READABLE (not hidden behind the card); sheet stays open and busy is off |
| S2-N3 | New order with a quantity above stock | Error text, no card |
| S2-N4 | Airplane mode, Add product, Save | Card, then the error "Could not add product — try again" readable; sheet usable; note how long the card stayed (D-8, KNOWN-ISSUES) |
| S2-N5 | Airplane mode, New order, Place order | Same: card, then "Could not create order — try again" readable; note the time |

### Edge cases
| # | Action | Expected |
|---|---|---|
| S2-E1 | While a card is up press Back, tap outside, tap Cancel, tap the X | Nothing closes; the sheet closes only after the answer |
| S2-E2 | Double-tap Save/Place order fast | One card, one record |
| S2-E3 | Add product with a photo chosen | Card, product added, photo queues as before |
| S2-E4 | Slow network (throttled data): Save | Card stays until the answer; note the longest wait seen. If it feels stuck, that is the KNOWN-ISSUES "no escape" entry |
| S2-E5 | Open Profile settings and save | No card (deferred, KNOWN-ISSUES); button spinner only |
| S2-E6 | Open the stuck-writes sheet (if any parked write) and tap Discard | Confirm opens, NO busy card over the list |

### Multiple scenarios
Add three products in a row, then two staff, then two orders: each shows its card once, each closes, no card is left behind on the next open. Fail one (airplane mode) between two successes: the next open starts clean (no card, no error text left).

### Monkey (manual)
2 minutes: open and close the three sheets at random, tap Save at random moments with valid and invalid data, toggle airplane mode twice, background and foreground the app while a card is up. No crash, no card stuck on a closed or reopened sheet, no unreadable error, no dead area.

### D1 (ToastHost, from the review)
Add a product with the soft keyboard open (type in the last field, tap Save without closing the keyboard). Watch the "Product added" toast: it must stay visible for its 5 s even though the keyboard closes with the sheet. If the pill vanishes or jumps down, KNOWN-ISSUES "ToastHost pill y" reproduced.

### Affected areas
| File | Automated coverage | Where to look on device |
|---|---|---|
| `qml/pages/AddProductDialog.qml` | SB-1, 2, 4, 8, 9 and 6 mutants | S2-H1, N1, N4, E2, E3 |
| `qml/pages/AddStaffDialog.qml` | SB-1, 2, 5, 7, 8 and 7 mutants | S2-H2, N2 |
| `qml/pages/NewOrderDialog.qml` | SB-1, 2, 6, 7, 8 and 6 mutants | S2-H3, N3, N5 |
| `qml/pages/StuckWritesSheet.qml`, `ProfileSettingsDialog.qml` (read only, in `NO_OVERLAY`) | SB-3, SB-3b | S2-E5, S2-E6 |
