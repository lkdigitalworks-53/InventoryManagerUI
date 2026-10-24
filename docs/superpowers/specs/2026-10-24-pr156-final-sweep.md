# PR #156 final sweep: P1 S2c lock `inventory` in `firestore.rules`

**Date:** 2026-10-24. **Reviewer account:** chat (identity `tsadmin@gmail.com`). **PR head:** `e91c9bb` (2 commits, 13 files, +380/-61). **Skills:** `requesting-code-review`, `ponytail-audit`, `qt-qml-review`.
**Verdict:** PR #156 itself is correct and safe to merge. The sweep found two **pre-existing, CI-proven holes** in the same rules file that matter more than the PR. Fix them next, before S2d.

## 0. What was checked

| Check | Result |
|---|---|
| CI on `e91c9bb` | All green. Rules 52, QML 2104, Functions 722, E2E 93 = 2971. Matches the PR's own prediction. |
| Rule change (`firestore.rules`, +23/-6) | Correct. `inventory`: read and list allowed to members, create/update/delete denied to every role. |
| 10 new rules tests + R08 re-point | Sound. Proves "denied write left stored data unchanged". Role loop covers owner/admin/manager/staff. |
| Independent writer audit (grep of all `FirebaseService.put/patch/putMany/remove/mintCounter*` callers, C++, scripts, prototypes) | Agrees with the PR: no client path writes `inventory`. |
| Repo script tests / skills index | 109/109 pass, index current (before and after my edits). |
| qt-qml-review | **0 `.qml` files in the diff.** Nothing to lint, nothing reported. Not padded. |
| Not run | Rules emulator and QML (no Java/Firebase download, no Qt in the sandbox). CI is the oracle. |

## 1. Code review (requesting-code-review format)

