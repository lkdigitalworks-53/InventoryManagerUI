# CHECKPOINT — 2026-11-02 L4a non-blanking data refresh on resume and reconnect — resume here

**Branch:** `feat/2026-11-02-l4a-resume-refresh`, cut from `main` @ `4c88ed9` (PR #180 L3 slice A and PR #181 R3 merged).
**Commit identity:** `taher.lkdw@gmail.com` (named in every commit message too, per Taher's standing rule).
**Rules in force:** no build or run until Taher says so; no Qt in the sandbox (CI is the QML oracle); always a branch; push without asking; one focused slice per chat turn; honest trade-offs; tests and a test plan for every change; caveman-full replies.
**Skills used:** `brainstorming` (design with decisions L4-D1..D8, defaults built, all vetoable in the PR), `qt-qml` (store and DataModel glue read against existing patterns), `qt-ui-design` (consulted; L4a has no UI, pull-to-refresh UI is L4b), `ponytail` (smallest design that is robust: pure policy + identical store block + one coordinator; a redundant swap snapshot was removed after a mutant survived).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-02-r3-merged-prev-CHECKPOINT.md` (R3 restock plan, PR #181 merged; its NEXT is R4).

## Why this slice
Next planned item after PR #180 (L3 slice A): "L4 resume sync / pull to refresh", own design first. Slice A removed the accidental hourly refresh on purpose (Taher accepted that cost in L3-D1c). L4 is the replacement. Read from code: the stores' only refresh is `_resetAndFetch` (blank, then refill), which would lose queued rows and blank lists on a resume. So L4a builds a non-blanking shadow refresh. Pull-to-refresh UI is L4b, incremental refresh L4c.

## Steps
- [x] 1. Read memory, cloned fresh into `/home/claude/repo` (PAT stripped from `.git/config` right after the clone), read AGENTS/CHECKPOINT/L3 design/stores/Gateway/Outbox/LockManager/AuthService.
- [x] 2. Branch created, previous checkpoint archived, design `specs/2026-11-02-l4a-resume-refresh-design.md` written (facts F1-F6, decisions L4-D1..D8, one open question).
- [x] 3. `qml/helper/RefreshPolicy.js` (pure) + `refreshPolicy.test.js` (40 tests, 37 mutants, 20000-step monkey).
- [x] 4. Six stores: `refreshFromFirebase(guard, done)` block, `_cancelRefresh()` first in `_resetAndFetch` and `clear`.
- [x] 5. `DataModel` coordinator (snapshot, requestRefresh, wait/poll, rearm once, watchdog), `LockManager.anyHeld`, `AuthService.isSessionOpen()` / `tokenNeedsRefresh()`, `Main.qml` resume hook.
- [x] 6. `refreshBehavior.test.js` (57 tests on the REAL function bodies, 24 mutants all killed) and `refreshWiring.test.js` (24 tests, 22 mutants). Updated `sessionRecheckWiring.test.js` for the hook's new shape.
- [x] 7. QML twins `tests/tst_RefreshPolicy.qml` (13 functions), `tests/tst_StoreRefresh.qml` (5): written, CI only.
- [x] 8. Test plan, README update, AGENTS pointer, KNOWN-ISSUES (3 entries), Skill 151 + `SKILLS-INDEX.md`.
- [x] 9. Sandbox runs: script suite 862/862, `functions` 985/985 (untouched).
- [x] 10. Pushed `8c4942e`, PR #182 raised. CI on it: ALL GREEN 3910/3910 (QML 2707, Functions 985, Rules 108, E2E 110). First QML-engine contact of the six edited stores and both new QML tests passed.

## REVIEW SWEEP 2026-11-03 (same PR, no stacked PR) - resume here
Ask: full deep review of PR #182 (requesting-code-review, qt-qml-review, ponytail-audit, qt-ui-design), fixes in the same PR. Baseline CI on `559e980`: ALL GREEN 3910/3910. Commit messages carry tsadmin@gmail.com.
- [x] RV-1. Cloned fresh into `/home/claude/InventoryManagerUI` (PAT via per-command header only), checked out the PR branch, read the full diff: policy, DataModel coordinator, six stores against their original fetch paths, hooks, tests, docs.
- [x] RV-2. qt-qml-review phase 1: linter run on the whole files, filtered to changed lines: 52 hits, triaged, none needs a change (design section 6). qmllint not available in the sandbox (CI is the oracle). Phase 2 agents were done as one sequential read in this chat turn (no subagent tool).
- [x] RV-3. Fix F1: a Transaction backoff retry (or any load started mid-refresh) could append pages on top of a committed copy and duplicate rows. Store check at commit (`loadingMore || _resetPending` -> discarded), retry timer stopped on commit. Design L4-D9, Skill 151 rule 10.
- [x] RV-4. Tests: behaviour 57 -> 72, wiring 24 -> 29, QML +1 function (CI only). Script suite 882/882 run locally. Three hand mutants of the fix killed.
- [x] RV-5. Fix F2: stale file name in the behaviour test header.
- [x] RV-6. Docs: design section 6 (findings, lint triage, I1-I3, lean note, ui-design audit), test plan (counts, device step 16), KNOWN-ISSUES entry, Skill 151 rule 10.
- [ ] RV-7. Push, then read CI on the new head. If QML is red, the likely place is `test_transaction_commit_stops_a_pending_retry_timer` in `tests/tst_StoreRefresh.qml` (creates the retry timer through `_scheduleRetry()`); fix only that.

## NEXT
1. CI is green (see step 10). Only re-check CI if something is pushed on top.
2. Taher: veto or accept L4-D1..D8 and answer the open question (should an open edit dialog, not only a held lock, hold the refresh?). Device steps in the test plan (two phones).
3. L4b: pull-to-refresh on the lists + "last updated" caption, calls `DataModel.requestRefresh("manual")` (returns run/wait/drop for the toast). Needs a qt-ui-design pass first.
4. L4c: incremental refresh, refresh of ActivityLog / categories / channels, move the sign-in sync to the shadow fetch (KNOWN-ISSUES).
5. Atomic-ops arc: R4 (`InventoryStore.restock` rewrite) is still next there.

## Not done / honest gaps
- Nothing built or run on a device; the foreground transition and what lists draw are device-only.
- QML tests ran in CI only (green), never locally.
