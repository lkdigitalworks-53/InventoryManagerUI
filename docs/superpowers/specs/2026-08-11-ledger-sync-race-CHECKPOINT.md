# Session Checkpoint — ledger-sync race on completed-order adjustments

**Started:** 2026-08-11
**Branch:** `fix/async-write-sequencing-review-fixes` (continuing on the same branch as the
2026-08-10 fix — Taher is testing this branch end-to-end and found this immediately after that fix)
**Status:** Fix implemented, tests written (unrun — no qmltestrunner in sandbox), docs updated.
Awaiting Taher's go-ahead in this session before commit/push (standing rule — nothing gets
committed/pushed without explicit confirmation each time, even mid-session).

## Trigger

Taher testing the 2026-08-10 before/after-aliasing fix on-device: add order → complete it → verify
in Firestore → close the app → reopen it → return an item. Symptom looked similar to the previous
bug (total not reflecting a return) but with a new, important detail: it only happened after an app
restart, and only if the return happened *promptly* after reopening. Given enough time after
reopening, everything worked normally. Taher's own diagnosis pointed at the tax/total calculation
in `OrdersStore.applyAdjustment` — correct call.

## Step log

1. First investigation pass (before Taher's follow-up) ruled out the ledger arithmetic itself: Node-
   ported `qml/helper/OrderMath.js`'s `allocate`/`refundPerUnit` and a hand-port of
   `TransactionStore.recordReturn`/`totalsForOrder`/`forOrder` (both source files are `.pragma
   library`, no QML deps, portable by their own header comments), ran three scenarios — simple
   single-line return, multi-line with 18% tax + a percent discount, and two sequential returns on
   the same order — all computed correctly. This ruled out a computation bug and narrowed the
   search to *what data the computation runs against*.

2. Taher's follow-up test isolated the actual variable: same sequence, no app restart (order stays
   open in the same running session, return happens "after some time" but with no restart) — works
   correctly, verified in Firestore. Same sequence WITH a restart, acting promptly — broken. Same
   sequence WITH a restart, waiting long enough first — works correctly. This pinpointed the bug to
   something that happens once, after a cold start, and finishes given enough time — a sync race,
   not a logic bug.

3. Traced `TransactionStore`'s Firestore sync: `Component.onCompleted` → `_resetAndFetch()` →
   `_fetchFromFirebase()`, paginated 50 docs/page via `FirebaseService.query("transactions",
   { limit, startAfter }, ...)`. Confirmed (reading `FirebaseService.query`) this defaults to
   `orderBy: "__name__"`, `direction: "ASCENDING"` — no override from the caller. Confirmed
   `TransactionStore._nextId(kind)` builds doc IDs as `"tx-" + kind + "-" + Date.now() + "-" +
   rand` — an ever-increasing, timestamp-prefixed string, meaning ascending-by-`__name__` is
   ascending-by-creation-time. **The newest transactions — including a just-completed order's own
   sale — load on the LAST page of the sync, not the first.**

4. Confirmed the actual failure mechanism in `OrdersStore.applyAdjustment`: for a completed order,
   `o.tax`/`o.total` come from `TransactionStore.totalsForOrder(orderId)` unconditionally — the
   `if (led) {...} else {...}` fallback is dead code, since `totalsForOrder` always returns an
   object, never null. If the order's own sale entry hasn't synced yet when a prompt return runs,
   `totalsForOrder` sums a ledger missing its base amount, and the wrong total gets committed.

5. Confirmed the scope of the fix needed: `grep -rn "totalsForOrder(" qml/` — exactly one caller,
   `OrdersStore.applyAdjustment`'s completed-order branch. Order completion itself doesn't read this
   ledger (`recordSaleFromOrder`'s allocation comes from the order's own `products`). This ruled out
   Taher's initial instinct to block the whole app while any store is syncing — the actual
   dependency is narrow, and a global block would have been a real UX regression for any business
   with meaningful order history (the paginated sync could take a while).

