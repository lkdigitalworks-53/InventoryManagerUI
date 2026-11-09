# Test plan — Review sweep of PR #188 (Restock Confirm fix) and PR #183 (R4 restock wire)

**Branch:** `review/2026-11-09-pr188-pr183-sweep`, stacked on `fix/2026-11-09-restock-confirm-noop` (PR #188). **Date:** 2026-11-09. **Commit identity:** `taher.lkdw@gmail.com`.
**Asked:** deep full-sweep review of PR #188, then of PR #183 (merged; R4, `InventoryStore.restock` on `RestockPlan`) for further bugs. (The ask said "R3"; the code under review is the R4 wiring from #183 and the R3 planner `RestockPlan.js` it calls, both read.)
**No server change, no deploy. The app was not built or run (standing rule); no Qt in the sandbox, CI is the QML oracle.**

## Review result in one table
| # | Severity | Where | Finding | Action |
|---|---|---|---|---|
| F-1 | Important | `RestockDialog.qml` qty read | The quantity SpinBox is editable. Typed text becomes `value` only on Enter or focus loss; nothing proves the Confirm tap moves focus first. Reading `qtyField.value` can book the OLD number (type 25, +10 booked): wrong stock and ledger row, no undo. PR #188 left this as device case E-SB1 "unverified, not fixed". | **Fixed.** `RestockFlow.qtyFromField` reads the typed text with the SpinBox's own `valueFromText`; refuses empty, junk, fraction, out of 1..9999 (never clamps); brings `qtyField.value` up to date. Decision D-C2 below. |
| F-2 | Important | `Gateway.qml` `_finishOperation`, `_answerDeltaCallbacks`, `recordOperation` | A caller's callback that throws (a toast, a dialog) aborted the Gateway's own bookkeeping. The waiter and delta maps are cleared BEFORE the loops, so every later callback was lost for good; the `operationApplied/Rejected` signal (the only route for a caller who left) was skipped; after enqueue `drainNow()` was skipped; after a send `_reschedule()` was skipped. | **Fixed.** `_callSafely` wraps each caller callback, logs it, never swallows silently. |
| F-3 | Minor, guard | name resolution | #188's guard only sees `.qml -> .js` by file basename. Same bug class elsewhere: helper `.js -> .js` (aliases like `Keys`), `.qml -> .qml` type or singleton from another directory, singleton not in `qmldir`. | **Added** `qmlTreeResolution.guard.test.js` (TR-1..3). Whole tree is clean today (independent scan agreed). |
| O-1 | Note | `RestockDialog.restockConfirmed` | Signal has no listener anywhere (`grep -i`). Kept: file comment calls `openFor` the contract and removal is a separate cleanup. | Roadmap, no code. |
| O-2 | Note | bulk import overwrite + D-1 hold | An overwrite row for a product with a queued restock is refused by `updateProduct` (correct, nothing corrupts), but the import summary has already counted it as updated. | Roadmap, no code. |
| O-3 | Note | busy sheet | While busy the sheet cannot be closed (all four dismissal paths guarded). Longest wait is `SendPolicy.TIMEOUT_AWAIT_MS` = 10 s, then it answers "queued". Fine; no hang path found because `Gateway` answers every `recordOperation` exactly once. | None. |

**Verified, no bug found (the sweep of #183 / R3 / R4):** callback exactly once on every `Gateway.recordOperation` path (sync queued, waiter, timeout, discard); `_restockSettled` dedupe between the live callback and the `operationApplied/Rejected` signal on all four orders (applied/queued/rejected/discarded); latch `hasQueuedOperationFor` reads the durable outbox and `markSent` runs before `_finishOperation`; D-1 edit/delete hold covers every whole-record writer (import overwrite funnels through `updateProduct`); sale guard and picker filter use the same latch; `RestockPlan.build/reflect` (refusals, token rule, overflow, one supplier mint, shape check); purchase `total` is unrounded exactly as the old `recordPurchase` was (no regression); `costFromText` cases; #188's `_confirm` (capture at tap, settled flag, busy reset), its tests and its 14 mutants.

## Decisions (vetoable in the PR)
- **D-C2 (F-1): read the typed text at the tap.** For: wrong stock is the worst failure here and a device cannot be consulted from the sandbox; if Qt already commits on focus loss the change is a no-op. Against: PR #188 chose "no fix without evidence" (Skill 156 rule 8); this adds a function and 3 dialog lines. Alternatives: (a) leave it and rely on device case E-SB1 (cheap, but a wrong qty reaches production if nobody runs it); (b) make the SpinBox non-editable (+/- only; removes the class, makes 9999 tedious); (c) force focus away at the tap (depends on the same platform focus rules). Refusing instead of clamping: the SpinBox itself would silently turn 100000 into 9999, which books a quantity nobody typed.
- **D-G (F-2): swallow-and-log caller exceptions inside `Gateway`.** For: bookkeeping must not depend on caller code. Against: a bug in a caller's callback now logs a warning instead of surfacing at the call site; a QtTest `compare()` failing inside such a callback is now swallowed (assert after the call, as the new tests do). Alternative: try/finally to run bookkeeping then rethrow (keeps surfacing, still loses later waiters unless each is guarded; not chosen).

## What was executed (honest)
- Node: `restockQtyField.test.js` 15, `gatewayCallbackIsolation.test.js` 11, `qmlTreeResolution.guard.test.js` 10, `restockDialogConfirm.test.js` +3 (CF-18..20, and CF-17 updated for the new local `typed`). Full `functions/` suite 1257/1257 (was 1218 on #188). `.github/scripts` suite run after the docs regeneration.
- Mutation: 17 hand mutants, all killed. Qty (7): stale read, no refusal return, clamp, fraction, no trim, parser throw treated as ok, no field sync. Gateway (6): raw waiter call, raw delta call, raw sync call, silent swallow, timer not stopped, signal skipped. Guard (4): dropped dialog directory import (TR-2), dropped `.import` in `RestockFlow.js` and in `RestockPlan.js` (TR-1, after reworking it to be alias-aware: the first version followed file names and missed the `Keys` alias), singleton removed from `qmldir` (TR-3). One mutant (no trim) first survived because the fake parser tolerated whitespace; the fake now models Qt's strict parser.
- QML twins written, NOT run: `tst_RestockFlow.qml` 3 cases, `tst_Gateway.qml` 2 cases. CI is the oracle.
- Not run: the dialog (Felgo), CI, any device.

## 1. Unit tests
`qtyFromField`: QF-1 typed beats stale value; QF-2 equal text; QF-3 limits 1 and 9999; QF-4 whitespace; QF-5 empty/blank refused; QF-6 junk; QF-7 fraction; QF-8 out of range never clamped; QF-9 parser throws; QF-10 no readable text uses committed value; QF-11 committed value checked the same way; QF-12 message names the field's own limits; QF-13 no field; QF-14 locale-aware parser asked with the field's locale; QF-15 dialog source shape. `Gateway`: GI-1..11. Guards: SC-1..6, TR-0..3.

## 2. Functional (Node, real function body, fake stores)
`restockDialogConfirm.test.js` CF-18 typed-not-committed number is sent and the field follows; CF-19 unreadable text sends nothing, never sets busy, shows the limits; CF-20 a refused tap leaves the sheet usable. `Gateway` bodies (`_callSafely`, `_finishOperation`, `_answerDeltaCallbacks`, `recordOperation`) run for real in a vm.

## 3. Rules / E2E
None (no server change).

## 4. Regression (automated)
All 1218 earlier `functions/` tests unchanged and green; the 14 #188 mutants still killed by CF-1..17; existing `tst_Gateway.qml` waiter/signal cases unchanged (the non-throwing path hands the same object, GI-11).

## On-device test plan (Taher, needs a build of this branch)
**Prerequisites:** owner or admin login; a product with stock 5; one supplier; `adb logcat` open (look for "[Gateway] a caller's callback threw" and "[RestockDialog]").

### Happy path
| # | Action | Expected |
|---|---|---|
| H1 | Restock, quantity 10 left as is, Confirm | +10, toast, sheet closes (PR #188 H1 still holds) |
| H2 | Type 25 with the keyboard, tap Confirm at once (no Enter, no tap elsewhere) | **+25**, toast "Restocked +25 units". This is PR #188's E-SB1; with this branch it must pass whether or not Qt commits on focus loss |
| H3 | Type 25, press Enter, Confirm | +25 |
| H4 | Use the + and - buttons, Confirm | The shown number is booked |

### Negative
| # | Action | Expected |
|---|---|---|
| N1 | Clear the quantity box, Confirm | Toast "Enter a whole quantity from 1 to 9999", sheet open and usable, nothing queued |
| N2 | Type 0, then -3, then 10000, then 100000, Confirm each | Same toast each time; never booked as 1 or 9999 |
| N3 | Type 2.5, Confirm | Same toast |
| N4 | Type letters, Confirm | Same toast (soft keyboard may block this) |
| N5 | After N1, type 12, Confirm | +12 |

### Edge cases
| # | Action | Expected |
|---|---|---|
| E1 | Type 25 and Confirm while offline | "Restock saved. Stock updates when it syncs"; on reconnect stock +25 once |
| E2 | Type 25 and Confirm, then change the box while the spinner shows | Toast and stock use 25 |
| E3 | Phone language Hindi or Gujarati (if you use them), type a number | Accepted (the SpinBox's own parser is used); report a refusal of a valid number |
| E4 | Quantity 1 and 9999 typed | Both accepted |
| E5 | Type 25, tap Confirm; the number in the box and the "After this, stock will be N" line | Both read 25 |

### Multiple scenarios
Three restocks of different products by typing different numbers, confirming each straight away; every stock and every Activity line matches what was typed.

### Monkey (manual)
Open the sheet 10 times; type random digits, letters, empty, huge numbers; tap Confirm at random moments including mid-typing; toggle airplane mode twice. No crash, no stuck spinner, no booking of a number nobody typed.

### Affected areas
| File | Automated coverage | Where to look on device |
|---|---|---|
| `qml/pages/RestockDialog.qml`, `qml/helper/RestockFlow.js` | QF-1..15, CF-18..20, mutants 7/7 | H1-H4, N1-N5, E1-E5 |
| `qml/model/Gateway.qml` | GI-1..11, mutants 6/6 | Any restock, order completion, sale; logcat shows no "callback threw" in normal use |
| name-resolution guards | SC, TR | CI only |

### Regression
PR #188's full on-device list (H1-H4, N1-N6, E1-E5, multiple, monkey) and PR #183's R4 list stay valid: re-run H1, N4 (offline queue), N5 (second restock while queued) and an order completion after a restock.
