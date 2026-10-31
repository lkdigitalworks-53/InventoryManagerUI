# Test plan — S2f-3: removed / suspended members see a clear screen; the 403 text names the cause

Design: `docs/superpowers/specs/2026-10-28-s2f3-access-wording-design.md`. Branch `feat/2026-10-28-s2f3-access-wording`. Client only: no functions or rules deploy.

## What changed
Login now reads the signed-in user's own member doc and decides from it (role, status). Removed, suspended and invalid-role members get `AccessBlockedPage` instead of the app; an unreadable answer reuses the role this device already verified, or blocks with "Could not check your access". The stuck-write text for HTTP 403 `no-tenant-context` names the two usual causes.

**Sixth session (PR #171 device test, 2026-10-31):** a suspended member who pressed **Approve** on Orders was told "Being edited elsewhere, try again shortly". The lock request (`acquireLock`) is refused with 403 `no-tenant-context` for a suspended member BEFORE any write is queued; the client called that "error" and bulk Approve filed every non-granted acquire under "edited elsewhere". Now the 403 is its own state (`noAccess`): bulk Approve and the three edit dialogs (order, product, staff) show the same removed-or-suspended text as a stuck write, and bulk Approve stops asking after the first 403. **H8 as first written was wrong** (it said Approve queues a write and shows a stuck row; it cannot, the lock fails first), so H8 now uses Restock and N8-N14 cover the lock paths.

## 1. Unit tests (`tests/tst_AccessState.qml`, 49 functions, pure JS)
| Kind | Cases |
|---|---|
| Constants | the four roles pinned to literals; `isValidRole` accepts exactly them (case, spaces, newline, null, undefined, numbers, objects, arrays rejected); `isBlockedState` |
| Happy | active member with each role -> ok + that role; extra doc fields ignored |
| Removed | HTTP 404 -> removed, also when a doc or `ok=true` is passed with it; carries no role |
| Suspended | `suspended` with each role; 20 odd statuses (missing, null, "", "Active", "ACTIVE", " active", "active\n", "inactive", numbers, booleans, objects, arrays) all suspended, fail closed; empty doc; status judged before role |
| Role | active with 17 invalid roles (undefined, null, "", "viewer", "Owner", " owner", numbers, objects, arrays) -> role, never a default |
| Unverified | failed reads (0, 400, 401, 403, 408, 429, 5xx, undefined, null, NaN, "timeout", "404", object, -1); 403 is NOT removed or suspended; ok without a usable doc (null, array, string, number, boolean); only boolean `true` counts as ok; missing arguments; a doc whose getter throws |
| Outcome | ok enters with the MEMBER role (beats the held role); removed / suspended / role block even with a held role; unverified enters only with a valid held role (`verified:false`), else blocks; junk classifications behave as unverified; ok with an invalid role never enters; **`prevBlock` (a "Try again" from the blocked screen):** a failed check keeps the block that is showing, with or without a held role, for all four reasons; a conclusive answer (ok, removed, suspended, role) beats it; a `prevBlock` that is not one of the four (empty, undefined, null, "zzz", "Suspended", numbers, objects) is ignored |
| Copy | the four titles and bodies pinned word for word; other states give empty strings, never undefined; shop-name fallback ("this shop") for 10 junk names; control characters and newlines flattened; cap boundary 60 / 61 / 5000 characters; markup stays text (the page uses plain text) |
| Scenario | status x role x held matrix (24 combinations) against an independent oracle; removed -> restored -> suspended; flaky network never blocks a verified member, always blocks an unknown one; a suspended member whose retry hits each of 5 failure codes (0, 500, 503, 401, 403) stays on "suspended", then a successful retry enters |
| Monkey | seeded (20261028 / 29 / 30 / 31): 4000 random docs vs an independent oracle; 4000 outcomes with invariants (enter only for an ok member or a valid held role; verified only from ok; held role never used for a refused member); 4000 outcomes with a random block showing (never enters on an inconclusive check while blocked, and identical to the two-argument result in every other case); 2000 copy calls return two strings; no state between calls |
Mutation: `node scripts/probes/access-state-mutants.cjs` -> 62/63 killed, the survivor is equivalent (dropping `doc === null`: `null.status` throws and the catch returns the same `unverified`). `scripts/probes/qtest-shim.cjs` now also understands `property` lines.
`tests/tst_FailureCause.qml` U14 updated (wording, names removed AND suspended, names "owner or an admin", no "deactivated", still no status echo). `tests/tst_Gateway.qml` F06e still passes (it pins the phrase "no longer accepts your access", which is kept).

## 2. Wiring and parity (Node, CI "script tests": `.github/scripts/__tests__/accessBlockWiring.test.js`, 34 tests)
One test that the real sources satisfy ~45 source rules, 35 mutation tests that each break one rule and must be reported, 3 parity tests.
- Trust: the users-doc callback never applies context or reads `.role`; no `|| "owner"` / `"staff"` role default anywhere in AuthService; `_loadMembership` is gone; the member doc path is `members/` + `AuthStore.uid`; the held role is reused only for the same tenant.
- Order: the block branch returns before `applyTenantContext`; `tenantContextReady` comes after it; exactly one of each in `_applyAccess` (`_verifyMembership` only reads and calls it); the applied role is `out.role`.
- Races: sequence number taken on every load, stale guard in both callbacks, bumped and the block cleared on sign-out.
- Retry: `recheckAccess` returns offline before `_loadUserProfile`; Main shows a toast offline before calling it. Online, the blocked screen stays up: `_loadUserProfile` never clears `accessBlock` up front (only the no-uid and no-tenant branches and a verified member do), an unreadable users doc and the offline branch keep it, `outcome` gets the showing block as `prevBlock`; the button shows a spinner (`loading`) and refuses a second tap (`enabled`), Sign out is never disabled by the check.
- Screen: visible only for authenticated + non-empty `accessBlock` and NOT tied to `profileResolved` (a retry re-resolves the profile and the login cover at z 100 would show through); `checking: !AuthService.profileResolved`; z above the 200 overlays and above login and setup; sign-out through `app.askLeave`; the three dynamic texts are plain text; touches swallowed; `createTenantForCurrentUser` re-verifies at both sites.
- `FirebaseService.get` passes the HTTP status on success and failure.
- Parity: `VALID_ROLES` in the helper = gateway = rules `roleIsValid`; `active` is the only status in the helper, the rules and the gateway; CMake globs `qml/*.qml` (no file list to edit).

## 2b. Behaviour (Node, CI "script tests": `.github/scripts/__tests__/accessBlockBehavior.test.js`, 72 tests)
Runs the REAL text of `_loadUserProfile`, `_verifyMembership`, `_applyAccess`, `recheckAccess`, `signOut`, `_ensureTenantName`, `loadTenantMembers` and `createTenantForCurrentUser` from `AuthService.qml` in a vm sandbox (bare names resolved through a Proxy, like QML resolves them against the root object) with stubs for `FirebaseService` / `AuthStore` and the real `AccessState.js`. 45 scenarios (fifth session added D13: a users doc 404 while blocked keeps the block, and seven for `leaveCurrentTenant`: unreadable / empty-body users doc writes nothing, field and other-shop preservation, 404 blank doc, write failure, refusals): role from the member doc only (users doc says owner), nothing applied before the member doc is read, removed / suspended / inactive / status-less / invalid or missing role / 403 / 500 / unreadable, held role reused only for the same tenant, B1 (retry keeps the screen, definitive ok clears it), B2 (failed retry keeps the block), conclusive retry replaces the block, offline retry asks nothing and does not invalidate a check in flight, stale answers dropped (two loads; sign-out in flight), sign-out clears block + shop name + roster, users doc without tenant / unreadable while blocked / no uid / offline, member path is the own doc, shop-name precedence + lookup, late shop-name answer after sign-out or tenant switch, late roster of the old tenant, roster with no tenant, and D12: users doc 404 (new account) goes to onboarding, users doc unreadable (0, undefined, 401, 403, 500, 503, empty body) is "unverified" and never onboarding, a verified member keeps working, a saved tenant without a valid role is not let in, a stale users-doc failure is dropped, create-workspace writes nothing after an unreadable users doc (and tells the user), proceeds on a 404, re-verifies when the doc already points at a shop, may create when the doc has no tenant. Plus a seeded monkey (300 sequences x 25 random events, invariants: announced only with a valid role and never while blocked, applied roles valid, sign-out leaves nothing, block is one of four reasons), 18 mutants of `AuthService.qml` each caught (and a control that the unmutated source passes), two caller pins (only `_applyAccess`, `_ensureTenantName`, `createTenantForCurrentUser` call `applyTenantContext`; `setTenantContext` is gone) and one pin for the Back-key guard in `Main.qml`. Not covered here (device only): bindings, what is drawn, z-order, the login cover timing.

## 3. Rules (CI, emulator): `test/firestore.rules.test.js`, 2 new test definitions
A removed member (no member doc) reads its own member path and gets "does not exist", not a permission error, and still cannot read anyone else's doc or the tenant doc. A suspended member of each role reads its own doc with `status` and `role` intact. (These are the two answers the app tells apart: 404 vs 403.)

## 4. Functions / handler / E2E
No server code changed, so no new handler tests. QML E2E runs one app session per process (singletons), so a second actor cannot be driven there; the cross-actor cases (X6 suspend, X7 remove while signed in) belong to the multi-role matrix.

## 2d. Lock no-access (Node, `.github/scripts/__tests__/lockNoAccessBehavior.test.js`, 40 tests; QML `tst_LockManager` +3, `tst_FailureCause` U17-U20)
Runs the REAL text of `LockManager._classifyAcquireResponse`, `OrdersPage._approveAllPending` (stubs for `LockManager`, `dataModel`, the dialog; real `BulkApproveProgress.js` and `FailureCause.js`) and the real helper.
- Classifier: 403 + `no-tenant-context` -> `noAccess`, `reason: "error"`, no holder; 11 near misses (other 403 bodies, 401/400/500/409 with the same code, null/string bodies) are NOT noAccess; 409 stays denied with its holder; 200 stays granted.
- Bulk Approve: the reported case (3 orders, every acquire 403) -> ONE dialog "3 not approved. The server no longer accepts your access...", never "elsewhere", "connection" or "try again", exactly one request (fail-fast), nothing completed, progress ends at 0 approved; connection errors -> "connection issue" with the ids and no fail-fast; real holder -> the old text with the id and the other orders still complete; all granted -> no dialog; insufficient inventory unchanged; a mixed run (ok, denied, error, 403, ok) stops after the 403 and lists each cause once; empty list; asynchronous answers; seeded monkey (200 runs x random outcomes incl. null, undefined, `{granted:"yes"}`) with 7 invariants (request count, completions, progress ends, approved count, "elsewhere" iff a real holder, access text iff a 403, "connection" iff an error, dialog iff something failed).
- Dialogs: each imports `FailureCause`, maps every acquire result through `FailureCause.lockState`, has the `no-access` branch with the shared text, never reads the raw `reason`.
- Pin: exactly four files call `LockManager.acquire` (the three dialogs and OrdersPage); a fifth caller fails this test until it adopts `lockState`.
- Mutants: 4 on the classifier, 11 on the page, 5 per dialog; every one is caught.
Not covered here (device only): that the dialog text is drawn where the user sees it, the real 403 from the server, timing.

## 5. Regression
Owner login and first sign-up unchanged in the happy path (device R1, R2). `FirebaseService.get` callers ignore the new third argument. Existing script tests (271 incl. these) pass locally. QML suites run only in CI.

## 6. Verification status
Run here: Node shim for `tst_AccessState` (49/49), helper mutants (62/63), `.github/scripts/__tests__` (325/325, of which 72 AuthService behaviour tests, 42 wiring, 40 lock no-access), `node --check` on the rules test. CI only: all QML tests (`tst_AccessState`, `tst_FailureCause`, `tst_Gateway`, `tst_LockManager`), rules tests, functions tests. Not verifiable without a device: layout, z-order, back button, the login cover timing.

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
| H3 | Still on H2's screen: set `status` back to `active`, tap **Try again** | The blocked screen STAYS with a spinner on **Try again** (no login screen in between), then the app opens normally and loads data |
| H4 | Delete the member doc (users doc stays). Force-stop, reopen | **Your access was removed**, body "You are no longer a member of <shop>. Changes that were not sent yet stay on this phone until you sign out. Ask the shop owner to add you again." Not the "Create your workspace" screen |
| H5 | Re-create the doc with `role: "viewer"`, `status: "active"`. Reopen | **Your role is not valid**, body "Your account in <shop> has a role this app does not recognise, so access is blocked. Ask the shop owner or an admin to fix your role." |
| H6 | On any blocked screen with nothing queued, tap **Sign out** | Straight to the login screen, no confirmation (same as the workspace-setup screen) |
| H7 | Queue a write first: airplane mode on, change a product's stock, airplane mode still on; suspend the member in the console; airplane mode off. Wait for the blocked screen, tap **Sign out** | The sign-out sheet lists the waiting change. **Stay signed in** returns to the blocked screen; **Sign out and discard** goes to login |
| H8 | App open on Inventory, online. Set `status` to `inactive`. Open any product, **Restock** by 1 and confirm. Wait up to 10 minutes, open the "not syncing" sheet | The row's cause line reads "The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it". **Record** whether the blocked screen appeared by itself (it does after a connectivity change). (Approve on Orders is NOT a valid way to reach this row: its lock is refused first and nothing is queued, see N8) |

### Negative
| # | Action | Expected |
|---|---|---|
| N1 | On a blocked screen turn airplane mode on, tap **Try again** | Toast "You are offline. Connect to the internet and try again"; the same screen stays; the app does not open |
| N2 | Android Back on a blocked screen | Toast "Press back again to exit"; a second press within a few seconds leaves the app; the app behind is never shown |
| N3 | Tap where the tab bar would be, and drag on the screen | Nothing underneath reacts |
| N4 | Tap **Try again** while the member is still suspended | Spinner on the button, the same screen throughout (no login screen flashes), then the button is usable again and the screen is unchanged |
| N5 | On the suspended screen tap **Try again**, then at once turn airplane mode on (the check fails) | The suspended screen stays: never the app, and the title does not change to "Could not check your access". **Record** whether anything tells you the check failed (today nothing does, see KNOWN-ISSUES) |
| N6 | While the spinner shows, tap **Sign out** | Sign-out works (sheet if something is queued, else login); the late answer does not bring the blocked screen back over the login screen |
| N7 | Double-tap **Try again** quickly | One check only (the button is disabled while it runs); no crash |
| N8 | App open on Orders, online, at least 2 pending orders. Set `status` to `suspended`. Tap the **Approve** banner button | Dialog "Some Orders Weren't Approved" with "2 not approved. The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it". NEVER "Being edited elsewhere" or "connection issue". Both orders stay pending. It ends in about a second (one request, not one per order). **Record** whether the blocked screen appeared |
| N9 | Same state. Open one pending order, change a quantity, tap the primary button | Red text under the form shows the same removed-or-suspended sentence (not "currently being updated elsewhere", not "connection issue"); the dialog stays open; the order is unchanged |
| N10 | Same state. Open a product, tap **Edit** | The same sentence appears in the product form as soon as edit mode opens, and again after tapping Save; the product is unchanged |
| N11 | Same state. Open a staff member, tap **Edit** (owner login) | The same sentence in the staff form on opening edit mode and on Save |
| N12 | After N8, set `status` back to `active` WITHOUT restarting the app. Tap **Approve** again | The orders are approved normally; no stale error text; no blocked screen |

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
| E8 | Owner of shop A, Team Members screen open once. Sign out, sign in as a member of shop B straight away (fast network, then again with the network throttled) | The Team Members screen and the header show ONLY shop B (name and roster); never a name or email from shop A, not even for a moment after B's data loads |
| E9 | Android Back on the blocked screen while the app behind was on the Orders tab, or with the profile page open | First Back: toast "Press back again to exit" (no tab change, no page closing out of sight). Second Back leaves the app. A sign-out sheet that is open closes first |
| E10 | Regression for D12: sign up a brand-new account (no users doc yet) | "Create your workspace" appears exactly as before (a 404 is a new account); creating the workspace works and the app opens as owner |
| E11 | Regression for D12: existing owner signs in on a good network | App opens directly as owner; "Create your workspace" never flashes |
| E12 | D13: a removed member is on the blocked screen; in the Firebase console delete that member's `users/{uid}` doc, then tap **Try again** | Spinner on the button, then the SAME blocked screen; no "Create your workspace" behind or after it; **Sign out** still works. (A cold start with the same two docs deleted shows "Create your workspace": see KNOWN-ISSUES) |
| E13 | D14: signed in as staff/manager, turn on airplane mode right after tapping **Leave workspace** and confirming | Error "Could not check your account. Check your connection and try again."; still signed in; in the console `users/{uid}` is unchanged (phone, address, `tenants` intact) |
| E14 | Member active, 2 pending orders, airplane mode ON, tap **Approve** | Dialog "Couldn't confirm 2 order(s) are free to edit (connection issue), try again: <ids>"; never the removed-or-suspended text and never "elsewhere". Turn airplane mode off, tap **Approve**: both approve |

### Multi-scenario / monkey (manual)
Cycle active -> suspended -> removed -> invalid role -> active, force-stopping between each, 10 rounds: the screen always matches the doc, never the previous one. Tap Try again rapidly 10 times on a suspended member, toggling airplane mode in between: no crash, never the login screen, never the app, ends on the suspended screen.

### Not testable on a device (no verified recipe)
- "Could not check your access": needs the member read to fail while the users read just succeeded on a first login. Covered by unit and wiring tests only.
- The users-doc read failing (D12: at login, during a retry, or inside create-workspace): needs the users read to fail while the network looks up (airplane mode makes the app skip the read entirely); unit, behaviour and wiring tests only.
- Non-owner roles: no way to sign in as staff yet (KNOWN-ISSUES).
- A REAL lock denial (another person holds the order): needs a second actor; covered by `tst_LockManager` (409) and the bulk Approve behaviour tests (text and other orders still complete).
- A dialog open when the block appears: known limit, stays above the screen.

### Affected areas
| File | Automated coverage | Where to look on device |
|---|---|---|
| `qml/helper/AccessState.js` | 49 functions, 62/63 mutants | H2-H5, E1-E2, N5 |
| `qml/model/AuthService.qml` | wiring pins only (Felgo) | H1-H7, E5-E7, N1, N4-N5 |
| `qml/pages/AccessBlockedPage.qml`, `qml/Main.qml` | wiring pins only | all, N2-N3, N4, N6-N7, E3-E4 |
| `qml/model/FirebaseService.qml` `get` | wiring pin | H1 (every login reads it) |
| `qml/helper/FailureCause.js` | tst_FailureCause U14, U17-U20; real-text node tests | H8, N8-N11 |
| `qml/model/LockManager.qml` | tst_LockManager (+3), node classifier + 4 mutants | N8-N12, E14 |
| `qml/pages/OrdersPage.qml` (bulk Approve) | real-text node run, 11 mutants, monkey | N8, N12, E14 |
| `qml/pages/OrderDetailDialog.qml`, `EditProductDialog.qml`, `StaffDetailDialog.qml` | source pins + 5 mutants each | N9-N11 |