6. Checked both routes into the vulnerable code: `DataModel.onAdjustOrder` (the normal
   ConfirmReturnSheet flow) and `DataModel.adjustOrderForImport` both delegate to
   `DataModel._tryAdjustOrder` — one guard there covers both. Checked `DataModel._reverseCompletedOrder`
   (the order-reopen path) separately — it writes to the ledger (`TransactionStore.recordReturn`)
   but never reads `totalsForOrder`, so it's unaffected and needs no guard.

7. **Implemented the fix**, three pieces:
   - `DataModel._tryAdjustOrder`: refuses (via the existing `dataModel.stockErrorMsg` +
     `callback(false)` pattern, matching the adjacent pre-existing status check) to adjust a
     completed order while `TransactionStore.hasMore` is true.
   - `OrderDetailDialog._save()`: the same check, proactively, right before the lines-changed branch
     that would otherwise open ConfirmReturnSheet — so the user finds out before filling in a
     reason/condition/note, not after.
   - `TransactionStore._fetchFromFirebase()`: added `_scheduleRetry()` — exponential backoff (3s,
     6s, 12s, 24s, capped at 30s), single-shot `Timer` via `Qt.createQmlObject`, mirroring
     `Gateway._drainTimer`'s existing pattern exactly (same file, same technique, already shipped).
     Necessary companion to the guard above: before this, a single failed sync page left `hasMore`
     stuck at `true` forever (no code anywhere reset it on failure) — shipping the guard without
     this would turn one dropped request into a permanent lockout on every completed-order return
     until the app restarts, which is a worse failure mode than the bug being fixed.

8. **Wrote two test files**:
   - `tests/tst_DataModel_adjustOrderSyncGuard.qml` — first test coverage for `DataModel.qml` at
     all (it isn't a `pragma Singleton` like the stores, so it's instantiated directly as a child
     item in the test; has no `Component.onCompleted` and the guard doesn't touch the
     dispatcher/RBAC layer, so this was safe to do standalone). Four cases: refuses while
     `hasMore` is true with a clear message, confirms no side effects on refusal (no ledger entry,
     no outbox item, order data untouched), proceeds normally once `hasMore` is false, and confirms
     the new guard didn't weaken the pre-existing pending-order check.
   - `tests/tst_TransactionStore_syncRetry.qml` — covers the backoff math in isolation (first-
     attempt delay, exponential growth, the cap, single-shot timer). Explicitly does NOT cover the
     actual network failure/retry round-trip — no established mocking pattern for `FirebaseService`
     responses in this test suite, and that path needs on-device verification instead (kill network
     mid-sync, confirm growing retry delays in the console log rather than a stuck `hasMore`).

   **Not run in this sandbox** — no Qt/qmltestrunner toolchain, same status as every other
   client-side test this session.

9. Ran the project's `qt-qml-review` deterministic lint script against every changed/new file,
   scoped to just the changed regions (diffed against baseline runs on the unmodified files to
   separate pre-existing findings from new ones). Two real findings on my own new lines:
   - `OrderDetailDialog.qml`: my new error message wasn't wrapped in `qsTr()` — fixed; this file's
     convention mixes plain and `qsTr()`-wrapped `stockErrorLabel.text` assignments depending on
     whether the string is static (wrapped, e.g. the two "confirming this order is free to edit"
     messages) or dynamically built (plain) — mine is static, so it should match the wrapped ones.
   - `TransactionStore.qml`: `LDR-3` (`Qt.createQmlObject` is slow/uncacheable) on the new retry
     timer, and `BND-1` (`property var` instead of a typed property) on `_retryTimer` — both
     verified against `Gateway.qml`'s existing, already-shipped `_drainTimer` construct, which
     triggers the identical findings. Not new anti-patterns; deliberately matching established
     precedent for a lazily-created singleton-scoped timer.
   Everything else was pre-existing (this project's `var`-everywhere convention, a pre-existing
   `!==` false-positive pattern in the linter already seen and documented in the 2026-08-10
   checkpoint, and unrelated findings elsewhere in files I only partially touched).

