# Product picker v2, slice S5c: touch targets, Back route, in-stock double toggle (2026-11-20)

Branch `feat/2026-11-20-picker-s5c-touch-back-toggle`, cut from `main` @ `0ce6534` (PR #202, S5b, merged). Closes or reframes KNOWN-ISSUES 8, 19a, 19b, 24a, 28b. Skill 177. Test plan: `test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5c checks 120 to 133).

## 1. Scope
In: (A) cart-row steppers in New Order and Edit Order become 48 dp touch targets; (B) the Android Back key with the product sheet up; (C) the in-stock row cannot toggle twice for one TalkBack gesture.
Out (S5d, S5e, KNOWN-ISSUES 70 to 72): measuring perf, TalkBack of the whole sheet, themes, font scale, other small targets.

## 2. What the code showed (before any design)
- **F-A, Back.** KI 8 assumed Back reaches `BottomSheet`'s `Keys.onBackPressed`. The app does not route Back that way: `Main.qml` sets `onBackButtonPressedGlobally: app._handleBack()` and `backButtonAutoAcceptGlobally: true`, and `_handleBack` closed the FIRST open entry of `_allDialogs()`. The product sheet is not in that list, but its parent (`newOrderDlg`, `orderDetail`) is. So with the sheet up and a draft, Back could close the dialog UNDER the sheet and lose the draft with no "Discard?" question. KI 8's "does nothing rather than lose data" was an unproven guess, and the opposite is at least as likely. Not reproduced (no device): treat as a probable real bug.
- **F-B, width.** Edit Order's price field (64) and three 28 dp buttons live in the `ListCard` trailing slot. At 48 dp that is about 250 dp beside a title on a 360 dp phone: the title would be about 20 dp wide.
- **F-C, TalkBack.** The steppers have no `Accessible.name` ("unlabeled button").

## 3. Decisions (defaults taken; veto in the PR)
| # | Question | Taken | Why / what it costs | Rejected |
|---|---|---|---|---|
| D1 | Where does the New Order stepper go at 48 dp | Own row under the name, right aligned | Name keeps its full width. Costs about 56 dp of card height per line. Same pattern as the sheet's row (S2). | Same row: name column drops from about 162 to about 116 dp on 360 dp, long names cut at about 13 characters. 44 dp same row: 8 dp back, still squeezed, and off the sheet's 48. |
| D2 | Edit Order controls | Own row under the `ListCard`: price field, stepper, remove | The only layout that fits 48 dp targets. Costs about 50 dp per line. Not seen on a screen. | Keep in the trailing slot at 40 dp: title still crushed. Hit area bigger than the frame without room: neighbours overlap. |
| D3 | Look | Frame stays 32 dp, target 48 dp (8 dp ring) | The cart looks as light as before. A 3-digit quantity (about 30 dp) may overlap the ring, never a button. | 48 dp painted frames: heavier cart. |
| D4 | Back route | The router asks the open dialog first (`consumeBack()`), the dialog asks the sheet (`handleBack()`); the sheet's own key handler also calls `handleBack()` (opt-in `routesBack`) | Works whichever route Android uses. | `Shortcut { sequence: "Back" }`: parse and delivery unverified, could double fire. Add the sheet to `_allDialogs()`: Main cannot see a sheet nested in a dialog. Rely on focus: that is the unproven path. |
| D5 | One press, two routes | 400 ms repeat gate inside `handleBack` | Without it a press seen by both routes asks "Discard?" then dismisses it (net nothing). Costs: a real second Back inside 400 ms is dropped, which is the safe side. | No gate: the double-fire case above. |
| D6 | Back while "Discard?" is open | Answers it "keep picking" | Android convention for a dialog. | Ignore it: dead key. Close everything: loses the draft. |
| D7 | Back while the sheet is busy | Swallowed (nothing, and not passed to the dialog below) | Same rule the router already applies to a busy dialog. | Pass through: would close the dialog under a commit. |
| D8 | In-stock double toggle | 250 ms repeat gate on the two accessibility actions only; the touch tap is not gated | I believe Qt Android sends only the press action, so this is cheap insurance for a case that may not exist. A real fast double tap still flips twice. | Drop one of the two handlers: loses a role path on a platform we have not seen. Do nothing: unknown. **Honest note:** this one is optional; drop it if you prefer less code. |
| D9 | `BottomSheet` contract | `routesBack` (default false): false keeps Back = `requestClose()`; true emits `backRequested()` | Opt-in, so a future `guardClose` sheet cannot end up with a dead Back. S5C-12 fails if a second `guardClose` sheet appears without a decision. | Change the default: silently dead Back for any other owner. |

## 4. Files
New: `qml/helper/CartStepperGeometry.js`, `qml/helper/PickerGuards.js`, `qml/helper/BackRouter.js`, `qml/components/CartStepper.qml`; tests `cartStepperGeometry.test.js` (CSG-01..07), `pickerGuards.test.js` (PGD-01..11), `backRouter.test.js` (BR-01..11), `pickerS5cWiring.test.js` (S5C-01..14), twins `tests/tst_CartStepperGeometry.qml`, `tst_PickerGuards.qml`, `tst_BackRouter.qml`.
Changed: `Main.qml` (`_handleBack` uses `BackRouter.route`), `BottomSheet.qml` (`routesBack`, `backRequested`), `ProductPickerSheet.qml` (`handleBack`, `_toggleStockA11y`), `NewOrderDialog.qml`, `OrderDetailDialog.qml` (CartStepper, `consumeBack`).
Guards changed ON PURPOSE (they pinned the old shape): EOW-23 (the `+` handler is now `onIncrement`), WIRE-18 (actions go through the gate), `main-back-uses-list` and its mutant, the S2f-3 `_handleBack` order check.

## 5. Evidence
RUN: new Node tests 43 (7 + 11 + 11 + 14), twins 29 cases (not run: no Qt in the sandbox, CI decides); functions suite 2033/2033 and scripts 1061/1061 after the sweep of edits. Hand mutants: 26 of the three helpers, 24 killed, 2 survivors: one redundant guard deleted (`windowMs <= 0` is implied by `now - lastAt < windowMs`), one equivalent (`typeof consumeBack === "function"`: a non-function throws and the try/catch gives the same answer; kept for readability). 15 of the QML sources, all killed.
NOT RUN: any QML, any layout, any device. The twins and the layout are unproven until CI and a device.

## 6. Risks stated up front
- Whether Felgo also delivers Back to the sheet's key handler is unknown; D5 makes either answer safe.
- `Date.now()` in the gate is wall clock: a backwards jump never swallows (PGD-04, S5C-09).
- The Edit Order row restructure is the largest unseen layout change in the slice.
