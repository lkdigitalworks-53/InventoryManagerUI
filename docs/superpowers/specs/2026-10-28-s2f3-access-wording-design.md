# S2f-3 — a removed or suspended member sees a clear screen, and the 403 text names the cause

**Status:** built 2026-10-28 on `feat/2026-10-28-s2f3-access-wording` (client only, no deploy). Every decision below was applied as the recommended default and is vetoable in the PR; none was asked live (the session had one turn).
**Slice of:** `2026-10-24-s2f-authz-hardening-design.md` row S2f-3. Also closes finding 12 of `2026-10-25-pr159-final-sweep.md` (client role default) and the "client ignores `status`" note in the S2f checkpoints.
**Why S2f-3 before S2f-6:** `2026-10-16-restock-atomic-operation-design.md` says S2f-6 `counters` locking IS the `mint` op ("build it once, here, do not build a separate S2f-6"). So it is not an independent slice: it is a large server change still waiting for spec approval. S2f-3 is client only and designed.

## Verified facts (code read 2026-10-28, `main` @ `69e7381`)
- `AuthService._loadUserProfile` took tenant AND role from `users/{uid}` (the user can write it) and, when that doc carried a role, never read the member doc: `tenantContextReady(tenantId, role)` fired at once. A suspended or removed member therefore got the full app with a role, and every read and write was refused (empty lists, writes stuck on HTTP 403).
- `_loadMembership` (used only when the users doc had no role) ignored `status`, defaulted a missing role to `staff`, and any failure sent the user to "Create your workspace". `createTenantForCurrentUser` defaulted a role-less users doc to `owner` (two sites).
- `FirebaseService.get` dropped the HTTP status, so 404 (member doc deleted) looked like any network error.
- `firestore.rules` already let a member read ITS OWN member doc even when suspended, and a missing own doc answers "does not exist" (404), not 403. Pinned by an existing rules test (suspended) and two new ones (removed, suspended with role).
- The gateway and the rules both mean "active member with a valid role" = status exactly `active` and role in owner/admin/manager/staff.

## What was built
| Piece | File | Notes |
|---|---|---|
| Pure decision + copy | `qml/helper/AccessState.js` | `classify(ok, status, doc)` -> ok / removed (404) / suspended (status not exactly `active`) / role (active, invalid role) / unverified (anything unreadable). `outcome(cls, heldRole)` -> enter or block. `copy(state, shopName)` -> `{ title, body }`. Never throws. |
| Login verifies membership | `qml/model/AuthService.qml` | `_verifyMembership` replaces `_loadMembership`. The users doc is read for the tenant pointer only; tenant context and `tenantContextReady` are applied after the member doc says ok. New `accessBlock`, `accessTenantName`, `recheckAccess()`. |
| Status reaches callers | `qml/model/FirebaseService.qml` | `get()` passes the HTTP status as a third callback argument (existing callers ignore it). |
| Screen | `qml/pages/AccessBlockedPage.qml`, `qml/Main.qml` | Title, plain-language body, "Signed in as", **Try again** (primary), **Sign out** (secondary, through `app.askLeave`). z 300. |
| Wording | `qml/helper/FailureCause.js` | 403 `no-tenant-context`: "The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it". |

## Decisions (recommended default applied; each is vetoable)
**D1. Read the member doc at every profile load, even when the users doc has a role.** Cost: one extra Firestore read per login and per reconnect re-run (`onIsOnlineChanged` already re-runs the profile load), and the login cover shows one round trip longer. Alternative: keep trusting the users doc and only reword. Rejected: it leaves the actual bug (full app, all requests refused). Alternative: custom auth claims (S2f D1 c): stronger, needs token refresh and a server write on every role change; over-scoped.
**D2. The role comes from the member doc only, with no default.** A member doc whose role is not one of the four blocks with "Your role is not valid" instead of becoming `staff`, which is what the gateway and rules already do (S2f D3). Cost: a hand-edited bad doc locks that user out of the UI too (it is already locked out of every request).
**D3. A dedicated screen, not only clearer text.** S2f open question 4 was never answered; the design row says "clear screen instead of empty lists". Cost: one new page, one Main binding, and a z-order to keep right.
**D4. A failed check does not lock out a member who was verified before.** `outcome` reuses the role this device already verified for the SAME tenant (`AuthStore.role`), and only blocks with "Could not check your access" when there is none (first login on this device). Why: reconnect re-runs on a flaky network must not throw an active owner out. Cost: a member suspended while the check keeps failing keeps the old UI until one check succeeds; the server and rules still refuse every request, so nothing is exposed. Alternative (block on any failure): safer on paper, worse for the daily user.
**D5. A removed member is not offered "create a new workspace".** One workspace per user is the current model and multi-tenant switching is a non-goal (multi-role design). The only exits are Try again and Sign out. Cost: a removed user who wants their own shop must sign out and use another account, or the owner re-adds them. Before this change they were sent to the create-workspace screen, which then reopened the old shop as `owner`.
**D6. The 403 text says "most likely".** The code also covers a missing users doc, an invalid role and an unsafe tenant id; the client cannot tell. The text names the two usual causes and who can fix it, never one as fact. Distinct server codes (`not-a-member`, `member-not-active`) are the PR #159 Q3 follow-up: a server change, not done here.
**D7. Stale answers are dropped.** `_profileSeq` is bumped by every profile load and by sign-out; a late answer from an older load (reconnect flapping, sign-out in flight) is ignored. Without it a slow "suspended" answer could cover a member who was just restored.
**D8. Try again offline does nothing to the state.** `_loadUserProfile` offline would reopen the app from the saved session, so `recheckAccess()` returns, and Main shows a toast.
**D9. The two `|| "owner"` defaults in `createTenantForCurrentUser` now re-run the profile load.** The member doc decides, never a default.

## Not in this slice (and why)
- Mid-session detection (L3 of the multi-role design): a member suspended while the app stays open is noticed at the next reconnect or launch, not at the next token refresh or resume, and no server code says which cause it was.
- Dialogs and sheets that are open when the block appears stay above the screen (Qt popups draw above every item). They cannot expose data (reads are refused); their writes are refused too. Closing them needs a shared dialog list; `_handleBack` pins its own list in `signOutGuardWiring.test.js`.
- Found, not fixed: a transient failure reading the users doc (`!ok || !data`) shows "Create your workspace" to a signed-in user. Same class as D4, different code path and an onboarding behaviour change. KNOWN-ISSUES.
- Found, not fixed: `AuthService.setTenantContext(tenantId, tenantName, role)` applies any role it is given; its only caller is a `Logic` signal nothing emits. Dead code candidate. KNOWN-ISSUES.

## Tests
See `docs/superpowers/test-plans/2026-10-28-s2f3-access-blocked-test-plan.md`.