10. **Docs**:
    - `SKILLS.md`: appended **Skill 38** with the full mechanism (why ascending-`__name__`
      pagination + timestamp-prefixed IDs means newest-loads-last), why the fix is scoped to one
      caller rather than a global block, why the retry is a necessary companion not a nice-to-have,
      the general rule (anything trusting a paginated store's data to be *complete* needs to check
      its `hasMore`-equivalent flag), and an explicit "left alone, not fixed" note that
      `OrdersStore.orders` has the same paginated shape but nothing currently aggregates across it
      the way `totalsForOrder` does — worth the same scrutiny if that changes.
    - `AGENTS.md`: cross-referenced in the Compliance & Audit Agent section (same location as the
      2026-08-10 note, since Taher found this testing that fix); added the two new test files and
      updated the suite count (18 → 20) in the Testing & QA Agent section, noting `DataModel.qml`'s
      first-ever test coverage and why it could be instantiated directly rather than needing a
      singleton-style reference.
    - `README.md`: added a chronological "Update 2026-08-11" entry to "Concurrency & Conflict
      Resolution", ordered above the 2026-08-10 entry (reverse-chronological, matching the existing
      convention), explicitly noting the root cause was different from 2026-08-10 despite the
      similar surface symptom.

## Follow-up (2026-08-11, same day) — Taher's on-device retest found it wasn't fully fixed

Taher rebuilt and retested against `7bb1db4` (confirmed, not a stale-build issue). Result: no
"still syncing" message appeared when returning an item promptly after a restart, and order/
inventory screens showed inconsistent/partial data, self-resolving after enough time passed —
meaning the underlying sync race is still happening, but the new guard isn't reliably catching it.

Investigated two hypotheses:
- **Overlapping `_resetAndFetch()` calls** (the same category of race `OrdersStore` already has a
  documented comment about) — checked whether `Component.onCompleted` and `onTenantContextReady`
  could both fire `_resetAndFetch()` on a plain cold start. Evidence says no: `Component.onCompleted`'s
  guard (`AuthStore.tenantId.length > 0`) is normally false at creation time on a fresh launch, so
  `onTenantContextReady` should be the sole trigger. Not ruled out with certainty, but no positive
  evidence either.
- **`FirebaseService.query`'s pagination/`hasMore` logic** — re-read in full; it over-fetches by one
  specifically to detect `hasMore` exactly at the page boundary (`PagingHelper.mergePage`), shared
  by every paginated store in the app, not something touched by the 2026-08-11 fix. No evidence of
  a bug here either, though not exhaustively verified.

**Concrete bug found and fixed**: `_resetAndFetch()` never cancelled a pending retry timer. If an
earlier fetch attempt failed and scheduled a retry, then something reset the sync again before that
retry fired, the stale retry would still go off later against a `_cursor`/`entries` state it no
longer matches. Fixed — `_resetAndFetch()` now calls `_retryTimer.stop()` first.

**Could not identify a second concrete bug from static reading alone.** Rather than guess further
(risk of a larger, speculative rewrite — e.g. a generation-counter guard against overlapping syncs —
built on an unconfirmed theory), added targeted diagnostic logging instead:
- `DataModel._tryAdjustOrder` now logs `TransactionStore.hasMore`, `.loadingMore`, and
  `.entries.length` at the exact moment the guard checks them.
- The existing `[TransactionStore] Firestore sync failed, retrying...` / `Synced N transactions`
  logs from the original fix remain in place.

Asked Taher to retest with logcat/console visible and share the output — this turns the next round
into an actual trace instead of more speculation. Also asked for clarification on what "transactions
not getting updated" on the Orders/Inventory pages specifically refers to.

**Files touched this round**: `qml/model/TransactionStore.qml` (`_resetAndFetch` timer-stop fix),
`qml/model/DataModel.qml` (diagnostic log line only — no behavior change). No new tests this round
(no new testable behavior — the timer-stop fix is covered in spirit by the existing
`tst_TransactionStore_syncRetry.qml` backoff tests, and the log line has nothing to assert on).

