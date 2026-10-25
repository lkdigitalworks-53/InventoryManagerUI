# PR #159 final sweep (2026-10-25)

**PR:** #159 `fix(s2f-1): gateway trusts the member doc, never users/{uid}` — branch `fix/2026-10-24-s2f1-membership-authority`, head `8c7eff7`, base `main` @ `b749a80`.
**Review branch:** `review/2026-10-25-pr159-sweep` (PR #162), stacked on PR #159. This PR adds only this report and the probe file. The fixes are on PR #159 itself (commits `d1a7f9a` and `b05ef77`); the text below is the sweep as it was written, against head `8c7eff7`.
**Skills used:** `superpowers:requesting-code-review` (no subagent tool in this chat, so the review was done inline against the template's checklist), `qt-cpp-review` (lint on all repo C++; the PR touches none), `ponytail:ponytail-audit` (ranked findings, four parts each), `caveman` (chat only).
**Commit identity for this sweep:** `dextran52@gmail.com`. The three PR commits carry `taher.lkdw@gmail.com` (finding 10).

## Status after the fixes (2026-10-25)

Decisions from Taher: Q1 allow-list the role (yes), Q2 `provisionMember` in its own slice, Q3 log now and distinct client codes later, Q4 remove redundant lines, Q5 recommended option (delete the dead check).

| # | Finding | Status |
|---|---|---|
| 1 | Unknown role gets staff access | Fixed on #159 (`VALID_ROLES` in `deriveContext`). The same allow-list for `firestore.rules` is still to do on PR #160. |
| 2 | Docs and PR text describe a removed rule | Fixed on #159: Skills 127/128, test plan, README row, AGENTS, CHECKPOINT, PR body. CI observed 3087 (QML 2104, Functions 835, Rules 52, E2E 96). |
| 3 | Silent refusals | Fixed on #159: one warning per refusal with uid and reason code, tenant id capped at 64 characters. |
| 4 | Extra tenant-doc read | Fixed on #159: read only in `provisionMember`, from the tenant doc only. |
| 5 | Test gaps | Fixed on #159 except the read-failure test (see 9): role table, tenantId types, logging, read recorder, seeded fuzz. `membershipAuthority` is now 113 tests. |
| 6 | `provisionMember` demotes owner / un-suspends | Own slice, not started. Probes P2 and P3 below still reproduce it. |
| 7 | Redundant `exists` line | Fixed on #159: line removed; Skill 128 rule 7 states the mutant results. |
| 8 | Dead check in `photoAccessDenied` | Fixed on #159: removed, comment updated. |
| 9 | Plain-text 500 on a Firestore blip | Not done, on purpose (pre-existing). Probe P5 still reproduces it. |
| 10 | Commit email | Left as is. |
| 11 | Tenant-id charset and length | Open: look at the dev tenant ids before deploy. It is in the PR #159 "Check first" list. |
| 12 | Client role default | Open for S2f-3. |

Probe P1 reproduced finding 1 on head `8c7eff7`. On the current #159 head every invalid role prints 403, so P1 now shows the fix; P2, P3 and P5 still show the open findings.

## What this change does

`deriveContext` (`functions/index.js:123-159`) is the identity step for all 10 gateway endpoints. Before the PR it read tenant and role from `users/{uid}`, which every user can write, and kept that role when the member doc was missing. Now it needs a member doc with `status === "active"`, takes the role and the actor name from that doc, and refuses an unsafe tenant id. Load assumed: one to a few shops, a handful of users each, sync bursts of up to 200 mutations per batch. Nothing here is a hot path; correctness and fail-closed behaviour matter more than speed.

## Strengths

- One choke point fixed once, then proven for every caller: a 10-handler table, a control row per handler (a real owner is not refused), and a guard test that counts `await deriveContext(` call sites so a new endpoint cannot skip it.
- The fix is small and reads clearly. Every real writer of member docs sets `status: "active"` (`AuthService.qml:515-522` bootstrap, `provisionMember` `functions/index.js:826-835`, `test/e2e/seed.js:102,133`), so the strict gate does not lock out anyone the app creates.
- Verified in this sweep (not taken from the PR text): `npm ci && npm test` in `functions/` = **811/811**; restoring `main`'s `deriveContext` makes **42 of 89** new tests fail; three of four mutants are caught (details in finding 7); script tests 109/109; `skills-index.js --check` current. CI on the head commit: **3063/3063** (QML 2104, Functions 811, Rules 52, E2E 96).
- The e2e tests mutate a seeded member doc and always restore it in a `finally`, so later suites keep their identity.
- Rollback is a revert plus `firebase deploy --only functions`; no data migration.

## Findings

### Must fix

1. **A member with no valid role gets staff-level access on 6 of 10 endpoints, and on most of `recordMutation`** (`functions/index.js:145`)
   - **What this is:** After the member doc is found, the role is copied as is: `member.role || ""`.
   - **Problem:** The role is tested in only three kinds of place: `provisionMember`, the two photo endpoints, and three entity kinds inside `recordMutation` (staff delete, `removed_staff`, product delete). `recordDelta`, `recordMutationsBatch`, `recordOperation`, `acquireLock`, `releaseLock` and `computeAnalysis` have no role check at all, and the rest of `recordMutation` has none either. Probe P1 (`2026-10-25-pr159-probes.probe.js`): a member whose role is `""`, `"viewer"`, `"Owner"`, missing, `7` or `{}` gets **200** on `recordOperation` and `acquireLock`. The PR text says "empty role = no privilege" and Skill 128 rule 4 says "fail closed on every missing piece: ... empty role". Both are true only on the gated endpoints. The only test of this claim (`F3b empty member role`) runs against `provisionMember`, a gated endpoint. A non-string role (object, number) would also be written into `audit_log.actorRole`.
   - **Fix:** In `deriveContext`, return `null` unless the role is one of `owner`, `admin`, `manager`, `staff` (the same set `firestore.rules` calls `roleIsValid`). One line plus tests: the 10-handler table with roles `""`, `"viewer"`, `"Owner"`, missing, number, object; a control that all four valid roles pass. Needs your decision first (Q1).
   - **If we skip it:** The security claim in the PR is false. A member doc with a typo or a future role value silently gets staff access. It also makes the audit trail's role column untrustworthy.

2. **Docs and PR text describe a rule the code no longer has** (`SKILLS.md` Skill 127 rule 5 and Skill 128 rule 4; PR body; test plan; CHECKPOINT)
   - **What this is:** Commit 3 made `status` strict (missing status is refused, D2 resolved). The docs written before that were not all updated.
   - **Problem:** (a) Skill 127 rule 5 said the gateway tolerates a missing status; Skill 128 rule 4 said "one tolerance is allowed ... a missing `status` counts as active". Both contradict the code and Skill 128's own rule 3. (b) The PR body still says "D2 missing `status` = active" and its deploy note says to check that every member has a `role`; the lock-out condition is now a missing or non-`active` **`status`**. (c) The test plan and CHECKPOINT said E2E observed 89 with "baseline 86, not 93", and a total of 3055/3056. CI shows E2E **96** (baseline 93, +3) and total **3063**. (d) The PR body's "3062 / 810" are also one test behind (89 new tests, not 88).
   - **Fix:** Done on PR #159 (Skills 127/128 text, test plan, test-plans index row, CHECKPOINT, AGENTS, PR body).
   - **If we skip it:** The next session reads Skill 128, re-adds the status tolerance "because the skill allows it", or distrusts the CI count. The deploy note would miss the one condition that can lock someone out.

### Should fix

3. **Refusals are silent** (`functions/index.js:133,136,138,142,144`)
   - **What this is:** Five early `return null` lines refuse a request and say nothing. `logger` is already imported but not used here.
   - **Problem:** The attack this PR closes (a users doc that points at someone else's tenant) leaves no trace in the logs, before or after the fix. You cannot see an attempt, or tell why a real user was refused (suspended, removed, wrong tenant). The client text already admits "the code cannot tell which" (`FailureCause.js:58-60`).
   - **Fix:** Log one structured warning per refusal with the uid and a reason code (`no-user-doc`, `no-tenant`, `unsafe-tenant`, `no-member`, `not-active`, and `invalid-role` after finding 1). Keep the HTTP response as is (one `no-tenant-context`); distinct response codes are an S2f-3 decision (Q3).
   - **If we skip it:** Takeover attempts and support questions ("why can't Ravi sync?") cannot be answered from logs.

4. **Every endpoint pays a Firestore read that only one endpoint uses** (`functions/index.js:151-157`)
   - **What this is:** `deriveContext` also reads `tenants/{tenantId}` to build `tenantName`.
   - **Problem:** `ctx.tenantName` is used only in `provisionMember` (L818, L831). The other 9 endpoints read the tenant doc and throw the value away: a third serial read on every sync call, billed and about one network round trip of latency.
   - **Fix:** Move the tenant read into `provisionMember` (about 6 lines) so `deriveContext` does two reads; optionally read the member and tenant docs together. Tests that seed a tenant doc for `provisionMember` keep working.
   - **If we skip it:** About 33% more identity reads than needed on every call. Small at today's load, but it grows with every sync batch.

5. **Gaps in the new test file** (`functions/test/index.handlers.membershipAuthority.test.js`)
   - **What this is:** The table is strong on the cases the author thought of.
   - **Problem:** (a) No role-shape cases (see finding 1). (b) `tenantId` types are not pinned: probe P4 shows numbers, `true`, `{}`, `[]`, 65 characters, `"tênant"`, `"a.b"` and a newline are all refused today, but no test says so. (c) The "monkey" test replays four fixed states three times; there is no randomness, so it cannot find a case nobody wrote. (d) No test for a Firestore read that throws inside `deriveContext` (finding 9).
   - **Fix:** Add (a) and (b) to the existing table; make the monkey test draw doc shapes from a small seeded generator (fixed seed, so it stays reproducible); add (d) once finding 9 is decided.
   - **If we skip it:** A later edit to the role or tenant-id check can regress without a red test.

6. **`provisionMember` can demote the owner and re-activate a suspended member** (`functions/index.js:753-835`, pre-existing, not in this diff)
   - **What this is:** Owner/admin endpoint that adds or updates a member. It writes the member doc with the Admin SDK, which skips `firestore.rules`.
   - **Problem:** The rules and the client both say "an owner's membership cannot be changed" (`firestore.rules` `resource.data.role != 'owner'`; `AuthService.qml` "Owner role cannot be modified"). The endpoint has no such check. Probe P2: an **admin** calls it with `{uid: <owner uid>, role: "staff"}` and the owner's member doc is merged to `role: "staff"`, so the shop can end up with no owner. Probe P3: calling it for a `suspended` member merges `status: "active"`, which un-suspends them without saying so. `canAssignRole` only limits what role you may hand out, not who you may change.
   - **Fix:** Inside the transaction, read the existing member doc first; refuse with 403 when its role is `owner`; decide whether an existing `suspended` member is refused or keeps its status (Q2). Test: admin vs owner target, admin vs suspended target.
   - **If we skip it:** An admin can strip or take over a shop's owner role through the one path the rules cannot see. This is the same class of bug as this PR, one function lower. I suggest a separate slice (not this PR) so #159 stays small and mergeable.

### Nice to have

7. **One check is redundant and one mutant claim is stale** (`functions/index.js:142`)
   - **What this is:** `if (!memberSnap.exists) return null;`.
   - **Problem:** With strict status, a missing doc gives `{}` after `.data() || {}` and is refused at line 144. Probe: deleting line 142 leaves all 89 tests green. The PR says "4 mutants (drop member-exists, ...) all caught"; that was true when a missing status was allowed. Now 3 of 4 are caught and the fourth is equivalent. Mutant results this sweep: old `deriveContext` 42 red; drop status 32 red; drop safe-segment 8 red; `actorName` from users doc 1 red; `role` from users doc 1 red; drop exists 0 red.
   - **Fix:** Keep the line (explicit fail-closed reads better than a side effect of the next check) and fix the claim in the test plan and Skill 128 rule 7; or delete it. Your call (Q4).
   - **If we skip it:** Nothing breaks; the "4 mutants" statement stays wrong.

8. **Dead check and stale comment in `photoAccessDenied`** (`functions/index.js:114-118`)
   - **What this is:** The first line re-checks `isSafePathSegment(ctx.tenantId)`.
   - **Problem:** `deriveContext` now refuses unsafe tenant ids before this runs, so the branch cannot be reached; the comment still says the tenant id "comes from a users/{uid} doc".
   - **Fix:** Delete line 118 and update the comment, or keep it as a second wall and say so in the comment (Q5).
   - **If we skip it:** An unreachable branch that counts against the "100% coverage" goal.

9. **A Firestore failure in the identity step returns a plain-text 500** (every `await deriveContext(` site, pre-existing)
   - **What this is:** The 10 handlers wrap writes in `try/catch` and answer `{ok:false, error: classifyWriteError(e)}`. The identity step has no `try/catch`.
   - **Problem:** Probe P5: when the member read throws `UNAVAILABLE`, the framework's error handler answers **500 `Internal Server Error`** (text, not JSON). The client then shows the generic "unknown" cause instead of "temporarily unavailable". Retry still happens, so no data is lost.
   - **Fix:** One small wrapper that turns a thrown read into `send(res, 503, {ok:false, error:"write-unavailable"})`, or a `try/catch` in `deriveContext` callers. About 12 lines; touches all 10 sites, so I would do it with finding 3.
   - **If we skip it:** Wrong wording in the app during a Firestore blip; nothing worse.

10. **Commit author email differs from your standing rule** (`git log`)
    - **What this is:** The three PR commits are by `taher.lkdw@gmail.com`; the standing rule (and this session's instruction) is `dextran52@gmail.com`.
    - **Problem:** The CHECKPOINT of the earlier session records `taher.lkdw@gmail.com` as "commit identity". Rewriting pushed history to change it is not worth the disruption.
    - **Fix:** Leave PR #159 as is; new commits (including this sweep) use `dextran52@gmail.com`. Tell me if you want the earlier identity restored for that account.
    - **If we skip it:** Mixed author emails in history; no functional effect.

11. **Tenant-id charset and length limit (D4)** (`functions/lib/photoValidation.js:39`)
    - **What this is:** The safe-segment rule allows `A-Z a-z 0-9 _ -` and 1 to 64 characters.
    - **Problem:** Tenants made by the app are `t_<uid>` (30 characters), so they pass. Any tenant doc created another way with a `.`, `:` or more than 64 characters becomes unreachable through the gateway. I could not see your dev data.
    - **Fix:** One look at the tenant ids in the dev Firestore console before deploy. No code change expected.
    - **If we skip it:** A hand-made dev tenant gets `no-tenant-context` for every call.

12. **For S2f-3 (client):** at login the client takes its UI role from the self-writable users doc (`AuthService.qml:280-289`) and defaults a role-less users doc to `owner` (`AuthService.qml:549`). The server no longer trusts it, so this is cosmetic now, but the UI can show owner screens to an account that cannot use them. Not part of this PR.

## Qt C++ lint (`qt-cpp-review`, phase 1, all `src/*.cpp` and `*.h`)

The PR changes no C++, so nothing here blocks it. The linter reported 15 hits in `src/`. I read the first `ERR-6` hits: they are false positives (the code uses the two-argument `.arg(a, b)` form, which fills `%1` and `%2` in one call). I did not run the six deep-analysis agents: they are scoped to the files in the change, and there are none.

| Rule | Where | Meaning | Assessment |
|---|---|---|---|
| ERR-6 x7 | `ImageProcessor.cpp:83,95`, `XlsxService.cpp:370,391,440,554,601` | `%2` with one `.arg(` call | False positive (two-argument form), checked 2 of 7 |
| HDR-3 x2 | `ImageProcessor.cpp:49`, `XlsxService.cpp:488` | unprotected `std::max` | Real only if `windows.h` is included without `NOMINMAX`; the repo ships `win/`. Low |
| DEP-7 x2 | `ImageProcessor.cpp:62`, `XlsxService.cpp:165` | `qMin/qMax/qBound` | Style |
| DEP-11 x2 | `XlsxService.cpp:349,474` | `currentDateTime()` | Check whether the value goes into a file or a user-visible label |
| DEP-10, DEP-13 | `NativeFile.cpp:37`, `XlsxService.cpp:530` | `.count()` / `QChar` object type | Style |

## Checked, not a finding

- Other readers of `users/{uid}` as an authority: none left in `functions/` (grep). `storage.rules` has no role logic (reads public, writes denied).
- Check-then-write gap (a member removed a few milliseconds after `deriveContext` passed, before the transaction commits): one extra write at most; the transaction does not re-read membership. Accepted by design; not worth a second read per request.
- Every other writer of member docs (bootstrap, `provisionMember`, e2e seed) sets `status: "active"`, so strict status locks nobody out of anything the app creates.
- The `suspended`/removed 403 is retried by the client with backoff (`Gateway.qml:822-824` leaves 401/403 out of the terminal list); the stuck-write UI already has an `access` cause for it (`FailureCause.js:58`).
- `firestore.rules` still has F1/F2 (any member can write `members/*`; suspended members keep direct access). That is PR-B and is stated in the PR. Until PR-B is deployed, a **member** can still promote themselves to owner by writing their own member doc directly, and `deriveContext` will then believe it. PR #159 closes the cross-tenant takeover; it does not close in-tenant promotion. Deploy rules and functions together.

## Questions for you (decisions I did not take)

- **Q1 (finding 1): fail closed on an unknown role?** Pro: matches the rules' `roleIsValid`, closes the hole, stops garbage reaching `audit_log`. Con: the allowed set now lives in two places (rules and gateway), so a new role such as `viewer` needs both edited. I recommend yes, with a comment naming the rules file.
- **Q2 (finding 6): fix `provisionMember` in this PR or as its own slice?** Own slice keeps #159 reviewable and already green; fixing here closes the owner-demotion path one PR earlier. What should re-provisioning a `suspended` member do: refuse, or keep the status?
- **Q3 (finding 3): distinct refusal codes now, or log only?** Distinct codes let the client say "you were removed" vs "you were suspended"; they leak nothing about other people (the caller only learns about themselves) but widen the API that S2f-3 must handle. I recommend log-only now, codes in S2f-3.
- **Q4 (finding 7):** keep the redundant `exists` line (clear intent) or delete it (less code)?
- **Q5 (finding 8):** keep `photoAccessDenied`'s tenant check as defence in depth, or delete it as dead?

## Verdict

**Merge with fixes.** Fix 1 (after Q1) and 2 (docs, done here except the PR body) before merging; 3 and 5 are cheap and belong in the same PR; 4 is optional; 6 is a real hole but not caused by this PR, so take it as its own slice. Nothing in the diff is wrong; the gap is that the stated guarantee ("empty role = no privilege") is bigger than what the code enforces.

Lean: 1 line removable (finding 7) or 1 (finding 8), about 6 lines moved (finding 4), 0 dependencies.
Not checked: Firestore rules tests (Rules 52, unchanged, ran in CI only), the QML suite (2104, CI only; no QML changed), the 3 new e2e tests (read, not run: no emulator here; CI ran them green), `functions/lib/*` beyond the files `deriveContext` calls.

## PR-body edits (applied to #159 on 2026-10-25, kept here as the record)

- Replace "D2 missing `status` = active" with "D2 missing `status` is refused (resolved strict, no legacy data)".
- Replace "Check first: every doc under `tenants/<t>/members` has a `role`" with "Check first: every doc under `tenants/<t>/members` has `status: "active"` and a `role` of owner, admin, manager or staff; a member doc without them can no longer use the gateway."
- Replace "810/810 (722 + 88 new)" and "Expected CI ... 3062" with "811/811 (722 + 89 new)" and "CI observed 3063 (QML 2104, Functions 811, Rules 52, E2E 96)".
