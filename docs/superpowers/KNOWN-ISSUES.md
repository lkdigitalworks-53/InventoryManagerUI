# Known Issues

Running log of accepted, non-blocking issues deferred for later. Each entry: what's
broken, where, why it was deferred, and leads for a future fix.

---

## Three sheets show no full-sheet busy overlay while saving — FOUND 2026-11-09 (Restock overlay report), FIXED in PR #190 session 2

**Where:** `AddProductDialog`, `AddStaffDialog`, `NewOrderDialog` set `busy = true` and never `busyMessage`. **Fixed:** each declares a constant `busyMessage` at its root. A ratchet in `functions/test/sheetBusyOverlay.test.js` fails any new root-`BottomSheet` file that turns `busy` on without one.
**Residual:** the wording says "this can take a few seconds". Order, product and staff saves first mint an id (GET plus commit, up to 8 attempts) and `FirebaseService._request` has no app-level timeout, so on a network that accepts the connection and then stalls the wait is whatever Qt's own transfer timeout is (not checked against the Felgo Qt). While busy the sheet cannot be closed (no cancel, no back, no tap outside). Not changed: a timeout and an escape hatch are a design call, see the next two entries.

---

## ProfileSettingsDialog shows no busy card while saving — FOUND 2026-11-09 (ratchet in PR #190 session 2), NOT FIXED

**Where:** `ProfileSettingsDialog` binds `busy: AuthService.busy`. `AuthService.busy` is also set by other flows (12 assignments), so a constant message would show on any of them while this sheet is open; a wording and timing call per flow.
**Lead:** a message that depends on what `AuthService` is doing (a `busyReason` string), or the sheet's own `busy` set at its Save tap. Listed in `NO_OVERLAY` in `sheetBusyOverlay.test.js` with this reason; the test fails when the entry goes stale.

---

## MemberManagementDialog redeclares `busy` and is driven from Main.qml — NOTED 2026-11-09 (PR #190 session 2 review), UNVERIFIED, not fixed

**Where:** `qml/pages/MemberManagementDialog.qml` is a root `BottomSheet` and declares its own `property bool busy: false` (line 26) although `BottomSheet` already has `busy`; `Main.qml` sets it with `busy: AuthService.membersBusy`. Two consequences by reading the text: (1) the busy-overlay ratchet in `sheetBusyOverlay.test.js` reads only a sheet's own file, so a `busy` driven from an instance in `Main.qml` is invisible to it; (2) whether `BottomSheet`'s own `closePolicy`, close-button guard and overlay gate (all `root.busy`) see the shadowing property or the base one depends on how Qt resolves a shadowed name (compiled QML may bind to the base type). Not checked in Qt; the sheet shows its own "Loading…" label instead of the card.
**Lead:** device check: open Member management, tap Refresh, press Back while "Loading…" shows. If the sheet closes, the shadowing bypasses the busy lock. Fix would be to delete the redeclaration and decide on a `busyMessage`.

---

## A sheet that is busy has no escape if its answer never comes — NOTED 2026-11-09 (PR #190 session 2 review), design call

**Where:** `BottomSheet.closePolicy` is `NoAutoClose` while `busy`, the close button and Cancel are guarded by `!busy`, and `Main.qml`'s Back honours `busy`. Every path found in `AddProductDialog`, `AddStaffDialog` and `NewOrderDialog` answers (the callback or `orderAdded` / `orderCreationFailed` / `errorOccurred`), so no stuck path was found; a stalled network is the only way to wait long. The new overlay makes the lock obvious ("Don't close the app or press back").
**Lead:** a per-sheet wait timeout that drops `busy` and shows "Still trying; check the list before retrying" would need care: a late answer after a timeout must not double-create (the order and product paths are idempotent only through their minted id).

---

## ToastHost pill `y` is a binding that an animation does not remove — NOTED 2026-11-09 (PR #190 session 2 review), UNVERIFIED, not fixed

**Where:** `ToastHost.pill` has `y: parent ? parent.height : 600` and is moved by `NumberAnimation` on `y`. Qt animations write with the "keep the binding" flag (from memory of the Qt source, not re-read this session), so if the parent's height changes while a toast shows (soft keyboard hiding on a dialog close, rotation) the binding re-evaluates and the pill jumps to the bottom edge and out of sight for the rest of its 5 s. The binding is older than this PR (the diff does not touch it); the move into the Overlay changes the parent but not the exposure.
**Lead:** device check D1 in the test plan (toast right as a keyboard closes). If it reproduces: set `y` imperatively in `_showInternal` (start below the layer, animate up) and drop the binding.

---


## Toast pill covers the lower part of a bottom sheet's footer buttons — NOTED 2026-11-09, design call

**Where:** `ToastHost` places the pill 110 dp above the bottom of the window (`tabbarClearance`). Now that toasts are drawn above dialogs, on a bottom sheet the pill lies over the lower part of the Cancel/Confirm buttons for about 5 s. Taps pass through the pill (it has no input handler), so nothing is blocked; it is visual only.
**Lead:** if it looks wrong on device, anchor the pill near the top while a modal popup is open (`Overlay` knows its popups), or raise it above the sheet footer. Not changed: a position change is a design decision.

---

## Restock quantity: typed text may not be committed when Confirm is tapped — FOUND 2026-11-09 (Confirm-fix review), FIXED in the #188/#183 review sweep (branch `review/2026-11-09-pr188-pr183-sweep`)

**Where:** `RestockDialog.qtyField` (`QQC.SpinBox`, `editable: true`). A Qt editable SpinBox updates `value` from its text on `editingFinished` (focus loss or Enter), and a `Button` may not take focus on a tap (focus policy depends on the platform and style). If so, typing 25 and tapping Confirm at once would send the previous value (10).
**Fix (review sweep):** the tap now reads the typed text with the SpinBox's own parser (`RestockFlow.qtyFromField`), refuses empty/junk/fraction/out-of-range instead of clamping, and brings `qtyField.value` up to date; whether Qt would have committed on its own is still unverified, and no longer matters. Device case H2 in `docs/superpowers/test-plans/2026-11-09-pr188-pr183-sweep-test-plan.md`. This is the only editable SpinBox in the app (`grep -rn SpinBox qml`).
**Why it was deferred first:** nothing shows it happening; it cannot be checked without a device, and a change made without evidence is a guess (systematic-debugging). It is the device-test case E-SB1 in `docs/superpowers/test-plans/2026-11-09-restock-confirm-noop-test-plan.md`.
**Lead:** if E-SB1 shows +10, read the text at the tap: `qtyField.valueFromText(qtyField.contentItem.text, qtyField.locale)`, clamp to `from`/`to`, and test it in `restockDialogConfirm.test.js`. The same pattern may exist in other dialogs with an editable SpinBox (`grep -rn "SpinBox" qml/pages`).

---

## Bulk Approve: a `tryCompleteOrder` that never calls back keeps the banner "running" — FOUND 2026-10-31 (PR #174 sweep), NOT FIXED

