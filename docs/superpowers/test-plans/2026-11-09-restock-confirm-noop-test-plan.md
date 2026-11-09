# Test plan — Restock dialog: the Confirm button did nothing (PR #183 device test)

**Branch:** `fix/2026-11-09-restock-confirm-noop`, from `main` @ `415b11c` (PR #183 merged). **Found:** on-device test of PR #183, 2026-11-09.
**Covers:** `qml/pages/RestockDialog.qml` (import, `_confirm()`), `functions/test/qmlHelperImports.guard.test.js` + `testSupport/qmlImportScan.js` (new), `functions/test/restockDialogConfirm.test.js` (new).
**No server change, no deploy. The app was not built or run in this session (standing rule).**

## Root cause (read from code, then proven by a failing test, not guessed)
`RestockDialog.qml` called `RestockFlow.costFromText(unitCostField.text)` on the first lines of the Confirm tap (added by the #183 review sweep, finding D-2) but never imported `RestockFlow.js`. `qml/helper/qmldir` declares only three singletons (`Constants`, `FormValidator`, `SafeArea`), so `import "../helper"` does not expose the helper `.js` files: each file must name the ones it uses, as `InventoryStore` does. The unresolved name throws `ReferenceError` BEFORE `busy = true`, so the person sees nothing (no spinner, no toast, no close) and the error exists only in the log.
Why no test saw it: `RestockDialog` imports the Felgo chain and cannot load under `qmltestrunner`; `InventoryStore.restock` (which has the import) and `RestockFlow.costFromText` (pure) both had full tests, and all of them passed.
Whole-tree check: the new guard (TREE-2) found exactly one file with this fault, `RestockDialog.qml`. No other QML file under `qml/`, `tests/` or `test/` uses a helper namespace it did not import.

## The change
1. **Root cause:** `import "../helper/RestockFlow.js" as RestockFlow` in `RestockDialog.qml`.
2. **Defence in depth (decision D-A, vetoable):** the Confirm body moved from the inline `onPrimaryClicked` handler into `function _confirm()`, now wrapped in one `try/catch`.
   - A thrown error is logged (`console.warn`) and shown ("Something went wrong. Check the stock before trying again"). The wording does not claim "nothing was saved": if the throw came after the operation was queued, the restock may exist, and the R4 latch then refuses a second one.
   - `busy` is cleared when the throw happened before the store answered, so the sheet cannot stay stuck (a busy sheet blocks Back, tap-outside and the close button).
   - An answer that already settled the tap (callback ran, then something threw) shows nothing extra.
   - Product id and quantity are captured once at the tap. Before, the callback re-read `qtyField.value` and `productId` when the answer arrived, which can be much later on a slow link.
3. **Guard:** a Node scan of every `.qml` for "helper namespace used, not imported", plus "every `.js` import points at a file that exists".
Alternatives weighed:
| Option | For | Against |
|---|---|---|
| A. One-line import only | Smallest diff | Next failure of the same kind in this handler is silent again, and a throw after `busy = true` sticks the sheet |
| B. Import + `_confirm()` + try/catch (applied) | Loud failure, no stuck sheet, real body testable in Node | Bigger diff; moved code needs a review read |
| C. Add the three `.js` helpers to `qml/helper/qmldir` so a directory import works everywhere | Removes the whole bug class at the source | Singleton/`.js` mixing in a qmldir changes how every file in `qml/` resolves names; cannot be verified without a Qt run, and the repo convention is the explicit import |
| D. Lint guard only | No product change | Does nothing for the person holding the phone |

## What was actually executed in the session (honest)
- **Node, not Qt.** `qmlHelperImports.guard.test.js` 19 tests, `restockDialogConfirm.test.js` 18 tests. Full `functions/` suite: see the PR (recount from CI, do not trust this line).
- **Failing first:** with the import removed, TREE-2, RD-1 and RD-3 fail; restored, 19/19.
- **Mutation check** (14 hand mutants of `RestockDialog.qml`, all run against both new files): drop the import; catch always toasts; catch keeps busy; callback re-reads `qtyField.value`; signal re-reads `productId`; no busy re-entry guard; cost typo becomes 0; role check removed; `settled` never set; busy not cleared on answer; queued text lost; supplier index off by one; handler emptied; reason not trimmed. **14/14 killed.**
- **Not run:** the dialog itself (Felgo), the CI run, anything on a device. There is deliberately NO new QML test (D-B): the dialog cannot load under `qmltestrunner`, a stand-in would test the stand-in.

## 1. Unit tests
| Kind | Cases |
|---|---|
| Scanner (`qmlHelperImports.guard.test.js`) | SCAN-1 missing import reported; SCAN-2 directory import does not count; SCAN-3 right import clears; SCAN-4 import under another alias does not clear; SCAN-5 line comment, block comment, string, template literal ignored; SCAN-6 a quote in a comment or `//` in a string does not hide a real use; SCAN-7 `obj.Name.x`, `myName.x`, `NameX.x` are not uses; SCAN-8 bare name with no member is not a use; SCAN-9 several names sorted once; SCAN-10 `jsImports` path and alias; SCAN-11 `stripNonCode` keeps length and lines; SCAN-12 empty input and empty name list |
| Confirm body (`restockDialogConfirm.test.js`) | CF-1 applied; CF-2 queued; CF-3 refused with cause; CF-4 refused without cause; CF-5 busy re-entry; CF-5b double tap = one restock; CF-6 role refused; CF-7 supplier index 0 and N; CF-8 cost text blank, spaces, `0`, ` 7.5 `, `abc`, `-3`, `1,5`; CF-9 reason trimmed; CF-10 inputs captured at the tap |

## 2. Functional (Node, real function body, fake stores)
`_confirm` is cut out of the `.qml` with `extractFunction` and run in a `vm` against fakes of `AuthStore`, `Toast`, `InventoryStore`, `partyCombo`, the three fields, `restockConfirmed`, `dlg`. `RestockFlow` is the REAL helper. CF-17 pins the list of free names the function uses, so a new collaborator cannot be added without the rig learning it (otherwise a missing fake could make a ReferenceError test pass for the wrong reason).
Failure handling: CF-11 the ORIGINAL bug (unresolved helper = ReferenceError): shown, logged, not busy, nothing sent. CF-12 `restock` throws before answering. CF-13 answers queued then throws. CF-14 the answer path throws inside `restock`. CF-15 a late answer after a throw still settles the sheet.

## 3. Rules / E2E
None. View-only change; nothing reaches Firestore rules, functions or the emulator.

## 4. Regression (automated)
- TREE-0 the scan still sees the tree (RestockFlow.js known, RestockDialog.qml scanned, more than 100 files). TREE-1 helper basenames unique. TREE-2 no QML file uses a helper it did not import. TREE-3 every `.js` import resolves.
- RD-1 the dialog imports `RestockFlow.js` under the name it uses. RD-2 every `RestockFlow.<fn>` the dialog calls is defined in `RestockFlow.js` (a rename in the helper goes red). RD-3 `costFromText` runs before `busy = true`, and no other helper in the file is missing an import.
- CF-16 the Confirm signal is exactly `dlg._confirm()`, one `InventoryStore.restock(` call site, one `_confirm`.
- Existing suites unchanged and must stay green: `restockFlow`, `restockHold`, `restockWire`, `restockSurface`, `tst_RestockFlow`, `tst_InventoryStore_restock*`.

## 5. Counts
Recount from the CI comment on the PR after the push. Expected delta: functions +37 (19 + 18). QML, Rules, E2E: +0.

---

## On-device test plan (Taher, needs a build of this branch)
**Prerequisites:** owner or admin login; a product with stock; one supplier saved; a second device or the web console to read the stock if you want to cross-check. Keep `adb logcat` open for the "RestockDialog" lines if you can.

### Happy path
| # | Action | Expected |
|---|---|---|
| H1 | Inventory, open a product, Restock, leave quantity 10 and the pre-filled cost, tap **Confirm** | Spinner on the button, then toast "Restocked +10 units", sheet closes, stock is +10, a batch and a purchase exist, Activity shows "Restocked" |
| H2 | Same with a supplier selected and a reason typed | Same, Activity subtitle shows the supplier and the reason |
| H3 | Same with a NEW supplier added through the + button | Supplier exists once, batch points at it |
| H4 | Blank the cost field, Confirm | Batch cost is the product's recorded cost (not 0) |

### Negative
| # | Action | Expected |
|---|---|---|
| N1 | Cost "abc", Confirm | Toast "Unit cost is not a valid amount", sheet stays open, button usable again |
| N2 | Cost "-5", Confirm | Same toast |
| N3 | Try to lower the quantity below 1 (minus button, or type 0) and Confirm | The spinner stops at 1 (or a refusal toast shows); never a silent nothing |
| N4 | Airplane mode, Confirm | Toast "Restock saved. Stock updates when it syncs", sheet closes, stock unchanged yet; reconnect: stock +N once, Activity once |
| N5 | While N4's restock is queued, open the same product's Restock again, Confirm | Toast "A restock for this product is still syncing..." |
| N6 | Staff (non-owner/admin) account | No Restock button; nothing to confirm |

### Edge cases
| # | Action | Expected |
|---|---|---|
| E1 | Double-tap Confirm quickly | One restock only |
| E2 | Confirm, then immediately press Back / tap outside | The sheet does not close while busy; after the answer it closes |
| E3 | Slow network (throttle), change the quantity spinner while the spinner is showing | Toast and stock use the quantity that was TAPPED |
| E4 | Quantity 9999 and 1 | Both accepted |
| **E-SB1** | **Type a quantity with the keyboard (for example 25) and tap Confirm without pressing Enter or tapping elsewhere** | **Expected +25. If the result is +10 (the previous value), the editable SpinBox did not commit its text: report it, it is a separate bug (decision D-C), not fixed here** |
| E5 | Open Restock for product A, close, open for product B, Confirm | B is restocked, not A |

### Multiple scenarios
Restock three different products in a row (online), then two offline and reconnect. Every stock is right, no duplicate batches, no stuck sheet.

### Monkey (manual)
Open and close the Restock sheet 10 times, changing quantity, cost, supplier and reason at random, confirming about half of them, toggling airplane mode twice. No crash, no sheet stuck on a spinner, every Confirm gives a visible result (toast), logcat shows no `ReferenceError`.

### Affected areas
| File | Automated coverage | Where to look on device |
|---|---|---|
| `qml/pages/RestockDialog.qml` | import guard (19), `_confirm` body (18), 14/14 mutants | the whole list above |