## Follow-up 2 (2026-08-12) — Taher found and fixed the actual root cause himself

Taher retested with the diagnostic logging in place and diagnosed it correctly, in his own words:
`TransactionStore.Component.onCompleted` calls `_resetAndFetch()`, and separately `Main.qml`'s
`onTenantContextReady` handler also calls it. Both are async. Whichever's page-1 request lands first
sets `loadingMore = true` and starts accumulating pages; the second call ran anyway (nothing gated
it), wiping `entries` back to `[]` and resetting `_cursor` out from under the first, still-in-flight
fetch — corrupting the rest of that pagination chain. This is exactly why the 2026-08-11 guard
(`DataModel._tryAdjustOrder` checking `TransactionStore.hasMore`) didn't reliably fire: `hasMore`
itself could read `false` while `entries` was genuinely still incomplete, because the corruption
happened at the pagination-state level the guard never inspected.

Taher's fix, committed directly (`e512c3f`, `2c23e16`): `_resetAndFetch()` now starts with
`if (loadingMore) return`, applied to `TransactionStore` first, then extended to every other
paginated store with the same shape (`InventoryStore`, `OrdersStore`, `StaffStore`,
`StockBatchStore`, `SupplierStore`). Also added a detailed test plan doc (`b9c86fc`,
`docs/superpowers/specs/2026-08-08-async-write-sequencing-test-plan-in-detail.md`).

Asked me (this session) to: review the fix, document it properly for future improvements, and check
the two stores Taher's pass didn't touch (`SalesStore`, `AuthStore`) plus anywhere else this bug
might exist — fix if found, document if not.

### This session's review

1. **Verified Taher's fix is correct** for the exact race described — traced through
   `_resetAndFetch()`'s new guard line by line against the failure sequence.

2. **Full sweep of all 21 `qml/model/*.qml` singletons** (not just the two named), checking each for
   the vulnerable shape (reset-like function, accumulator state, async fetch, more than one trigger):
   - Confirmed `SalesStore` and `AuthStore` are both structurally immune — `SalesStore` has no
     Firestore fetch at all (`_rebuildDerivedData()` is a synchronous recompute over `OrdersStore.
     orders` already in memory); `AuthStore.loadSession()` is a synchronous local `QSettings` read
     with exactly one caller, no async, no second trigger possible.
   - Found **three more stores with the same dual-trigger exposure** Taher's pass didn't cover:
     `ActivityLog`, `CategoryStore`, `OrderChannelStore` — all in `Main.qml`'s `onTenantContextReady`
     resync list alongside the six already-fixed stores. Traced each in full: all three are
     structurally immune to the *corruption* itself (each does a single bounded fetch — a top-50
     query or a single-document `get()` — not multi-page pagination with a shared mutable cursor, so
     a duplicate concurrent call just re-fetches the same correct data harmlessly). But none of the
     three guarded `Component.onCompleted` with the `AuthStore.tenantId.length > 0` check every
     other dual-triggered store already had — meaning each fires a guaranteed-to-fail, unscoped
     Firestore request on every cold start before `onTenantContextReady`'s real sync runs. Different,
     smaller issue than the main bug, found while checking the same trigger pair; fixed for
     consistency with a one-line guard matching the established pattern (`qml/model/ActivityLog.qml`,
     `qml/model/CategoryStore.qml`, `qml/model/OrderChannelStore.qml`).
   - Confirmed `OutboxStore` and `PartyStore` have exactly one call site for their load functions
     (grepped the whole `qml/` tree) — safe by construction, no second trigger exists to race against.
   - Confirmed `AnalysisService`, `GoogleAuthService`, `LockManager`, `MigrationService`,
     `StorageService` have no `Component.onCompleted` or Firestore fetch at all — not applicable.
   - Found a third, currently-**dead** trigger while tracing `Main.qml`'s `onTenantContextReady`:
     `Logic.syncAllStores` / `DataModel.onSyncAllStores` calls `syncFromFirebase()` on seven stores,
     but nothing in the app actually emits `logic.syncAllStores()` anywhere today — declared and
     handled, never wired to a UI action. Already covered by Taher's fix regardless (the guard is on
     `_resetAndFetch()` itself, not per-caller), so no separate action needed — worth knowing if a
     future pull-to-refresh feature wires this signal up.

