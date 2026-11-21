# Test plan: P1 S4b-2, stock register page on the phone

Branch `feat/2026-11-20-p1-s4b2-register-page`. Design: `specs/2026-11-12-p1-s4b-register-client-design.md` sections 5 and 8. Standard format (Skill 49). The feature is now VISIBLE: Profile, "Stock register" (owner, admin, manager). Node tests were RUN in the sandbox; QML tests run only in CI.

## 1. Unit tests

| File | Cases | Run? | Covers |
|---|---|---|---|
| `.github/scripts/__tests__/stockRegisterPage.test.js` | SRP-01..05 + 53 mutants (70 tests) | RUN | Chips and labels; `resolveWindow` (six presets equal the engine, custom trimmed, bad day, reversed, out of range, junk index, bad clock); `tapDecision` order (busy, window, role, offline) and junk input; `stateFromResult` (ok, wrong window, each error kind, retry flag, busy/cancelled leave the page, junk); `stateFromCache`, `stateFromBody`, `stateFromRefusal`; flat row keys (no `id`); `loadLabel`, `nextExpanded`, `summaryText`, `warningLines` (agrees with the engine's `hasWarning`), `emptyText`, `asOfText` (IST, midnight, noon, year end), `inlineError`, `captionText`, `detailRows`; seeded monkey 600 rounds; battery repeated in four time zones; no local-time getter or clock in the file; every mutant run under a non-UTC zone |
| `.github/scripts/__tests__/stockRegisterPageWiring.test.js` | SRW-01..15, 20..35, 40, 41 + 34 mutants (68 tests) | RUN | Imports by name; every `Glue.*` used is exported; delegate roles equal the row keys in order; ON DEMAND ONLY (one `load(` call, no timer or auto-load hook); service flag is the only latch; chips and custom fields off while loading; reset on workspace/role change, cancel before clear; Profile row and gate; Main overlay (Back order, workspace change, role loss, tab change, tabbar hidden, sign-out clear, z-order, still four tabs); dormancy replaced by an exact caller allow-list; the page's real function bodies in a vm: send once, refusals send nothing, cancel keeps the view, error clears rows, wrong-window refused, throw survived, chips use the remembered answer, show-all makes no request, row toggle, reset, warnings, empty answer, monkey 400 actions |
| `.github/scripts/__tests__/stockRegisterService.test.js` | SRS-04 changed | RUN | Old "nothing names the service" pin replaced by a pointer to SRW-13 |
| `.github/scripts/__tests__/sessionRecheckWiring.test.js` | pin extended | RUN | `_closeAllForWorkspaceChange` must close the new overlay (list and mutant text updated) |
| `tests/tst_StockRegisterPage.qml` | 7 functions | CI only | Main contract in the real Qt JS engine |

Whole script suite after the review sweep (2026-11-21): 1199/1199 (ran in the sandbox). CI on `66b4d3f`: QML, Functions, E2E, Rules all green. Review sweep additions: `asOfText` past the Date range (no "NaN"), SRW-14 (overlay refreshes the page clock on open; forced sign-out closes it), SRW-15 (figures shrink, never only elide), three vm checks and three mutants for `refreshPeriod`.

## 2. Functional / rules / e2e
- Functional: the vm tests above run the page's real function bodies against the real helpers.
- Rules and server: unchanged.
- E2E (emulator): none (KNOWN-ISSUES, S4b-2 item 1).

## 3. Regression
- `Main.qml` gained an overlay, one Back branch, one close line, one `clear()`; `ProfilePage.qml` one row and one signal. Review sweep: `open()` now calls `refreshPeriod()` and `onSignedOut` closes the overlay. Existing QML tests must stay green in CI; the Back order test (SRW-11) and the four-tab test (SRW-12) guard Main.

## On-device test plan (Taher; build needed; dev tenant with some stock history)

### Happy path
1. Sign in as owner. Profile shows a "Stock register" row. Open it: header "Stock register", chips "This month" selected, a hint and a "Load register" button. NOTHING loads by itself (watch the log: no request until the tap).
2. Tap "Load register": spinner on the button, "Cancel" and the two-minute note appear. The answer shows: period line, "as of ... (IST)", summary, rows with Opening / In / Out / Closing.
3. Tap a row: per-kind lines open; tap again: closes; tap another: the first closes.
4. Flip "Show all products": rows with no stock history appear, the count line changes, no request is sent.
5. Chip "Last month" then back to "This month": the first shows the hint (no answer), the second shows the earlier answer instantly.
6. Do a sale of 1 on a product, reload: its Out and Closing change by 1 and the ledger note is absent.

### Negative
7. Turn on airplane mode, tap "Load register": a red card with the offline words, button reads "Try again", numbers cleared. Back online, tap: works.
8. Chip "Custom", type `2026-05-01` and `2026-04-01`: red text says the range is reversed, the button is disabled. Type `abc`: red text says the start date is not a real day.
9. Tap "Cancel" during a load: the earlier view returns, no error card.
10. Sign in as a staff member (or viewer): no "Stock register" row.

### Edge cases
11. A new workspace with no products: "No products in this workspace yet."
12. A workspace where every product has no history: "Nothing to show for this period..." and the switch lists them.
13. Custom range of one day (same from and to): works. A range from 1999: refused with words.
14. A product with a very long name: one line, ends with "..." (no overlap with the chevron).
15. A mismatch (edit stock count directly in the database on a dev tenant): orange border and note on that row, and a "Check these numbers" card.
16. Rotate the phone (if allowed) and use a small phone: chips scroll, nothing is cut off.

### Multiple scenarios
17. Load, open a row, go to Orders and back via Profile: the page keeps the answer and the open row.
18. Load, then switch workspace: overlay closes; reopen: empty start. Sign out and in as another account: no old numbers.
19. Tap "Load register" twice quickly: one request (watch the log).

### Monkey
20. For two minutes: tap chips, Custom fields, Load, Cancel, rows and the switch in random order, press Back during a load. The app must not crash, the button must never stay stuck on a spinner after Cancel or Back-and-return, and the list must never show rows under a red error card.

### Affected areas
21. Profile: other rows (Team members, Notifications, Sign out) unchanged. Floating tab bar hides while the register is open and returns on Back.
22. Android Back: closes the register first, then Profile is not reopened.

### Review sweep additions (2026-11-21, PR #209)
23. Clock on open (F-A): load "This month", leave the app running, move the phone date to the 1st of the next month, reopen Profile, Stock register WITHOUT restarting the app. The caption above the numbers still shows the answer that was loaded (its own period). Tap Reload: the request is for the NEW month and the caption changes. With no answer loaded the caption shows the new month before any tap.
24. Forced sign-out (F-B): open the register, then force a sign-out (disable the user in Firebase Auth and wait for the session re-check, or any other forced route you have). The login page must show, not the register. The same gap exists for Profile, Staff and Activity overlays (KNOWN-ISSUES, S4b-2 item 14): check them in the same pass.
25. Long figures (F-C): on a dev tenant set one product's stock to 1234567.5 (and one to 12345678). Load: the figure shrinks to fit its column and never ends with "...". Repeat with the phone font size at the largest setting and on a 360 dp phone.
26. Typing a date (review note): Chip "Custom": on Android AND iOS the keyboard must let you type "-" (the field uses a numbers-preferred hint). If it cannot, open a follow-up for the date picker (KNOWN-ISSUES, S4b-2 item 2).
27. Out-of-range read time (F-E) is not device-testable (the server never sends it); it is covered by the unit tests and the QML twin.
