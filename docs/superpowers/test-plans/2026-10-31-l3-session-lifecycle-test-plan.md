# Test plan — L3 session lifecycle (slice A BUILT 2026-10-31, CI unverified; slices B and C still PLANNED)

Design: `docs/superpowers/specs/2026-10-31-l3-session-lifecycle-design.md` (L3-D1c, D2a, D5b decided 2026-10-31; D3, D4, D6, D7 open). Branch of this PR: `docs/2026-10-31-l3-session-lifecycle-design` (docs only, no behaviour). Standard format (Skill 49). Slices: **A** client silent re-check + resume (no deploy), **B** server `reason` (deploy), **C** client consumes `reason`. Slice A rows are final (L3-D1c, D2a, D5b decided). Slice B and C rows assume the recommended answers (D3b, D4b, D6c) until Taher decides; if Taher answers differently the affected rows change and the plan is edited in the same commit as the design.
**Slice A as built (2026-10-31, branch `feat/2026-10-31-l3a-silent-recheck`; numbers are what ran in the sandbox, CI is the QML oracle):** `SessionRecheck.js` unit 37 tests (33 hand mutants, all caught) in `sessionRecheck.test.js`; behaviour on the REAL `AuthService` text 101 tests in `sessionRecheckBehavior.test.js` (47 scenarios, 49 hand mutants all caught, 4 seeded monkeys x 6000 steps against a reference model, minimum coverage pinned per seed); wiring 51 tests in `sessionRecheckWiring.test.js` (rules + 47 mutants); `tests/tst_SessionRecheck.qml` 25 test functions (CI only). Whole script suite 659 of 659 (631 as the PR was opened, 462 before this slice; counts include the 2026-11-01 review sweep, section 9). The existing S2f-3 pins were updated to the new call shapes (and now also pin the `silent`/`quiet` pass-through). **Deviations from the rows below, all deliberate:** (1) no `tst_AuthService_silentRecheck.qml` or `tst_Main_resume`: `AuthService` cannot be instantiated under `qmltestrunner` (Felgo), so those cases are the Node behaviour test on the real function text; (2) a lost silent check is replaced after 120 s (`STALE_MS`) because `FirebaseService` reads have no timeout; (3) a refresh answer that lands after sign-out or an account switch is dropped (`sentWith` guard), a pre-existing race that resume would have made likelier; (4) L3-D5b: no tab is role-gated, so there is no tab to jump to; the only role-gated screen is the Staff overlay, which closes on a role change when `!canViewStaff`; (5) only a session that is already open is re-checked silently, cold start, sign-in, onboarding and Try again stay full loads that always emit `tenantContextReady`; and the first answer of every sign-in counts as a change (`_contextSynced`, kind `first`) because the saved session already holds tenant and role, so "nothing changed" would otherwise skip the first store sync. **An independent review found this after the first version of the slice had it wrong:** at cold start `init()` resolves OFFLINE (`isOnline` is still false), then `Main.qml` sets `isOnline = true` and the silent check found "no change", so no store ever synced. The test harness had always started online, which is why 600 tests missed it; the scenarios now replay the real order.
Tooling truth: no Qt in the sandbox, so every `tst_*.qml` is verified by CI only; pure JS, script tests and `functions/` tests run in Node here. Counts below are PLANNED; the observed CI numbers replace them when each slice lands.

## 1. Unit tests (planned)
| Slice | Target | Cases |
|---|---|---|
| A | `qml/helper/SessionRecheck.js` (pure) | Constants pinned (60 s automatic spacing, 30 s for a refused-request trigger). Throttle: first call runs; inside the window dropped; exactly at the boundary runs; after the window runs; "Try again" bypasses; clock going backwards never wedges the throttle; `NaN`, `undefined`, `null`, strings for `now` fail safe (run, never throw). In-flight: second trigger dropped while one is out; released on answer, on error, on sign-out. Decision `decide(prev{tenant,role,verified}, outcome)`: same tenant+role -> `none`; role changed (4x4 matrix, 12 changes) -> `roleChanged`; tenant changed -> `tenantChanged`; first resolve -> `first`; refused (removed / suspended / role) -> `block`; unreadable with a verified role -> `keep`; unreadable without one -> `block-unverified`; junk inputs never throw. |
| A | `AccessState.js` | unchanged; the existing 49 functions stay as regression |
| B | `functions/lib` refusal mapping (`refusalReason`) | each of the 6 internal causes -> its public reason; unknown or non-string cause -> `not-a-member` (fail closed); output never contains the input string; body shape `{ok:false,error:"no-tenant-context",reason}` pinned; `error` value pinned as a literal |
| C | `FailureCause.js` / `LockManager.qml` classifiers | reason present -> exact cause sentence; reason absent (old server) -> today's "most likely" sentence; unknown reason -> today's sentence |

