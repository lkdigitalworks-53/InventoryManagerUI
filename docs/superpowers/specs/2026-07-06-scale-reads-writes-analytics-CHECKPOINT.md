# Implementation Checkpoint — Scale Reads/Writes/Analytics

Tracks progress across sessions so work can resume without re-deriving context. Update this file
after every meaningful step (branch created, code written, reviewed, committed, or pushed).

**Design doc:** `docs/superpowers/specs/2026-07-06-scale-reads-writes-analytics-design.md` — read
this first for the full architecture/rationale. This file is the "where are we, what's left" tracker.

**Repo:** `https://github.com/lkdigitalworks-53/InventoryManagerUI.git` — **now private**. Any future
session needs a fresh push token from Taher to push (repo can still be cloned read-only if a token is
provided for that too, since it's private now — plain `git clone` without auth will fail).

**Local repo path (this session):** `/home/claude/InventoryManagerUI` (container clone — this
filesystem resets between sessions, so a fresh session must reclone; nothing is lost, since every
commit below is already pushed to `origin`).

**Standing workflow rules (unchanged, saved in Claude's memory, apply automatically in future
sessions too):** show full file/diff for review before any further action; commit only after
Taher's explicit confirmation; push only after Taher provides a push token in that session.

---

## Status at a glance — everything below is committed AND pushed to `origin`

| Item | Branch | Commit |
|---|---|---|
| Design spec written + reviewed | `main` | `20ecac5` |
| Phase 0 — write-path fix (3 call sites) + read stopgap | `fix/write-path-bulk-overwrite` | `32af145` |
| Phase 1 — full pagination, all 6 stores | `feature/paginated-reads-phase1` | `66ce94b`, `8ef5887`, `d6b7717` |
| Phase 2 — env-aware Cloud Functions + `computeAnalysis` + `AnalysisService.qml` | `feature/paginated-reads-phase1` | `5e5e69c` |

**Neither `fix/write-path-bulk-overwrite` nor `feature/paginated-reads-phase1` has been merged into
`main` yet.** Both are pushed and PR-ready; merge strategy (open PRs? merge order? squash?) hasn't
been decided — that's a legitimate open question for Taher, not something to decide unilaterally.

## What's NOT done — deferred as its own future project (decided, not just paused)

**`SalesPage.qml` has not been cut over to `AnalysisService`, and this is now explicitly deferred as
its own separate, undesigned future project** — not "a separate later step of Phase 2" as earlier
checkpoint text said. Correction, found when actually starting this work: `InventoryStore.
realisedProfitByDimension`/`realisedTotals`/`realisedBucketWalk` are called *synchronously* at 15+
call sites in `SalesPage.qml` (the main `_rebuildBreakdown()` view, plus a 5-call export flow) — a
synchronous function cannot return a value that depends on `AnalysisService.compute(...)`'s async
network response. There is no "thin passthrough" version of this swap; it requires rewriting
`SalesPage.qml`'s data-loading flow to be callback-driven (loading states per chart/hero, the
export flow's 5 calls batched into one `dims:[...]` request). That's a real risk to a large file
with zero automated test coverage (Skill 29's coverage ceiling). Taher explicitly chose to defer
this entirely rather than attempt it now or as a smaller partial step — see design spec §9.1 for
the full writeup (added there specifically so this isn't rediscovered from scratch later).

`computeAnalysis` and `AnalysisService.qml` remain built and available for whenever that future
project is taken up — their contract doesn't need to change to support it.

---

## Full picture: what actually changed and why (read this before touching related code again)

### Phase 0 — write-path fix (`fix/write-path-bulk-overwrite`, `32af145`)
Firestore hard-caps a single `:commit` at 500 writes. `OrdersStore._commit` (every order mutation),
`StaffStore.addStaff`, and `ActivityLog`'s 4 mutators (`record`/`markAllRead`/`dismiss`/`dismissAll`)
all rebuilt their *entire* collection into one bulk commit on every change — a hard failure waiting
to happen past 500 docs, not just wasteful. Fixed to single-doc (or, for genuinely multi-doc actions
like `approveAllPending`, chunked via the new `FirebaseService.putMany()`) writes. Everything else
(`InventoryStore`/`StockBatchStore` via `Gateway.recordMutation`, `SupplierStore`, `TransactionStore`)
was already correct — **do not re-touch those**, they were audited and confirmed clean.

Also includes the immediate read-side stopgap: `FirebaseService.get()` now follows Firestore's
`nextPageToken` instead of silently returning a truncated first page (this was the exact bug behind
"250 products in Firestore, only 170 show up in the app" — confirmed and reproduced).

### Phase 1 — full pagination, all 6 stores (`feature/paginated-reads-phase1`, 3 commits)
New `FirebaseService.query()` (Firestore `:runQuery`, cursor-based, `limit+1` over-fetch trick for
exact `hasMore` detection) + `PagingHelper.js` (pure merge/cursor logic). All 6 stores
(`InventoryStore`, `StaffStore`, `SupplierStore`, `OrdersStore`, `TransactionStore`,
`StockBatchStore`) now page in <=50-doc chunks and **auto-page to exhaustion** — full local data,
same app behavior as before, just pagination-safe fetch mechanics.

**Important, easy-to-forget finding:** the original plan was "bounded collections auto-page, unbounded
ones (orders/ledger) keep a recent window." That was revised (see design spec SS3.1) after auditing
every consumer of `OrdersStore`/`TransactionStore`/`StockBatchStore` and finding they're read directly
by correctness-critical logic *today* — FIFO consumption (`DataModel.qml`'s `consumeFifo`/
`topUpOldest`/`restoreFifo`, and `InventoryStore`'s stock-value functions which filter for
`qtyRemaining > 0` **after** iterating the whole array — an old, large, not-yet-exhausted batch would
silently vanish from stock value under a recency window), Dashboard/KPI sums (`SalesStore.qml` loops
the full `OrdersStore.orders`), import dedup (`ImportPreviewDialog.qml` builds a full existing-orders
map), and the live Analysis page (`SalesPage.qml` reads `TransactionStore.entries` directly right now,
not just after some future phase). **A real memory-bounded redesign for these three is explicitly
deferred, unscheduled future work (SS9 Phase 3 in the spec) — don't attempt it casually, it requires
redesigning Dashboard KPIs, import dedup, and FIFO consumption simultaneously.**

**Safe-default pattern established (apply this if touching any collection's query ordering again):**
default to ordering by Firestore's `__name__` (always present on every doc, immune to schema drift),
NOT by an app-level timestamp field, unless you've confirmed that field is present on literally every
existing document. The tell to look for: a defensive `field || ""` / `field || fallback` fallback
already in the existing normalization code is strong evidence some documents lack that field —
ordering by it would make Firestore silently **exclude** those documents from paginated query
results entirely (same failure shape as the original bug, just reintroduced via a different field).
This was caught for `SupplierStore.createdAt`, `OrdersStore.date`, `TransactionStore.timestamp`, and
`StockBatchStore.receivedDate` — all four default to `__name__` instead.

### Phase 2 — env-aware Cloud Functions + `computeAnalysis` (`feature/paginated-reads-phase1`, `5e5e69c`)
Two things landed together, on purpose (they share one helper):

1. **Env-awareness fix for all 4 Cloud Functions** (`recordMutation`, `provisionMember`,
   `runCutover`, new `computeAnalysis`). Confirmed in the actual code: `admin.firestore()` was called
   once at module load with no `databaseId`, meaning every Cloud Function always read/wrote the
   `(default)` (prd) database regardless of which env (dev/test/prd) the calling client was built
   for — exactly the gap SKILLS.md's Skill 30 already flagged for the write side, now confirmed and
   fixed. New `scopedDb(env)` mirrors `EnvConfig.js`'s stage->env->databaseId chain exactly (fail-safe
   to prd), and `db` is now resolved **per request** from a client-declared `env` field, not a
   module-level global. `Gateway.qml` injects `env: FirebaseService.environment` into all 3 of its
   outgoing bodies so no caller (stores, `AuthService.qml`) needed to change.

   Note: `Gateway.mode` currently defaults to `"direct"` and `provisioningAvailable` to `false` —
   meaning `recordMutation`/`provisionMember` aren't actually exercised by the client in normal
   operation today (only `runCutover` fires unconditionally, and that's a rare owner-only action).
   This fix is real but currently latent groundwork, not an active-bug fix — it matters for whenever
   those switches flip to enable the gateway path for real.

2. **`computeAnalysis`** — new Cloud Function, same `onRequest`+Bearer+`deriveContext` convention as
   the existing 3. Reads a tenant's `transactions`/`orders`/`inventory`/`suppliers` via
   `readAllPaged()` (Admin-SDK-internal pagination, <=500 docs/page — never one unbounded query), then
   runs **ported** (not literally shared — QML's `.pragma library`/`.import` isn't valid Node syntax)
   versions of `RealisedMath`/`BreakdownMath`/`OrderMath` in `functions/lib/`. Returns
   `{totals, byDimension, bucketWalk}` — see spec SS6.5 for the exact contract.

   **Honest scope note, written into the code too:** reads are paginated, but the accumulated result
   is still one in-memory array by the time the math runs (`RealisedMath`/`BreakdownMath` take a full
   `entries` array, same as the QML originals — no streaming/incremental rewrite was attempted). This
   still fixes the actual failure mode (an unbounded read tripping Firestore's response/size limits)
   and moves the memory burden from a phone to a Cloud Function with far more headroom. A true
   streaming version is a possible future refinement, not attempted here.

   Parity between the QML math and its Node port is proven by fixtures lifted directly from already-
   verified cases in `tests/tst_RealisedMath.qml`/`tst_BreakdownMath.qml` (not invented fresh) —
   `functions/test/*.test.js` (5+2 tests, all passing via `cd functions && npm test`), with paired QML
   mirror files (`tests/tst_{RealisedMath,BreakdownMath}ParityFixtures.qml`) that need a real
   `qmltestrunner` run to fully confirm (couldn't run that in this container — no Qt/Felgo toolchain
   here, it's a Windows binary per SKILLS.md's Skill 27).

**What's verified vs. not, honestly, for Phase 2:**
- Verified in this container: all pure math logic (both the ports themselves and their parity against
  known-correct QML test values), the full `computeAnalysis` aggregation pipeline end-to-end with
  mock data standing in for Firestore, syntax-validity of every changed file (`node -c`).
- **NOT verified here** (needs a real machine / deploy / emulator): the QML parity test files under
  actual `qmltestrunner`, real Firestore reads (`readAllPaged`/`scopedDb`/`deriveContext` against a
  real or emulated database — `getFirestore(app, databaseId)` from `firebase-admin/firestore`
  should work with the installed `firebase-admin@^12.6.0`, but this was never exercised against a
  real database), and the full HTTP request/response path end-to-end (auth token verification, CORS,
  actual network round-trip).
- Two of my own bugs were caught and fixed before landing, worth knowing about if debugging similar
  issues later: (1) a `PagingHelper` test fixture that under-supplied the over-fetch row (test data
  bug, not implementation), caught by porting the test to Node and running it; (2) `functions/
  package.json`'s `test` script initially used `node --test test/` (trailing slash), which fails
  Node's module resolution — `node --test` with no path argument (default discovery) is what
  actually works.

---

## Next action for a fresh session

**There is no pending implementation work from this design.** Phase 0, Phase 1, and Phase 2 (as
actually scoped — the backend capability, not the SalesPage cutover) are complete, committed, and
pushed. The `SalesPage.qml` cutover is deferred as its own future project (see above and spec §9.1)
— it needs its own brainstorming/design pass when Taher wants to take it up, not a continuation of
this one. Likely first questions for that future project: does it get its own design spec file, and
does it happen before or after the branch/merge decisions below.

Two open, undecided questions for Taher whenever he's ready:
1. Branch/PR/merge strategy for the two already-pushed, not-yet-merged branches
   (`fix/write-path-bulk-overwrite`, `feature/paginated-reads-phase1`).
2. Whether/when to actually deploy the Cloud Functions changes (`firebase deploy --only functions`)
   — nothing in Phase 2 has touched a real Firestore instance yet; that deploy would be the first
   real end-to-end test of everything built here.

---

## Session log

**2026-07-09, session 2 — bug found in QA before merge (IN PROGRESS):**
- Taher QA'd `feature/paginated-reads-phase1` before merging and found: on cold app open (persisted
  session, not a fresh login), some of the six paginated stores randomly come back 403/empty; a
  logout/login always fixes it. Not present on `main`.
- **Root cause (confirmed via `superpowers:systematic-debugging`, code-evidence-based, no app run
  needed — no Qt/Felgo toolchain in this container):**
  1. All six stores fire their first Firestore read unconditionally from their own singleton's
     `Component.onCompleted`. `DashboardPage.qml`'s eager property bindings
     (`OrdersStore.revision`/`InventoryStore.revision`/`ActivityLog.revision` at lines ~200-202, plus
     `StaffStore.staff` via a KPI card) force those singletons into existence — and thus fire their
     first fetch — before `AuthService`'s `Component.onCompleted` (which calls
     `AuthStore.loadSession()`, restoring `idToken`/`tenantId` from disk) has necessarily run.
     `AuthService` is only pulled in via `Connections { target: AuthService }` / the explicit
     `AuthService.ensureFreshToken()` call in `App.Component.onCompleted` (`Main.qml:37-39`) — no
     earlier eager binding guarantees it goes first. With `AuthStore.tenantId == ""`,
     `FirebaseService._resolvePath()` (`FirebaseService.qml:62-65`) returns the **unscoped** path,
     which Firestore rules reject with 403 — matches the log exactly (`documents:runQuery` /
     `documents/activity_log` with no `tenants/{id}/` prefix).
  2. This part isn't random by itself — it happens every cold start. The **existing** safety net
     (`Main.qml`'s `onTenantContextReady` handler, already in the codebase, re-syncs every store once
     tenant context resolves) is what makes it *look* random: Phase 1 pagination added a
     `loadingMore` single-flight guard (needed for the recursive page-loop) to
     `OrdersStore`/`InventoryStore`/`StaffStore`/`TransactionStore`/`SupplierStore`/`StockBatchStore`.
     If the resync's `syncFromFirebase()` call lands while the store's own doomed first request is
     still in flight, `if (loadingMore) return` silently drops the resync — no new request is sent,
     and `_resetAndFetch()` already cleared the array to `[]` moments earlier. Nothing then ever
     repopulates the store until logout/login restarts the cycle with `loadingMore` already `false`.
     Outcome depends purely on network timing (whether the tenant-context round trip finishes before
     or after each store's own first request) — hence "random."
  3. **Control case confirmed the mechanism**: `ActivityLog.qml` was *not* touched by pagination —
     still plain `FirebaseService.get()`, no `loadingMore` guard — so its resync is never dropped.
     That's exactly why the user's log shows `ActivityLog` fail-then-succeed on every run, while
     `OrdersStore`/`InventoryStore`/`StaffStore` only ever showed the single failure.
  4. Confirmed via diff (`d6b7717`) that pre-pagination `OrdersStore._fetchFromFirebase` used plain
     `FirebaseService.get()` with no concurrency guard at all — the guard (and thus this failure
     mode) is new in this branch, explaining why `main` doesn't show the bug.
- **Fix direction chosen (root-cause level, not a retry-coalescing patch):** stop the six stores from
  firing the premature, doomed first fetch at all. `onTenantContextReady` already unconditionally
  re-syncs every one of them on both cold start and fresh login, so the `Component.onCompleted`
  fetch only needs to run when `AuthStore.tenantId` is *already* known at that exact moment
  (lazy/warm creation, well after tenant context resolved); otherwise defer entirely to the existing
  `onTenantContextReady` resync. Removes the race instead of coordinating around it.
- **Status:** root cause confirmed, fix direction agreed with Taher.
  - [x] TDD step 1 (RED/GREEN proof): wrote a Node-runnable pure-logic reproduction (same technique
    as `tst_AddStaffSyncClose.qml` — model the timing bug with a minimal object, since the real
    singletons need the full Felgo App context and this container has no Qt toolchain). Confirms:
    old code drops the retry when it races the first request (bug), old code self-heals when it
    *doesn't* race (proves the "random" symptom is the same code, different timing), fixed code
    never sends the doomed first request and is deterministic either way, fixed code has no
    regression for warm/lazy store creation (tenantId already known at `Component.onCompleted`).
    Scratch file `scratch_race_repro.js` at repo root, all 4 assertions pass — will be deleted
    before commit (not part of the real test suite).
  - [x] Ported the proof into `tests/tst_TenantContextRaceGuard.qml` (repo's real suite — same
    "model the timing with a minimal object" technique as `tst_AddStaffSyncClose.qml`, since the real
    singletons need the full Felgo App context and can't load under `qmltestrunner`; not run here for
    the same reason — needs a real machine, per Skill 27). 4 cases: old-code drops the retry when
    racing, old-code self-heals when it doesn't race (proves "random" = timing, not two code paths),
    fixed-code never drops regardless of race timing, fixed-code has no regression for warm/lazy
    creation (tenantId already known at `Component.onCompleted`).
  - [x] Applied the fix to all six stores (`OrdersStore`, `InventoryStore`, `StaffStore`,
    `TransactionStore`, `SupplierStore`, `StockBatchStore`) — same one-line change at each call site:
    `Component.onCompleted` only calls `_load()`/`_resetAndFetch()` when `AuthStore.tenantId.length >
    0`; otherwise defers entirely to the existing `onTenantContextReady` resync in `Main.qml`. No
    change to `loadingMore`/pagination logic itself — this removes the race instead of coordinating
    around it. `ActivityLog`/`OrderChannelStore`/`CategoryStore` have the same
    `Component.onCompleted`-fires-a-fetch shape but were left untouched (out of scope for this bug —
    `ActivityLog` has no `loadingMore` guard so it isn't actually broken today; flagging as an
    optional follow-up, not bundling it in).
  - [x] Linted the six changed files (`qt-qml-review` Phase 1 script, deterministic, no Qt needed):
    zero findings within the exact lines this fix touched. (The full-file run surfaces many
    pre-existing `var`/`==`/property-ordering findings elsewhere in these files — unrelated
    pre-existing style, out of scope, not touched.)
  - [x] Diff reviewed line-by-line in this session — six files, same single change repeated, no
    unrelated edits.
- **Status: committed and pushed to `origin` — `951fa11` on `feature/paginated-reads-phase1`.**
  - [x] TDD proof, real test (`tests/tst_TenantContextRaceGuard.qml`), fix in all six stores, lint
    clean, diff reviewed, committed, pushed. Still needs a real `qmltestrunner` run on an actual
    machine to fully confirm (same limitation as the Phase 2 parity tests — no Qt/Felgo toolchain in
    this container).
  - `ActivityLog`/`OrderChannelStore`/`CategoryStore` optional follow-up (same
    `Component.onCompleted`-fires-a-fetch shape, not actually broken today) remains open, undecided.
  - Push token used this session should be treated as burned — Taher was told to revoke/rotate it on
    GitHub right after the push.

**2026-07-06, session 1:**
- Read `/mnt/skills/plugins/superpowers:brainstorming/SKILL.md`, followed its process for the design
  spec (context exploration -> clarifying questions -> approaches -> sectioned design -> write spec ->
  self-review).
- Cloned repo fresh into `/home/claude/InventoryManagerUI` (container filesystem resets between
  sessions — recloning is expected, not a data-loss event).
- Found & fixed the confirmed 250->170 product truncation bug (unfollowed `nextPageToken`).
- Full store-by-store audit requested by user — found write-path bulk-overwrite bug isolated to 3
  call sites (`OrdersStore._commit`, `StaffStore.addStaff`, `ActivityLog.record`), confirmed
  everything else already correct.
- Wrote and committed the design spec (`20ecac5`).
- Implemented + pushed Phase 0 (write-path fix, `32af145`).
- Implemented + pushed Phase 1 foundation + `InventoryStore` pilot (`66ce94b`).
- User asked to use brainstorming skill again for the remaining stores. Deeper audit found
  `OrdersStore`/`TransactionStore`/`StockBatchStore` are read directly by correctness-critical logic
  (FIFO, KPIs, import dedup, live Analysis) — the original "recent window" plan for these three would
  have silently miscomputed real numbers, not just under-displayed a list.
- User redirected: keep full-local-data behavior for all 6 stores in Phase 1 (fix the read/write
  *mechanics* only), explicitly document the real memory-bounded redesign as deferred future work,
  and confirmed the Blaze plan is active. Spec revised (SS3, SS3.1, SS9, SS10) and committed along with
  `StaffStore`/`SupplierStore` (`8ef5887`).
- Completed Phase 1 for the remaining 3 stores (`OrdersStore`/`TransactionStore`/`StockBatchStore`,
  `d6b7717`).
- Used brainstorming again for Phase 2: explored `functions/index.js`, confirmed the env-unawareness
  gap in real (already-deployed) code, confirmed `Gateway.mode`/`provisioningAvailable` currently
  make `recordMutation`/`provisionMember` dormant in normal operation. User decided to fix
  env-awareness for all 4 functions together. Built ported math libraries + parity tests,
  `computeAnalysis`, `AnalysisService.qml`, `Gateway.qml` env injection (`5e5e69c`).
- Repo visibility changed to private by Taher partway through the session; a fresh push token was
  provided and used for the final push. **Any future session needs a new token from Taher to push
  (and, since the repo is now private, likely to clone/pull too).**
- This checkpoint file substantially rewritten at the end of the session (per Taher's explicit
  request) to be self-sufficient for a fresh session — the conversation itself had become too large
  to carry forward as context.
- Taher then asked to continue with "next remaining steps, as per the plan" (the SalesPage cutover).
  Investigating the actual call sites (not just assuming, per this project's established discipline)
  found the cutover was mischaracterized in the checkpoint/spec as a "thin passthrough" — it isn't
  one, since `InventoryStore`'s three realised* functions are called synchronously at 15+ sites and
  `AnalysisService.compute` is necessarily async. Surfaced this to Taher rather than either
  proceeding with a large risky rewrite or silently declining. Taher chose to defer the cutover
  entirely as its own future project. Design spec (§9, §9.1, §10, §11) and this checkpoint corrected
  accordingly so the mistake isn't rediscovered later.