3. **Identified a residual trade-off in the fix as shipped**, not fixed, documented for a future
   decision: `if (loadingMore) return` also silently drops a *legitimate* reset arriving mid-fetch —
   e.g. switching accounts while the previous account's own initial sync is still in flight. Lower
   probability than the cold-start double-fire (needs a deliberate fast account switch), and not
   something Taher's testing has hit, but real. A "pending reset" flag (set a flag instead of no-op,
   re-run the reset once the in-flight fetch's callback completes) would close this without
   reintroducing the corruption risk — not implemented, since it's not a live bug and adds real
   complexity; flagged so it's a deliberate choice next time rather than a rediscovery.

4. **Wrote `tests/tst_TransactionStore_resetGuard.qml`** — two cases: `_resetAndFetch()` is a no-op
   (doesn't touch `entries`/`_cursor`) while `loadingMore` is true, and still resets normally when
   nothing is in flight. The second case deliberately lets a real `_fetchFromFirebase()` call run
   (same no-real-network safety pattern as `tst_Gateway.qml` — empty `AuthStore.idToken`), with a
   `cleanup()` that stops any retry timer it schedules so it can't bleed into other test files.

5. **Docs**: appended **Skill 39** to `SKILLS.md` (the full mechanism, why the `Component.
   onCompleted` guard's "shouldn't normally be true yet" assumption didn't hold on-device, the fix,
   the residual account-switch trade-off, and the full 21-store sweep table). Cross-referenced in
   `AGENTS.md` (Compliance & Audit Agent, Testing & QA suite count 20 → 21) and `README.md`
   (Concurrency & Conflict Resolution changelog, chronologically above the 2026-08-11 entry).

**Files touched this round**: `qml/model/TransactionStore.qml` (comments only — Taher's fix was
already in place, this session added no code change here), `qml/model/ActivityLog.qml`, `qml/model/
CategoryStore.qml`, `qml/model/OrderChannelStore.qml` (`Component.onCompleted` tenantId guard),
`tests/tst_TransactionStore_resetGuard.qml` (new).

## What's NOT done / needs Taher



- **On-device, the original repro**: complete an order, verify in Firestore, restart the app, and
  attempt a return immediately — confirm the new message appears ("Still syncing transaction
  history...") instead of the wrong total, and that waiting and retrying succeeds normally.
- **On-device, the retry path specifically**: the backoff *math* is tested, but the actual
  network-failure → retry → eventual success round-trip has no test coverage in this sandbox.
  Kill the network mid-sync (e.g., airplane mode right after opening the app) and confirm the
  console log shows retries with growing delays (`[TransactionStore] Firestore sync failed,
  retrying (attempt N)...`) rather than `hasMore` getting stuck.
- **`qmltestrunner`**: run all three new suites (`tst_DataModel_adjustOrderSyncGuard.qml`,
  `tst_TransactionStore_syncRetry.qml`, `tst_TransactionStore_resetGuard.qml`) plus the existing
  baseline.
- **Not addressed, flagged only**: `OrdersStore.orders` has the same paginated/`hasMore` shape as
  `TransactionStore` (Skill 38, "left alone" paragraph) — no live bug found, but worth checking
  again if a future feature starts aggregating across the full orders list the way `totalsForOrder`
  aggregates across transactions.
- **A decision needed, not an on-device check**: whether the account-switch-mid-sync trade-off
  (Skill 39, "residual trade-off" paragraph) is worth the added complexity of a "pending reset" flag,
  or acceptable as-is given how narrow the window is.
