# Test plan: L4b, "Updated 3 min ago" row with tap-to-refresh

Branch `feat/2026-11-04-l4b-refresh-row`. Design: `specs/2026-11-04-l4b-refresh-row-design.md` (B-D1..B-D10). Standard format (Skill 49). Nothing was built or run on a device. Node tests were RUN in the sandbox; QML tests are written and run in CI only.

## 1. Unit tests

| File | Cases | Run? | Covers |
|---|---|---|---|
| `.github/scripts/__tests__/refreshCaption.test.js` | 35 (one battery of ~200 checks, a 4000-step seeded monkey, 33 hand mutants) | RUN | `ageText` on both sides of every unit boundary, backwards clock, junk; `view` precedence offline > running > waiting > idle, tappable only when idle and online, junk fails to a disabled row; `accessibleName`; `requestMessage` for every action and reason, and a cross-check that every answer the REAL `RefreshPolicy.decide` can give a manual tap has the right kind of message; `unfinishedMessage`; helper is pure. |
| `.github/scripts/__tests__/refreshBehavior.test.js` | +26 (9 scenarios, 1 monkey, 17 hand mutants over the real `DataModel` function bodies) | RUN | `manualRefresh` answers `{action, reason}` and `requestRefresh` still answers the bare action; a manual wish that waits out its time, or is dropped (offline, blocked) while waiting, signals `gave-up` once, resume and reconnect stay silent; a manual run ending partial signals `partial` unless a re-armed retry is coming, a reset or sign-out cancelled it, or no session is open; a hung run cancelled as lost IS reported; the poll timer is on exactly while a run is out or a wish waits (6 seeds x 3000 steps with taps); `refreshState` and `lastSyncMs` expressions evaluated from the real file. One L4a assertion changed on purpose (the timer now stays on while a run is out). |
| `.github/scripts/__tests__/refreshRowWiring.test.js` | 28 (2 + 26 mutants) | RUN | The five pages carry the row, wired identically, as the first child of the content column, next item gives up its top margin; Activity, Profile and the auth pages do not; pages reach the refresh only through `app.requestManualRefresh()`; the row reads nothing but its props, is 48 dp, is a button for a screen reader, ticks every 30 s only while visible, has no animation of its own; `Main.qml` toasts; `DataModel` signal emitted in exactly two places, read-only views, one caller of `refreshFromFirebase`. |
| `.github/scripts/__tests__/refreshWiring.test.js` | 1 rule repointed | RUN | The L4a watchdog rule now reads `_request` (where `requestRefresh` delegates). |
| `tests/tst_RefreshCaption.qml` | 8 functions | CI only | Helper contract in the real Qt JS engine. |
| `tests/tst_DataModel_refreshRow.qml` | 6 functions | CI only | Real `DataModel`: offline manual tap dropped with reason, `requestRefresh` unchanged, `lastSyncMs` and `refreshState` follow the engine, manual wish signals once, automatic wish silent. |

Suites after the change: script suite 994/994 (905 before), `functions` 985/985 (untouched).

## 2. Functional / rules / e2e
- Functional: the behaviour tests above (real function bodies, fake edges).
- Rules: unchanged. A refresh reads only what L4a already read.
- E2E (emulator): none. Nothing server-side changed.
- The row itself (layout, text fitting, spinner) cannot be tested without Felgo (`dp`, `sp`, `Icon`); it is pinned by the wiring test and checked on a device.

## 3. Regression
- `requestRefresh(trigger)` keeps its return value; resume and reconnect behave as in L4a (the timer now also runs while a run is out).
- Every page keeps its first item; only its top margin moved into the row's spacing, so the gap under the header should look the same or slightly tighter (step 14).
- Existing QML tests must stay green in CI.

## On-device test plan (Taher; build needed; phones A and B, same owner account, dev tenant)

