# Test plan — S2f-3: removed / suspended members see a clear screen; the 403 text names the cause

Design: `docs/superpowers/specs/2026-10-28-s2f3-access-wording-design.md`. Branch `feat/2026-10-28-s2f3-access-wording`. Client only: no functions or rules deploy.

## What changed
Login now reads the signed-in user's own member doc and decides from it (role, status). Removed, suspended and invalid-role members get `AccessBlockedPage` instead of the app; an unreadable answer reuses the role this device already verified, or blocks with "Could not check your access". The stuck-write text for HTTP 403 `no-tenant-context` names the two usual causes.

## 1. Unit tests (`tests/tst_AccessState.qml`, 44 functions, pure JS)
| Kind | Cases |
|---|---|
| Constants | the four roles pinned to literals; `isValidRole` accepts exactly them (case, spaces, newline, null, undefined, numbers, objects, arrays rejected); `isBlockedState` |
| Happy | active member with each role -> ok + that role; extra doc fields ignored |
| Removed | HTTP 404 -> removed, also when a doc or `ok=true` is passed with it; carries no role |
| Suspended | `suspended` with each role; 20 odd statuses (missing, null, "", "Active", "ACTIVE", " active", "active\n", "inactive", numbers, booleans, objects, arrays) all suspended, fail closed; empty doc; status judged before role |
| Role | active with 17 invalid roles (undefined, null, "", "viewer", "Owner", " owner", numbers, objects, arrays) -> role, never a default |
| Unverified | failed reads (0, 400, 401, 403, 408, 429, 5xx, undefined, null, NaN, "timeout", "404", object, -1); 403 is NOT removed or suspended; ok without a usable doc (null, array, string, number, boolean); only boolean `true` counts as ok; missing arguments; a doc whose getter throws |
| Outcome | ok enters with the MEMBER role (beats the held role); removed / suspended / role block even with a held role; unverified enters only with a valid held role (`verified:false`), else blocks; junk classifications behave as unverified; ok with an invalid role never enters |
| Copy | the four titles and bodies pinned word for word; other states give empty strings, never undefined; shop-name fallback ("this shop") for 10 junk names; control characters and newlines flattened; cap boundary 60 / 61 / 5000 characters; markup stays text (the page uses plain text) |
| Scenario | status x role x held matrix (24 combinations) against an independent oracle; removed -> restored -> suspended; flaky network never blocks a verified member, always blocks an unknown one |
| Monkey | seeded (20261028 / 29 / 30): 4000 random docs vs an independent oracle; 4000 outcomes with invariants (enter only for an ok member or a valid held role; verified only from ok; held role never used for a refused member); 2000 copy calls return two strings; no state between calls |
Mutation: `node scripts/probes/access-state-mutants.cjs` -> 55/56 killed, the survivor is equivalent (dropping `doc === null`: `null.status` throws and the catch returns the same `unverified`). `scripts/probes/qtest-shim.cjs` now also understands `property` lines.
`tests/tst_FailureCause.qml` U14 updated (wording, names removed AND suspended, names "owner or an admin", no "deactivated", still no status echo). `tests/tst_Gateway.qml` F06e still passes (it pins the phrase "no longer accepts your access", which is kept).

## 2. Wiring and parity (Node, CI "script tests": `.github/scripts/__tests__/accessBlockWiring.test.js`, 21 tests)
One test that the real sources satisfy ~35 source rules, 17 mutation tests that each break one rule and must be reported, 3 parity tests.
- Trust: the users-doc callback never applies context or reads `.role`; no `|| "owner"` / `"staff"` role default anywhere in AuthService; `_loadMembership` is gone; the member doc path is `members/` + `AuthStore.uid`; the held role is reused only for the same tenant.
- Order: the block branch returns before `applyTenantContext`; `tenantContextReady` comes after it; exactly one of each in `_verifyMembership`; the applied role is `out.role`.
- Races: sequence number taken on every load, stale guard in both callbacks, bumped and the block cleared on sign-out.
- Retry: `recheckAccess` returns offline before `_loadUserProfile`; Main shows a toast offline before calling it.
- Screen: visible only for authenticated + resolved + non-empty `accessBlock`; z above the 200 overlays and above login and setup; sign-out through `app.askLeave`; the three dynamic texts are plain text; touches swallowed; `createTenantForCurrentUser` re-verifies at both sites.
- `FirebaseService.get` passes the HTTP status on success and failure.
- Parity: `VALID_ROLES` in the helper = gateway = rules `roleIsValid`; `active` is the only status in the helper, the rules and the gateway; CMake globs `qml/*.qml` (no file list to edit).

## 3. Rules (CI, emulator): `test/firestore.rules.test.js`, 2 new test definitions
A removed member (no member doc) reads its own member path and gets "does not exist", not a permission error, and still cannot read anyone else's doc or the tenant doc. A suspended member of each role reads its own doc with `status` and `role` intact. (These are the two answers the app tells apart: 404 vs 403.)

## 4. Functions / handler / E2E
No server code changed, so no new handler tests. QML E2E runs one app session per process (singletons), so a second actor cannot be driven there; the cross-actor cases (X6 suspend, X7 remove while signed in) belong to the multi-role matrix.

## 5. Regression
Owner login and first sign-up unchanged in the happy path (device R1, R2). `FirebaseService.get` callers ignore the new third argument. Existing script tests (192 incl. these) pass locally. QML suites run only in CI.

## 6. Verification status
Run here: Node shim for `tst_AccessState` (44/44), helper mutants, `.github/scripts/__tests__` (192/192), `node --check` on the rules test. CI only: all QML tests (`tst_AccessState`, `tst_FailureCause`, `tst_Gateway`), rules tests, functions tests. Not verifiable without a device: layout, z-order, back button, the login cover timing.