**Strengths**
- Right trade-off on C1: a new named tier instead of reusing `isLedgerCollection`, whose comment is an auditor-facing claim.
- Tests prove the negative properly (read back with rules off, `deepEqual`), not just `assertFails`.
- Honest PR text: says the audit is a grep, says CI is the only check, says what breaks (old pre-#154 builds).
- Bonus not in the PR text: the owner/admin gate on **product delete** (`functions/index.js`, BC1) is now enforceable, because a member can no longer delete a product document directly.

**Critical:** none in the PR.
**Important:** none in the PR. Items 4-6 below are doc wording to fix on merge.
**Minor:** items 9-10.
**Assessment:** ready to merge.

## 2. Audit report (ponytail-audit format)

**What this repo does:** Felgo/Qt QML inventory and order app for small shops, with Firebase Cloud Functions as a compliance gateway that writes the audit log and stock ledger. Load assumed: one shop, a handful of staff devices, dev only (no prod users yet, per design decision D10).

### Must fix (not caused by #156, proven in CI)

1. **Any member can rewrite memberships, including promoting itself to owner** (`firestore.rules:100-137` vs `:174-180`)
   - **What this is:** `members/{uid}` has its own careful rules: only owner/admin can create, update or delete, with role checks.
   - **Problem:** The catch-all `match /{collection}/{docId}` also matches `members/U`. Firestore allows a request if ANY matching rule allows it (the file's own comment says so). The catch-all lets every member write every collection it does not exclude, and `members` is not excluded. Probe PR #157, CI run 40103744373: a `staff` token **succeeded** at (a) setting its own role to owner, (b) creating a membership for a new uid with role owner, (c) deleting the owner's membership. The gateway then reads that role (`deriveContext`) and trusts it.
   - **Fix:** Exclude `members` from the catch-all's write guard (one more `&&`, same trick as Skill 126). Keep its read. Then the explicit block is the only thing that decides. About 6 lines plus tests.
   - **If we skip it:** The lowest role can take over a workspace, and every owner/admin-only check in the app and the functions becomes optional.

2. **A suspended member keeps direct Firestore access** (`firestore.rules:29-32`)
   - **What this is:** The app can suspend a member (`MemberManagementDialog`). The gateway honours it: `deriveContext` refuses any member whose `status` is not active.
   - **Problem:** The rules' `isMember` only checks that the member doc exists. Probe PR #157: a suspended member **could** read `inventory` and **could** write `orders`. Suspension only stops the gateway, not direct REST calls.
   - **Fix:** `isMember` also requires status active, **but tolerate a missing `status`** exactly like the gateway (`member.status && member.status !== "active"`), or legacy member docs are locked out. Keep self-read of the own member doc so the app can still learn it is suspended. Check once that the extra `get()` of the same document does not add a billed read (believed cached per request; not verified).
   - **If we skip it:** A suspended person can still read stock and write orders (and the other open collections) from a script for as long as their Firebase login stays enabled.

### Should fix

3. **No test covers the `users`, `tenants` or `members` blocks** (`test/firestore.rules.test.js`)
   - **What this is:** The file tests ledger, working, locks, pending_cleanup and now inventory.
   - **Problem:** Those three blocks (bootstrap owner creation, voluntary leave, role-change limits) are only used for seeding. Finding 1 lived there because of this.
   - **Fix:** Start from the probe branch's 6 tests (written to assert the secure result, so they are red now and go green with the fix), then add: owner cannot demote self, admin cannot touch an owner, self-leave works for non-owner, bootstrap only once, `users/{uid}` only own.
   - **If we skip it:** The next hole in these blocks is found the same way, by luck.

4. **Server role gates on `staff` delete and `removed_staff` can be skipped by a direct write** (`functions/index.js:203-216` vs rules)
   - **What this is:** The gateway restricts staff delete and the `removed_staff` tombstone to owner/admin. The comment there says the client check "is not a trust boundary".
   - **Problem:** Rules still let any member delete or create `staff` / `removed_staff` documents directly, so the gate is only a speed bump. (Product delete is now closed by #156.)
   - **Fix:** Lock both in the same tier, after item 1 is fixed (else the escalation in item 1 gets the gate anyway).
   - **If we skip it:** The code comment claims a protection the system does not give.

5. **Design note C3 gives an incomplete reason for leaving `orders`/`staff`/`suppliers`/`removed_staff` open** (`specs/2026-10-24-p1-s2c-...-design.md`, C3)
   - **What this is:** C3 says these "carry no stock ledger rows".
   - **Problem:** They do carry `audit_log` rows when written through the gateway, and `orders` carry money fields. A direct write skips the audit row, the same harm the PR names for `inventory`.
   - **Fix:** Reword C3 to say the scope was kept short, not that the risk is absent. See section 5 for the audit and the options.
   - **If we skip it:** A later reader will think the open collections were judged safe.

6. **Design note audit row hides item 1** (same file, section 2, row "App other direct writes")
   - **What this is:** The row lists `tenants/*/members` as "wildcard / own blocks | unaffected".
   - **Problem:** True for #156, but "wildcard / own blocks" is exactly the overlap that is the hole. Also the header still says "ready to implement" and section 4 says the lock takes effect only on deploy; Taher confirmed on 2026-10-24 that the S2c deploy is done.
   - **Fix:** On merge, change the row to point at item 1, set status to implemented, and say deployed.
   - **If we skip it:** The audit evidence reads cleaner than the truth.

### Nice to have

7. **`counters/*` is client-writable** (`FirebaseService.mintCounterValue`). Any member can set `counters/orders` to any number. Impact is limited: a later create of an existing id is rejected by the gateway's before-compare (409, `gatewayLogic.js:215-222`), so it blocks new records, it does not overwrite. Cannot be locked until minting moves server-side. Record it, do not fix now.
8. **`activity_log` sits next to `audit_log` and is client-writable.** It is a UX feed, not compliance. Label it that way in `FIRESTORE_RULES.md` so an auditor does not read it as evidence.
9. **README:344 is one 884-character status line** that grows each slice. Trim to a pointer to `CHECKPOINT.md` when convenient.
10. **Rules deploy is manual (no workflow deploys it).** Dev now runs rules from the #156 branch while `main` does not have them. A deploy from `main` before the merge silently re-opens `inventory`. Merge #156 soon.

Lean: -0 lines, -0 dependencies possible. This review adds docs only: Skill 127, an AGENTS.md note, this report.

## 3. qt-qml-review

Scope: diff of PR #156. Files reviewed: 0 QML. Phase 1 lint: no input. Phase 1b `qmllint`: not available, not needed. Phase 2 agents: nothing in scope (no bindings, layouts, loaders, delegates, states or performance code changed). Findings: 0. Items 1-2 are rules findings from the audit, not QML findings.

## 4. Probe result (how items 1-2 were proven)

Draft PR #157 (closed), branch `probe/2026-10-24-pr156-members-wildcard`, 6 tests that assert the SECURE behaviour, based on #156's branch.
CI: Rules 58 tests, 53 pass, 5 fail. PROBE-1, 2, 3, 5, 6 failed with "Expected request to fail, but it succeeded". PROBE-4 (control: owner changes a staff role) passed, so the setup is valid. QML, Functions, E2E unchanged and green.
The branch is kept: its red tests are the first commit of the fix.

## 5. Audit of the four collections (Taher: "yes, audit them")

Method: every `FirebaseService` write caller, `main.cpp`/`src`, `scripts`, `prototypes`, Gateway entity map, `functions/index.js` role gates.

| Collection | Client direct write today | Written by | Server role gate | Rules today | Lockable now? |
|---|---|---|---|---|---|
| `orders` | none | Gateway `order` (+ `recordOperation` for completion) | none | any member writes | Yes. Money fields; a direct write skips `audit_log`. |
| `staff` | none | Gateway `staff` (+ provisioning functions) | delete: owner/admin | any member writes | Yes. Gate is bypassable today. |
| `suppliers` | none | Gateway `supplier` | none | any member writes | Yes. Lowest risk. |
| `removed_staff` | none | Gateway `removed_staff` (tombstone on staff delete) | create: owner/admin | any member writes | Yes. Gate is bypassable today. |
| (extra) `counters` | yes, `mintCounter*` | client | none | any member writes | **No**, until minting is server-side. |
| (extra) `activity_log`, `config`, `_migrations` | yes | client | none | any member writes | No, by design. |

Limits: a grep, not a proof (same as the PR). A variable path equal to one of these names at run time would be missed. QML e2e seeding uses `Bearer owner` (skips rules), so the lock does not touch it.
What a lock costs: the `working/` test loop becomes empty and R08's write half must move to a still-open collection (`activity_log` or `config`); the on-device list must exercise one order, staff and supplier action.

**Options**
- **A. Fix items 1-2 only (small, security first).** Cheapest, closes the escalation. Leaves items 4-5 open.
- **B. A, then lock `staff` + `removed_staff`, then `orders`, then `suppliers` as separate slices.** Smallest blast radius per step, but each slice costs a session and the user's token budget is the real limit.
- **C. A, then lock all four in one slice** (one word each in the tier list, tier name stays truthful if renamed). One CI cycle, larger blast radius if a writer was missed. The lock fails loudly (`permission-denied` on dev), not silently.
- **D. Replace the catch-all with an allow-list** (explicit blocks for `activity_log`, `config`, `counters`, `_migrations`; read-only for the rest). Fixes items 1, 4, 5 and look-alike names by construction and every future collection starts closed. Largest diff on a file only CI can test.

**Reviewer recommendation:** A first, as its own slice, started from the red probe tests (it is a privilege escalation, small, and dev has no prod users yet). Then C. D is the better end state but a bigger risk than the budget justifies right now.

## 6. Decisions recorded and open

Recorded (Taher, 2026-10-24): everything through S2c is deployed to dev, so S2d may start after #156 merges; audit of the four collections: yes (section 5).
Open, need Taher: (1) merge #156 as is; (2) next slice A vs B vs C vs D; (3) is the S2c deploy really from the #156 branch (item 10)? (4) confirm there are no real users on dev data (item 1 impact); (5) S2d now or after A?

## 7. Test plan for this change

Docs only (this report, Skill 127, AGENTS.md note, CHECKPOINT). No code or rules changed, so no unit/functional/e2e tests apply. Checked: `skills-index.js --check` current, script tests 109/109. The fix slice for items 1-2 needs its own test plan from the template; the probe tests are its red starting point.
