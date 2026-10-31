# CHECKPOINT — 2026-10-31 L3 session lifecycle: DESIGN + TEST PLAN pushed, D1/D2/D5 DECIDED, PR raised, STOP here; next session builds slice A (resume here)

**Branch:** `docs/2026-10-31-l3-session-lifecycle-design` (from `main` @ `f18445e`, which contains PR #171 merged). Docs only: no app, server, rules or test code changed, so no test counts moved. Push after every phase.
**Commit identity:** `tsadmin <tsadmin@gmail.com>` (the project instruction for this session). Earlier sessions used other addresses; that history is not rewritten.
**PAT:** from the chat prompt only, passed with `git -c http.extraHeader="Authorization: Basic $(printf 'x-access-token:%s' "$PAT" | base64 -w0)"`, never in the remote URL, `.git/config`, the repo or memory. This session's first clone put it in the remote URL by mistake; the URL was reset at once (`grep -c ghp_ .git/config` = 0, re-checked after the push).
**Rules in force:** no build/run until Taher says so; no Qt in the sandbox (CI is the QML oracle); always a branch; push without asking; short scope per chat turn; honest trade-offs, grill before deciding; tests + a test plan for every change (docs-only change: the plan is written for the slices it designs); update skills/AGENTS/README on need; caveman FULL in chat only, documents in normal prose; do not touch other PRs/branches.
**Skills used:** `brainstorming` (path: architectural, so spec first, hard gate on approval), `qt-qml`, `qt-ui-design`, `ponytail` (the two UI skills apply to slice A/C code, none written yet).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-31-pr171-merged-prev-CHECKPOINT.md`.

## Why L3 (and what "next in PR #171" meant)
PR #171's checkpoint NEXT: "L3 session lifecycle (refresh/resume re-check + distinct server codes), then S2f-6 only together with the restock `mint` design approval". S2f-6 stays blocked on that design. L3's source (`2026-10-25-multi-role-login-design.md` D6/D7, L3) is a DRAFT with unanswered decisions, so the design is NOT ready and nothing was implemented (brainstorming hard gate; Taher's own "grill me before deciding").

## Steps
- [x] 1. Read brainstorming, qt-qml, qt-ui-design, ponytail skills.
- [x] 2. Cloned `InventoryManagerUI`, set identity, scrubbed the PAT from the remote URL, read CHECKPOINT, the multi-role draft, the S2f-3 design and KNOWN-ISSUES.
- [x] 3. Verified from code (no run): F1 a re-check on token refresh EXISTS; F2 it is not silent (sign-in cover at z 100, store resync, `orders = []` first); F3 no resume hook; F4 one server code for six causes, ten call sites; F5 roster `on_leave` is unlinked from member `status`; F6 `provisioningAvailable` still `false`.
- [x] 4. Branch, archived the old checkpoint.
- [x] 5. Design `docs/superpowers/specs/2026-10-31-l3-session-lifecycle-design.md`: intent, facts, findings, decisions L3-D1..D7 (options, trade-offs, recommendation, empty `Taher:`), slices A/B/C, risks, test strategy. Self-review fixed a wrong poll-cost number (1,440 reads/day, not 700) and two line refs.
- [x] 6. Test plan `docs/superpowers/test-plans/2026-10-31-l3-session-lifecycle-test-plan.md` (Skill 49 shape; planned, nothing run) + index row.
- [x] 7. Corrected the stale "no re-check on token refresh" claim in KNOWN-ISSUES, the S2f-3 design (line 44) and the multi-role draft (line 11); new KNOWN-ISSUES entry "A healthy re-check shows the sign-in form and blanks lists" (read from code, NOT device-verified).
- [x] 8. Skill 145 + regenerated `SKILLS-INDEX.md` (check passes), AGENTS pointer. README: no change needed (it indexes no L3 content).
- [x] 9. Script suite run, committed, pushed (see `git log` on the branch).
- [x] 10. Taher answered in chat 2026-10-31: L3-D1 = (c) resync only when tenant or role changed, L3-D2 = (a) add resume, L3-D5 = (b) toast + jump to first allowed tab. Recorded in the design `Taher:` lines, the test plan header, the AGENTS pointer and this file. PR raised from this branch (docs only).
- [ ] 11. Still open: L3-D3, D4, D6 (not needed for slice A), D7 (read `Gateway` in slice C step 0). Taher may run device step B0 (baseline, confirms or refutes F2); if nothing flashes, slice A shrinks to the resume trigger and the plan is edited.

## Decisions
DECIDED (2026-10-31): L3-D1c silent check, resync only on tenant or role change or first resolve, L4 right after slice A (the hourly accidental refresh loss was stated and accepted). L3-D2a resume trigger, 60 s throttle, drop not queue, Try again bypasses. L3-D5b toast and jump to first allowed tab.
OPEN: L3-D3 additive `reason` (rec b), L3-D4 silent `recheckAccess` on a refused request (rec b), L3-D6 leave stays roster-only (rec c, question: should on-leave ever block login, rec no), L3-D7 parked writes (question, read first). The refused-request trigger of D2(b) waits on D4.

## NEXT
1. Merge or review the docs PR (docs only, nothing to run; no CI expected beyond docs checks).
2. Build slice A first, new branch `feat/<date>-l3a-silent-recheck` from `main` (after this PR merges, or from this branch if not yet merged), tests before code. Step 0: read the tab-gating code (L3-D5b) and `AuthService` call sites. Then `qml/helper/SessionRecheck.js` + Node shim + hand mutants, `AuthService` silent path with its own `checking` flag, wiring pins, `Main.qml` resume hook, role toast and tab jump. CI is the QML oracle; no Qt in the sandbox; no build or run until Taher says so.
3. Then L4 (resume sync, pull to refresh), B (server `reason`, deploy first, needs D3), C (needs D4, D7).
4. S2f-6 only together with the restock `mint` design approval (unchanged).
