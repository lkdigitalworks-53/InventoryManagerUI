# Product Picker v2, Slice S2: Sheet Component (dormant) Plan

**Goal:** Build the searchable picker sheet with a quantity stepper per row, and everything it needs, without wiring it into any dialog. Nothing instantiates it, so the app behaves exactly as before. S3 (New Order) and S4 (Edit Order) wire it in.

**Design:** `docs/superpowers/specs/2026-11-03-product-picker-v2-design.md` (approved, D1 to D7). **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md`. **Branch:** `feat/2026-11-04-picker-s2-sheet-component`, cut from `main` @ `415b11c` (PR #185 merged).

## Decisions taken in this slice (vetoable in the PR)

| # | Decision | Why |
|---|---|---|
| S2-D1 | A new pure helper `qml/helper/PickerSheetModel.js` sits between the S1 helpers and the sheet. `build(input)` returns the rows, hidden count, reconciled draft, totals, commit gate and empty-state text in one call. | The design listed only `PickerRowGeometry.js` as a new helper, but a sheet that decides "what rows, what words, what is the draft worth" in QML would put the decisions where nothing can test them (Skill 83). Moving them costs one file and lets 28 Node cases and a seeded monkey cover them. |
| S2-D2 | View rows are flat (strings, numbers, booleans, every key always present) and kept in a `ListModel`. When the new rows list the same products in the same order the sheet updates the rows in place (`PickerSheetModel.sameOrder`), otherwise it rebuilds and, only when the person changed the search, a chip or the toggle, scrolls to the top. | Replacing a JavaScript-array model on every stepper tap resets the list to the top and recreates every delegate (Skill 83, the gallery model). |
| S2-D3 | The row is two lines: photo and text on top, pills on the left and the stepper on the right below. The pills wrap to their own line when less than 64 units remain beside the stepper. | A stepper beside the name competes with the name for width at large system fonts. The stepper below it gets three 48-unit targets, two 8-unit gaps and a field wide enough for six digits at every phone width and font scale. |
| S2-D4 | `BottomSheet` gets two opt-in properties, `scrollBody` (design D5) and `guardClose`. `guardClose` makes the X, Cancel, a tap outside, Escape and the Back key ask the owner through `closeRequested()`; the owner answers with the "Discard N items?" question (design D1). Defaults leave the other 20 sheets untouched, and a source pin (WIRE-04) fails if any other file sets either property. | Design D1 requires the discard question on every close path. `Popup`'s own tap-outside close cannot be intercepted, so `closePolicy` becomes `NoAutoClose` while `guardClose` is on and the modal overlay forwards the tap. |
| S2-D5 | The sheet knows no store. The dialog passes `products`, `hooks`, `orderLines` and a `revision` integer; the sheet re-reads when any of them changes. | One place (the dialog) owns the three stock formulas (design section 3), and the sheet stays testable by reading. |
| S2-D6 | The quantity field commits while typing, clamps at once (the field shows the clamped number), and an empty field means "no change" until the person leaves it, when it shows the draft quantity again. | The footer total and the Add button must follow what the person typed, and a number the draft refused must never stay on screen. |

## Files

| File | Responsibility |
|---|---|
| `qml/helper/PickerRowGeometry.js` (create) | Touch targets, gaps, field width, pill wrapping, row height. |
| `qml/helper/PickerSheetModel.js` (create) | `build`, `categories`, `hiddenNote`, `reasonTextFor`, `sameOrder`, `priceOf`. |
| `qml/components/ProductPickerRow.qml` (create) | Paints one row from the model roles and the geometry; asks through `stepRequested` and `qtyTyped`. |
| `qml/components/ProductPickerSheet.qml` (create) | State (query, chip, toggle, draft), the list, the footer, commit and the discard question. |
| `qml/components/BottomSheet.qml` (modify) | `scrollBody`, `guardClose`, `closeRequested`, `requestClose`. |
| `functions/test/pickerRowGeometry.test.js`, `pickerSheetModel.test.js` (create) | Node cases `GEOM-01..12`, `SHEET-01..26` (with `b` variants). Their QML twins `tests/tst_PickerRowGeometry.qml`, `tst_PickerSheetModel.qml` are derived. |
| `functions/test/pickerSheetWiring.test.js` (create) | `WIRE-01..16`: source pins for the Felgo layer and the dormancy of the new files. |
| `functions/test/pickerDormancy.test.js`, `testSupport/pickerTwin.js` (modify) | Allow-list the S2 files, register the two new twins. |

## Not in S2

Wiring into either dialog (S3, S4); the dry run of `CompletionPlan` before "Add to order" (S3, see KNOWN-ISSUES); `qml/helper/qmldir` entries (the helpers are imported by relative path, as the S1 helpers are, so none is needed); a build or run of the app (Taher decides).

## Verification

Node: `node --test functions/test/picker*.test.js`. Mutants: a script kept out of the repo, re-run after every test change. QML twins and the Felgo layer: CI and the on-device plan only.