## On-device test plan
### Prerequisites
| Item | Value |
|---|---|
| Build | APK built by Taher from this branch (nothing in the sandbox builds it) |
| Account | a fresh user + tenant (owner), signed in once so the app has a saved session. Write down the user's uid and the tenant id |
| Console | Firebase console, Firestore, doc `tenants/<tenant>/members/<uid>` and `users/<uid>`. A non-owner login cannot be created yet (provisioning is off), so the OWNER's own member doc is edited |
| Before each scenario | doc back to `status: "active"`, `role: "owner"` (copy the original fields first; for H4 re-create the doc with the same fields) |
| Wait | a console edit shows on the phone after force-stop + reopen (online), or after Try again, or after the next reconnect; nothing is instant |
| Settings | OS font size Normal unless a step says Large; Android Back = gesture or button |

### Happy path
| # | Action | Expected |
|---|---|---|
| H1 | Force-stop, reopen online (member active) | Login cover for a moment, then the app opens as before: tabs visible, role owner, dashboard data loads |
| H2 | Set `status` to `suspended`. Force-stop, reopen online | After the login cover a full screen: title **Your access is suspended**, body "Your access to <shop> is suspended or inactive. You cannot see or change shop data until the shop owner or an admin restores it. Changes that were not sent yet stay on this phone until you sign out.", small line "Signed in as <email>", buttons **Try again** and **Sign out**. No tab bar, no empty lists |
| H3 | Still on H2's screen: set `status` back to `active`, tap **Try again** | Login cover, then the app opens normally and loads data |
| H4 | Delete the member doc (users doc stays). Force-stop, reopen | **Your access was removed**, body "You are no longer a member of <shop>. Changes that were not sent yet stay on this phone until you sign out. Ask the shop owner to add you again." Not the "Create your workspace" screen |
| H5 | Re-create the doc with `role: "viewer"`, `status: "active"`. Reopen | **Your role is not valid**, body "Your account in <shop> has a role this app does not recognise, so access is blocked. Ask the shop owner or an admin to fix your role." |
| H6 | On any blocked screen with nothing queued, tap **Sign out** | Straight to the login screen, no confirmation (same as the workspace-setup screen) |
| H7 | Queue a write first: airplane mode on, change a product's stock, airplane mode still on; suspend the member in the console; airplane mode off. Wait for the blocked screen, tap **Sign out** | The sign-out sheet lists the waiting change. **Stay signed in** returns to the blocked screen; **Sign out and discard** goes to login |
| H8 | App open on Orders, online. Set `status` to `inactive`. Approve an order. Wait up to 10 minutes, open the "not syncing" sheet | The row's cause line reads "The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it". **Record** whether the blocked screen appeared by itself (it does after a connectivity change) |

### Negative
| # | Action | Expected |
|---|---|---|
| N1 | On a blocked screen turn airplane mode on, tap **Try again** | Toast "You are offline. Connect to the internet and try again"; the same screen stays; the app does not open |
| N2 | Android Back on a blocked screen | Toast "Press back again to exit"; a second press within a few seconds leaves the app; the app behind is never shown |
| N3 | Tap where the tab bar would be, and drag on the screen | Nothing underneath reacts |
| N4 | Tap **Try again** while the member is still suspended | Login cover, then the same screen again |

### Edge cases
| # | Action | Expected |
|---|---|---|
| E1 | Set the tenant name (users doc `tenantName`) to a 100-character string, repeat H2 | The name is cut to 59 characters plus "…" in the body |
| E2 | Tenant name `<b>Acme</b>`, repeat H2 | Shown literally as text, not bold |
| E3 | OS font size Large, repeat H2 | Title and body wrap, both buttons fully visible (scroll if needed), no overlap |
| E4 | Rotate to landscape on the blocked screen | The content scrolls; both buttons reachable; rotate back, no layout break |
| E5 | App open and working, owner doc suspended in the console, then airplane mode on and off | The blocked screen appears after reconnect. **Record** how long it took |
| E6 | On a blocked screen restore `active` in the console and do NOT tap anything | The screen stays until **Try again** or the next reconnect |
| E7 | Users doc has `role: "staff"` but the member doc says `owner` (edit users doc), reopen | The app opens with OWNER rights (the member doc wins) |

### Multi-scenario / monkey (manual)
Cycle active -> suspended -> removed -> invalid role -> active, force-stopping between each, 10 rounds: the screen always matches the doc, never the previous one. Tap Try again rapidly 10 times on a suspended member: no crash, ends on the suspended screen.

### Not testable on a device (no verified recipe)
- "Could not check your access": needs the member read to fail while the users read just succeeded on a first login. Covered by unit and wiring tests only.
- Non-owner roles: no way to sign in as staff yet (KNOWN-ISSUES).
- A dialog open when the block appears: known limit, stays above the screen.

### Affected areas
| File | Automated coverage | Where to look on device |
|---|---|---|
| `qml/helper/AccessState.js` | 44 functions, 55/56 mutants | H2-H5, E1-E2 |
| `qml/model/AuthService.qml` | wiring pins only (Felgo) | H1-H7, E5-E7, N1, N4 |
| `qml/pages/AccessBlockedPage.qml`, `qml/Main.qml` | wiring pins only | all, N2-N3, E3-E4 |
| `qml/model/FirebaseService.qml` `get` | wiring pin | H1 (every login reads it) |
| `qml/helper/FailureCause.js` | tst_FailureCause U14 | H8 |
