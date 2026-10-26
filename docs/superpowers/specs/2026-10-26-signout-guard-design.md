# Sign-out guard (S0): warn before signing out discards unsynced work

**Date:** 2026-10-26. **Status:** implemented in this PR on the design Taher already chose (Q-A6, 2026-10-16: warn and let proceed). Defaults taken here are marked **vetoable**; each is cheap to reverse.
**Parent:** section 4b of `2026-10-16-restock-atomic-operation-design.md` (PR #147, merged to `main` 2026-10-26 with Q-A8 answered; its note 2 already points here). This file is self-contained and supersedes 4b where they differ (D-S0-3).
**Path:** UI + one pure helper, no server change, no deploy. Skills used: `superpowers:brainstorming`, `qt-qml`, `qt-ui-design`, `ponytail`.

## 1. The problem (verified in code on `main` @ `b494d52`, 2026-10-26)

Signing out, or leaving a workspace, throws away every queued write and nothing tells the person.

- `AuthService.signOut()` emits `signedOut`; `Main.qml onSignedOut` calls `Gateway.clear()` (which runs `OutboxStore.clear()`) and `PhotoQueue.clear()`. `OutboxStore.items` is Settings-backed, so it would survive a relaunch, but sign-out empties it on purpose ("a pending write must never replay under the next account").
- The only confirmation today is `confirmDlg` "Sign out?" in `Main.qml` (`profilePage.onSignOutRequested`) and "Leave workspace?" (`onLeaveWorkspaceRequested`). Neither mentions pending work.
- What gets dropped: edits and creates that have not reached the server, stock deltas, a queued order completion, parked (server-rejected) writes the stuck-writes sheet is still showing, and queued product photos (their local files are deleted too).
- Not a theory for this team: Taher device-tests every PR on a new tenant, so he signs out between tests, often right after provoking a stuck or parked write.

Entry points that reach `signOut()`: `ProfilePage` Sign out, `ProfilePage` Leave workspace (`AuthService.leaveCurrentTenant`, which does network writes first and then `signOut()`), `TenantSetupPage` Sign out. Nothing signs out automatically (grep of `qml/`, `signOut(` has exactly two call sites: `Main.qml onSignOutRequested`, `AuthService.leaveCurrentTenant`). The C++ side was not checked.

## 2. Options, with the honest trade-offs

| Option | What it does | Cost | Verdict |
|---|---|---|---|
| A. Warn, then allow | Sheet lists what will be lost; the person can stay or discard | A one-tap path to loss remains, now an informed one. Cheap, no new state | **Chosen by Taher (Q-A6).** Built here |
| B. Block while anything is pending | Sign-out disabled until the outbox drains | Keeps "a tap is durable" absolute, but traps a person who is offline and must leave (shared phone, lost shop key) | Rejected by Taher |
| C. Persist the outbox per `uid + tenant`, replay only for that account | Removes the loss instead of warning about it, and removes the cross-account leak the clear exists for | Token and tenant handling at replay, risk of replaying under the wrong account, a big change to `OutboxStore`/`Gateway` | Not now. Revisit after the atomic-operation consumers land |

Challenge to the chosen option (Taher asked to be grilled, so on record): A is a seatbelt, not a fix. Anyone who taps "Sign out and discard" still loses data, and "Sending" items may already have landed, so the sheet can only say "may or may not". C is the real answer; A is right to ship first because it is small, independent and needed before restock becomes a queued operation (the restock design requires it).

## 3. Design

### Where the check lives

One chokepoint in `Main.qml`: `askLeave(opts)` where `opts = { title, plainMessage, plainConfirm, discardLabel, proceed }`. It builds the guard summary; if nothing is pending it shows the existing plain `confirmDlg` (today's behaviour, unchanged wording), else it opens `SignOutSheet`. All three entry points call it. **Why not inside `AuthService.signOut()`:** it has no UI, and `leaveCurrentTenant` does network writes before it reaches `signOut()`, so the warning must come before those writes start.

### The pure helper (`qml/helper/SignOutGuard.js`)

`build(outboxItems, photoItems, opts) -> { count, rows, more, summary, consequences, hasSending }`.

- `opts` (all optional): `inFlight(requestId) -> bool` (injected: `OutboxStore.isInFlight`), `productName(productId) -> string` (injected), `maxRows` (default 5).
- Row title/detail for outbox items come from `DescribeItem.describe` (same words as the stuck-writes sheet). Photos: title "Product photo", detail = product name, else product id.
- Row state, one of `waiting`, `sending`, `attention`. Outbox: `attention` if the item is parked or stuck (read from the persisted item: `StuckWrites.isParkedItem(item)` or `item.stuck === true`), else `sending` if `inFlight(requestId)`, else `waiting`. Photos: `failed` is `attention`, `uploading` is `sending`, anything else `waiting`.
- `count` = outbox items + photo items. `rows` = the first `maxRows`; `more` = the rest.
- `consequences` lists only the lines that apply, in this order: (1) always: discards, will not sync when you sign back in, even as the same user; (2) if any row is `sending`: may or may not have been saved, check after you sign in; (3) per kind present: queued order completion (the order stays Pending, complete it again after signing in), other queued changes (enter them again), photos (not uploaded, lost); (4) local data on this device is cleared.
- Never throws; malformed items are counted but described as "Pending change".

### The sheet (`qml/pages/SignOutSheet.qml`, a `BottomSheet`)

- Title "Sign out with unsynced work?" (leave variant: "Leave with unsynced work?"). One-line summary: "N changes haven't reached the server." (singular for 1).
- Up to five rows, each: title, detail, and a state tag in words plus colour (Waiting / Sending / Needs attention; never colour alone, WCAG). "+ K more" below.
- The consequence lines, one short sentence each.
- Footer: **Stay signed in** (primary, right) and **Sign out and discard** (secondary, left, red text). Back, tap outside and the X all mean Stay. The destructive action is never the default and never reachable by an accidental tap outside.
- Live: bound to `OutboxStore.revision`, `OutboxStore.inFlightCount`, `PhotoQueue.revision`. If the queue empties while the sheet is open, it shows "Everything has synced. Nothing will be lost." and the destructive button reads plain "Sign out" / "Leave workspace".
- Added to `Main.qml _handleBack` so Android Back closes it (= stay).
- `BottomSheet` gets one backward-compatible property, `secondaryColor` (default `Constants.textPrimary`), bound to the ghost button's `textColor`.

## 4. Decisions

- **D-S0-1 (taken, Taher's earlier answer): warn and allow.** See section 2.
- **D-S0-2 (vetoable): one chokepoint in `Main.qml`, all three entry points.** The `TenantSetupPage` path normally has an empty queue, so it shows the plain confirm; routing it costs one line and closes the "queue survived a relaunch and the user landed on tenant setup" corner.
- **D-S0-3 (vetoable, deviates from #147 4b): `attention` means parked OR stuck, not only parked.** A stuck write that is still retrying is also "not syncing" in the stuck-writes sheet; calling it "Waiting" would understate it. Cost: none beyond one extra field read.
- **D-S0-4 (taken): no "Sync now" third button (ponytail).** Honest cost: when the device is online and rows are only `waiting`, a one-tap drain is what a person would want, and today they must stay signed in and wait. The existing "Changes not syncing" sheet is where to retry. **Question for Taher (Q-S0-1):** add a "Try to sync first" button that calls `Gateway.drainNow()`? My recommendation: not in this PR; add it only if device testing shows people hit this.
- **D-S0-5 (taken): pending batch-id mints are NOT in the sheet.** They live in a separate Settings queue (`StockBatchStore._pendingMints`) that sign-out does not clear today. Finding of this session: it also is not tenant-scoped, so it can replay into the NEXT tenant. Fixed in the stacked PR (tenant-tag it; keep it for its own tenant). So it is neither lost nor listed.
- **D-S0-6 (taken): no `restock` label in `DescribeItem` yet.** The restock operation does not exist; add the label in the PR that creates it (YAGNI).
- **D-S0-7 (taken): strings are plain English in the helper, `qsTr` in the sheet.** Same split as `DescribeItem` / `StuckWritesSheet`; the helper returns text keyed by kind, the sheet owns the layout and the title.

## 5. Out of scope, named so it is not mistaken for forgotten

Option C (replay per account); app killed or uninstalled while items are queued (the outbox survives a kill, only sign-out drops it); token expiry (no automatic sign-out exists); a restock operation label; a "sync first" button (Q-S0-1).

## 6. Risks

- **Mirror risk:** the sheet and `Main.qml` wiring cannot run under `qmltestrunner` (Felgo, no `App` context). All logic that can be wrong lives in `SignOutGuard.js` and is tested there; the sheet is a dumb view of its output; `Main.qml` is covered by the on-device plan.
- **"Sending" is only as true as the outbox.** The tag means a request is in flight, not that it will fail or that it will land.
- **Wording.** "Discard" is irreversible; the button says discard, not "sign out anyway".

## 7. Test strategy

Pure helper: `tests/tst_SignOutGuard.qml` (happy, negative, edge, a seeded monkey that checks invariants). Wiring, sheet and the three entry points: on-device plan in `docs/superpowers/test-plans/2026-10-26-signout-guard-test-plan.md`. CI is the only oracle for QML (no Qt in the sandbox).
