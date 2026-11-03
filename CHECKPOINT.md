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
- [ ] 10. Pushed, PR raised, CI result read (see below / next session).

## NEXT
1. Read CI on the PR head; fix only what it shows (QML is unrun here: `tst_StoreRefresh.qml` and the six edited stores are the first QML-engine contact).
2. Taher: veto or accept L4-D1..D8 and answer the open question (should an open edit dialog, not only a held lock, hold the refresh?). Device steps in the test plan (two phones).
3. L4b: pull-to-refresh on the lists + "last updated" caption, calls `DataModel.requestRefresh("manual")` (returns run/wait/drop for the toast). Needs a qt-ui-design pass first.
4. L4c: incremental refresh, refresh of ActivityLog / categories / channels, move the sign-in sync to the shadow fetch (KNOWN-ISSUES).
5. Atomic-ops arc: R4 (`InventoryStore.restock` rewrite) is still next there.

## Not done / honest gaps
- Nothing built or run on a device; the foreground transition and what lists draw are device-only.
- QML tests are unrun here (CI only).
