# Test plan — Orders "Approve all pending": pressed colour, busy guard, progress bar

**Branch:** `feat/2026-10-13-approve-all-progress` off `main` @ 73c4cf6. **Design:** `CHECKPOINT.md` on the branch (design section) and SKILLS Skill 117; bounded design approved in chat 2026-10-13, end state = option A (hold ~1.2 s with a success state).
**Covers:** `qml/helper/BulkApproveProgress.js` (new, pure), `qml/pages/OrdersPage.qml` (button, banner, progress bar, hold timer, `_approveAllPending` guard).
**Not covered:** pixels. Nothing here renders the page; the pressed colour, the bar and the hold are device-only (section "On-device").
**Run status:** helper cases run for real in node (QML test body against the helper, 29/29) with 12 hand-made mutants all caught; script suite 94/94 run. `qmltestrunner` NOT run (no Qt in the sandbox, standing rule): `tests/tst_BulkApproveProgress.qml` is CI-only.

## 1. Unit tests — `tests/tst_BulkApproveProgress.qml` (17 of 29 cases)
| Area | Cases |
|---|---|
| `newState`, `canStart` | zeroed idle state; only idle can start (null, undefined, idle, running, done) |
| `start` | valid total runs; 0, negative, NaN, undefined, null, text, ±Infinity, 0.4 stay idle; 2.7 floors to 2; "3" accepted |
| `step` | ok advances; last order -> done; locked counts `lockedOut` not `failed`; failed counts; unknown outcome counts failed (never approved); ignored when idle, done, null, undefined, or malformed (done already = total); returns a new object |
| `fraction`, `approved`, `allOk` | 0 idle, 0.25, 1/3, 1; malformed totals; approved = done - failed - locked; allOk only for a finished clean run |

## 2. Regression tests — same file (4 of 29)
| Defect | Case |
|---|---|
| Double tap ran two loops; `DataModel._completingOrderIds` refused the 2nd completion of each order and the 2nd loop showed a false "Insufficient inventory" | `test_regression_second_tap_while_running_is_refused`, `..._tap_during_end_hold_is_refused` |
| Banner hid at pending = 0, so 100% / success was never visible | `test_regression_done_state_is_not_idle_until_hold_elapses` |
| A late or duplicate callback could push progress past 100% | `test_regression_late_callback_cannot_overflow_progress` |
Also in `.github/scripts/__tests__/ordersPageApproveWiring.test.js`: the button must not return to a fixed 22% white background.

## 3. Functional tests — same file (7 of 29) + page wiring guard (18 script tests)
- Stand-in for the page loop (the page cannot load under `qmltestrunner`, Felgo import): all approved; mixed ok/failed/locked/ok (counts, one dialog, one hold); all locked; zero orders (nothing shown, no hold); single order (0 -> 1 in one step); fraction strictly increasing over 7 mixed steps; second run allowed after the hold.
- `ordersPageApproveWiring.test.js` reads `OrdersPage.qml` and fails if any of 12 wiring rules is missing: import, guard as FIRST statement of `_approveAllPending`, `start`, both `step` calls, hold start, `enabled` binding, pressed colour, banner held open, hold Timer, bar fraction, `qsTr` on the new strings. 12 mutants (one per rule) are each reported; 3 edge cases (missing function, unbalanced braces, empty page, guard not first); run 18/18.

## 4. Monkey tests — same file (1 of 29)
`test_monkey_random_sequences_keep_invariants`: 5 seeds x 400 random calls (start with 0, 1, 2, 5, 13, -4, NaN, "6", 2.9; step with ok, failed, locked, undefined, null, "weird", 3; reset). After every call: 0 <= done <= total, counts non-negative, failed + locked <= done, fraction in 0..1, phase done iff all counted, full bar iff done, idle iff no total, the input object never mutated. A failing run reproduces from its seed.

## 5. Rules tests / E2E
- **Rules (Firestore/Storage):** none. No data shape, path or rule changed.
- **E2E (`test/e2e`):** none added, on purpose. `tst_OrdersE2E.qml` drives the stores, not `OrdersPage`; the page cannot load under `qmltestrunner`. Writing an e2e that only re-implements the page would prove nothing. The real page is covered by the wiring guard above and the device plan below.

## On-device test plan
Setup: owner or manager login, auto-approve OFF, several pending orders with stock for all of them, plus one order whose product has too little stock. Build/run is Taher's call.

### Happy path
1. Pending orders exist: teal banner shows "Approve all pending", "N orders waiting" and an **Approve** pill.
2. Press and hold the pill: it turns clearly lighter (38% white) while held. Release.
3. Pill shows `0 / N`, then `1 / N` ... as each order completes, greyed (12% white) and not tappable; subtitle reads "Approving… k of N done"; a thin white bar along the banner bottom grows with k/N.
4. Last order done: pill says **Done**, bar full, subtitle **All approved**, banner stays ~1.2 s, then disappears. Orders list shows them completed; stock down once per order.

### Negative
1. Double-tap Approve fast: only one run starts; no "Insufficient inventory" dialog; stock deducted once per order.
2. With one order lacking stock: run finishes, banner holds with "k of N approved" (not "All approved"), the existing "Some Orders Weren't Approved" dialog lists the order.
3. Open an order in a second session (lock held): run reports it as "Being edited elsewhere"; subtitle "k of N approved".
4. Tap Approve again during the 1.2 s hold: ignored (pill greyed).

### Edge cases
1. Exactly 1 pending order: pill `0 / 1` -> Done, bar jumps empty to full in one step (expected, not a bug).
2. Large batch (50+): pill text `37 / 50` fits the 80 dp pill; bar moves smoothly enough; nothing else on the page blocks.
3. A new order arrives during the 1.2 s hold: banner stays until the hold ends, pill re-enables, count is right.
4. Staff login: only own pending orders counted and approved; progress total matches that count.
5. Phone rotation / OS font scale 200%: pill and subtitle do not overlap; subtitle elides.
6. TalkBack/VoiceOver: pill announced "Approve all pending orders, button" and disabled while running; the bar announced "Approval progress".
7. Offline: completions queue and show completed immediately (existing behaviour); progress still reaches Done.

### Affected areas
| File | Automated coverage | If not covered, check on device |
|---|---|---|
| `qml/helper/BulkApproveProgress.js` | 29 QML cases (CI), same body run in node | n/a |
| `qml/pages/OrdersPage.qml` button/bar/hold | wiring guard (18) | happy path 2-4 |
| `OrdersPage._approveAllPending` | guard first line + step calls pinned | negative 1-4 |
| `DataModel`, `LockManager`, `OrdersStore` | untouched | n/a |

### Regression tests (how you would notice it came back)
- Double tap shows "Insufficient inventory" for orders that were fine -> busy guard lost.
- Banner vanishes the instant the last order completes, no "Done" -> hold lost.
- Pill looks identical before and after the press -> pressed/disabled colours lost.
- Bar shows past full or stays full for the next run -> `step`/`newState` misuse.

### Monkey
Hammer the pill with random-rhythm taps during a 20-order run, rotate the phone mid-run, background the app mid-run and return, toggle auto-approve on and off mid-run, pull to refresh. Expect: one run only, bar never beyond full, no stuck disabled pill after the run ends (if it sticks, that is the known `shortcut:` limit in the helper header: no watchdog).

### Known limits (stated, not hidden)
- No watchdog: if a completion callback never fires, the pill stays disabled until the page is rebuilt.
- No reduced-motion path needed: the bar has no animation (the project has no reduced-motion setting).
- Out of scope, unchanged: the loop approves `pending` and `processing`, the banner counts only `pending`.
