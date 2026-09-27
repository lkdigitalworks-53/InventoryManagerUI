# CHECKPOINT — 2026-09-26: C-3 Phase 3 PR 2 (store hooks, Task 9) ready for review, Task 10 needs a design check-in

**Session date:** 2026-09-26 (continues the 2026-09-18/20/22 arc)
**Branch:** `feat/2026-09-26-completion-store-hooks`, off `main` @ `277f246` (PR #83's merge commit — verified
via `git merge-base`, not assumed)
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-22-atomic-operation-outbox-CHECKPOINT.md`
**Commit identity:** `Taher (via Claude session) <tsowner@lkdigitalworks.com>` (confirmed by Taher). PAT is
supplied by Taher in chat each session and is never written to the repo, `.git/config`, or memory.
**Spec:** `docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md` (D1-D5 approved, on `main`).
**Plan:** `docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md` (13 tasks, 3 phases, on `main`).
**Test plan:** `docs/superpowers/test-plans/2026-09-20-atomic-operation-outbox-test-plan.md` (updated this
session for Task 9 — see its own "Updated 2026-09-26" note).

## Where things actually stand (all live-checked, not assumed)

**Merged to `main`:** everything through #83 (Phase 3 PR 1 — Tasks 6-8: `OutboxStore`/`Gateway` transport).
See the archived 2026-09-22 checkpoint for that history.

**This session (not yet a PR at session start — opened partway through, see step log):** Task 9, the four
store hooks the plan calls for, implemented against `main` re-read fresh (not the plan document's draft
code, which was stale in two ways — see below):

- `InventoryStore.applyRemoteStock(productId, stock)` — replaces stock, returns previous or `undefined`.
- `StockBatchStore.applyRemoteQty(batchId, qty)` / `addLocalBatch(doc)` / `removeLocalBatch(batchId)`.
- `OrdersStore.buildOrderUpdate(orderId, fields)` (pure half of `updateOrder`, no Gateway/local-state side
  effects) / `applyRemoteOrder(doc)`.
- `TransactionStore.buildSaleDocs(order, epoch, legacyIds)` (pure half of `recordSaleFromOrder`) /
  `addLocalEntries(docs)` / `removeLocalEntries(txIds)`.

56 new tests across 4 new files (`tst_InventoryStore_applyRemote.qml` 9, `tst_StockBatchStore_applyRemote.qml`
12, `tst_OrdersStore_buildOrderUpdate.qml` 15, `tst_TransactionStore_buildSaleDocs.qml` 20). **Verified in CI,
1356/1356 green** (PR #87) — one genuine test bug caught and fixed along the way (see step 20c/20d below), so
the hand-tracing-before-push discipline this arc uses is not a substitute for CI, just a way to keep the
false-positive rate low before it runs.

**Two real findings from re-reading live code instead of trusting the plan draft:**

1. `OrdersStore._normalizeOrder` returns a fixed-field object literal — it does NOT carry unknown fields
   through. The plan's Task 9 draft set `o.completionEpoch` and assumed it would just persist; it would have
   been silently dropped by the very next `_clone()`/normalize pass (every `updateOrder` call, every sync),
   which would have broken the deterministic-key mechanism Task 10 depends on in a way that's easy to miss in
   review (works once, then quietly stops). Fixed `_normalizeOrder` (and `_normalizeOrders`, the
   Firestore-sync path, for consistency) to carry `completionEpoch` through. Added
   `test_completionEpoch_survives_an_unrelated_updateOrder_call` specifically to pin this — same lesson as
   Task 7 finding the `signal.connect()` disconnect-handle bug, and the CAS shape-mismatch lesson already in
   `docs`/memory: a field-list mismatch between construction paths is the recurring failure mode in this
   codebase.
2. `TransactionStore.recordSaleFromOrder`'s `allocByProduct` lookup is keyed by `productId`, so two lines of
   the *same* product in one order silently collide — the second line's `OrderMath.allocate` result
   overwrites the first's in the map, and both lines then read the second line's tax/discount allocation.
   Pre-existing, not introduced by extracting `buildSaleDocs` out of it, not previously covered by any test.
   **Not fixed here** — fixing it is a GST-relevant behaviour change and deserves its own decision, not a
   drive-by inside a refactor PR. Flagged in a code comment and to Taher directly.

**Nothing calls these hooks yet.** `DataModel._tryCompleteOrder` still uses the old per-line delta chain.
App behaviour is unchanged by PR #87. The C-3 bug is **still not fixed** — that's Task 10.

## Step log (append-only; resume from the last ticked step)

- [x] 1-18 (2026-09-18 through 2026-09-25): see the archived 2026-09-22 checkpoint for full detail — spec,
      plan, test plan, Phases 1-2, and Phase 3 PR 1 (#83) through merge.
- [x] 19. Taher's decision on Phase 3 PR 2 arrived as "start with next phase … pick up tasks immediately" —
      read as: proceed with Task 9 (store hooks), the lower-risk, more mechanical half of PR 2, and hold
      Task 10 for the design check-in already flagged in step 20 below rather than bundle both into one PR.
- [x] 20a. Re-read all four target store files fresh on current `main` (not the plan draft) before writing
      anything, per this file's own resume instructions. Found the two issues above.
- [x] 20b. Implemented and tested all four Task 9 hooks (56 tests, see above). Updated the test plan's
      "Store hooks" row and header note.
- [x] 20c. Committed, pushed, opened as **PR #87** against `main`. CI ran: 1355/1356 passed first try —
      `Functions Tests`, `Firestore Rules Tests`, `E2E Tests` all green; `QML Tests` failed exactly 1 of 1111,
      per the `pr-comment` job's summary: `OrdersStore_buildOrderUpdate::test_completionEpoch_defaults_to_zero_when_absent`.
      Real cause (test bug, not a store bug): `getById()` returns the raw stored object with no
      normalization, and the test's raw fixture never set `completionEpoch`, so it read `undefined`, not the
      store's `0` default (which only applies inside `_normalizeOrder`, i.e. after a `_clone()`). Fixed by
      routing the fixture through `buildOrderUpdate` first, same as this file's other normalize-path tests.
      This is the first PR in this arc where the "hand-traced, unproven until CI" caveat on every store-hook
      test actually caught something — worth remembering next time that caveat is written off as boilerplate.
- [x] 20d. Pushed the fix. **CI green: 1356/1356** (QML 1111, Functions 176, Firestore Rules 28, E2E 41).
      PR #87 is genuinely CI-verified now, not just hand-traced. Task 9 is done and ready for Taher's review;
      the PR has not been merged by this session (merging `main` is Taher's call per the standing rule of
      never pushing to `main` without explicit instruction — that extends to merging a PR into it).
- [ ] 21. **Before Task 10 (`DataModel._tryCompleteOrder` rewrite):** flagged again, more specifically now —
      this is the optimistic apply/revert/re-plan logic, "has never run" per the plan's own self-review, and
      is where a mistake would actually reach users (unlike Task 9's hooks, which nothing calls yet). Worth a
      short design check-in with Taher first, specifically on: the re-plan bound (`maxReplans=3` in the plan
      draft — still right?), whether "queued while offline" should show as `completed` to the user before the
      server confirms, and how the guard interacts with `_reverseCompletedOrder`. Do not start Task 10 code
      without that check-in. When it does start: re-read `DataModel.qml`'s current `_tryCompleteOrder` fully
      first — same lesson as Task 7 and this session's Task 9 findings, the plan document's draft code for
      Task 10 is written against an older, smaller version of that function.
- [ ] 22. After PR 2: Phase 3 PR 3 (plan Task 11, the "saved, syncing" UI hint) and Task 12 (docs/tracker/
      `SKILLS.md` sweep for the whole Phase 3 arc — check the current highest `SKILLS.md` number before
      picking one; as of this session it's 70). Task 13 (deploy + on-device plan) is Taher's, throughout.

## Resume instructions

Fresh session: clone, read this file, re-check live PR/CI state for whatever PR step 20c opens (or opens it,
if this checkpoint was committed before that happened — check first, don't assume). Do not build or run the
app until Taher asks. **Do not start Task 10** without the design check-in in step 21 having actually
happened in the conversation. Before touching `DataModel.qml` for Task 10, re-read it fresh on current
`main` — do not assume the plan document's draft code still matches reality (this session found two similar
staleness issues in Task 9's supposedly-simpler files). `CHECKPOINT.md` conflicts are resolved by keeping the
branch's version and archiving `main`'s copy under `docs/superpowers/specs/`.

---

# CHECKPOINT (separate thread, different branch) — 2026-09-27: silent staff-credential-provisioning-failure — fixed, awaiting CI + on-device verification

**This section is independent of the C-3 Phase 3 / Task 9-10 checkpoint above.** Different branch, no
shared files (`AuthService.qml`/`Main.qml` here vs. `InventoryStore`/`StockBatchStore`/`OrdersStore`/
`TransactionStore` there), does not touch Task 10 or its design-check-in gate. Appended rather than
replacing the section above, per the "keep the branch version" conflict rule in ways-of-working — this way
neither thread's history is lost regardless of merge order.

**Session date:** 2026-09-27
**Branch:** `fix/2026-09-27-silent-staff-provisioning-failure`, off `main` @ `66ffa4fbee3454a53901540a059354e767b85100`
**Commit identity:** `Taher (via Claude session) <tsowner@lkdigitalworks.com>`. PAT supplied by Taher in
chat this session; never written to the repo, `.git/config`, or memory.
**Bug report (Taher, verbatim):** "in the team members page after adding new member as staff or any
roles, if we press the team members view button, newly added member is not visible. Only owner is
visible. Even after refresh nothing shows up."
**Test plan:** `docs/superpowers/test-plans/2026-09-27-silent-staff-provisioning-failure-test-plan.md`

## Where things stand

Root cause found by tracing, not guessing (see the test plan's "Traced and ruled out" list for everything
checked and cleared): `AuthService.provisionStaffCredentials` always runs asynchronously from `Main.qml`'s
`onStaffAdded`, well after `AddStaffDialog` has already closed. Every failure branch inside it called
`authFailed`, a signal `Main.qml` only ever surfaces into `inviteMemberDlg`/`forgotPasswordDlg` — neither
of which is ever open during this flow. Every failure was therefore completely silent: the staff roster
entry (`StaffStore.addStaff`) had already saved, so the add looked successful, but the person never got a
`tenants/{tenantId}/members/{uid}` doc — what the Team Members dialog actually reads — and refreshing
correctly found nothing, because there was nothing to find.

**Fixed:** `qml/model/AuthService.qml` (all 6 failure branches in `provisionStaffCredentials` now emit
`memberOperationFailed`) + `qml/Main.qml` (`onMemberOperationFailed` falls back to the existing
`successMessage`→`Toast` bridge when neither relevant dialog is open). No Firestore rules change, no Cloud
Function change — client-side signal-routing only.

**Not yet known:** the actual underlying reason `provisionMember` was failing for Taher's specific repro
(bad/duplicate email, password policy mismatch, something else). This fix makes that reason visible via a
toast for the first time — the on-device retest (step 13 below) is what will surface it, if it's still an
issue at all.

**Docs updated this session:** `SKILLS.md` Skill 72 (new pattern: background async continuations whose
failure signal is only conditionally surfaced need an unconditional fallback), `AGENTS.md` staff-row note
(without overclaiming the unrelated delete-button gap is resolved), `docs/superpowers/test-plans/README.md`
index. **`README.md` deliberately left untouched** — no user-facing feature, build step, or architecture
changed; nothing there needed updating.

## Step log

- [x] 1. Cloned repo fresh; read `ways-of-working.md`/`overview.md`/`learnings.md` (project memory) and
      `AGENTS.md`/`SKILLS.md`/`CHECKPOINT.md` per session-start convention.
- [x] 2. Traced the bug (`/superpowers:systematic-debugging`, `/qt-development-skills:qt-qml`): ruled out
      `FirebaseService.get`'s collection pagination/decoding, `MemberManagementDialog`'s role filter
      (defaults to "all"), `firestore.rules`' `members` `allow read` rule (not per-document filtering),
      server-side `canAssignRole` (owner can assign all three roles from the bug report), and `deriveContext`'s
      env/tenant scoping. Confirmed `ProfilePage` → `StaffPage` (not `MemberManagementDialog` directly) is
      intentional per `AGENTS.md`, not a bug.
- [x] 3. Found the actual root cause: `provisionStaffCredentials`'s `authFailed` calls have no live UI
      target in the add-staff-with-login flow.
- [x] 4. Created branch `fix/2026-09-27-silent-staff-provisioning-failure` off `main`.
- [x] 5. `AuthService.qml`: all 6 failure branches in `provisionStaffCredentials` → `memberOperationFailed`.
- [x] 6. `Main.qml`: `onMemberOperationFailed` falls back to `successMessage`/`Toast` when neither
      `inviteMemberDlg` nor `memberMgmtDlg` is visible.
- [x] 7. `tests/tst_ProvisionStaffCredentialsFailureRouting.qml` — 9 real `SignalSpy` cases against the
      live `AuthService`/`AuthStore`/`Gateway` singletons (no network — uses `Gateway.provisionMember`'s own
      synchronous no-XHR guards).
- [x] 8. `tests/tst_MemberOperationFailedFallback.qml` — 6 pure-logic model cases for `Main.qml`'s handler
      (can't load `Main.qml` itself under `qmltestrunner` — same reason as `tst_AddStaffSyncClose.qml`).
- [x] 9. Wrote the test plan; added it to `docs/superpowers/test-plans/README.md`'s index (newest first).
- [x] 10. `SKILLS.md` Skill 72 appended; `AGENTS.md` staff row annotated; `README.md` deliberately left
      alone (see "Docs updated" above).
- [ ] 11. Commit + push to `origin/fix/2026-09-27-silent-staff-provisioning-failure` (this step).
- [ ] 12. Open a PR against `main`; wait for CI's `qml-tests` job — not run in this sandbox (standing rule,
      no Qt toolchain installed here).
- [ ] 13. **Taher's on-device retest**, per the test plan's Negative Case 4 — reproduce the original repro
      exactly and read whatever the toast now says. That message is the real remaining diagnostic lead, if
      any; no further code change is anticipated here unless it points to something new.

## Resume instructions

Fresh session picking up THIS thread specifically: read this section (not the C-3/Task 9-10 one above,
which is a different, unrelated arc), check PR/CI status for `fix/2026-09-27-silent-staff-provisioning-failure`.
If CI (`qml-tests`) is green, this branch needs only step 13 (Taher's on-device confirmation) — don't start
new code changes here unless the on-device retest surfaces a genuinely new, distinct failure reason.
