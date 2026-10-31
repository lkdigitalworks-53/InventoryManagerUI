# L3 session lifecycle — DESIGN (decisions OPEN, nothing built)

**Status:** 2026-10-31. Brainstorming path: **architectural** (a new client re-check flow, a server error contract, a new trigger). No code in this PR; every `L3-Dn` below has options, trade-offs, a recommendation and an empty `Taher:` line. Nothing is approved until those lines are filled.
**Why now:** PR #171's checkpoint named L3 next. Source: `2026-10-25-multi-role-login-design.md` section 3 D6/D7 and section 4 L3, a DRAFT whose D6/D7 were never answered. Reading the code to design it overturned two of that draft's premises (section 3), so this spec supersedes the L3 bullet there.
**Test plan:** `docs/superpowers/test-plans/2026-10-31-l3-session-lifecycle-test-plan.md` (planned, nothing run).

## 1. Intent (written back for correction)
- **Outcome:** a signed-in person whose access changes while the app is open (suspended, removed, role changed) finds out soon, from a clear screen, and a person whose access did NOT change is never disturbed by the check.
- **Who:** shop owners today (everyone in prod); staff, managers and admins once L1 ships.
- **Success:** (a) a refused member sees the access-blocked screen at the next check, without first having a write fail; (b) a healthy session never flashes the sign-in form or blank lists during a check; (c) a role change takes effect without a restart; (d) every path has automated tests and a device step.
- **Taher said:** pick up what PR #171 planned next. **My assumptions (correct me):** L3 changes what the server TELLS the client, never what it refuses; no realtime push; L1, L2, L4, L5 stay separate slices.