## 2. Functional tests (planned)
- **A, behaviour test on the REAL function text** (`.github/scripts/__tests__/sessionRecheckBehavior.test.js`, same method as `accessBlockBehavior.test.js`): a silent check never sets `profileResolved = false`; healthy -> healthy emits no `tenantContextReady` and triggers no store sync; role change emits once; suspended / removed -> block, cover untouched; offline -> no request; failed read keeps a verified member in and keeps a showing block; overlapping checks (`_profileSeq`: the older answer is dropped); sign-out mid-check drops the answer; 50 resumes inside 60 s -> 1 request; "Try again" during an automatic check -> the manual one wins; token refresh during a resume check -> one check, not two.
- **A, wiring pins** (`sessionRecheckWiring.test.js`): the `LoginPage` `visible:` expression no longer depends on a value a silent check flips; resume hook present and calls the throttled entry only; no other writer of `profileResolved = false` on the refresh path.
- **B, handler tests** (`functions/test/`): 10 endpoints x 3 reasons (30) -> 403, `error` unchanged, correct `reason`; owner/admin/manager/staff active -> success body byte-identical to today (4 roles x 10 endpoints); structural test: every `deriveContext(` call site builds its 403 through the shared function; **fail-open guard:** `deriveContext` still returns `null` (not an object) on refusal.
- **C:** `LockManager` and bulk Approve with each reason; storm control (100 refused requests in a row -> one `recheckAccess`; second one after 30 s); old-server answer (no `reason`) behaves exactly as PR #171.
- **QML (CI only):** `tst_SessionRecheck.qml` (helper, same cases as 1), `tst_Main_resume` where the harness allows, extended `tst_LockManager`.