Prerequisites: P1 dev functions deployed (unchanged), P2 A signed in as owner with 20+ orders and 20+ products, P3 B signed in as the same owner, P4 airplane-mode toggle at hand.

### Happy path
1. On A open Inventory. Expect: a centered row at the top of the content: refresh icon and "Updated just now" (or "Updated N min ago"), then the KPI cards. No double gap under the header.
2. On B add a product "L4b Test". On A tap the row. Expect: the text becomes "Refreshing..." with a spinner at once (under half a second), then "Updated just now" and the new product is in the list. No toast. The list never goes blank.
3. Repeat on Orders (new order on B), Staff (new staff on B), Dashboard (today's sales after a completed order on B) and Sales (completed order on B). Expect: the same row, same behaviour, the new data shows after the tap.
4. Leave A on Inventory for 3 minutes without touching it. Expect: the text counts up on its own ("Updated 3 min ago").

### Negative
5. Tap the row twice quickly. Expect: the first tap starts the refresh; the row is not tappable while it says "Refreshing...", the second tap does nothing and no toast appears.
6. After a refresh finished, tap the row again within 15 seconds. Expect: the toast "Just refreshed. Try again in a few seconds." and no new read.
7. Airplane mode on A. Expect: the row says "Offline - Updated N min ago" (neutral colour, not tappable) next to the header's offline line. Tap it: nothing happens.
8. On A create an order offline, then network on and tap the row at once. Expect: the toast "Sending your changes first. The refresh follows.", the row says "Waiting to refresh...", the order stays visible, and when it is acknowledged the row refreshes by itself and ends on "Updated just now".
9. On A open Edit product, close it without saving, then tap the row. Expect: a normal refresh (the open-form hold from L4a ended with the form, no toast).

### Edge cases
10. Put A offline, tap the row while it waits behind an unsent order (step 8), then keep the network off for 2 minutes. Expect: after the wait ends the toast "Couldn't refresh. Tap the refresh row to try again." and the row returns to "Offline - Updated ...".
11. Suspend the member on B (members/<uid>.status = suspended) while A waits on a queued write, then tap. Expect: the access screen (L3); a toast about the refresh may flash over it (the wish is dropped as blocked), which is harmless; no crash.
12. Rotate the phone and use a small screen (compact width). Expect: the row stays centered, text on one line, ellipsis only for very long text.
13. Screen reader on (TalkBack or VoiceOver). Expect: the row is announced as a button: "Updated 4 minutes ago. Tap to refresh." and activates on double tap; while refreshing it announces "Refreshing..." with no action.
14. Compare the gap between the header and the first card on all five pages with the previous build. Expect: tidy, no doubled space.

### Multiple scenarios and monkey
15. Tap the row 30 times over 2 minutes (monkey) while B adds rows. Expect: never more than one refresh per 15 seconds, no crash, no blank list, the numbers match the server at the end.
16. Put A in the background for 6 minutes, resume (L4a automatic refresh), and watch the row. Expect: it may show "Refreshing..." for a moment on its own and then "Updated just now".
17. Switch tabs Inventory -> Orders -> Sales -> Dashboard repeatedly for 2 minutes. Expect: each row shows the same "Updated" time, counting up together; no flicker.
18. Hung read (hard to force): turn the network off right after tapping and leave it off for 4 minutes with airplane mode OFF but no route (captive portal or router with its WAN unplugged). Expect: within about 3 minutes the row leaves "Refreshing..." by itself and the toast "Some lists could not be updated. Tap the refresh row to try again." appears; the row is tappable again.

### Affected areas
Inventory, Orders, Staff, Dashboard and Sales pages (new first row), `DataModel` refresh engine (timer now on while a run is out), `Main.qml` toasts.

### Regression
R1 resume and reconnect refresh as before (L4a steps 1-3). R2 sign-out and sign-in leave no row stuck on "Refreshing...". R3 the offline line in the header and the stuck-writes line still show. R4 completing, returning and restocking behave as before.
