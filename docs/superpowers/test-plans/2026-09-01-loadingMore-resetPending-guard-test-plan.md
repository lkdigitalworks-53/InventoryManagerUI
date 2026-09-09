# Test plan — feature/2026-09-01-loadingMore-resetPending-guard

**Covers:** `_resetPending` flag added to all 6 paginated stores — `TransactionStore.qml:44,73,116`,
`InventoryStore.qml:30,79,116`, `OrdersStore.qml:34,101,143`, `StaffStore.qml:31,299,313`,
`StockBatchStore.qml:50,110,144`, `SupplierStore.qml:42,87,122`. Design: `SKILLS.md` Skill 39
(original concurrent-reset-race fix and its noted residual trade-off) + this branch's entry in
`docs/superpowers/E2E-TESTING-ROADMAP.md`'s "Resolved this arc" section (no separate `specs/` design
doc was written for this one — the design was small enough to live in the roadmap entry directly).

**Read this first:** the *concurrent dual-trigger* race (`Component.onCompleted` and
`onTenantContextReady` both calling `_resetAndFetch()` in the same tick) was already fixed and is
**not** what this branch touches — that fix (`if (loadingMore) return`) stays exactly as it was. What
this branch adds is narrower: that same guard had a known, accepted side effect — a **genuine**
account switch that happens to land while a fetch is still in flight was silently dropped instead of
honored. `_resetPending` fixes that specific gap. If you're testing this, you are specifically trying
to make a real account switch land *during* an in-flight sync, not just testing that switching
accounts works at all (that part was never broken).

