# Design — show the CAUSE when an order completion fails, is discarded or is parked (2026-10-13)

Follows PR #90 (atomic `completeOrder`, merged). Taher asked for this in the #90 sweep (D-1 follow-up). Status: **decided 2026-10-13: Q-EC-1 A, Q-EC-2 A, Q-EC-3 A (Taher); implemented the same day** on `feat/2026-10-13-completion-error-cause`.

## 1. Problem, traced in code (not assumed)
| # | Path | What the user sees today | Cause available where |
|---|---|---|---|
| P1 | Online, server answers `ok:false` (409/400/404 body) | Only `insufficient-quantity` has its own text. Everything else, after 3 re-plans: "Could not complete this order — please try again" (`DataModel._onCompletionRejected`) | `rejection.error`, `opIndex`, `current` in the body |
| P2 | Completion was queued/shown done (`callback(true)` already fired), later rejected and finally fails | NOTHING: `_failCompletion` sets `stockErrorMsg`, but `callback` is null so no toast. The order silently flips back to pending | same body, but no one is listening |
| P3 | Server answers HTTP 500 `write-rejected` / `-unavailable` / `-failed`, write becomes stuck / parked | Stuck sheet: "Rejected by the server. Paused until you tap Retry or Discard." No reason | `Gateway._noteFailure` receives the body; `StuckWrites` keeps only a boolean `terminal`; the code string is dropped |
| P4 | Same row title | "Order completion" + detail = `ops[0].entityId`, which is a **stock batch id** (CompletionPlan puts batch deltas first). Meaningless to the user | the order op is `entity:"order"`, `entityId = orderId`; customer name is on `ops[i].after` |
| P5 | Discard | Specific text already ("was discarded") | n/a, no change |

Server fact: `classifyWriteError` keeps only the class (rejected/unavailable/failed). The Firestore code (permission-denied, invalid-argument, not-found, failed-precondition) never reaches the client.

## 2. Decisions to take (each with the trade-off)
### Q-EC-1 Where does the cause text come from for P3 (HTTP 500 bodies)?
- **A (recommended): client-only.** Persist the body's `error` string + HTTP status per stuck item, map to plain sentences ("The server refused to save this. Usually a permission change, invalid data or a record deleted elsewhere. Retry once, else Discard"). No deploy. Honest limit: write-rejected stays vague.
- B: server adds an additive `detail` = whitelisted Firestore code name (never the message) to every `send(res, 500, ...)` body, client maps each to its own sentence. Better text and better debugging on device. Costs: a `functions/` change at 5 call sites + 100% tests + Taher must deploy; old clients ignore the field, new clients without the deploy fall back to A.
- C: A now, B later only if on-device text proves too vague. (Taher can already read Cloud Functions logs, which hold the real code.)

### Q-EC-2 P2 (queued, later reverted): how loud?
- **A (recommended): one error toast with the cause** ("Order for <customer> was not completed: <cause>"), order stays `pending`. Cheap, uses the existing `dispatcher.errorOccurred("order", msg)` path.
- B: A + a persistent list entry (Activity or notification). Survives an app restart, but a new surface to build, test and keep consistent. Not worth it before the toast is proven insufficient.
- C: status quo (silent). Rejected: the user was told "done", then it un-done itself with no word.

### Q-EC-3 Persist the cause across relaunch?
- **A (recommended): yes**, as `lastError {code, status}` on the outbox item next to the persisted stuck meta (P5 did the same for `stuck`/`terminal` because losing it on relaunch was seen on device). Additive field: old saved items just have none, the sheet falls back to today's text.
- B: in-memory only. Smaller, but after a relaunch the sheet is generic again, exactly the case a user opens it.

## 3. Proposed scope (small, three slices, one PR each unless told otherwise)
- **S1 pure helper** `qml/helper/FailureCause.js` (`.pragma library`, no QML): `forRejection(rejection, opEntityName)` and `forWriteError(code, status)` -> `{ text, kind }`; `orderLabel(item)` -> customer / order id for P4. Never throws, unknown code -> generic text. Tests runnable in Node in the sandbox.
- **S2 stuck path** (P3, P4): `StuckWrites.noteFailure/metaOf/hydrate` carry `lastError`; `OutboxStore.setStuckMeta` persists it; `Gateway.stuckRows()` returns `cause`, `StuckWritesSheet` shows it; `DescribeItem` uses `orderLabel`. Clears when the item leaves the outbox (existing `prune`).
- **S3 completion path** (P1, P2): `DataModel` uses `FailureCause` for the exhausted-replans message and toasts when `callback` is already null.
- NOT in scope (separate PRs, order set by Taher in #90): Task 11 "Saved, syncing" hint, C-1 `_tryAdjustOrder`.

## 4. Risks
- `Gateway.qml`, `OutboxStore.qml`, `StuckWritesSheet.qml` and the `DataModel` re-plan loop are the most delicate files in the app; QML tests are CI-only, so expect one CI round.
- Re-plan loop: the toast must fire exactly once per finished completion (not once per attempt). Test with a monkey run.
- Text must not claim a cause the code cannot know: P3 under option A says "usually", never asserts.
- Strings are `qsTr`; no new colours or layout, same `Text` styles as the sheet today (qt-ui-design: no new component).

## Addendum 2026-10-15: Q-EC-4 (decided by Taher: option A, in this PR)
**Problem:** an `inactive` member makes every write endpoint answer HTTP 403 `no-tenant-context`. That is "stuck, retrying", not parked, and the cause line fell through to "The server returned an error (HTTP 403)", which does not tell the person their access changed.
**Superseded 2026-10-28 (S2f-3): the text now reads "The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it" (names the two usual causes, still hedged). The decision below is kept for the record.**

**Decision:** map `no-tenant-context` in `FailureCause.forWriteError` to "The server no longer accepts your access to this shop. Your account may have been changed or deactivated. Ask the shop owner" (kind `access`). Hedged with "may" because the same code also covers a missing user record or an account with no shop. Not changed: the 403 stays non-terminal (the member can be re-activated, so retrying is right). Tests: U14, U15, F06e.