## 3. Rules tests
None planned: `firestore.rules` does not change in any slice. The existing 108 rules tests stay green as regression (they pin the suspended member's own-doc read that the re-check depends on).

## 4. E2E tests (planned)
- **B, emulator:** seed an active owner; call `recordMutation` with a token whose member doc is (i) suspended -> 403 `member-not-active`, (ii) deleted -> 403 `not-a-member`, (iii) given an invalid role -> 403 `invalid-role`, (iv) active -> 200 unchanged; same three for `acquireLock` (the D15 path).
- **A / C:** QML E2E runs one app session per process, so two-actor scenarios live at the server layer; a QML E2E that edits the member doc through the Admin REST between two `recheckAccess()` calls (active -> suspended -> active) is planned for CI.
- **Not testable in automation:** real background/foreground transitions (needs a device), real token expiry timing, Felgo `App` lifecycle.

## 5. Regression tests (must stay green; exist because of earlier defects)
`accessBlockBehavior` (72), `accessBlockWiring` (42), `lockNoAccessBehavior` (52), `lockTransportBehavior` (20), `tst_AccessState` (49), `tst_LockManager`, `tst_FailureCause` U14 + U17-U20, Functions 866, Rules 108, E2E 101 (CI observed on the PR #171 line; the S2f-3 design records them). New pins that exist because of this change: the sign-in cover must not follow a silent check; `tenantContextReady` count on a no-change check is zero; `deriveContext` return shape unchanged.

## 6. Monkey and multi-scenario tests (planned)
- **Seeded random sequence** (4 seeds, 4000 steps each) over {resume, online flip, token refresh, Try again, sign-out, role change, suspend, remove, reinstate, offline, check answer slow / fails / 403 / 404 / 5xx} against an independent reference model. Invariants: (i) the sign-in cover is never visible while authenticated and previously verified; (ii) blocked iff the last definitive answer refused; (iii) `tenantContextReady` only on first resolve or a tenant/role change; (iv) at most one request in flight and at least 60 s between automatic checks; (v) the app never opens for a refused member; (vi) a verified member is never blocked by an unreadable answer.
- **Server (B):** seeded random member docs (status, role, extra fields, wrong types) against an oracle for the public reason; 4000 per seed.
- **Multi-scenario table** (hand-written): active -> suspended -> active; active -> removed -> re-invited; admin -> staff -> manager; two devices, one change; resume during token refresh; resume while offline; sign-out then resume; blocked then resume still blocked; reinstated then resume.
- **Mutation:** hand mutants of `SessionRecheck.js` (throttle `>=` to `>`, window off by one, in-flight guard removed, role compare loosened, bypass always on) and of the `AuthService` text (cover flag restored, resync unconditional) in a Node shim; goal: all killable mutants killed, survivors explained.

## 7. On-device test plan (unticked; Taher runs it)
**Prerequisites:** P1 owner phone signed in; P2 a second member made as in the PR #171 device test (Firestore console: member doc + users doc, `provisioningAvailable` is still `false`); P3 Firestore console open on the member doc; P4 USB debugging / logcat if available; P5 screen stays awake while testing.

**B0 Baseline on current `main` (confirms Finding F2 before any fix).** Foreground the app signed in as owner for about 60 minutes with Orders open. Expected today (if F2 is right): around the token refresh the sign-in form flashes and the Orders list goes blank, then returns. Record what you actually see; if nothing flashes, slice A shrinks to the resume trigger and this plan is edited.

**Happy path**
- H1 (A) Same 60-minute foreground run on the slice-A build: no sign-in flash, lists never blank, nothing visible at the refresh.
- H2 (A) Background the app 2 minutes, return: no visible change, no spinner over the app.
- H3 (A) Console: set the second member `status: "suspended"`. On that phone background and return: the "suspended" access screen appears; Sign out works.
- H4 (A) Console: delete the member doc, background and return: the "removed" screen.
- H5 (A) Re-create or set `active`, tap Try again: the app opens, lists load once.
- H6 (A) Console: change role admin -> staff while open, background and return: toast "Your role is now staff"; manager-only controls gone; if you were on a manager-only tab you land on an allowed one (L3-D5b).
  - As built (L3-D5b): tabs are not role-gated, so the check is the Staff overlay: as a manager open Team members, change the role to staff in the console, background and return: toast "Your role is now staff" and the overlay closes (Home, Orders, Stock, Analysis stay).

- H7 (C) Suspended member presses Approve: access screen opens after the refused request, not just a sentence.

**Negative**
- N1 Airplane mode, background and return: nothing blocks, nothing flashes.
- N2 Suspended member, airplane mode, resume: the screen stays as it was; no false "removed".
- N3 Background and foreground 20 times within 30 seconds: no visible effect; (logcat) one check.
- N4 Sign out during a check: no zombie session after sign-in as someone else.
- N5 Blocked and still suspended, resume: stays blocked, no flicker.
- N6 (B) `curl` a gateway endpoint with the suspended member's token: 403 with `reason: "member-not-active"` and `error: "no-tenant-context"` unchanged.
- N7 Old app build against the new server (B deployed first): D15 wording still correct.

- N12 (A) Cold start, online: kill the app and relaunch. Orders, Stock, Analysis and Team load exactly as before this slice (this is the path the first version broke). Repeat with the phone offline at launch, then go online: the lists load once the phone is online.
- N8 (A) Turn on airplane mode while a resume check is out, then off: no sign-in form, no blank lists; the next resume after 2 minutes checks again (a lost check does not stop checks).
- N9 (A) Resume with the phone asleep for over an hour (token expired): one silent check after the refresh, no sign-in form, no error toast.
- N10 (A, iOS) Pull down the notification centre and release 5 times quickly: at most one check (log), no visible effect.
- N11 (A) Sign out while a token refresh is in flight (resume, then tap Sign out at once): the sign-in form stays, the old user does not come back.
- N13 (A, review sweep) Weak signal at launch: open the app with the network throttled or toggling (airplane mode on and off) until it opens, then restore a good network and wait about a minute (or send the app to the background and back). Orders, Stock, Analysis and Team lists fill in; no "Your role is now" toast. Expect the stores to sync once more after the network is good, not zero times.
- N14 (A, review sweep) Resume after a long background with the network flapping: keep the app in the background for over an hour, suspend the member in the Firestore console, then return while switching Wi-Fi off and on. Within about two minutes (no need to wait for the hourly refresh) the access screen shows.
- N15 (A, review sweep) No stray sign-in error: with a token that is about to expire (background the app for about an hour), open Add staff (owner), fill the name, then background and return on a weak network. No "authentication failed" text appears in the dialog and Add stays usable (it is not freed mid-provisioning). Repeat with Invite member.
- N16 (A, review sweep) Account switch: sign out and sign in as another member within a minute of a resume, suspend that member in the console, then background and return. The new account is re-checked on its first resume (the access screen shows).

**Edge cases**
- E1 Resume at the moment the token is about to expire: one refresh, one check, no double flash.
- E2 Both Firestore docs gone (E12 of the S2f-3 plan): cold start still shows "Create your workspace"; resume does not.
- E3 Two devices of one owner: change a product on A, resume B: B shows the change only after L4 (before L4 this step documents the freshness loss from L3-D1c).
- E4 Rotate the phone and open the keyboard while a check runs: no layout break.
- E5 Very long shop name on the access screen (existing S2f-3 case) after a silent re-block.

**Monkey (device)**
- M1 20 minutes of random background / foreground / airplane toggles / screen lock while filling a new-order dialog: no crash, draft intact, no sign-in flash.
- M2 Flip the member `status` between active and suspended every 30 seconds from the console while tapping randomly on that phone: the screen always matches the last definitive answer, never a half state.

**Affected areas (file, automated coverage, where to look on a device if none)**
| File | Coverage | Device |
|---|---|---|
| `qml/model/AuthService.qml` | behaviour test on real text, QML, wiring pins | H1-H6, N4 |
| `qml/helper/SessionRecheck.js` (new) | unit, mutants, monkey | N3, M1 |
| `qml/Main.qml` (cover condition, resume hook, toast) | wiring pins; hook itself device-only | H1, H2, E4 |
| `functions/index.js` (10 call sites) | handler, structural, e2e | N6, N7 |
| `qml/model/LockManager.qml`, `qml/helper/FailureCause.js` | unit, behaviour, QML | H7 |
| `qml/pages/AccessBlockedPage.qml` | unchanged; regression | H3-H5, E5 |

**Regression (how you would notice an old bug returning)**
- R1 PR #171 N8-N12 (suspended member + Approve / Edit): wording still "no longer accepts your access", never "edited elsewhere".
- R2 PR #171 E12/E13 (users doc gone): unchanged.
- R3 Sign-out sheet with unsent changes still warns.
- R4 A flaky network never blocks a signed-in owner.

## 8. Slice A as built: what is NOT proven here
Real `Qt.application.state` transitions (Android, iOS, Felgo), the property bindings and what the screen draws, real token expiry timing, and the on-device baseline B0 that confirms Finding F2 (nothing was seen on a device; F2 is read from code). The hook in `Main.qml` is a thin binding over a tested function so that the untested part is one line. Owners with two phones lose the accidental hourly refresh until L4 (accepted at L3-D1c).

## 9. PR #180 review sweep (2026-11-01): what each fix is covered by
Findings and the fixes made in the same PR. Every row has a happy path, a negative case and an edge case; no new Firestore rules or server code changed, so there are no rules tests and no emulator e2e (client only; the e2e suites are unaffected and must stay green).

| Fix | Behaviour scenario (real `AuthService` text) | Monkey (reference model updated) | Hand mutants | Wiring pin | Device |
|---|---|---|---|---|---|
| F1 an unreadable answer must not use up the 60 s window | R180-1 (401, 500, junk body, unreadable users doc: window free; healthy answer and refusal: window kept), R180-2 (expired-token 401, refresh lands 2 s later, check runs, role change seen) | unreadable answer sets the model's window free; refused and healthy do not | 5 | `auth-unreadable-frees-window` | N14 |
| F2 an unreadable answer must not count as "stores synced" | R180-3 (silent first resolve: emit, not synced, next definitive answer syncs once, no toast, then nothing; three unreadable in a row), R180-4 (full load unreadable; verified marks; unreadable never un-marks) | `synced` follows verified emissions only | 3 | `auth-synced-before-emit`, `auth-synced-verified-only`, `auth-synced-set` | N13 |
| F3 a refresh nobody asked for fails silently | R180-5 (resume refresh fails: no authFailed, no check; no refresh token: nothing sent, nothing reported; explicit refresh and missing token still report; only an explicit `true` silences) | resume/refresh actions unchanged (their answers already random ok/fail) | 4 | `auth-refresh-silent-param`, `auth-refresh-quiet-guard`, `auth-refresh-quiet-callers`, `auth-resume-throttle` | N15 |
| F4 sign-out forgets both spacing windows | R180-6 (resume, sign out, other account signs in, resume 1 s later: checks) | `signOut` resets both model windows | 2 | `auth-signout-windows` | N16 |

Unit (`SessionRecheck.js` unchanged: its 37 Node tests and the 25 QML test functions still apply). Functional/regression: the whole earlier scenario set (41) passes unchanged, which shows the fixes only change the unreadable-answer, refresh-failure and sign-out paths. Not proven here: the QML suite in CI and everything in the device steps. Decisions NOT taken in the sweep (need the owner): see KNOWN-ISSUES, entries dated 2026-11-01 (PR #180 review).