**Status (2026-09-01):** implemented, automated tests written and passing, **not yet run on a real
device or against the real singletons at all** — see Section 1.2. This is a different, and in one way
worse, gap than item 1's N3: item 1 has synthetic coverage that's merely *unconfirmed* against real
timing; this fix's only automated coverage is a **hand-written model** of the real code, not the real
code itself (`FirebaseService.query` turned out to be non-injectable — confirmed, not assumed, see
the roadmap's testing-environment-limitations callout). Section 3.2 below is the only way to know
whether the real stores actually behave like the model.

---

## 1. Unit tests

### 1.1 Already covered (automated, in `tests/`)

`tests/tst_ResetPendingGuard.qml` (6 tests, all passing under `qmltestrunner` in the CI/dev sandbox) —
a minimal plain-JS-object model of the `loadingMore`/`_resetAndFetch`/`_fetchFromFirebase` control
flow (same technique as the pre-existing `tests/tst_TenantContextRaceGuard.qml`), covering: the old
(pre-fix) behavior silently applying stale data when a reset races an in-flight fetch, the fix
deferring rather than dropping a racing reset, the fix ending up with the new account's data instead
of the stale response, the fix coalescing multiple rapid resets (A→B→C, arriving before A's response
lands) down to exactly one extra request for the last one requested, and the non-racing baseline path
being unchanged.

`tests/tst_TenantContextRaceGuard.qml` (pre-existing, 5 tests) — the *original* concurrent-reset-race
fix this branch builds on. Untouched by this branch; still relevant context for why the `loadingMore`
guard exists in the first place.

### 1.2 Gap — not covered by any committed test, this is what Section 3 exists to close

- **Neither test file above exercises the real store singletons.** Confirmed this session, not
  assumed: reassigning `FirebaseService.query` from a test throws `Cannot assign to read-only
  property`, so the real async callback path can't be driven deterministically from a test at all.
  The model in `tst_ResetPendingGuard.qml` is a careful, traced-through reimplementation of the real
  control flow — but it's still a *reimplementation*, hand-kept in sync, not the shipped code. If the
  real `_resetAndFetch`/`_fetchFromFirebase` pattern in any of the 6 stores drifts from what the model
  assumes (now, or in some future change that doesn't also touch the model), the model's tests would
  keep passing while proving nothing about what's actually running. **This is the entire reason
  Section 3.2 below needs to happen on a real device — there is no automated substitute available for
  it right now**, same conclusion as item 1's N3 but for a structurally different reason (there, the
  gap is untested *timing*; here, the gap is that even the tests that exist don't touch the real code
  path at all).
- Not exercised anywhere: what happens if a genuine reset lands while a store is specifically in its
  **retry backoff window** (`TransactionStore` only — the other 5 stores have no retry logic at all).
  During that window `loadingMore` is already `false` (see `TransactionStore.qml:105-107`), so
  `_resetAndFetch()` takes its *normal* path, not the `_resetPending` path — reasoned through as
  correct (stops the pending retry timer, resets, fetches fresh), but never actually exercised, model
  or otherwise. Covered on-device in E3 below.

---

## 2. Regression tests

Nothing in this list should have changed behavior — these are either untouched code paths, or the
same guard clause that existed before this branch, just with one more line added after it.

- [ ] Normal sign-in, single account, no switch mid-sync — every store's initial `_resetAndFetch()`
      call (via `Component.onCompleted`/`onTenantContextReady`) still runs exactly once, same as
      before this branch. `_resetPending` should never even become `true` in this flow.
- [ ] The *original* concurrent dual-trigger race this branch's prerequisite fix covers
      (`Component.onCompleted` and `onTenantContextReady` both firing) — still resolved the same way,
      `tst_TenantContextRaceGuard.qml` untouched and still passing.
- [ ] Normal multi-page pagination (any store with enough rows to page) — `hasMore`/`_cursor`
      chaining across pages, no switch involved, should feel identical; this branch's new check
      (`if (_resetPending)`) sits *before* the existing pagination-chaining logic in every store's
      callback and only diverts when the flag is actually set.
- [ ] `TransactionStore`'s retry-on-failure path (a fetch that fails once, backs off, retries) with no
      account switch involved — untouched logic, `_retryTimer`/`_scheduleRetry()` unchanged by this
      branch.
- [ ] Sign out → sign back in as the **same** account, with no deliberate timing (i.e. not trying to
      race it) — should feel exactly as it did before this branch.
- [ ] Pull-to-refresh / manual sync triggers (wherever `syncFromFirebase()` is exposed in the UI), not
      racing anything — normal single-reset path, unchanged.

---

## 3. On-device tests

### 3.1 Happy path

| # | Flow | Steps | Expect |
|---|---|---|---|
| H1 | Normal sign-in | Sign in, let the app fully sync (all 6 stores) with no interruption | Everything loads normally, same as before this branch — this fix should be invisible when nothing races |
| H2 | Deliberate slow account switch | Sign out, wait several seconds (let any in-flight requests fully settle), sign in as a different account | Second account's data loads correctly — this is the *non-racing* switch case, should already have worked before this branch too |
| H3 | Pull-to-refresh mid-idle | Trigger a manual refresh on a screen backed by one of the 6 stores when nothing else is happening | Refreshes normally, no behavior change |

### 3.2 Negative / race tests — this is the section that matters

The goal in every scenario below is the same shape: **start a sync for account A, then trigger a
switch to account B before A's sync has finished** — and confirm the app ends up showing B's data,
not a mix of A's stale data and B's, and not a permanently-stuck loading state either. A tenant/
account with enough data that its initial sync takes a few seconds (not milliseconds) makes the
timing window realistic to hit without needing artificial network throttling; if both your test
accounts sync too fast to reliably race, throttling the connection (weak WiFi, or the device's own
network-condition simulation if available) widens the window.

| # | Scenario | Expect |
|---|---|---|
| N1 | **The core case.** Sign in as Account A (one with enough data that sync visibly takes a moment). While its initial sync is still clearly in progress (spinner/loading state visible), sign out and immediately sign in as Account B. | Account B's data ends up displayed correctly across all 6 stores — not Account A's stale data, not an empty/stuck state. This is the scenario `_resetPending` exists for; if this fails, the fix doesn't work as designed. |
| N2 | Same as N1, but time it to land **as late as possible** in A's sync — i.e. try to let A's fetch get as close to actually completing as you can before switching, rather than switching immediately after sign-in. | Same expectation as N1 — this tests the "response already essentially ready, discard it anyway" edge of the timing window, not just the "barely started" edge. |
| N3 | Same as N1, but for `TransactionStore` specifically, timed to land **during its retry-backoff window** rather than during an actual in-flight request — i.e. get A's transaction sync to fail once first (if you can trigger a failure deliberately, e.g. brief connectivity drop) so it's sitting in backoff, *then* switch accounts. | Per Section 1.2's reasoning: since `loadingMore` is `false` during backoff, this should take the *normal* reset path (stop the pending retry, reset, fetch B's data) rather than the `_resetPending` path — confirm this is actually what happens, not assumed from the code reading. |
| N4 | Rapid triple switch: A → B → C, each triggered before the previous one's sync could plausibly have finished. | Ends up showing **C's** data (the last one requested), not B's, not a mix, and not more than one extra network round-trip's worth of visible reloading per store — mirrors `tst_ResetPendingGuard.qml`'s coalescing test, on a real device instead of the model. |
| N5 | Switch accounts (A→B, racing as in N1), then **immediately** switch back to A again before B's sync finishes either. | Ends up on A's data again, correctly — same mechanism as N4 but specifically testing "switch back to where you started" rather than always moving forward to a new account. |

### 3.3 Edge cases