**Where:** `OrdersPage._approveAllPending` + `BulkApproveProgress` (the `shortcut: no watchdog` comment). The lock request can no longer hang (D16: 15 s timeout, circuit breaker after 3 no-answers), but the completion step (`DataModel.tryCompleteOrder`, the Gateway write) has no watchdog of its own here: if its callback never fires the state stays "running" and the Approve button stays disabled until the page is rebuilt.
**Why deferred:** nothing shows it hanging (Gateway's own send timeouts, 10 s / 30 s, answer every request), and a page-level watchdog would need a cancel/abandon design for an in-flight write.
**Lead:** if a device ever shows the banner stuck, add a per-order timer in the loop that records the order as failed after `SendPolicy.TIMEOUT_AWAIT_MS` x 2 and ignores the late callback (answer-once guard, Skill 144 rule 2).
**Also unmeasured:** `LockManager.requestTimeoutMs` (15 s) is a starting value; read `acquireLock` latency (cold start) and tune.

---

## Access-blocked screen: a failed "Try again" says nothing — FOUND 2026-10-28 (S2f-3 review pass), NOT FIXED

**Where:** `AuthService._verifyMembership` / `AccessState.outcome` (D11). When the retry cannot reach the server the spinner ends and the same screen stays; nothing tells the user the check failed (offline is covered by a toast, a server error is not). **Why not fixed:** it needs AuthService to report the outcome of a recheck (a signal or a `lastCheckFailed` flag) and a second wording; the safe behaviour (stay blocked) is already right. **Lead:** emit one signal from the `unverified`-while-blocked branch and let Main show the same toast style as the offline case.

## Cold start vs retry differ when BOTH the member doc and the users doc are gone — FOUND 2026-10-29 (S2f-3 fifth-session sweep), by design (D13), NOT FIXED
A removed member whose `users/{uid}` doc was also deleted (the staff cleanup `cleanupStaffAuthDocs` deletes both) sees \"Create your workspace\" on a cold start (a 404 on the users doc is indistinguishable from a brand-new account) but keeps the \"Your access was removed\" screen when they tap Try again while already blocked (D13). Both are safe: the new workspace is the idempotent `t_<uid>` of their own, never the old shop. Fix would need a server-side marker of \"was removed\" (L1/L3 of the multi-role design). Test plan E12.

## Mid-session membership changes are noticed late — KNOWN 2026-10-28 (S2f-3), L3 of the multi-role design

A member suspended or removed while the app is open keeps the old UI until the next token refresh (about hourly: `refreshIdToken` re-runs the profile load), reconnect (`onIsOnlineChanged`) or launch; **not** at an app resume (nothing listens to `Qt.application.state`). **Update 2026-10-31 (D15):** the first thing such a member does that needs the lock service (Approve on Orders, Edit on an order, product or staff) now shows the removed-or-suspended sentence instead of "edited elsewhere" / "connection issue", but the access-blocked screen still does NOT open on that 403: opening it from a lock or write 403 (a `recheckAccess` trigger with storm control for bulk actions) belongs to L3. **Corrected 2026-10-31:** this entry used to say there is no re-check on token refresh; there is (F1 of `specs/2026-10-31-l3-session-lifecycle-design.md`), but it is not silent (see the next entry). There is no re-check on app resume, and the server answers one code (`no-tenant-context`) for every cause, so the 403 text says "most likely". Dialogs and sheets that are open when the access-blocked screen appears stay above it (Qt popups draw above every item); they cannot expose data (reads are refused) and their writes are refused. A cold start OFFLINE after being blocked reopens the app from the saved session (the block is in memory only); it is re-applied at the next online profile load. **Update 2026-11-01 (L3 slice A, CI unverified, device steps H3-H5 pending):** returning to the foreground now re-checks silently (60 s throttle, one in flight) and a refused member sees the access screen at the next resume instead of at the next failed write; the 403-triggered re-check (L3-D4, slice C) and distinct server reasons (slice B) are still open.

---

## A healthy re-check shows the sign-in form and blanks lists — FOUND 2026-10-31 (L3 design, read from code, NOT seen on a device), FIXED IN L3 SLICE A (CI unverified; device steps B0 and H1 pending)

**Where:** `AuthService._loadUserProfile` (`profileResolved = false`), `Main.qml` L693 (`LoginPage` at z 100 while `!profileResolved`), `Main.qml` L314 (`onTenantContextReady` re-syncs about ten stores), `OrdersStore._resetAndFetch` (`orders = []` before the refetch). **Trigger:** every token refresh (about hourly, from the 120 s timer in `Main.qml` or any gateway call near expiry) and every offline to online flip, for EVERY signed-in user including owners.
**Effect (expected from the code):** the sign-in form and empty lists show for the length of two Firestore reads plus the refetch, mid-task; the same path is the app's only periodic data refresh, so a fix removes that side effect unless the resume sync (L4) lands with it. Test-plan step B0 confirms or refutes this on a device before any fix.
**Fix:** slice A of `specs/2026-10-31-l3-session-lifecycle-design.md` (decision L3-D1c), built 2026-11-01: an open session is re-checked silently (own `checking` flag, no cover, no resync unless tenant or role changed or the screen was blocked). **Cost accepted by Taher (L3-D1c):** an owner on two phones loses the accidental hourly refresh until L4 (resume sync, pull to refresh) lands.

---

## The Staff overlay is not gated by role — FOUND 2026-11-01 (L3 slice A, read from code), NOT FIXED

**Where:** `Main.qml` `staffPageOverlay` (opened by Home "navigateToStaff", Profile "Team members" and `_routeActivity` for `staff_added` / `staff_updated`), `AuthStore.canViewStaff`. **Effect:** `canViewStaff` (owner, admin, manager) has no consumer in `qml/`; a staff-role user can open the overlay through activity routing. The server and rules still refuse what staff may not read or write. L3 slice A closes the overlay when a role change leaves `!canViewStaff`, nothing more. **Lead:** gate `_routeActivity` and the Home tile on `canViewStaff`, then decide what the overlay shows for staff.

---

## A read with no answer leaves the sign-in cover up for good — FOUND 2026-11-01 (L3 slice A, read from code), NOT FIXED

**Where:** `FirebaseService._request` sets no `xhr.timeout` (Skill 144), so a Firestore read can fail to call back at all. A FULL profile load (cold start, sign-in, Try again) that hits one leaves `profileResolved = false`, so `LoginPage` stays at z 100. **Silent re-checks are protected:** a check out for 120 s is replaced (`SessionRecheck.STALE_MS`) and its late answer dropped. **Lead:** a timeout in `_request` with the same answer-once guard as `LockManager._post`; every caller then needs a look at what an error does (Skill 144 rule 3).

---

## Staff add: link lost on 409, and two roster entries can share one login — FOUND 2026-10-26 (PR #165 sweep), NOT FIXED

**Where:** `AuthService.provisionStaffCredentials` (stamps `appUid` only when the call returns `ok`), `StaffStore.setAppUid`, `AuthService.cleanupStaffAuthDocs`, `functions/index.js` `provisionMember` (409 `member-exists`, no `uid` in the body). Dormant: `Gateway.provisioningAvailable` is `false`.
**Case A:** the owner adds a staff entry whose email is already a member with a different role, or is suspended. The roster record saves, the call answers 409, no `appUid` is stamped. The person keeps a working login but is unlinked: `StaffScope.ownOrders` fails closed (they see no orders), and deleting the roster entry does NOT remove their member doc, so their access outlives the entry.
**Case B:** there is no duplicate-email check when adding staff. A second entry with the email of an already linked, active, same-role member gets the exact-repeat 200 (with `uid`), so both entries carry the same `appUid`. Deleting the second entry runs `cleanupStaffAuthDocs` and removes the member doc and `users/{uid}` of the person the first entry still describes. (Before S2f-7 the old merge linked them too; it is not new, it is now explicit.)
**Leads:** (1) refuse a second roster entry with an email already on the roster (client, one check); (2) on 409 show the toast AND offer to remove the just-saved roster entry; (3) never cascade from an entry whose `appUid` is also on another entry. **Decided 2026-10-27: fix in L1, before the flag flips (design "L1 gate").**

---

## Invite-by-uid adds any Auth account without consent, and probes uid existence — FOUND 2026-10-26 (PR #165 sweep), NOT FIXED

**Where:** `provisionMember` with `body.uid` (`getUser(uid)` then member doc + `users/{uid}.tenants` push). Test plan row DE3 pins it.
**Why it matters:** an owner/admin who knows any uid (for example of someone who left their workspace) can put that account into their own tenant as `admin`/`manager`/`staff` with no accept step; the member doc stores that account's Auth email, which the roster then shows; and 404 `user-not-found` vs 200 tells the caller whether a uid exists in the whole Firebase project. Needs an owner/admin token and the uid. Relevant to the DPDP consent work (P4).
**Leads:** an invitation doc the invitee accepts (multi-role slice L1), or at least do not copy the Auth email into the member doc. **Decided 2026-10-27: accept step in L1, before the flag flips (design "L1 gate").**

---

## Membership changes leave no `audit_log` row — FOUND 2026-10-26 (S2f-7 design), NOT FIXED

**Where:** `provisionMember` (Admin SDK) and the Team Members role/status edits (client writes to `tenants/{t}/members/{uid}` under `canManageTarget`). Neither writes to `audit_log`, and the gateway's `ENTITY_COLLECTIONS` map (`functions/lib/gatewayLogic.js`) has no `member` entity.
**Why it matters:** an auditor asking "who made Ravi an admin, and when" cannot be answered from the ledger; the member doc only holds the latest state plus `invitedBy` / `joinedAt` for the first add. It is an access-control record, adjacent to Rule 11(g) rather than part of the books of account.
**Leads:** a server-side membership endpoint (the client cannot be trusted to write its own audit row), or a Firestore trigger on `members/**` that appends the row. Decide before staff login goes live (multi-role slice L1). Do not forget the rules-path edits, they bypass any function.

---

## `provisionMember` turns an unknown role string into `staff` — FOUND 2026-10-26, NOT FIXED

**Where:** `functions/index.js` `provisionMember` (`if ([...].indexOf(role) < 0) role = "staff"`), pinned by `index.handlers.remaining.test.js` ("an unrecognized role string silently falls back to staff"). Also: `body.uid` is not run through `isSafePathSegment` (not exploitable: `getUser` must succeed first).
**Why deferred:** behaviour change on a dormant endpoint (`Gateway.provisioningAvailable` is `false`); safer answer is 400 `invalid-role`. Asked in the S2f-7 design, Q2.

---

## Pending batch-id mints replayed under the wrong tenant — FOUND + FIXED 2026-10-26 (stacked PR on the sign-out guard)

`StockBatchStore._pendingMints` (E2E roadmap item 1, Decision 1) survived sign-out and was tenant-blind: after a failed mint under tenant A, signing in as B and going online minted B's counter and wrote a `stock_batch` into B for A's product id; `hasPendingMint` also hid B's same-id product from B's pickers. Read from code, not reproduced on a device. Fixed by tagging items with their tenant (`PendingMints.js`), Skill 137, design `specs/2026-10-26-pending-mints-tenant-scope-design.md`. **Residual:** an item owed to a tenant nobody signs into again stays on the device (tiny, harmless); the whole queue is retired when the restock design (server-side mint inside the operation, PR #147) lands. Older-build or damaged items are quarantined on load (`rejectedJson`, newest 50, never replayed), not destroyed. PR #168 sweep (2026-10-27) also fixed: the success path of `addBatch` wrote into the NEW tenant when the account switched while the mint was out, and the retry could mint before the tenant's batch ledger had loaded (counter seed from an empty ledger). **Status: fixed in code, headless tests green; the store wiring is device-verification pending** (test plan H/N/E rows). **Open (Taher):** quarantine vs adopt-into-first-tenant for pre-fix items, see the design doc section 6.

---

## Owner can mint a second owner via `ownerId` — RESOLVED (fixed by #164 / R3, found in the PR #161 review 2026-10-25)

The `tenants/{t}` update rule now requires `request.resource.data.ownerId == resource.data.ownerId`, so the bootstrap rule can no longer be fed a new owner id. Covered by the rules test "R3 tenant ownerId is immutable". Fix option B (bootstrap only when the tenant has no members) was not needed and is not planned. Kept as a pointer; delete when convenient.

---

## Client cleanup writes the rules refuse (`users` delete, tenant rollback) — FOUND 2026-10-25 (PR #161 review), NOT FIXED

**Where:** `AuthService.qml` `cleanupStaffAuthDocs` (about line 923) and the onboarding rollback (about lines 575-580) call `FirebaseService.remove("users/<uid>")`, but `firestore.rules` has `allow delete: if false` on `users/{uid}`, so these get 403 and only `console.warn`. The rollback `remove("tenants/<id>")` also fails when the member doc was never created, because `isOwner` needs the member doc: a failed onboarding can leave an orphan `tenants/<id>` and `users/<uid>` doc. Read from the code and rules, not run.

**Why it is harmless today:** since PR #159 the gateway ignores `users/{uid}`, so a leftover doc grants nothing. It is dirt, not a hole.

**Leads:** move the cleanup into a Cloud Function (Admin SDK), the same fix as the `TODO` already in `cleanupStaffAuthDocs`; do it together with the staff-login work.

---

## No way to log in as staff / admin / manager: `Gateway.provisioningAvailable` is still `false` — FOUND 2026-10-25 (PR #159 device test), NOT BUILT

**What is missing:** the app can only ever run as the **owner**. Both ways to create another login go through `Gateway.provisionMember` (`AuthService.provisionStaffCredentials` for Add Staff, `AuthService.inviteMember` for Invite by UID, `qml/model/AuthService.qml` ~L637 and ~L806). `provisionMember` returns `provisioning-unavailable` at once while `Gateway.provisioningAvailable` is `false` (`qml/model/Gateway.qml` L41, `provisionMember` ~L1076), so no request is sent and no Auth account / `users/{uid}` / member doc is created. The staff RECORD is saved, the login is not.

**Why it is `false`:** hard-coded pre-Blaze (design `specs/2026-06-26-five-features-design.md`, "The Blaze reconciliation"). The comment on the flag says "flip the day functions/ is deployed". Functions ARE deployed now (`provisionMember` exists, `functions/index.js` ~L710), the flag was never flipped. Earlier docs call this "dormant until login provisioning ships" (README staff-delete note, this file's staff-delete entry, `AGENTS.md`), but there was no entry of its own until now.

**Consequence for tests:** every non-owner path is untestable on device: role guards in `DataModel.on*`, the server-side `staff/delete` role check, PR #159/#160 (member doc authority, suspended/removed members), `canAssignRole`. They are covered only by unit / handler / rules / emulator tests, never by a real second login. Cross-user flows (staff sells, owner restocks, staff set to leave, owner removes staff while staff is signed in) have never been run against two real sessions.

**Dev-only workaround to device-test PR #159 today (no code change):** in the Firebase console create an Auth user (email + password), then write `users/{uid}` = `{tenantId, role}` and `tenants/{tenantId}/members/{uid}` = `{role, status: "active", displayName, email}`. Email sign-in already exists (`AuthService.signInWithEmail`). Do NOT do this on a project that holds real data.

**Status 2026-10-25:** full DRAFT design written, decisions OPEN, to be picked up AFTER the compliance features: `specs/2026-10-25-multi-role-login-design.md` (decisions D1-D8, slices L1-L6, cross-actor matrix X1-X13, resume questions Q0-Q7). Do NOT enable provisioning on prod before slice L2 (server RBAC): see the "no server-side role check" entry below, which becomes exploitable once a real non-owner can log in.

**Scope when built (see the design above and `specs/2026-10-25-multi-role-login-CHECKPOINT.md`):** (1) turn provisioning on and prove it with the emulator + a device run, (2) role-aware first screen / sign-in for non-owner roles, (3) a multi-actor test matrix across tenant users (staff sale, owner stock update, staff status change to leave / suspended, removal while signed in), with realtime/sync behaviour on the second device.

---

## A server `operation-too-large` for an order completion is mishandled, but the app cannot reach it today — FOUND 2026-10-18 (PR #149 review), NOT BUILT

**Question (Taher):** what happens when an order's lines hit the server's 166 cap and it answers `operation-too-large`?

**Answer (code reading, plus the Node pin `movementWiring.test.js` "write budget accepts the largest order the client planner can send"):**
- The app never gets there. `CompletionPlan.build` refuses more than `MAX_OPS` = 200 ops BEFORE sending (about 66 lines: batch op + stock op + sale op each, plus the order op). The person sees "This order is too large to complete in one step (N changes, limit 200)", the order stays `pending`, and nothing reaches the server (`tst_DataModel_completeOrderAtomic` case 12).
- 166 is the server ceiling for an operation made only of inventory ops. A planner order has at least 2 ops per stock line plus the order op, so at most 99 inventory ops: 2 x 200 + 1 + 99 = 500 writes, inside the budget.

**Latent defect, only if the two caps ever drift** (a changed `MAX_OPS`, or an older / foreign client): the 400 carries no `opIndex`, so `DataModel._onCompletionRejected` re-plans and re-sends the same oversized operation `maxReplans` (3) times, then calls `_failCompletion(..., markOutOfStock = true)`. The order is then flagged `out of stock`, which is the wrong reason (Skill 118 rule 6, the same misnomer), and the cause toast is right ("too large"). Fix when needed: treat `FailureCause` kind `limit` as terminal at once (no re-plan, no `out of stock`).

**Decision (Taher, 2026-10-19):** the app targets B2C retail counters, so the 200-op limit is accepted for now and the order is not completed in chunks (chunking would give up all-or-nothing completion and needs its own design). The refusal now tells the person what to do: "...Move some lines, or part of a line's quantity, to a second order, then complete both (N lines, M changes, limit 200)" (`CompletionPlan.js` via `FailureCause.js`, pinned in `tst_CompletionPlan`, `tst_FailureCause`, `tst_DataModel_completeOrderAtomic`).

**Open risk (Taher: batches per product are unbounded):** the cap counts one op per stock BATCH consumed, not per line, so a product bought often in small lots can reach 200 ops with very few lines (one line over 199 batches = 202 ops). Splitting the quantity gets round it, but a busy shop will meet it. Leads when it hurts: merge exhausted / same-cost batches of one product, or consume at most N batches per line and book the rest as one repair batch (changes FIFO cost, needs a decision). Not built.

**Why the server path is not reworked now:** unreachable with the current constants, and the Node pin fails first if either cap moves. Code for it would be untestable from the app and CI-only on the QML side.

## Restock is two independent writes: a 4xx drops the stock delta but keeps the batch — DECIDED 2026-09-30, NOT BUILT

**Status 2026-10-28:** server half built (R2: `mint` op, `restock` opType, PR on `feat/2026-10-28-r2-mint-engine`). The client rewrite (R3 `RestockPlan`, R4 `InventoryStore.restock`, R5 dialog and `activity_log`) is still NOT BUILT, so this bug is still live in the app.

**Found on-device (Taher, PR #97 test).** Member `status` set to suspended, then restock a product: toast "Could not
restock", the stuck list showed one write. After setting the member active and tapping Retry now, the stock batch
appeared but the product's `stock` in Firestore did not change. Batch and stock disagree.

**Cause (code reading, plus Taher's two on-device confirmations: the toast, and `stock` unchanged in Firestore).**
`InventoryStore.restock` sends two unrelated writes in parallel: `StockBatchStore.addBatch` (`Gateway.recordMutation`,
sender `_send`) and `Gateway.recordDelta` (sender `_sendDelta`). A suspended member gets 403
`{ok:false, error:"no-tenant-context"}` on both. `_send` retries any non-2xx that is not a CAS conflict, so the batch
stays queued and stuck. `_classifyDeltaResponse` treats a 4xx with a well-formed `ok:false` body as a definitive
rejection, so the delta is removed from the outbox and its callback gets the failure (which is the toast). Retry now
then lands only the batch. Not caused by the stuck-writes dialog or state persistence (PR #97 / S2a); those only made it
visible. Any 4xx on the delta produces the same batch-without-stock state, not just a suspended member.

**Also lost in that path:** the ActivityLog "Restocked" entry and the purchase `TransactionStore` record, because they
run inside the delta callback. That callback lives in memory (`Gateway._deltaCallbacks`), so even a delta that is only
retried and then succeeds after a relaunch lands on the server without them.

**Decision (Taher, 2026-09-30): make batch + stock delta ONE atomic operation** (`Gateway.recordOperation`, the C-3
atomic outbox), so both land or neither does. Documented only; nothing built. Rejected for now: (A) retrying deltas on
403, which fixes this one path but leaves the two writes independent and the callback loss unchanged.

**Leads for whoever builds it** (not verified, open questions):
- `functions/lib/operationLogic.js` has `OP_TYPES = ["completeOrder"]`; a `restock` opType needs server logic and a
  deterministic `opKey` (`OperationKeys.js` has the pattern) so a re-run is exactly-once. This also bears on the
  RestockDialog double-submit item (ASYNC-REENTRANCY-BUGS C-4).
- The batch id comes from `StockBatchStore.nextBatchId`, a network mint that can itself fail (`_queuePendingMint`). Decide
  whether the id is minted before the operation or by the server.
- The ActivityLog / purchase record should follow the operation's applied signal, not an in-memory callback, or the
  relaunch loss stays.
- Supplier resolution (`_resolveSupplierId`) stays a separate step before the operation; its failure handling is unchanged.
- Not checked: other places that pair `addBatch` with `recordDelta` (for example product create with opening stock) and
  may have the same shape.

**Design written 2026-10-16, refreshed 2026-10-26** (v2: ids minted inside the transaction, awaiting spec approval): `docs/superpowers/specs/2026-10-16-restock-atomic-operation-design.md`; test plan `docs/superpowers/test-plans/2026-10-16-restock-atomic-operation-test-plan.md`; standing `docs/superpowers/ATOMIC-OPERATIONS-STATUS.md`. Still NOT BUILT. #146 is merged; restock sends an explicit `receipt` movement. `mint` also delivers S2f-6.

**Until built:** to force a stuck write in device tests use a single-write action (edit a product name), not Restock.

---

## Async re-entrancy / double-submit bug class — tracked separately, severity-ranked

Found via the 2026-09-14 order-completion double-submit fix (PR #70): a whole *class* of bugs where
a fire-and-forget signal into an async `DataModel` orchestration function, with no busy state and
no re-entrancy guard, lets a repeated user action (double-tap, reopen-and-retry) run the same
mutation twice against stale local state. A full-codebase sweep (2026-09-15) found two more
Critical instances (`ConfirmReturnSheet`/`_tryAdjustOrder` exchanges, `NewOrderDialog` duplicate
order creation) and one Medium (`InviteMemberDialog`). Full trace, severity ranking, and the
checklist used to find them: `docs/superpowers/ASYNC-REENTRANCY-BUGS.md` — kept separate from this
file since it's one specific, well-defined pattern with its own severity structure, not a grab-bag
entry.

---

## Leave-workspace: self-leave rule staged but not deployed

**Status:** Update (2026-07-29) — the deploy this entry was blocked on has now happened.
`Gateway.mode` flipped to `"gateway"` (commit `649046d`), and Taher confirms Cloud Functions +
`firestore.rules` are deployed and working. Since `firestore.rules` ships as one unit, the
self-leave clause described below should now be live for free. **Not independently re-verified
in a session** (i.e. nobody has confirmed the leaver's member doc actually gets auto-removed
post-deploy) — treat as likely-resolved, not confirmed-resolved, until someone checks it on
live data.

**Original issue (2026-06-12), kept for context:** Re-login bug was fixed in code from the start
(`leaveCurrentTenant()` clears the tenant pointer on the leaver's own `users/{uid}` doc — a
self-write allowed even under the old rules). What was blocked on this deploy specifically: a
`firestore.rules` clause letting a member delete their OWN non-owner membership
(`tenants/{tid}/members/{uid}` where `uid == request.auth.uid`); before this deploy, that
self-delete was denied (403) and the leaver's member doc lingered as `status: active` (cosmetic
only — the owner could always remove the ghost member manually via Member Management).

---

## Order returns: cross-period temporal netting mismatch

When a completed order is returned/modified in a *different month* than the original sale, the
Analysis reports net the reversal in **different periods** depending on the surface:

- **Sold / Profit** are ledger-sourced (`TransactionStore` sale + return events). A return event is
  dated when the return happens, so Sold/Profit reduce the **return-month** bucket.
- **Revenue** is order-sourced (`OrdersStore.orders`, bucketed by `order.date`). `applyAdjustment`
  updates the order's lines/total but not `order.date`, so Revenue reduces the **original-sale-month**
  bucket retroactively.

Net effect for a sale in month A returned in month B: month A's Revenue drops while its Sold/Profit
stay full; month B shows the Sold/Profit reversal with no Revenue change. The "this year" hero and
all-time totals reconcile correctly; only narrower period buckets (and period-scoped exports) show
the split.

**Decision:** Accepted limitation for now (chosen during the returns/exchange brainstorm — the
"preserve consumption[] on adjusted lines" fix closed the by-supplier ₹0 bug; the temporal split was
explicitly logged here rather than re-sourcing Revenue from the ledger). Revisit when Revenue moves
to a ledger-sourced read (natural fit with the P0 immutable-ledger roadmap), at which point all three
surfaces would net in the same period.

**Related, 2026-08-20:** a second, different site of the same consumption-loss bug class was found
and fixed — `OrderDetailDialog._save()`'s plain metadata-edit path (customer/email/phone/status/
channel/staff, no line changes) was silently dropping `consumption[]` on every save to a completed
order, independent of the adjustment path referenced above. See SKILLS.md Skill 42 for the full
writeup.

---

## Delete: `Gateway._send` terminal-failure black hole applies to deletes too — RESOLVED 2026-10-13 (slices C, S1, S2a, S2b, S3 all merged)

`feature/product-order-delete-ui` (2026-08-30) added the missing row-level UI for the
already-implemented product/order delete logic. Tracing the full failure surface for that ticket
surfaced this: a delete is applied **optimistically** to local state the moment the user confirms,
before the network call resolves. `Gateway._send`'s non-conflict failure path
(`OutboxStore.markFailed()`) retries with backoff **indefinitely** — no terminal-vs-transient
classification, no signal back to any caller, ever. If a delete hits a persistent failure (bad
Firestore rules, a bug, a genuinely-terminal 403/5xx), the item is gone from the UI forever while
the server-side working doc — and the compliance `audit_log` entry — may still exist, silently
diverging from what the user believes happened.

**Not delete-specific** — this is the same latent infinite-retry bug already named as an
out-of-scope follow-up during the `fix/bulk-import-chunking-durable-status` work (chunked-batch
imports hit the identical `_send` code path). A real fix touches shared retry/classification logic
used by every mutation of every entity, not just deletes.

**Decision:** deferred again, same reasoning as the chunked-import branch's original deferral —
should ride together with (or immediately after) whatever session finally rewrites `_send`'s
retry/terminal-classification behavior, as one piece of work rather than two partial ones. Full
trace: `docs/superpowers/specs/2026-08-30-product-order-delete-ui.md`.

**Update 2026-09-19 (PR #75) — surfaced, not resolved.** The *silent* half is fixed: `Gateway` now counts
server-side failures per queued write in all three senders (`_send`, `_sendBatch`, `_sendDelta`) and, after
5, shows one toast and a persistent `GlassHeader` caption line until the write leaves the outbox (spec:
`docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-design.md`). Taher chose surface-only over
drop + rollback, park, or server-side classification, so the *diverged* half remains: retry, backoff and
dropping are unchanged, local state still differs from the server while a write is stuck, and there is no
in-app Retry/Discard. Follow-ups, in the order they would pay off: (B) park a stuck write and offer
Retry/Discard, with Discard rolling back to the outbox item's `before`; (C) have `functions/index.js` map
Firestore error codes to distinct HTTP statuses (today every exception is `500 write-failed`) so the client
can classify precisely instead of counting.

**Update 2026-09-28 (part C landed, branch `fix/2026-09-28-gateway-write-error-classification`):** (C) is done, but
NOT as distinct statuses: the status stays 500 and the body `error` is `write-rejected` / `write-unavailable` /
`write-failed` (a 4xx would make the delta and operation senders drop the write, SKILLS Skill 74). The client labels
stuck writes the server rejected ("N change(s) rejected by the server. Still retrying."). Still open: (B) park +
Retry/Discard (Taher's Q2-Q4: re-pull on Discard, persisted parked flag, tappable caption -> dialog).

**Update 2026-10-13: RESOLVED.** Every slice is on `main`: C error classification (#93), S1 Retry now and S2a persisted stuck flag (#97), S2b park rejected writes (#106), S3 Discard + resync (#110; #109 was its design). A rejected write is parked and listed, never dropped; the user chooses Retry or Discard (re-pull from Firestore). A delete behind a parked write is refused up front (PR #119 D2/D3). Roadmap item 1 closed in `DELETE-FEATURE-ROADMAP.md`.

---

## Delete: staff delete has the identical missing-UI gap as products/orders had — RESOLVED 2026-09-21

Same root cause `feature/product-order-delete-ui` fixed for products and orders:
`StaffPage.qml` declares `signal deleteStaffClicked(string staffId)` and `Main.qml` already has a
confirm-dialog handler wired to it (`onDeleteStaffClicked` → `confirmDlg.ask(...)` →
`logic.deleteStaff(...)`) — but no visible element in the row template ever emitted it. Fixed
(`feat/2026-09-21-staff-delete-ui`) with the same trash-icon `Rectangle`+`MouseArea` idiom already
used in the orders row and `InventoryPage`.

`StaffStore._onMutationConflicted` also gained the `action` param and delete-specific toast wording
it was deliberately left without during the products/orders fix (it was unreachable from the UI
until this gap closed). Along the way, two adjacent findings: a client-side guard now blocks
deleting your own staff record (dormant until login provisioning ships, see the entry below), and
`recordMutation` gained a narrow server-side role check for staff/delete specifically (see "Delete:
recordMutation has no server-side role check for any entity/action" below — staff/delete is now the
one exception).

Design: `docs/superpowers/specs/2026-09-21-staff-delete-ui-design.md`.

### Follow-up found on-device, fixed on the same branch (2026-09-25): a deleted staff member's name vanished from history

Taher's on-device pass of PR #80 found what the "resolved" note above missed: orders and sale events keep only
a `staffId`, and every display path re-looked it up in the live roster. After a delete, the order detail
showed "Sold by (none)", the exported Orders sheet had a blank Staff column, and Sales Analysis showed a bare
"(removed)". Worse, `OrderDetailDialog`'s picker only offered *active* staff, so opening and saving such an
order **silently cleared `staffId`** (same for staff on leave / suspended), and re-adding a staff member with
the same name made the old order read as the new person's. The test plan's original case 8 had asserted the
blank/"(removed)" outcome was fine — an assumption from reading code, never exercised; corrected.

Fix: a `removed_staff` tombstone `{staffId, name, removedAt}` written through the Gateway when a staff
record is deleted, one resolver (`StaffStore.displayName` → `Name (removed)`) for the picker, export and
analysis, `nextStaffId` refuses a tombstoned id, and the picker keeps the order's current attribution
selectable. See test plan section 5 and Skill 70. **Still open:** orders attributed to a member deleted
*before* this fix have no tombstone (test data only — there was no delete UI before PR #80); a tombstone
freezes the name at deletion time; a low-priority follow-up would be to also stamp `staffName` on
orders/events at write time (the same schema-level change DELETE-FEATURE-ROADMAP item 3 describes for
products) if history must survive without the tombstone collection.

---

## Security: `recordMutation` has no server-side role check for any entity/action except staff/delete

Found while closing the staff-delete gap above (2026-09-21). `functions/index.js`'s `recordMutation`
derives `actorRole` from the caller's own tenant membership doc for the audit trail, but never uses
it to authorize the mutation itself — only `provisionMember` checks role
(`canAssignRole`/`role-not-allowed`). Every `DataModel.on*` role guard (`onDeleteOrder`,
`onDeleteProduct`, `onAdjustOrder`, etc.) is client-side only; a signed-in tenant member with a valid
ID token can call the gateway directly and bypass every one of them. Confirmed by a passing test:
`functions/test/index.handlers.test.js`'s "an ORDER delete by a non-owner/admin is unaffected" case
returns 200 for a `manager` role, by design of the current (unfixed) behavior.

Staff delete got a narrow, targeted fix (2026-09-21) because it carries real security weight — it
can cascade-revoke a teammate's Firebase Auth login via `AuthService.cleanupStaffAuthDocs`. Every
other entity/action is unfixed.

**Update 2026-10-25:** becomes exploitable the day non-owner login ships (`Gateway.provisioningAvailable` flip). Planned as slice L2 of `specs/2026-10-25-multi-role-login-design.md` (D3), a hard prerequisite for real staff accounts on prod.

**Decision:** not built — a general authorization matrix (deriving the allowed actions per role,
server-side, for every entity) is a bigger design than any single delete-UI ticket should absorb
piecemeal; each narrow fix duplicates logic that belongs in one place. Needs its own session:
probably a shared `authorize(ctx.role, entity, action)` check called once per handler, sourced from
the same role/action rules `DataModel.qml`'s guards already encode client-side, so the two stay in
sync by construction rather than by two people remembering to update both.

**Update 2026-09-30 (photos design session):** the two product-photo endpoints (`uploadProductPhoto`,
`deleteProductPhoto`) get a narrow owner/admin gate, mirroring `AuthStore.canManageInventory`. This is partial
hardening only: a staff token can still edit or delete the product itself through `recordMutation`. When the general
`authorize(ctx.role, entity, action)` check above is built, replace the photo gate with it instead of keeping two copies.

---

## Delete: product delete doesn't clean up stock batches or the product photo — RESOLVED 2026-09-02

`InventoryStore.deleteProduct()` splices the product from the local array and routes the delete
through `Gateway.recordMutation`, but does **not** clean up that product's `StockBatchStore`
entries or call `StorageService.deleteProductPhoto()`. Both become orphaned after a product delete
— a stock batch pointing at a productId that no longer resolves to anything, and an unreferenced
image left in Firebase Storage.

**Original decision:** not touched by `feature/product-order-delete-ui` — this changes the blast
radius of what "delete a product" actually does (cascading deletes across two more subsystems)
and deserves its own review, not a drive-by inside a UI ticket that was scoped to "add the
missing button."

**Resolved.** Three candidate designs (do-nothing, centralize-the-read-filter, cascade-delete-
with-audit) were compared via `superpowers:brainstorming` + `ponytail:ponytail-audit` on three
throwaway branches (deleted after the decision — see
`docs/superpowers/specs/2026-09-02-cleanup-batches-photo-on-product-delete.md` for the full
comparison and the final, decided design). Cascade-delete was chosen. `deleteProduct()` now
removes every batch for the deleted product (audit-preserved via
`Gateway.recordMutation("stock_batch", ..., "delete", ...)`, mirroring the product's own delete)
and calls `StorageService.deleteProductPhoto()`, guarded in a `try/catch` since that call falls
through to a native singleton unavailable outside the real compiled app — same failure class as
the `logic`/`dispatcher` bug (Skill 58), guarded against directly this time rather than found the
hard way. The shared `InventoryStore._activeBatches()` filter (from the comparison's middle
tier) was implemented alongside it as a defensive backstop, replacing the four duplicated inline
guards added while fixing the two Sales Analysis bugs above. Full test plan:
`docs/superpowers/test-plans/2026-09-02-batch-cleanup-on-delete-test-plan.md`.

**Still open, not decided**: backfill for batches already orphaned by deletes that happened
before this shipped, and final confirm-dialog copy — both flagged in the spec doc, not blocking.

---

## CI ran `feature/product-order-delete-ui`'s tests — one real bug found and fixed, two tests reclassified

Update, 2026-09-01, to the entry that used to be here: this session flagged that qmltestrunner
*can* run (Skill 54) and recommended actually running this branch's new tests before merge.
That happened — real CI run, real `results.xml` — and it was worth doing:

**Real bug found and fixed:** all 9 `DataModel_deleteGuards` tests failed with
`ReferenceError: logic is not defined`, thrown from inside `DataModel.qml`'s own dispatcher
Connections block (`onDeleteOrder`, `onDeleteProduct`, and by the same pattern every other
handler in that block — `onAddOrder`, `onAdjustOrder`, `onUpdateStaff`, `onDeleteStaff`, etc.,
34 call sites total). `logic` was never declared anywhere in that file; the correctly-wired
property is `dispatcher` (`property alias dispatcher: _logicBus.target`, set from `Main.qml`'s
`DataModel { dispatcher: logic }`). This is **pre-existing on `main`**, not introduced by this
branch — `DataModel.qml` isn't part of this branch's diff. It went uncaught because no test had
ever exercised these handlers via a real signal dispatch before this branch's tests did; every
prior test either called a deeper private function directly (bypassing the buggy line, like the
existing `_tryAdjustOrder` precedent) or didn't touch this file at all.

**What this means beyond the test failure:** because the guard-refusal lines throw *before*
emitting anything, a blocked delete (wrong role, open-order reference, completed-order status)
was very likely failing **silently** in the real running app too — no crash, no error modal,
nothing visible, just a console `ReferenceError` nobody sees on a device. This directly
contradicts what this document's spec doc and test plan claimed about the permission/business-
rule error path being "already fully handled, verified" — that verification was a static code
trace, and a trace reading `logic.errorOccurred(...)` has no way to notice `logic` doesn't
resolve. Fixed: all 34 real call sites renamed `logic.` → `dispatcher.` in
`qml/model/DataModel.qml`.

**Two tests reclassified, not fixed as tests:** `tst_InventoryPage_deleteButton.qml` and
`tst_OrdersPage_deleteButton.qml` failed to *compile* — `InventoryPage.qml` → `GlassHeader` →
`Constants.qml` → `import Felgo`, and `.github/workflows/checks.yml`'s "QML Tests" job installs
plain Qt 6.8 only, confirmed by reading the workflow file rather than guessing. No full-Page QML
test can compile under that job, for any page, ever — not something fixable by editing the test.
Moved to `test/felgo-dependent/` (no CI job scans it; see that directory's README) rather than
deleted or left silently failing.

**Decision:** both closed out this session — bug fixed, tests relocated with their content
intact for manual runs on a Felgo-equipped machine. Full detail:
`docs/superpowers/test-plans/2026-08-30-product-order-delete-ui-test-plan.md`.

---

## Housekeeping: a memory-recorded active branch doesn't exist on the remote

Noticed, not chased down: prior-session memory records `fix/chunked-batch-import-over-200-rows` as
an active branch. It isn't on `origin` — the closest match by name and apparent scope is
`fix/bulk-import-chunking-durable-status`. Worth Taher confirming which one is actually current;
unrelated to `feature/product-order-delete-ui`, not investigated further here.


## Delete: Sales Analysis "Potential profit" went negative, "Inventory Value" didn't move at all — both fixed. Five other tabs' breakdown labels — RESOLVED 2026-09-26

Bug report (2026-09-02): after deleting a product, a value in Sales Analysis wasn't updating
correctly. Followed `superpowers:systematic-debugging` — traced all 6 `SalesPage.qml` view
modes (Value, Purchased, Current, Revenue, Sold, Profit×2 sub-modes) rather than guessing at
the one tab mentioned, since the report asked for exactly that.

**Root cause, confirmed and fixed**: `InventoryStore.deleteProduct()` doesn't clean up that
product's `StockBatchStore` entries (already documented above, deliberately deferred). The
orphaned batch then gets walked by both `InventoryStore.potentialProfitByDimension()` (feeds the
xlsx export's Potential section) and `SalesPage.qml`'s on-screen "Potential" tab, which duplicates
that walk inline rather than calling the store function. Both priced the batch's revenue at 0
(`getById(productId)` returns nothing) while still charging its real `cogs` — a phantom loss that
dragged the "Potential profit on open stock" hero total down by the deleted product's full COGS,
for stock that, from the user's perspective, no longer exists.

**Fixed**: both places now skip a batch entirely once its product no longer resolves, instead of
pricing it at 0. Failing test written first (`tests/tst_InventoryStore_potentialProfitOrphanedBatch.qml`,
4 cases) against the store function — same import tier as `tst_InventoryStore_mutationConflicted.qml`,
which passed on a real CI run this session, so no reason to expect this one can't. The
`SalesPage.qml` mirror isn't independently tested (Felgo page, can't run in this CI job) — verified
by code symmetry with the tested fix instead, same discipline as the rest of this session.

**Follow-up report, same session (2026-09-02): "Inventory Value" tab wasn't affected by a delete
at all — not the total, not any chart.** Confirmed and fixed. Same upstream root cause (orphaned
`StockBatchStore` entries), different symptom: `totalValue()`, `valueByProduct()`, and
`valueBySupplier()` never called `getById()` at all — they only need `qtyRemaining × unitCost`
from the batch's own stamped fields, no live product required, so a deleted product's remaining
stock kept counting in full, forever, with zero visible effect. `valueByCategory()` did call
`getById()`, but only to pick the category label (falling back to "(uncategorised)") — it still
included the value either way, never excluded it. Fixed all four with the same defensive skip:
exclude a batch entirely once `getById(productId)` returns nothing. This also makes the Value tab
consistent with "Current," which already excludes a deleted product's stock (it walks
`InventoryStore.products` directly) — before this fix the two tabs disagreed with each other about
whether a deleted product's stock still existed. `SalesPage.qml`'s filtered `_valueMaps()` walk had
the identical unguarded pattern and got the same fix; the unfiltered path already delegates to the
now-fixed store functions. Failing test first: `tests/tst_InventoryStore_valueOrphanedBatch.qml`
(5 cases). Note: `totalValue()` itself currently has no live caller anywhere in the QML codebase
(checked) — fixed anyway since it's part of the same function group and is exercised by the new
test, but the actual user-visible path is the `_valueMaps` → `valueByProduct/valueBySupplier/
valueByCategory` chain.

**A bigger question this raised — answered 2026-09-02**: should deleting a product with
remaining stock (`qtyRemaining > 0` in any batch) even be allowed in the first place? Answered:
yes, allowed, with a warning — see the resolved entry above. `deleteProduct()` now shows the
remaining quantity and value in the confirm dialog and cascades the delete through the stock
batches rather than leaving them orphaned. Blocking the delete outright was considered and
rejected — there's no existing way to write off a batch's quantity to zero otherwise, which would
have trapped a user wanting to remove a discontinued or mis-entered product.

**Reconsidered again, 2026-09-14, on-device review**: proposed blocking delete until *every*
transaction referencing the product has been "reverted." Re-examined rather than implemented:
this doesn't actually solve the trapped-user problem it's aimed at, for two reasons. First,
there's no way to revert a *purchase* (a received batch) at all — `StockBatchStore` has no
"return to supplier" or remove-a-batch function — so this would make delete permanently
impossible for any product that was ever restocked, which is most of them. Second, reverting a
*sale* (reopening or reversing a completed order) increases remaining stock — it undoes the
consumption — it doesn't provide any path to reduce stock to zero. A product with genuinely
excess or unsellable stock would never become deletable under this rule, recreating the exact
problem blocking delete outright was rejected for the first time around. The actual fix for the
underlying concern — dangling references surviving a delete — is what shipped this same day: see
the entry below, which found and fixed a concrete instance of exactly that risk in the order-
reversal path, using the same "guard every consumer, don't block the action" approach rather than
restricting when delete is allowed.

**Second finding, audited but explicitly not fixed here — different, bigger root cause**: the
other five tabs (Value, Purchased, Revenue, Sold, Profit's Realised sub-mode) keep correct
*totals* after a delete — those walk the immutable event/batch ledger directly, no live-product
dependency for the number itself. But their **by-category** breakdown silently reclassifies a
deleted product's historical contribution into an "(uncategorised)" bucket, and their **by-name**
breakdown shows the raw `productId` instead of the product's name, because both resolve
category/name via a live lookup (`InventoryStore.getById`/`.products`) rather than data stamped on
the transaction record at the time of the sale/purchase. This is correct-by-design for the
"Current" tab (a live stock snapshot — a deleted product correctly vanishing from it is not a
bug) but wrong for anything meant to be permanent history. Real fix would mean stamping
category/name onto each transaction/consumption record at creation time — a schema-level change
across every write path that creates one, not a one-line defensive check, and a different root
cause from what's fixed above. Not attempted this pass — flagging it here rather than bundling a
second, much larger fix into the same change (Iron Law: one fix at a time).

**Decision**: fixed the total-corrupting bug (Potential profit). Documented, not fixed, the
breakdown-mislabeling issue across the other five tabs — worth its own dedicated design pass.

**Follow-up, RESOLVED 2026-09-26 (`fix/2026-09-26-sales-analysis-deleted-product-labels`)**: the
"schema-level change" framing above turned out to only be half true once traced to source.
`productName` was already stamped on every `TransactionStore` entry at creation time — the by-name
half was a small, contained **read-side** fix (`BreakdownMath._productNameKey` /
`SalesPage._namedProductMap` re-derived the name live instead of using what was already on the
entry). `category` genuinely was never stamped anywhere — that half needed the write-path change
as originally scoped: `recordPurchase` / `recordCreated` / `recordSaleFromOrder` now stamp
`category` at time-of-transaction; `recordReturn` / `recordPriceAdjust` reuse the *original sale's*
stamped category via a new `_stampedCategoryFor()` lookup, since the product referenced by a return
may already be deleted by return time. Read side (`BreakdownMath`/`RealisedMath`) now prefers the
stamped value **only** when the live product no longer exists — a still-existing, recategorized
product's history keeps showing its current category, unchanged. A real, pre-merge bug in this fix
itself is worth recording: the first pass got the precedence backwards for `RealisedMath` (used
`e.category || categoryOf(...)`, which let a stale stamp override a still-live product's *current*
category) — caught by the Node parity suite's `bydimension_category_live_product_wins_over_stale_stamp`
test actually failing (real `node --test` run, not a trace), fixed with a `_resolvedCategory()`
helper that checks live-product-existence first. See
`docs/superpowers/specs/2026-09-26-sales-analysis-deleted-product-labels-design.md` for full detail.
Also applied to the server-side parity port (`functions/lib/breakdownMath.js` / `realisedMath.js`),
which had the identical bug and is a live Cloud Function (`computeAnalysis`) reading the same
Firestore collections — would otherwise have kept mislabeling server-generated reports/exports
after the client-side fix shipped.

**Two adjacent, related findings — audited, deliberately not fixed here (Iron Law: one fix at a
time)**:
1. The category **filter** dropdown (`RealisedMath._passesScope`'s `scope.category` matching) is a
   separate mechanism from the breakdown **label** fixed above and stays live-only. A deleted
   product can no longer be chosen in the filter dropdown in the first place, so this doesn't
   reproduce the mislabeling bug — but if a *still-live* product is filtered by category while a
   *different, now-deleted* product's history should logically also match, that history is silently
   excluded from the filtered total. Low severity, no user report against it.
2. An order-wide price adjustment (no single `line.productId`) spreads its delta across every
   product in the order via `OrderMath.spreadOrderDelta(..., categoryOf)`, which is inherently
   per-split-product and doesn't have a single value to stamp — genuinely deleted-product entries
   from that path still resolve category live and can still show "(uncategorised)". Narrow: only
   affects an order-wide (not per-line) adjustment touching an already-deleted product.

## Delete: cascade-deleting stock batches created a NEW dangling-reference path — found on-device review, fixed

Found during Taher's on-device review of the Tier C cascade-delete PR (2026-09-14), not by a test
— a real regression introduced by that same PR's own fix.

**The chain**: `deleteProduct()`'s cascade (see the entry above) correctly removes every batch for
a deleted product. But `StockBatchStore.restoreFifo`/`topUpOldest` — called from **11 places** in
`DataModel.qml` whenever a completed order gets reopened, reversed, or adjusted (a return or
exchange with restock, for instance) — fall through to synthesizing a brand-new
`"Adjustment (drift repair)"` batch at `unitCost: 0` when no batch exists for the productId
anymore. That fallback is correct for genuine drift on a product that still exists (its original,
intended purpose). It's wrong once the product has been deleted: it resurrects exactly the
orphaned-batch problem the cascade was built to prevent, except now with the wrong (zero) cost
basis, for a product a user explicitly removed. Concretely: sell 1 of 5 units via a completed
order, delete the product (batch correctly cascades away), later process a return/exchange or
reopen that order — a phantom batch reappears for a product that no longer exists in the catalog.

**Fixed**: two shared wrappers in `DataModel.qml` (`_restoreFifoSafe`, `_topUpOldestSafe`) check
`InventoryStore.getById(productId)` first and skip the call entirely — rather than letting it fall
through to the synthesize-a-batch path — when the product no longer exists. All 11 call sites
route through these instead of calling `StockBatchStore` directly, rather than guarding each one
individually (same "one place to get it right" reasoning as `_activeBatches()`). Test:
`tests/tst_DataModel_restoreFifoSafeGuards.qml` — only the skip path is independently testable;
the "product still exists, delegates through normally" path chains into a real network round-trip
to mint a batch id, same untestable-without-mock-HTTP territory as the rest of this session's
`Gateway`-adjacent tests.

**Worth naming as a pattern, not just this one instance**: this is the second time a fix aimed at
one symptom (orphaned batches breaking Sales Analysis) needed tracing into a completely different,
non-obvious corner of the codebase (order reversal/adjustment) to find where the SAME underlying
resource (a deleted product's batch data) gets touched again. A change that looks contained to
"what happens at delete time" can have consumers anywhere a productId outlives the product record
— reversal flows, exports, reports, anything that persists a productId and looks it up later.
Worth a deliberate sweep for other such consumers before considering this fully closed, not
assumed complete after one round.

## Delete: batch stays in Firestore after product delete — CAS-check failure, pre-existing bug found via on-device repro

Reported on-device, exactly reproducible: create a product with stock 10, sell 1 via a
completed order (batch now `qtyRemaining: 9`), delete the product — product disappears, batch
stays in Firestore at `qtyRemaining: 9`, confirmed directly in the Firestore console.

**Root cause, pre-existing, not introduced by the cascade-delete feature**: `StockBatchStore`'s
`consumeFifo`/`restoreFifo`/`topUpOldest` success handlers stamped a fresh, client-generated
`updatedAt: new Date().toISOString()` onto the local batch cache after every successful
`Gateway.recordDelta` call. Server-side, `applyDelta` never touches `updatedAt` at all — only the
delta's target field. So the local cache's `updatedAt` diverges from Firestore's actual stored
value the moment any batch is first consumed against, restored, or topped up, and stays diverged
forever. The cascade-delete feature was the first thing to ever send that locally-cached batch as
a CAS `before` for a delete — the server's `_deepEqual(current, before)` check fails on that one
field, the delete gets silently rejected as a 409 conflict (conflicts are never retried), and
`StockBatchStore._onMutationConflicted` quietly restores the batch to the local array with no
toast (by design) — invisible unless someone checks Firestore directly, exactly what happened
here. Full trace and the general lesson: SKILLS.md Skill 60.

**Fixed**: removed the synthetic `updatedAt` bump from all three success handlers — the field now
correctly stays whatever it was, matching what the server's delta-apply path actually does.

**Not independently unit tested** — verifying it needs a real `Gateway.recordDelta` network
round-trip to fire the success callback, same untestable-without-mock-HTTP territory as every
other Gateway-adjacent path this session. Verified by exact code trace instead; on-device
re-test of the original repro is the real confirmation, recommended before considering this
closed.

## Delete: reversal/reopen silently skipping stock restoration needed to be visible, not just safe

Follow-up report, on-device (2026-09-15): the Skill 60 fix (batch actually gets deleted now) was
confirmed working. But testing the *other* direction — reopening a completed order back to
pending, or reducing its quantities, when the product it referenced has since been deleted —
looked wrong: "it just vanishes... there's no product or batch to handle the return or revert of
status." That's `_restoreFifoSafe`/`_topUpOldestSafe` (see the entry above) doing exactly what
they were built to do — correctly refusing to resurrect a phantom batch — but doing it with only
a `console.warn`, invisible to whoever's actually processing the reversal. The order's own
status/quantity change still completes; the stock side of it silently becomes a no-op with no
indication why.

**Fixed**: both wrappers now also emit a new `Logic.stockRestorationSkipped(productId)` signal
(via `dispatcher.stockRestorationSkipped(...)`, the correct property post-Skill-58), which
`Main.qml` turns into a Toast — "Stock wasn't restored — a product on this order was deleted and
no longer exists." The reversal/reopen still completes either way (blocking it was already
considered and rejected, see the entry further above); this only makes the consequence visible
instead of silent. Test: `tests/tst_DataModel_restoreFifoSafeGuards.qml`, extended with 2 cases
verifying the signal fires with the right productId, using `SignalSpy` on the real `Logic`
signal — not a repeat of the `Gateway.recordMutation` monkey-patch mistake from earlier.

## Delete: the Activity feed never showed a delete happening at all

Reported same review pass: `product_added`/`product_updated`/`product_restocked`/`staff_added`/
`staff_updated` all call `ActivityLog.record(...)`; none of the three delete functions
(`InventoryStore.deleteProduct`, `OrdersStore.deleteOrder`, `StaffStore.deleteStaff`) ever did.
Deleting something left zero trace in the one place this app already shows a history of what
happened.

**Fixed**: added the same `ActivityLog.record(...)` call already used by every other mutation in
each of those three functions (`"product_deleted"`, `"order_deleted"`, `"staff_deleted"`), plus
matching icon/gradient entries in `ActivityPage.qml` for the three new kinds — reusing the
`"delete"` icon name, which already existed in `Constants.colorIconSet` for exactly this kind of
history-feed entry (the same lookup this session avoided for the row-level delete *buttons*,
which needed a different, tintable icon instead — see the `feature/product-order-delete-ui`
work). Test: `tests/tst_ActivityLog_deleteEntries.qml` (4 cases) — `ActivityLog.record`'s local
`entries` update is synchronous, only the Firestore push is fire-and-forget, so this one is
cleanly and fully testable, unlike most of this session's Gateway-adjacent fixes.

## Delete: pushing the stock-restoration-visibility fix broke a pre-existing, unrelated test on CI

The `Logic.stockRestorationSkipped` fix (entry above) shipped a bare
`dispatcher.stockRestorationSkipped(productId)` call inside `_restoreFifoSafe`/`_topUpOldestSafe`.
Real CI run: `tst_OrderMetadataEditPreservesConsumption.qml` failed with `Property
'stockRestorationSkipped' of object DataModel... is not a function`. That test (and 3 others —
`tst_DataModel_discountEditTax.qml`, `tst_DataModel_completeOrderReentrancy.qml`,
`tst_DataModel_adjustOrderSyncGuard.qml`) instantiate `DataModel { id: dm }` with no `dispatcher`
set at all. QML's `Connections` defaults `target` to its parent when unset — so `dispatcher`
there silently resolves to the `DataModel` instance itself, which has no such function. Real
production code is unaffected; `Main.qml` always wires a real `Logic` instance as `dispatcher`.

**Fixed**: guarded the call with `if (dispatcher && typeof dispatcher.stockRestorationSkipped ===
"function")` in both wrappers, rather than touching any of the 4 unrelated pre-existing test
files. New regression test added to `tests/tst_DataModel_restoreFifoSafeGuards.qml` reproducing
the exact no-dispatcher setup.

---

## Photos PH3: accepted limits of the server cascade — BUILT 2026-10-03, PH3b merged and deployed (Taher 2026-10-12), PH4 client BUILT 2026-10-06 (items 1, 4, 5; item 2 dropped, `Qt.uuid` missing; see the photos design)

Built: owner/admin gate on both photo endpoints (the narrow gate from the 2026-09-30 update above), `pending_cleanup`
marker written in the product-delete transaction, post-commit prefix sweep, F3 upload preflight (no orphan objects on
404/409), strict id whitelist. Design: `specs/2026-09-30-photos-s3-s4-design.md`. Accepted, on purpose:

1. **F5 (strict CAS includes `photoIds`).** An edit whose `before.photoIds` is stale (a photo was confirmed on the
   server between edit and drain) gets 409 and the user's edit is parked. Pinned by F37-F39. Relaxing it needs the
   server to preserve `photoIds` itself; not done.
2. **Residual upload race.** A product deleted between the F3 preflight read and the Storage write can leave one orphan
   object pair (the transaction then returns 404). Pinned by F10. The marker sweep does not catch it (the marker was
   written before the upload). PH3b's scheduled sweeper is the intended fix.
3. **Failed sweep is only retried by PH3b.** Until the scheduled function is DEPLOYED (built 2026-10-05, see "PH3b scheduled sweeper: accepted limits"), a sweep that fails (Storage outage)
   leaves the marker with `attempts` and `lastError` and nothing re-drains it.
4. **Batch/ops reject inventory deletes** (400 `cascade-delete-not-allowed`, whole request, zero writes): they cannot
   write the marker without breaking their write-ceiling arithmetic. No client sends one today (bulk import is
   create-only). Revisit when an atomic product delete is built.
5. **Existing e2e `test_upload_rejects_a_productId_containing_a_path_traversal_slash`** still expects `invalid-request`;
   the whitelist did not change that error code.
6. **E2E helper vacuity (found 2026-10-03, PR #113 CI).** `E2EHelpers.pollEmulatorDoc` starts with `latest = null`, so a
   `d === null` ("doc is absent") predicate passed on the first tick, before any response arrived. It hid a real failure:
   the cascade test deleted from a client cache with no `photoIds` (photos were uploaded by direct POST), the server
   returned 409 and the Gateway dropped the delete as stale (same family as item 1). Fixed for the photos tests via the new
   optional `requireResponse` argument (absence checks must pass `true`). **Still vacuous, deliberately not touched in this
   PR:** `tst_InventoryE2E.qml` (the product-delete check, ~line 262) and `tst_BulkImportChunkingE2E.qml` (~line 154). Making
   `requireResponse` the default would make them honest but could turn them red; do it as its own small PR.

---

## Product delete is destroy-before-ack (found 2026-10-04, PR #113 device test) — FIXED: photos (PR #113 branch), batches (BC1 #118 server + BC2 #119 client), Activity and queued photos (BC2, ack-gated)

**Symptom:** device A uploads a photo while device B deletes the product (9 photos). Result: product still listed, 3 photos shown,
4 objects in Storage, Activity says deleted, batches gone.

**Root cause:** `InventoryStore.deleteProduct` starts irreversible side effects without waiting for the server's answer to the
product delete. A's upload changes `photoIds`, B's CAS `before` is stale, the delete 409s and the product survives (the
`_onMutationConflicted` restore is the "reappeared"). Meanwhile B had already sent one `deleteProductPhoto` per cached photo
(PH4 item 3 of the design, not yet built in PH3-only PR #113), which removed ids and objects from the surviving product. The
server upload path is NOT at fault: it 404s on a missing product.

**Fixed (branch `fix/2026-10-04-pr113-upload-delete-race`):** removed the client photo loop; photos are removed only by the server
sweep after a committed delete. Pinned by e2e `test_stale_delete_409_keeps_the_product_and_every_photo`.

**BC1 (server) implemented 2026-10-05 (branch `feat/2026-10-05-bc1-server-batch-sweep`, not yet deployed):** after a committed
product delete the server now also removes the product's `stock_batches` (queried server side by `productId`, chunks of 100,
one `cascade~{productId}~{batchId}` audit entry per batch) before it sweeps the Storage prefix, driven by the same
`pending_cleanup` marker. The marker now carries `actorUid`/`actorRole`/`requestId`. `recordMutation` gained an owner/admin gate
on `inventory` delete (403 `role-not-allowed`). Items 1-3 below stay open until BC2 (client) lands AND BC1 is deployed.
**PH3b review 2026-10-05 (design only, nothing changed in code):** `index.js` `updateMarker` uses `set(patch, {merge:true})`, which re-creates a marker another sweeper just deleted as a partial doc. Dormant today (one sweeper); it becomes real the moment PH3b runs beside the handler, so the PH3b slice S-B fixes it with `update()`. Do not deploy a scheduler without that fix.
**PH3b second review 2026-10-05 (PR #125):** (R1, fixed in design) a single unordered `limit(500)` read would let parked markers starve new ones; now paged (`PAGE_SIZE` 200 x `MAX_PAGES` 10). (R2) PRODUCTION BLOCKER: the Cloud Monitoring alert on `PH3B_ALERT` logs must exist and pass test DV-9 before any production data (runbook `specs/2026-10-05-ph3b-alert-runbook.md`). Alerts reach email / Google Cloud console mobile app, not the Karobar app.
**New limits created by BC1:** (a) a failed batch sweep leaves the marker and WAITS for PH3b (no replay re-sweep, Q-BC-9 = no);
batches are money data, so PH3b must not silently abandon a capped marker. (b) Until BC2 ships, an old client still sends its own
`stock_batch` deletes; they answer 409 `current: null` after the sweep (harmless, no toast). (c) A direct token call by
manager/staff to delete a product now gets 403 (the UI never sends it). (d) PR #118 review C1: the `cascade~` audit-id prefix is reserved (400 `invalid-request-id`); `recordMutation` / `recordDelta` still do NOT validate the rest of `requestId` / `entityId` (no `/` or length check, unlike `operationLogic.isSafeDocId`): pre-existing, flagged here, fix on its own branch.

**Status 2026-10-13: items 1-3 CLOSED by BC2 (#119, merged).** `InventoryStore.deleteProduct` sends only the product delete; the server sweeps batches and photos after the commit, and the Activity entry and queued-photo purge wait for the ack (`_onMutationApplied`); a 409 or a discarded parked delete resyncs. Item 4 stays accepted. The text below is the original problem list.

**Original list (items 1-3 closed with BC2):**
1. Batch deletes are sent before the product delete is acked -> after a 409 the product has no stock batches. Options: (a) gate
   batch deletes on a Gateway "applied" signal (new ack plumbing, per-mutation); (b) one atomic `recordOperation` for product +
   batches (the delete roadmap item, larger, also removes the `photoIds` CAS problem); (c) accept for dev. (b) is correct, (a) is a patch.
2. `ActivityLog.record("product_deleted")` is written locally at click time even when the delete is rejected.
3. `PhotoQueue.discard` of this device's queued photos runs before the ack: a rejected delete loses the user's pending photos.
4. A delete 409s on any concurrent `photoIds` change (F5 family); the user retries after the restored row appears.

## PR #118 device test (2026-10-04): four observations. Root causes from CODE READ, not reproduced on a device

**Setup:** add a product with a description over 1 MiB; edit it; wait 3 min; restock it; delete it.

1. **Edit of a >1 MiB description is rejected 3 min later and the glass header shows the rejected list.** Not a new bug: the client has no size cap on `description` (nor on any text field) and the server write is refused (Firestore documents are capped at about 1 MiB; exact status/response UNVERIFIED), so the write is parked as a server rejection (S2b) and listed. Open: decision D1 (cap length client-side and server-side).
2. **Restock confirm: dialog never closes, Confirm and Cancel dead, other fields still editable.** `RestockDialog.onPrimaryClicked` sets `busy = true` and clears it only in the callback of `InventoryStore.restock` -> `Gateway.recordDelta`. The parked edit from (1) HOLDS the key `inventory/{productId}` (`OutboxStore.dueItems`: a parked item claims its keys; later writes for the same record wait behind it), so the restock delta is never due, its callback never fires, `busy` stays true. Meanwhile `StockBatchStore.addBatch` runs in parallel on a different key and DOES land: **a batch exists but the product's stock was never incremented** (stock vs batch ledger drift). Open: decision D2.
3. **Delete while the edit is parked: batches deleted, product and rejected list intact.** Same held key: the product delete waits behind the parked edit and is never sent, while the per-batch `stock_batch` deletes (other keys) go out at once. This is exactly the destroy-before-ack bug; BC2 (this branch) stops sending batch deletes, so nothing is destroyed on the server any more. New consequence (decision D3): the product vanishes from the local list while its delete sits behind the parked write; if the user then discards the parked edit, the delete goes out with the stale local `before` (which still contains the rejected edit) and answers 409, so the product returns (with its batches, after the resync) and the user must delete again.
4. **Rejected list stays after the delete.** By design: a parked write is released only by Retry or Discard (S2b/S3), and a later delete of the same record does not touch it.

**Status (updated 2026-10-04, PR #119):** (3) fixed in the batch part by BC2 (BC1 deployed per Taher). (1) **accepted as is** (D1: no size cap in the app). (2) and (3-consequence) **fixed by refusing up front** (D2, D3, commit `2362d9d`): restock and delete show "Fix or discard the stuck change for this product first" while the product has a parked write, and write nothing. **Order completion (2026-10-04, PR #121, decision B):** `_tryCompleteOrder` now refuses up front when a line's product has a parked write (same message; order stays `pending`; nothing consumed or queued). Cause (code read, repro = red-by-design E2E in `tst_OrdersE2E.qml`): the parked item claims `inventory/<id>` in `OutboxStore.dueItems`, so `deductStock`'s delta never sends, its callback never fires, `_completingOrderIds` stays set and FIFO batches drift from `product.stock`. Cost accepted by Taher: a counter sale is blocked until the parked edit is Retried or Discarded (advice was to bypass). **Still open (same hang, UNVERIFIED, not guarded):** `_tryAdjustOrder` (returns/exchanges: `deductStock`, `creditStockNoBatch`), `completeImportedOrder`, and the `creditStockNoBatch` failure-path credit inside `_afterAllDeltas`. A product with a parked write cannot be restocked, deleted or sold until the user Retries or Discards it (intended).


## Unsynced product edit (PR #121 follow-up, 2026-10-05)
- **Fixed in `feat/2026-10-05-unsynced-edit-ledger` (CI unverified):** a product edit's `field_change` / `stock_adjustment` rows and its Activity entry no longer register when the server rejects the edit; a sale is refused while the product has any queued edit.
- **S4 done in PR #122 (CI unverified):** server reads overlay queued AND parked edits (changed fields only) and the product card / edit dialog show a "Not synced" / "Rejected" badge. A queued CREATE is not injected into a read after a relaunch (the product is missing from the list until the create syncs): roadmap.
- **Open (roadmap, decision Q3):** `created`, `purchase`, `photo_change`, `sale`, `return`, `price_adjust` ledger rows still register before their parent write is acked (same bug as device observation 1). Needs `recordEdit` + `dependsOn` per call site.
- **Open:** Activity `product_updated` for an edit is in-memory until the ack; an app death between edit and ack drops the entry (the ledger rows survive).
- **Fixed in PR #122 (CI unverified):** a product doc over 1 MiB (`DocLimits`, estimate with a 4 KiB reserve) is refused before anything is queued; the dialogs pre-check. Gap: bulk import (`ImportPreviewDialog`, `recordMutations`) has no size check; an oversize row is still rejected by the server and removed by `_onBatchMutationFailedPermanently`.
- **Verified by code read (PR #122):** every send path (single, batch, delta, operation) ends in `Gateway._reschedule()` after a conflict or permanent drop, so `pruneOrphans` runs. Not run.
- **Open (found in PR #121 final sweep, 2026-10-05):** (a) the sale guard counts a queued CREATE and a queued edit made OFFLINE as "unsynced": an offline edit, or a product added offline, cannot be sold offline until it syncs (decision Q1 = Z, accepted; real cost for an offline-first counter). (b) Device-test cases 4.2, 4.3, 4.4, 4.10 of `2026-10-05-unsynced-edit-ledger-test-plan.md` forced a server rejection with a > 1 MiB description; the client cap now refuses that up front, so no verified on-device way to force a rejection exists. Pick one before testing.


## PH3b scheduled sweeper: accepted limits (BUILT 2026-10-05/06; deployed, DV-1..DV-9 reported done by Taher 2026-10-12)

Code: S-A #126, S-B #127 (merged); e2e S-C (this branch). Found in the PR #126/#127 final sweeps; none changed in code on purpose.

- **M1 env order.** Envs run `dev`, `test`, `prd` and share ONE 240 s budget. Many slow dev/test sweeps in a single run could defer `prd` markers to the next run. Needs many slow sweeps at once; backoff caps retries at 30 min. One-line fix exists (`["prd","test","dev"]`, plus edits to ~17 order-sensitive test assertions). Decision: keep, reopen if `deferred` is ever non-zero for `prd` in the logs.
- **M2 no per-sweep timeout.** One sweep started at ~239 s can reach the 300 s function timeout. Safe: every step is idempotent, `attempts` is not bumped, the next run retries.
- **M3 parked markers are never deleted** and count toward `MAX_SCAN` (2000). Only an unrealistic number could hide new ones; ERROR `PH3B_ALERT backlog` fires first. Humans clear parked markers (un-park or delete).
- **M4 false `park-failed` alert.** If `updateMarker` hits NOT_FOUND at attempt 11 (a concurrent sweeper deleted the marker) `park` also NOT_FOUNDs and raises a false alert. Needs 11 failures plus a race.
- **M5 summary `parked`** counts already-parked + capped markers, not newly parked malformed ones (those are in `malformed`).
- **E2E cannot prove (DV-1..DV-9 on a real project do):** the no-index claim, cursor-without-`orderBy` on the real Admin SDK, structured-log field names in Cloud Logging, Cloud Scheduler location for `asia-south1`, `maxInstances` on a scheduled function, the alert policy.
- **Deploy drift:** the P3 `update()` fix is in `recordMutation`'s shared module. Deploy ALL functions, not only the new one.
- **Production blocker (Q-L):** the log-based alert (runbook `specs/2026-10-05-ph3b-alert-runbook.md`) must exist and DV-9 pass before production data relies on the sweeper.

## PR #133 review (2026-10-07): two accepted limits of "row gone -> discard queued photos"

1. **RESOLVED 2026-10-08 (Taher chose option b, this PR): a 404 is no longer judged by status only.** The text below is the original limit, kept for the record; `PQL.shouldDiscardOnFailure` now also requires the body error `product-not-found` (`PQL.errorCodeOf`). The decision now lives in `PhotoQueue._failUpload` (unit-tested since the PR #138 sweep); only the XHR plumbing is device-only.
   **Accepted limit introduced by R1 (PR #138 sweep):** a 404 WITHOUT the `product-not-found` body (misrouted/undeployed endpoint, or a body lost by the QTBUG-49896 status snapshot) for a product whose row is gone from the COMPLETE local list parks a `failed` queue item that no tile shows (`ProductPhotoGallery` only lives in the product dialog, nothing listens to `photoUploadFailed`). It kept its local files until sign-out (`PhotoQueue.clear()`). **FIXED 2026-10-12 (PR #138 sweep part 2, O1, Taher asked for it):** `PhotoQueue.purgeOrphanedFailures()` discards `failed` items of the signed-in identity whose row is absent, run by `InventoryStore.onListCompleteChanged` only when the list is complete (never during paging, a fetch in flight or a reset). Accepted trade-off: R1's body check still governs the immediate 404 answer, but the later purge relies on the row-gone check alone, so a bad local list that reports complete without a live product could lose a failed photo (its local file included). The log line `404 without product-not-found, keeping photo` and `[PhotoQueue] purged N failed photo(s) whose product is gone from the complete list` show it on device. Same sweep fixed O2 (a late 2xx or failure report after `PhotoQueue.clear()` could emit `photoUploaded` under the next account: both paths now require the item to still be `uploading`) and O3 (a timeout firing both `onreadystatechange` and `ontimeout` counted the breaker twice: same guard).
   Original: **A 404 is judged by status only.** `PQL.shouldDiscardOnFailure(404, hasProduct === false)` never reads the response body. The server's real answer is `{error: "product-not-found"}` (`functions/lib/photoCleanup.js`, `functions/index.js`), but a misrouted or undeployed endpoint also answers 404. `InventoryStore` pages 50 rows at a time and the queue drains at startup, so a product that is queued but not yet loaded counts as "gone": the photo and its local file would be discarded and cannot be recovered. (That partial-list case was closed on 2026-10-07 by `listComplete`, PH4 follow-up 2; what R1 still protects against is a misrouted endpoint plus a row truly absent from the complete list.) Accepted while everything is dev state. Fix before production: also require the body error `product-not-found` (about 3 lines in `PhotoQueueLogic.js` plus the Node mirror and cases). Decision for Taher, see the review note.
2. **`current: null` on a conflict means "row gone".** Server side that is exact (`gatewayLogic.js`: `currentSnap.exists ? data : null`). Client side `Gateway._parseMutationConflict` also maps a malformed 409 body with no `current` key to null, which would purge queued photos and show the "already deleted" toast. The server always sends the key, so only a proxy or hand-built response could trigger it. Gateway.qml's header comment now states the real contract.

## Pre-PH5 tenants are unusable after PH5 (accepted, Taher 2026-10-08)
PH5 removed the product `photoUrl`/`photoUpdatedAt` fields from the client. Server CAS compares whole documents, so any product doc created before PH5 (all carry `photoUrl:""`, `photoUpdatedAt:""`) 409s on every edit or delete. Dev environment only; every PR is tested on a new tenant. If an old tenant ever matters: either recreate it or add server-side tolerance for the two keys (design Q-P5-3 option d). Pinned by `functions/test/gatewayLogic.test.js` F42. Spreadsheet exports from before PH5 have a 15th "Photo URL" column; the importer ignores it silently.

## Spreadsheet import is positional; a pre-PH5 15-column file or template imports shifted (accepted, Taher 2026-10-08)
`XlsxService.cpp` `readSheet` reads column N and labels it `kProductHeaders[N-1]`; the file's header row is never read and there is no column-count check. After PH5 a file exported or a template downloaded BEFORE PH5 (Photo URL in column 11) imports with Supplier = the URL text (a bogus supplier is created on confirm), Size = Supplier, Taxable = Size, Tax % = Taxable, old Tax % ignored. No warning. Accepted: dev only, fresh install each time, always export first and import later from the same build. Rule for users: never import a file or template made by an older build. If this ever matters: header-row check in `readSheet` (rejects a mismatched file; also covers the orders and staff sheets that share it). Review PR #137, finding R1.

## `OutboxStore.enqueueDelta` could coalesce a new delta into a PARKED or already-sent item: FIXED in PR #170 sweep (2026-10-28)

Found while reading the coalescing loop for P1 S2d-1: it skipped only the in-flight item. Two holes, both silent: (1) a PARKED item (rejected, waits for the user) took the new change down with it; (2) an item with `attempts > 0` was sent at least once and its reply may have been lost AFTER the server applied it, so the retry (same requestId) got the old answer back (idempotent replay) and any quantity merged in since was dropped while the caller was told ok. Fixed for ALL deltas (derived too): such an item is never a merge target (`StuckWrites.isParkedItem(candidate) || attempts > 0`), the new call queues as its own item. Tests in `tst_OutboxStore_movements.qml` (parked explicit/derived, sent-and-failed explicit/derived, skip does not hide a later fresh item) and `tst_InventoryStore_movementKinds.qml`. Cost: while offline with a failed first send, each tap queues its own item (same total, more requests). Status: fixed in code, CI is the oracle, not device-verified.

## Derived (non-explicit) deltas still merge across different floors (open, found 2026-10-28)

Explicit movements only merge when their floors are equal (K12). The OLD derived rule is untouched: `enqueueDelta` keeps the LATEST call's floors, so a derived `deductStock` with `floors {stock: 0}` followed by a derived credit (floors `{}`) merges into one item without the floor, and a derived restock-like credit followed by a floored deduction merges and is rejected as one. Reachable today only for derived callers (clamped `completeImportedOrder` uses clamps, not floors; no shipped caller mixes a floored derived deduction with another derived call on the same product within one outbox window). Fix when needed: apply the same equal-floors rule to derived pairs (changes `tst_OutboxStore` coalescing expectations, so it is its own slice).

## Imported-order completion is typed `adjustment`, not `sale` (P1 S2d-1, by design until S2d-2)

A clamped deduction cannot carry explicit movements (server 409 on a clamped quantity would lose the deduction). S2d-2 = a server-side kind hint for derived rows; needs a functions deploy.
## BottomSheet footer: the secondary button ellipsizes first on narrow phones and at Large font (open, Q-FW-1, 2026-10-28)
Since PR #167's footer fix the primary button keeps its full label (`SheetFooter.primaryFloor`) and the secondary button gives way. When both labels cannot fit side by side (somewhere between about 340 and 370 dp wide, the real glyph widths were estimated not measured; or Large system font; H2 in the footer test plan records the real number) the secondary label ends in "..." (sign-out sheet: "Sign out and disc..."). Nothing is lost: the title and the consequence lines already say that the work is discarded. Fix if a 340 dp phone matters: stack the two buttons vertically when their label widths do not fit (primary on top); needs a `GridLayout` footer and a second `TextMetrics`. Not done: it changes the footer pattern, which the bug report did not ask for.
Related, same cause class: `PrimaryButton` draws its busy spinner at the left edge over the centred label, so a busy primary that sits exactly at its floor (long primary label next to a long secondary) has no room for it. No shipped sheet pairs the two today.

## CI deploy-on-merge (PR #173 sweep, 2026-10-29): accepted, not fixed
- `firebase-tools@15.25.1` is fetched by `npx` at deploy time: pinned by version, no lockfile integrity. Moving it into a lockfile would turn every CLI bump into a functions-dependency change.
- Tag `deployed-main` is movable by anyone with write access. The forward-only move and the stale guard protect against our own runs only.
- No `dependabot.yml` for `github-actions`: the SHA-pinned `google-github-actions/auth` (`v2.1.13`) is bumped by hand.
- `main` has no branch protection (API check 2026-10-29). The approval gate protects the deploy, not the merge.
- The root `firestore-rules-tests` job still runs an unpinned `npm install -g firebase-tools` (pre-existing, not in this PR).
## `mint` placeholders replace user text that equals a bound name — FOUND 2026-10-28 (R2 design M6), ACCEPTED

In an operation with a mint op, a string inside `after` that contains `{{name}}` for a name bound EARLIER is replaced by the minted id, even when a user typed it (a supplier called `{{batch}}` gets the batch id in its name). Cosmetic, same caller, never another tenant or counter. Other brace text is kept as typed. Cost of the alternative (reject any brace text): a supplier typed `{{x}}` could never be restocked.

## Server mint registry holds only supplier and batch counters — BY DESIGN 2026-10-28

`counters` stays client-writable and product / order / staff ids are still minted by the client until each consumer migrates (atomic design 7b). F7 (a member can burn ids) stays open until the last caller moves; then the rules pin flips in its own PR.

## Mint seed lists the whole collection once per counter per year — FOUND 2026-10-31 (R2 sweep 2), ACCEPTED

When a counter doc is missing or damaged (first restock ever, and every January for the year-scoped batch counter) the server lists all doc ids of `suppliers` or `stock_batches` once to seed the counter. For a tenant with tens of thousands of batches that is that many document reads, once. A document-id range query on the year prefix would cut it, but could not be verified without the emulator in the chat sandbox. Revisit if a tenant ever passes ~10k batches.

## A member can still set a counter to any value up to 999,999,999 — FOUND 2026-10-31, OPEN until the rules pin

F9 closed the worst case (a value near 2^53 killed minting for the tenant). A member can still move a counter forward by hand, burning ids up to the ceiling; they cannot lock the tenant out any more because an out-of-range value is re-seeded. The real fix remains the `counters` rules pin at the end of the atomic arc (F7 above).

## `firebase-functions` is pinned to a release candidate (`^7.3.2-rc.0`) — FOUND 2026-11-01, OPEN

Seen while moving the runtime to Node 24; not changed in that PR. A pre-release in the deployed functions can change without a version bump of ours. Fix is its own PR: move to the current stable `firebase-functions` 7.x, run the full functions suite and the emulator e2e, then deploy.

## Deploy IAM role list — CLOSED 2026-11-01

Two gaps were found by the first live deploys (actAs on the App Engine default SA, `roles/firebase.viewer`); after both grants and the Node 24 runtime the deploy succeeded end to end, so no further role was needed. Left open as a choice, not a bug: the compute-SA `serviceAccountUser` grant may be unnecessary (see the design doc).

---

## Automatic token refreshes report failure inside open dialogs — FOUND 2026-11-01 (PR #180 review, read from code), FIXED 2026-11-01 (Q3)

**Where:** `AuthService.refreshIdToken` raised `authFailed` on every failure. `AddStaffDialog` listens while `_provisioning` (shows the error and frees the busy flag, so the owner can submit again mid-provisioning); `Main.qml` `onAuthFailed` writes into the Invite and Forgot-password dialogs when they are visible. **Fixed in the review sweep:** the refresh that a resume starts is silent (`refreshIdToken(true)`). **Fixed (Q3, owner took the default):** `ensureFreshToken()` now passes `true`, so the 120 s timer, `Gateway`, `PhotoQueue`, `LockManager` and `AnalysisService` refresh silently; wiring rules pin every caller. **Cost:** a refresh that keeps failing is invisible until the request that needed the token gets a 401, which each caller already handles. The explicit `onRefreshAuthToken` in `Main.qml` still reports.

---

## A silent check can switch workspace under open screens — FOUND 2026-11-01 (PR #180 review, read from code), FIXED 2026-11-01 (Q2)

**Fixed (Q2, owner took the default):** a silent workspace change now shows the "Your workspace changed" access screen (`accessBlock = "moved"`) and switches nothing; `Main.qml` closes every dialog, sheet and overlay first; Continue is a full load that applies the new workspace and syncs once. **Costs:** unsaved input in a closed form is lost; a write already sent when the pointer changed is still decided by the server from the users doc (not fixable client side). **Was:** `SessionRecheck.changeKind` returns `"tenant"`, `_applyAccess` resyncs every store through `tenantContextReady`, nothing closes open forms or tells the user. **Effect:** if `users/{uid}.tenantId` changes while the app is open (an invite accepted on another phone), an order form for workspace A can be saved after the stores already hold workspace B. **Lead:** treat a silent workspace change like a block (a screen that says the workspace changed, then reopen), or at least close overlays and toast. 

---

## An unreadable member doc for a DIFFERENT workspace blocks "unverified" even in a silent check — FOUND 2026-11-01 (PR #180 review), CHANGED 2026-11-01 (Q1)

**Changed (Q1, owner took the default):** a SILENT check ignores an unreadable member answer for a workspace this device never verified (nothing applied, 60 s window freed); full loads (sign-in, Try again) still block "unverified". A block that is already showing is kept. The old scenario was rewritten, not loosened. **Was:**

**Where (before):** `AccessState.outcome` has no held role for a workspace the device has not verified, and a silent check applies its answer. **Effect:** a flaky network at that moment puts an open session behind the access screen until "Try again". **Trade-off:** blocking is safe (server and rules decide every request anyway) but contradicts "a failed check never locks out a verified member"; ignoring it keeps the member working in the old workspace while the pointer says otherwise. Q4 (role toast printed the raw id) is fixed too: `AccessState.roleLabel` gives "Admin", "Manager"..., and "a new role" for any other value.

---

## Back does not close `confirmReturnSheet` and `staffActionSheet` — FOUND 2026-11-01 (PR #180 Q2 fold-in, read from code), NOT FIXED

**Where:** `Main.qml` `_allDialogs()` (the Back list) lacks these two popups, so a Back press with one open falls through to the overlays under it. **Not changed** (a Back behaviour change needs its own device check). The workspace change closes both (`_closeAllForWorkspaceChange`), and wiring rule `main-popups-complete` fails when any popup declared in `Main.qml` is in neither list. **Lead:** add both to `_allDialogs()` and run the Back steps on a device.

---

## A write sent just before a workspace change is decided by the server — FOUND 2026-11-01 (PR #180 Q2), NOT FIXED

**Effect:** closing a busy form does not cancel its request; the gateway derives the workspace from the users doc, so a request sent in the seconds around a change can land in the new workspace. Rare (an invite accepted on another phone at that moment). **Lead:** send the workspace id with gateway writes and refuse a mismatch on the server (a server slice, own design).

---

## Resume and reconnect now refresh the lists quietly — BUILT 2026-11-02 (L4a, CI unverified, device steps pending)

**What changed:** returning to the app, or the network coming back, re-reads the six paged lists (orders, inventory, stock batches, suppliers, staff, transactions) into a private buffer and replaces the lists in one step, only when the lists are at least 5 minutes old, nothing is queued, in flight or locked, no photo is uploading and the account is not blocked. Nothing blanks or flashes. Design `specs/2026-11-02-l4a-resume-refresh-design.md` (L4-D1..D8), test plan `test-plans/2026-11-02-l4a-resume-refresh-test-plan.md`.
**Limits (known, by design):** (1) A parked write blocks automatic refresh for that user until Retry or Discard. (2) If the sign-in sync fails, the lists count as current for up to 5 minutes. (3) `ActivityLog`, categories and order channels are not refreshed. (4) Every refresh re-reads every document (no incremental read). All four are L4c. (5) Pull-to-refresh and a "last updated" caption are L4b.

## Sign-in sync and discard resync still blank the list and drop rows that exist only on this device — FOUND 2026-11-02 (L4a design, read from code), NOT FIXED

**Where:** every store's `_resetAndFetch` (`orders = []`, then paging), used by `onTenantContextReady` and the discard resync. **Effect:** a row created offline and still queued is missing from the list until it is sent and a later sync reads it back; the data is safe in the outbox. A sign-in sync with queued writes is rare (queued writes survive a restart, so it is possible). L4a deliberately does NOT use this path on resume (the reason for the shadow fetch). **Fix idea:** move the sign-in sync to the same shadow fetch once L4a has been seen on a device (needs a decision on what the sign-in cover shows during the fetch).

## A read with no answer can hold a refresh for up to 3 minutes — FOUND 2026-11-02 (L4a, read from code), MITIGATED

`FirebaseService` sets no request timeout. A hung refresh read keeps `refreshing` up; since L4b the 5 s poll timer also runs while a run is out, so the run is cancelled by its own watchdog about 3 minutes after it started (`RefreshPolicy.runLost`), and a manual one tells the user (before L4b only the next trigger cancelled it). The older sign-in sync has no such watchdog (existing issue, unchanged).

## L4a review: three unconfirmed risks, left on purpose — FOUND 2026-11-03 (review sweep of PR #182), NOT FIXED

(1) The refresh swap does not compare the workspace id; it relies on every workspace change resetting the stores, which cancels a running refresh first. (2) A resume refresh that waits for a token refresh can run out its 2 minute wait if the token refresh is late; the next trigger covers it. (3) Swapping a whole list may reset a list's scroll position; only a device shows it. Details and the reasons they were not fixed: design doc section 6 (I1 to I3). The duplicate-row race between a Transaction retry and a refresh commit WAS fixed in the same PR (L4-D9).

## An open edit form stops the automatic list refresh while it is open — BY DESIGN 2026-11-03 (L4-D10, Taher's decision)

Nine forms hold the refresh (Add/Edit product, New order, Order detail, Restock, Add staff, Staff detail, Import preview, Confirm return). A form left open for a long time means lists under it can be older than the server's; closing the last form asks for one refresh (resume rules: 5 minute staleness, 15 s spacing, waits for the outbox). Read-only sheets, the staff action sheet and the category and channel managers do not hold. If a form is ever missed, a wiring test lists the exact set.

---

## Product picker v2: carried requirements for S3 and S4 — FOUND 2026-11-04 (S1 review sweep of PR #185, read from code), NOT FIXED (dormant helpers only)

**Where:** `qml/helper/PickerDraft.js` (`MAX_LINES`), `ProductPickability.js` (hook contract), the future wiring in `NewOrderDialog` and `OrderDetailDialog`.
1. **`MAX_LINES = 60` is only an early stop.** A line that spans two FIFO batches costs 4 operations, so 50 such lines give 201 and `CompletionPlan` refuses with `too-many-ops` (pinned by `FLOW-09`). The dialogs must run `CompletionPlan.build` as a dry run (it is pure) before enabling "Add to order", and keep `PickerDraft.canCommit` as the cheap first gate. The audit brief said the cap "asks CompletionPlan"; the code hard-codes 60 until S3.
2. **Completed-order edit does not use `CompletionPlan`** (`DataModel._tryAdjustOrder` uses the legacy per-line deduct), so the 60-line cap is only an early stop there; S4 decides whether to apply it.
3. **Parity gap to verify before S3:** `OutboxStore.hasParkedForEntity` counts held `dependsOn` rows, `unsyncedByEntity` skips them. If a held row can be parked, completion refuses a product the picker shows enabled.
4. **Guards that stay in the dialogs** because they are about the order, not the row: the order lock, `busy`, the `TransactionStore.hasMore` refusal for completed-order edits, the booked-tax rule on re-add, and a valid selling price (`PickerDraft.totals` counts a missing price as 0).
5. **Ids:** draft and plan ids are strings; an order line may hold a numeric id. Match plan entries to lines with `String(line.productId) === entry.productId`.
6. **Pre-existing, not S1:** `NewOrderDialog` skips the stock check at submit when the product is gone (`inv` null), so it fails open there.
7. **Answered in S2 (read from code):** `InventoryStore.revision` (ticks on every `products` change), `StockBatchStore.revision` (batches) and `OutboxStore.revision` exist. `InventoryStore.syncStates` is a property, so it emits its own change signal when the outbox changes. **`StockBatchStore._pendingMints` has NO revision counter:** adding or retiring a pending mint emits only `_pendingMintsChanged`, and `hasPendingMint` reads it. S3 must give the sheet a `revision` that also changes when `_pendingMints` changes (a small public counter on the store bumped from `onPendingMintsChanged`, or a `Connections` on `on_PendingMintsChanged`), otherwise a product whose mint lands while the sheet is open stays hidden until something else ticks.
8. **S2 (2026-11-04): `BottomSheet` Back key not verified.** With `guardClose` the popup's `closePolicy` is `NoAutoClose`, so the system Back key is handled only by the `Keys.onBackPressed` handler on the sheet's content item. It needs the content item to hold focus; the sheet sets `focus: true` but this was never run. If Back does nothing with a draft, nothing is lost, but it must be fixed in S5 (a `Shortcut` or a focus fix). On-device check 39.
9. **S2: the quantity field's `Accessible` label and the in-stock toggle's `Accessible.checked` are set but never read by a screen reader here.** TalkBack is step 25 of the test plan; S5 owns it.
10. **S2: `ProductPickerRow` reads `AuthService.isOnline` and `StorageService` directly** (to decide whether to ask for a thumbnail), while the sheet itself knows no store. Fine for now; if the row is ever reused outside the app, pass the photo URL in as a role instead.
11. **S2 review sweep of #187 (2026-11-09), FIXED on the branch:** double tap on Add handed the plan over twice (latch `_committed`); every tap rebuilt all chips (`sameList`); every refresh set every row (`changedRows`); the in-stock row had no accessibility action. Skill 161 rules 10 to 13.
12. **S2: the row showed no unit, FIXED 2026-11-09 (Taher: yes).** The price line reads "₹120 / kg", the pills "5 kg left" and "In this order: 2 kg", the quantity field is named "Quantity of X, in kg"; a blank or non-text unit is "pcs" (the store's default). Long units ("dozen boxes") make the pill wrap on a narrow card: check on a device. Original finding: `InventoryPage` shows stock as "12 pcs"; the picker row never reads `unit` (the role is built and unused), so a quantity of 5 has no unit on screen. Wrong-unit orders are a money error. Show it next to the price and the quantity field, or delete the role.
13. **S2: the list filled only in `onOpened`, after the slide-in, FIXED 2026-11-10 (sweep 3 of #187).** `Popup.opened` is true only once the enter transition has finished, so the sheet slid up with an empty list and filled in at the end (and `_later` and the debounce, gated on `opened`, dropped every refresh during the slide-in). Now a `Connections` on the sheet runs `_reset()`, sets `_live` and builds on `aboutToShow`, clears `_live` on `aboutToHide`; `rebuild` is a no-op unless live and not committed, so a late refresh or a late debounce cannot repaint a sheet that is leaving. A `Connections` and not `onAboutToShow:` because a handler here would replace BottomSheet's own slide-up. A reopen during the fade of a discarded sheet also starts clean now (before, only a committed one did). Device check 45 and 51. WIRE-19, 22, 23.
14. **S2: search debounce ADDED 2026-11-09 (Taher: yes), still measure (step 46).** The query is taken at once, the list is rebuilt 150 ms after the last key, Clear search and close act at once. The 150 ms is a guess: tune it from the device measurement. Original finding: Each key runs `Model.build` over the catalog and, when the list changes, `clear()` plus `append` of every match. Measure with the scale catalog on a low-end phone; add a short `Timer` only if it janks.
15. **S2: no soft-keyboard handling in the sheet (device step 41).** Quantity fields in the lower rows may sit under the keyboard; same behaviour as other sheets with inputs, but this one has a list of them.
16. **S2: model words are plain English** (reason text, pills "N left", "In this order: N", empty-state text, hidden note) inside a pure helper, so `qsTr` cannot translate them. Same as other pure helpers; matters only if the app is localised.
17. **S2 ponytail audit, PARTLY APPLIED 2026-11-09 (Taher: delete now).** Deleted: the row roles `available`, `inOrder`, `reason` (`unit` is used now) and the geometry outputs `ok`, `fits`, `photo`, `pills`, `stepper` (tests compute the pill width from the sizes that remain; the old `fits` boundary test is gone, nothing read it). Still open: `_ids` duplicates `_rows`, the triple digit guard (kept on purpose, WIRE-13), `flickableDirection`. Original list: `delete:` four row roles never read by `ProductPickerRow` (`unit`, `available`, `inOrder`, `reason`; decide `unit` first, item 12); `delete:` five geometry outputs never read by QML (`ok`, `fits`, `photo`, `pills`, `stepper`; tests read them); `yagni:` `_ids` in the sheet duplicates `_rows` (derive ids from `_rows`, changes `sameOrder`'s argument and SHEET-21); `shrink:` `maximumLength`, the `RegularExpressionValidator` and `ImhDigitsOnly` state one rule three times (WIRE-13 pins all three on purpose); `delete:` `flickableDirection: Flickable.VerticalFlick` is the ListView default and does not do what its comment says. net: about -45 lines, 0 deps possible; not applied because the row shape changes S3's contract.
18. **S2 sweep 3 (2026-11-10), FIXED on the branch:** the in-stock row exposed a second, unnamed accessibility stop (the inner `Switch`) and the switch could take focus and flip away from the filter; it now only paints (`focusPolicy: Qt.NoFocus`, `Accessible.ignored: true`, WIRE-24). Device check 53.
19. **S2 sweep 3, OPEN, device only:** (a) if a platform sends both `pressAction` and `toggleAction` for one TalkBack double tap, the in-stock row would toggle twice (net nothing); check 49 and 53 decide it, fix is to drop one of the two handlers. (b) The Android Back key reaching `BottomSheet`'s `Keys` handler is still unproven (item 6 of Skill 161); with `guardClose` Back does nothing rather than lose data, which is safe but may feel dead. (c) `Model.categories` runs on every rebuild, including each stepper tap, although the chips change only with the catalog; it is dwarfed by the catalog filter in the same call, so it is left until check 46 shows a real cost.
20. **CI, OPEN, not a test:** the `PR Test Summary Comment` job exits 1 on `4461cb9` while Functions, Rules, QML and E2E are all green. Its log was not read (annotation: `Process completed with exit code 1`). Probably the comment-posting step; look at it once on GitHub.
21. **S2 ponytail audit, sweep 3: nothing new to delete.** `_ids` beside `_rows` (item 17) stays: removing it changes `sameOrder`'s argument and SHEET-21 for three lines. The lint output has no defect (the BottomSheet hits are older code).

---

## L4b refresh button (was a row until 2026-11-10): BUILT 2026-11-04, reshaped 2026-11-10 (CI unverified, device steps pending); four known limits
**2026-11-10:** the always-visible row was too loud, so it is now `RefreshAction`, a ghost icon, first entry of each page's header actions; its caption shows only after a tap and fades 3.5 s after the refresh settles (design addendum A-D1..A-D4). Orders' header now has four icons: check a narrow phone. The text below describes the original row; "row" = the button, "pull gesture" was still not built (too much effort, Taher).
`RefreshRow` (first child of the content column on Inventory, Orders, Staff, Dashboard, Sales) shows "Updated N min ago" and a tap starts a manual refresh (`DataModel.manualRefresh()`). Design `specs/2026-11-04-l4b-refresh-row-design.md`, test plan `test-plans/2026-11-04-l4b-refresh-row-test-plan.md`.
- **A tap, not a pull gesture (B-D1).** Pages scroll in `AppScrollView`, pinned to `StopAtBounds` on purpose (Android free-drag bug), so an overscroll pull has nothing to read; a custom gesture cannot be verified in the sandbox or in CI and competes with `SalesPage`'s swipe handler. The row sits where a pull indicator would. A pull gesture can be added later on `manualRefresh()` if the device test says the row is not enough.
- **Dashboard's recent-activity feed is not refreshed (B-D2).** Its KPIs and orders are; the `ActivityLog` rows catch up at the next sign-in sync until L4c adds `ActivityLog` to the refresh. The row says "Updated" for the whole page.
- **"Updated" can be the sign-in sync start even if that sync failed (B-D3, L4a limit).** A manual tap fixes it.
- **Strings are English literals** in `RefreshCaption.js` and `RefreshAction.qml`, like `FailureCause.js`; not in `qsTr`.
- **The row is not unit-testable in CI** (needs Felgo `dp`, `sp`, `Icon`); it is pinned by `refreshActionWiring.test.js` and checked on a device.
- **A stuck or parked write blocks a manual refresh until the user fixes it (found in the PR #186 review).** The gate counts every outbox item, parked ones included (L4a, by design), so a tap waits and gives up after 2 minutes however often it is repeated. Before the review the toast said "Sending your changes first", which is not true for a stuck write; with `Gateway.stuckCount > 0` it now says the changes are not syncing and to fix or discard them. Not changed: the gate itself (a refresh swapping lists under an unsent write is what L4a prevents).
- **A tap that is ended by a reset (not by a failure) is silent (PR #186 review, confidence 65; DECIDED: leave as is).** If a discard-resync or another reset supersedes one store while a manual run is out, the run ends partial without a toast and `lastSyncMs` stays old (the other stores did commit). The row shows the old age after a tap with no explanation. Not fixed: rare, and changing `allCommitted` to count a reset store as current needs an L4a decision. Verify on a device by discarding a parked write while a manual refresh runs.
- **Disabled rows give no answer to a tap (PR #186 review; DECIDED: keep disabled).** Offline, "Waiting" and "Refreshing" make the row non-tappable (neutral text), so the offline toast, "Already refreshing." and the other `requestMessage` branches are only reachable by a race (a state flipping between render and tap) and by tests. Kept: a muted row that does nothing is the usual disabled look and the spinner is its own answer. If the device test shows people tapping the offline row, make offline tappable (a `tappable` field in `view`, the toast already exists).
- **FIXED in review 2 of PR #186: the discard retry (`_wantRearmed`) was never re-armed after its first use.** It was cleared only when a request had to wait, so after one retry cycle a request that ran at once got no retry if its copy was dropped (a manual tap then ended in the "could not be updated" toast). `_request` now clears it on a direct run; the retry run itself keeps it, so a stream of writes still cannot loop the refresh.

## Order CAS base: FIXED 2026-11-10 (CI unverified, device steps pending); five known limits
After a hand edit in the Firestore console (a changed `quantity`, an extra field), every edit, completion and delete of that order answered 409 for ever, and a refused delete still wrote an "Order deleted" Activity entry. Cause: `before` was rebuilt from the local copy while the server deep-compares it with the stored doc. Fix: `OrdersStore._serverBase` keeps the exact server image per order and `before` is a copy of it. Design `specs/2026-11-10-order-cas-base-design.md`, test plan `test-plans/2026-11-10-order-cas-base-and-refresh-button-test-plan.md`, Skill 160.
- **The first app save of a hand-edited order recomputes its totals** from the lines (D-2); a hand-edited total or an unknown field does not survive it.
- **An offline delete shows no Activity entry until the server confirms** (D-4, same as products).
- **Other stores still rebuild `before`** (inventory, suppliers, staff, batches). Not reported; each store's stored shape against its rebuild needs its own check.
- **A Timestamp typed by hand in the console** decodes to null on the client, so that doc still cannot match. Not covered.
- **Each order is held twice in memory** (the list and its base).