## 2. Verified facts (read in code at `main` f18445e, 2026-10-31; nothing was run)
- **F1 Re-check on token refresh exists.** `AuthService.refreshIdToken` (qml/model/AuthService.qml ~L456) calls `_loadUserProfile()` after every successful refresh. The refresh fires from the 120 s `Timer` in `Main.qml` (L165) via `ensureFreshToken`, which refreshes when the token is within 5 minutes of expiry (about hourly), and from 5 other call sites in four files (Gateway x2, LockManager, PhotoQueue, AnalysisService).
- **F2 A re-check is not silent.** `_loadUserProfile` sets `profileResolved = false`; `Main.qml` L693 shows `LoginPage` at z 100 while `!profileResolved`. When both reads answer, `_applyAccess` emits `tenantContextReady`, and `Main.qml` L314 re-syncs about ten stores. `OrdersStore._resetAndFetch` sets `orders = []` before it refetches. `onIsOnlineChanged` does the same on every offline to online flip. **Read from code, not seen on a device** (test-plan step B0 checks it).
- **F3 No resume hook.** No QML or JS file listens to `Qt.application.state`. While the app is suspended the Timer does not tick, so after hours in the background nothing re-checks until a gateway call finds the token near expiry.
- **F4 One server code for every refusal.** `deriveContext` (functions/index.js L138) returns `null` for six causes (`no-user-doc`, `no-tenant`, `unsafe-tenant`, `no-member`, `not-active`, `invalid-role`) and logs the cause; ten call sites answer `403 {error: "no-tenant-context"}`. `role-not-allowed` is a different code for a different question (member fine, action refused) and exists already for photos and `provisionMember`.
- **F5 "Leave" and member status are unlinked (old D7, was UNVERIFIED).** `StaffStore` statuses `on_leave` / `suspended` are roster text (StaffStore.qml L114, L170). Member `status` changes only through `AuthService.setMemberStatus` (Main.qml L782). No client or server code connects them.
- **F6 L1 has not shipped.** `Gateway.provisioningAvailable` is `false` (Gateway.qml L42): the app cannot create a non-owner login, so today non-owner paths are exercised only by editing Firestore by hand (as the PR #171 device test did). F1/F2 hit owners now.

## 3. Findings that change the plan
1. **KNOWN-ISSUES and two designs said "no re-check on token refresh". That was wrong** (F1). Corrected in this PR (KNOWN-ISSUES, the S2f-3 design line 44, the multi-role draft line 11). The draft's recommendation "re-resolve on every token refresh" (D6a) is already half built, by accident, with the side effects in F2.
2. **The accidental re-check is also the app's only periodic data refresh** (F2): about once an hour every store is refetched. The multi-role draft's D5 (cross-device freshness) assumed there was none. Making the check silent therefore removes a freshness side effect, which is a trade-off Taher must accept (L3-D1).
3. **Ordering trade-off, stated honestly.** L3 before L1 means the non-owner half of L3 has no real users yet and can only be device-tested by console edits. The silent-check half (slice A) fixes something owners hit today, which is the reason to build A now. B and C pay off when L1 ships; they are cheap to defer.

## 4. Decisions
**L3-D1. What a periodic re-check does when nothing changed.**
(a) Status quo: sign-in cover, resync everything. Cost: the flash and the blanked Orders list in F2, and once L3-D2 adds a resume trigger it would run on every app resume. Benefit: accidental hourly freshness. **Not viable with D2.**
(b) Silent check, never resync. Lowest cost. Freshness falls back to "login only" until L4.
(c) Silent check, resync only when tenant or role changed. Same normal-case cost as (b), correct after a role change (staff scope depends on role).
(d) Silent check, resync every time through a non-blanking merge. Needs every store's sync rewritten: that is L4's scope, not L3's.
(e) Smallest patch: keep the resync, replace `profileResolved = false` with a separate `checking` flag. Kills the sign-in flash, not the blanked lists, and D2 makes it worse.
**Rec: (c), then L4 (resume sync, pull to refresh) straight after slice A.** Honest regression: an owner who uses two phones loses the accidental hourly refresh until L4 lands. (e) is the choice if you want zero freshness change now.
Taher:

**L3-D2. When to re-check.** Today: launch, token refresh (about hourly), reconnect. Missing: resume from background, and a refused request.
(a) Add resume. (b) Add resume and a refused request (L3-D4). (c) Poll on a timer: rejected, two reads every two minutes is about 1,440 reads a day per device for nothing.
Throttle (applies to every automatic trigger): one check in flight; at least 60 s between automatic checks; a trigger inside the window is dropped, not queued; "Try again" bypasses the throttle. Two reads per check (users doc, member doc).
**Rec: (a) in slice A, the refused-request trigger in slice C.**
Taher:

**L3-D3. Server error contract.**
(a) Keep one code; the client reads the member doc to learn the cause (it already does for the blocked screen). (b) Keep `error: "no-tenant-context"` and add a `reason` field. (c) Replace the code with distinct codes.
(c) breaks every client already in the field: D15 matches status 403 plus that exact `error`, so an old build would fall back to "connection issue" wording. (b) is additive: old clients ignore `reason`, new clients use it, and a new client against a server that has not deployed yet still works through (a).
Public `reason` values: `not-a-member` (no-user-doc, no-tenant, no-member, unsafe-tenant), `member-not-active`, `invalid-role`. `unsafe-tenant` folds into `not-a-member` so nothing from the self-writable users doc is echoed. The reason describes only the caller's own membership.
**Do not change `deriveContext`'s `null` return to carry the reason:** ten callers test `!ctx`, and a changed shape that is truthy would fail OPEN (a refused caller treated as a member). Build the body in one shared function and pin, with a structural test, that every `deriveContext(` call site uses it.
**Rec: (b), slice B, server deploys first (CI deploy-on-merge, #173), client second.** Needs a deploy.
Taher:

**L3-D4. What the client does on a refused request mid-session.**
(a) Words only (today, D15). (b) A silent `recheckAccess()`; the member doc stays the authority and opens the blocked screen only when it confirms. (c) Open the blocked screen straight from the server reason.
(c) gives two sources of truth for the block, and the removed-versus-suspended wording already comes from the member doc.
**Rec: (b)**, with storm control: one re-check in flight, at least 30 s between automatic ones, and a bulk Approve that hits the 403 fail-fast triggers exactly one. Slice C.
Taher:

**L3-D5. A role changes while the app is open.** The re-check already applies the new role through `AuthStore.applyTenantContext`; role flags rebind. Open question is the screen the person is on.
(a) Toast only ("Your role is now staff"). (b) Toast, and if the current tab is no longer allowed, jump to the first allowed tab. (c) Reset the app to the home state.
(c) throws away unsaved work. **Rec: (b).** Slice A reads how tabs are gated before it commits to the jump; if gating is not binding-driven the jump becomes its own small step.
Taher:

**L3-D6. Meaning of "leave" (old D7).** Verified: roster status and member status are unlinked (F5). (a) Leave is roster text only, today's behaviour. (c) Blocking access is a separate, explicit act (`setMemberStatus`). **Rec: (c), which is what exists: no code, one pinning test, one doc line.** Question for you: should "on leave" ever block login? Rec: no.
Taher:

**L3-D7. Parked writes when the member is gone (not decided, question only).** The blocked screen already promises unsent changes stay on the phone until sign-out. Not yet read: does the outbox keep retrying 403s, and after a reinstate plus "Try again" do stuck rows resume or stay stuck? Slice C step 0 reads `Gateway` classification and decides; I will not guess.

## 5. Slices (each its own branch, PR, test plan section)
- **A, client only, no deploy** (L3-D1c, D2a, D5b): pure `SessionRecheck.js` (throttle and change decision), silent path in `AuthService` with a `checking` flag instead of `profileResolved = false`, `tenantContextReady` and the store resync only when tenant or role changed or on the first resolve, resume hook in `Main.qml`, role toast.
- **B, server, deploy** (L3-D3b): shared refusal body with `reason`, structural pin, handler tests, emulator e2e.
- **C, client** (L3-D4b, D7): `LockManager` and write classifiers read `reason`, storm-controlled `recheckAccess`, 403 text loses "most likely" when the reason is known.
- **L4 follows A** (resume sync, pull to refresh), per L3-D1c.
**Recommended order: A, then L4, then B, then C.** A is the only slice with a user-visible effect for owners today.

## 6. Risks
R1 removing the accidental hourly freshness (L3-D1). R2 resume storm (throttle, drop not queue). R3 `Qt.application.state` behaves differently across Android, iOS and Felgo: device-only, so the hook is a thin binding over a tested helper. R4 a silent check racing a user "Try again": `_profileSeq` orders them, slice A pins it. R5 an unreadable answer must never block a verified member (`AccessState.outcome` unchanged, D4 of S2f-3). R6 the refresh path also reloads `loadTenantMembers`: it moves under the "changed" branch. R7 fail-open server change: see L3-D3. R8 no Qt in the sandbox, so every QML test is verified by CI only; the decision logic lives in pure JS that runs in Node here.

## 7. Test strategy (details in the test plan)
Pure helper unit tests plus hand mutants in a Node shim; behaviour tests that run the REAL `AuthService` function text against fakes (the `accessBlockBehavior.test.js` pattern); wiring pins on `Main.qml` (cover condition, resume hook, throttle constants); QML tests in CI; server handler tests across all ten endpoints and three reasons; emulator e2e for the reasons; no rules change (existing 108 stay as regression); seeded monkey over the trigger sequence against a reference model; on-device steps with a baseline step (B0) that confirms F2 before any fix.