| # | Scenario | Expect |
|---|---|---|
| E1 | Race the switch against a store with **very little** data (fast sync) vs. one of the 6 with the **most** data in your test tenant (slow sync) in the same test pass — i.e. confirm the fix holds even for the store where the timing window is narrowest. | All 6 stores end up correct, not just the ones with an easy-to-hit window. |
| E2 | Switch accounts while one store is mid-pagination (page 2+ of a multi-page fetch), not just on its first page. | The abandoned page's data doesn't leak into the display, and pagination for the new account starts fresh from page 1 — confirms the early `return` in the callback (before the pagination-chaining logic) actually discards the stale in-flight chain rather than letting it finish one more page first. |
| E3 | Force a failure on one store's request (e.g. toggle airplane mode briefly, then back off) *without* switching accounts at all — confirm this alone still behaves exactly as before this branch (this is `TransactionStore`'s existing retry path with zero interaction from this fix, since no reset was ever requested). | No behavior change; sanity-checks that this branch didn't accidentally touch the plain-failure path. |
| E4 | Switch accounts, then switch a **third** time back to the very first account, all three racing tightly (A→B→A, not A→B→C like N4) — a specific variant worth trying since "switch back to where you started" could plausibly hit a different code path than "keep moving forward" if there's a subtle bug in how `_resetPending` gets consumed. | Ends up on A's data (the last one requested) — same expectation as N5, listed separately here because it's worth deliberately trying with the *tightest* possible timing, not just an unhurried version. |

### 3.4 Monkey testing

- Rapid sign-out/sign-in cycling (as fast as the UI allows) between two accounts for 30+ seconds
  straight — confirm the app never ends up permanently stuck loading, never crashes, and whatever
  account you stop on eventually shows correctly once things settle.
- Background the app (switch away) mid-race (during N1's window, right after triggering the switch to
  B), then foreground it again — confirm it recovers to B's correct data rather than being stuck
  showing A's stale state or an empty screen.
- Force-close and relaunch immediately after triggering an account switch mid-sync — on relaunch,
  confirm the app syncs the **currently signed-in** account correctly rather than showing anything
  left over from the previous session.

---

## 4. Suggested order of attack

1. **N1** — the core scenario this fix exists for. If this doesn't hold, nothing else in this plan
   matters until it does.
2. **N4** — the coalescing case; confirms the fix's actual mechanism (a flag remembering "at least one
   reset is pending," not a queue), not just that switching twice happens to work by accident.
3. **H1/H2** — confirm the non-racing paths still work at all before spending more time on race
   timing.
4. **E2** — the pagination-specific variant; a plausible place for a subtle bug even if N1 passes,
   since it's testing a different point in the callback (page 2+ vs. page 1).
5. **N3** — `TransactionStore`'s retry-window variant; lower priority than N1/N4 since it's reasoned
   through carefully already, but the one case in this plan with an actual "should NOT hit the new
   code path" assertion worth confirming.
6. **N2, N5, E1, E4** — the remaining timing/ordering variants, as time allows.
7. **E3** — quick sanity check, not expected to find anything.
8. Regression checklist (Section 2) — spot-check, nothing here was touched directly by this branch.
9. Monkey testing last, time-permitting.

## 5. Explicitly out of scope for this test plan

- Building a way to make `FirebaseService.query` mockable so the real singletons could be tested
  deterministically instead of via the model — a real fix here, if it's ever decided this class of
  bug is common enough to justify it, is a separate, deliberate piece of work (see the roadmap's
  testing-environment-limitations callout), not something to improvise inside this test plan or this
  branch.
- The year-boundary/counter-reset class of edge case from the batch-id-minting test plan — unrelated
  feature, not touched by this branch.
- Multi-device concurrent testing — same pre-existing gap noted in every other test plan this
  session's context references (no way to log a second session into the same tenant yet); not
  relevant here anyway, since this fix is about a single session's own sequential account switches,
  not concurrent sessions.

## 6. Sign-off checklist

- [ ] Section 1.1 automated tests passing — already confirmed in-session (`tst_ResetPendingGuard.qml`
      6/6, `tst_TenantContextRaceGuard.qml` 5/5), re-confirm in the real build if anything changes
      before this merges.
- [ ] N1 confirmed on-device — the one result this whole branch is actually waiting on.
- [ ] N4 confirmed on-device — proves the coalescing mechanism, not just single-switch correctness.
- [ ] N3 confirmed on-device — the retry-window variant, `TransactionStore`-specific.
- [ ] E2 confirmed on-device — the mid-pagination variant.
- [ ] Regression checklist (Section 2) — spot-check at minimum.
- [ ] Remaining Section 3.2/3.3 scenarios (N2, N5, E1, E4) and monkey testing — opportunistic, not
      blocking, if time is short.
