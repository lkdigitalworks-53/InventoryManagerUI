# L4b: "Updated 3 min ago" row with tap-to-refresh

Branch `feat/2026-11-04-l4b-refresh-row`, cut from `main` @ `17db878` (PR #182, L4a, merged and device tested). Parent design: `2026-11-02-l4a-resume-refresh-design.md` (L4b was named there: "pull-to-refresh on the lists and a last-updated caption"). Test plan: `../test-plans/2026-11-04-l4b-refresh-row-test-plan.md`. Skill 152.

## 1. Intent and scope

L4a refreshes the lists by itself on resume and reconnect, silently, at most every 5 minutes. Two things are missing: the user cannot ask for "now", and cannot see how old the lists are. L4b adds both, on the pages that show refreshed data.

In scope: a pure helper (what the row says, what a tap answers), three small additions to `DataModel`, one reusable row component, five pages, toast wiring in `Main.qml`, tests, docs.
Out of scope (stays as L4a left it): the engine, the gate, the stores, `ActivityLog` / categories / channels refresh and incremental refresh (L4c).

## 2. Facts found in the code (read, not run)

- F1. Every page scrolls in `AppScrollView`, which pins its `Flickable` to `StopAtBounds` on purpose (its header: on Android a press-and-hold anywhere free-dragged and rubber-banded the whole page). A pull below the top therefore does not move anything today; the usual overscroll pull-to-refresh has nothing to read.
- F2. `SalesPage` already has a `DragHandler` (horizontal swipe between views) on the same scroll view, with a comment that touch behaviour differs between Android and desktop and must be device-verified.
- F3. `DataModel.requestRefresh(trigger)` returns `"run" | "wait" | "drop"` and already supports `"manual"` (ignores the 5 minute staleness rule, keeps the 15 s spacing and the whole gate). The reason behind a `wait` or `drop` is computed inside `RefreshPolicy.decide` and thrown away.
- F4. `_lastSyncMs` (when the lists were last known current) is private; `_wantTrigger` (a wish that is waiting) and `_refreshRunning` are plain properties, so a binding can follow them.
- F5. Pages talk to app state through `app.*` (`GlassHeader` reads `app.isOnline`, `app.syncStuckCount`). `Toast.show(text)` is a global.
- F6. `GlassHeader`'s subtitle slot is already contested: offline text beats the stuck-writes text beats the page subtitle.
- F7. `Icon` has a tintable `retry` icon (FontAwesome refresh). Components in `qml/components` need no registration. `QQC.BusyIndicator` is already used for small spinners (`PrimaryButton`).
- F8. `DashboardPage`'s recent-activity feed mixes orders with `ActivityLog`, which L4a does not refresh.
- F9. Both the sign-in sync and L4a read all six stores for every role, so a refresh has no role-specific path to guard.

## 3. Decisions (all vetoable in the PR; defaults are built)

**B-D1 The control: a visible row, not a pull gesture. (Departs from the plan's wording. Veto here first.)**
Options laid out:
- (a) Real overscroll pull. Needs `StopAtBounds` removed on the page scroll views (F1). That brings back the Android free-drag bug on every page. Rejected.
- (b) A custom pull gesture over `StopAtBounds` (a passive handler that measures a downward drag while the list is at the top). Cannot be verified in this sandbox, CI cannot drive a touch drag on Android, and it competes with the Flickable and, on Sales, with the swipe handler (F2). A gesture that sometimes steals a scroll, or silently does nothing, is worse than no gesture. Also not reachable by keyboard or a screen reader. Rejected for this slice.
- (c) **A row at the top of the page content: refresh icon and "Updated 3 min ago", the whole row is the tap target. Built.** It sits where a pull indicator would sit, so "scroll to the top and refresh" is the same motion. It shows state (age, refreshing, waiting, offline) which a gesture cannot. Honest cost: it is a tap, not a pull; and it scrolls away (the user scrolls up to reach it).
- (d) A refresh icon in `GlassHeader`'s action row. Always visible, but the header has no room for a caption, Inventory already carries two icons, and the offline / stuck precedence (F6) would need a third state. Rejected.
A pull gesture can be added later on top of the same `DataModel.manualRefresh()` without touching anything built here, if the device test says the row is not enough.

**B-D2 Where.** First child of the content column on Inventory, Orders, Staff, Dashboard and Sales. Not Activity (its data is not refreshed: the row would lie). Dashboard is included knowing F8: its KPIs and order feed are the main reason to refresh, and its activity rows catch up at the next sign-in sync (KNOWN-ISSUES; ActivityLog joins the refresh in L4c). The row replaces the first child's top margin so the gap stays the stack spacing (no double gap).

**B-D3 What "updated" means.** `DataModel.lastSyncMs`, the L4a "lists last known current" time (start of the sign-in sync, or a refresh in which all six stores committed). Age text: under 1 minute "just now" (also for a clock that went backwards: never a future time), then "N min ago", "N h ago", "N d ago". Unreadable or never: no age. Known limit carried from L4a: if the sign-in sync failed, the row still says "Updated" for the sign-in time.

**B-D4 States and text** (pure `RefreshCaption.view`): offline beats everything: "Offline · Updated 4 min ago", not tappable, neutral (the header already shouts "App is offline"; a second red line is noise). Running: "Refreshing…" with the spinner, not tappable. Waiting (a request is queued behind writes or a check): "Waiting to refresh…" with the spinner, not tappable (a second tap would only restart the same wait). Idle: "Updated 4 min ago", tappable. Never synced: "Tap to refresh".

**B-D5 What a tap says** (`DataModel.manualRefresh()` returns `{action, reason}`; `requestRefresh()` keeps returning the plain action, so no L4a caller or test changes meaning). `run`: no toast (the row flips to "Refreshing…" at once, well inside 400 ms, and to "Updated just now" when it ends). `wait`: a toast says why in plain words (changes still sending, editing, or busy for a moment). `drop`: offline reuses the existing sentence, too-soon says "Just refreshed", anything else "Can't refresh right now". Rejected: a toast on every success (noise on the most common path).

**B-D6 A request that never finishes tells the user.** Two silent endings existed in L4a: a manual wish that waits out its 2 minutes, and one dropped because the phone went offline or the account was blocked while it waited. `DataModel` now emits `manualRefreshUnfinished("gave-up")` for those (manual only; resume and reconnect stay silent), and `"partial"` when a manual run ends with some lists not updated and no automatic retry coming. `Main.qml` turns both into a toast ("tap the row to try again"). A discarded copy that re-arms its one retry stays quiet until that retry ends.

**B-D7 How the row reaches the app.** The component is pure props plus one signal (`lastSyncMs`, `online`, `state`, `refreshRequested`), so it is testable alone. Each page wires it the same four lines through `app.*` (the `GlassHeader` precedent); `Main.qml` exposes `refreshLastSyncMs`, `refreshState`, `requestManualRefresh()`. A wiring test pins that all five pages wire it identically and that Activity does not.

**B-D8 The clock tick.** A 30 s timer inside the row recomputes the age text, runs only while the row is visible, and the text is also recomputed when the row becomes visible and when `lastSyncMs` changes. Cost: one binding evaluation per 30 s per visible row. Rejected: a global ticker (wakes the app for pages nobody sees).

**B-D9 Touch target and accessibility.** The row is 48 dp high (Material minimum) and the whole row is the target; `Accessible.role: Button`, the name is the visible text plus "Tap to refresh" when it is tappable, `Accessible.onPressAction` triggers it. No looping custom animation (reduced-motion safe); the only motion is `BusyIndicator`'s own, and only while busy.

## 4. Known limits (also in KNOWN-ISSUES)

- A tap, not a pull: the user must scroll to the top to see the row.
- Dashboard's activity feed (`ActivityLog`) is not part of the refresh yet (L4c).
- The row says "Updated" for the sign-in sync start even if that sync failed (L4a limit).
- English-only strings in the helper, like `FailureCause.js`; the row's static labels are not wrapped in `qsTr` either (house helpers do the same).
- Nothing built or run on a device; what the row looks like and how it feels on a phone is device-only.
