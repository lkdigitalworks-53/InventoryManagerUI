# CHECKPOINT — 2026-10-21 P1 S2a-1: delete client `runCutover` + `stock_movement` client mapping (resume here)

**Branch:** `feat/2026-10-21-p1-s2a1-client-cutover-delete` off `main` @ `773c4ef` (PR #151 merged). Open the PR against `main`.
**Commit identity:** `taher.lkdw@gmail.com`. PAT only in the push command, never in a file or git config; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** do not build/run the app; no Qt in the sandbox (CI is the QML oracle); push without asking, Taher reviews in the PR; short scope (token budget, multi-account hand-off); honest trade-offs and grill before decisions; tests + test plan for every code change; caveman FULL.
**Skills used:** `brainstorming` (design already approved: S2 rev 2, so no new design; only a scope split), `qt-qml`, `qt-ui-design` (no UI touched), `ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-21-p1-s2b-prev-CHECKPOINT.md`.

## Why this item
PR #151 (S2b) merged. Next per the design: S2a. Split in two (Skill 124): the `mode` property has 79 uses in 22 files, so removing `direct` mode is a CI-only-oracle session of its own.

## Steps
- [x] 1. Read memory, cloned repo, read old checkpoint + S2 design, cut branch.
- [x] 2. Audit: `runCutover`/`cutoverUrl`/`cutoverFinished` have no caller; `_captureBeforeStatusIsLost` still has 5 users (kept; 6 on `main` incl. `runCutover`); `DataModel` has no `stock_movement` string in code, only a comment (fixed in the review sweep).
- [x] 3. `Gateway.qml`: deleted `runCutover()`, `cutoverUrl`, `cutoverFinished`; removed `stock_movement` from `_collections` (comment says why).
- [x] 4. `tst_Gateway.qml`: removed 1 stale assertion, added 3 test functions (stock_movement refused by 4 entry points, `collectionFor` refuses it, cutover API pin).
- [x] 5. Docs: test plan + index row, Skill 124 + `SKILLS-INDEX.md`, AGENTS.md (2 spots), README, design doc note, this checkpoint.
- [x] 6. `cd functions && npm ci && npm test`: 722/722 (server untouched; first run showed 509/7 fail only because `node_modules` was missing).
- [ ] 7. **Taher:** review PR, wait for CI (`qml-tests` is the only proof for the QML edits), merge, run the on-device list in the test plan.
- [ ] 8. **Next slice, own session: S2a-2** (recipe below), then S2c (rules lock + rules test), then S2d.

## Review sweep 2026-10-23 (stacked PR on this branch: `review/2026-10-23-pr152-final-sweep`)
Skills: `requesting-code-review`, `ponytail-audit`, `qt-qml-review` (lint run; `qmllint` not available; no Qt in sandbox).
Verdict: no Must-fix. CI green on `3755713` (QML 2107 = 2104 + 3 new, Functions 722, Rules 45, E2E 93). Lint: 0 hits on PR-changed lines (477 pre-existing, house `var` style).
- [x] R1 `test_collectionFor_covers_every_registered_entity` asserted 6 of 7 entities: added `removed_staff`.
- [x] R2 dead `ignored = {stock_movement}` branch in `tst_DataModel_discardResync.qml` deleted (test renamed).
- [x] R3 test name said "every write entry point": `recordOperation` is server-gated only; renamed + comment (why `gateway` mode is set).
- [x] R4 docs said `_captureBeforeStatusIsLost` has 6 users: it is 5 (test plan, Skill 124, this file).
- [x] R5 docs claimed a `stock_movement` string in `DataModel._storesToResync`: it was only a comment; comment fixed, Skill 124 rule 5 rewritten, rules 6-7 added.
- [x] R6 README said deploy will ask to delete `runCutover`: Taher deleted it by hand in the console 2026-10-23; README, AGENTS, test plan updated, `curl` check added (expect 404).
- [ ] R7 **Taher:** run the `curl` in the test plan (sandbox cannot reach `cloudfunctions.net`).
- [ ] R8 **Taher:** merge the review PR into `feat/2026-10-21-p1-s2a1-client-cutover-delete`, wait for CI, merge #152. `CHECKPOINT.md` conflicts: keep the branch version.

## S2a-2 recipe (for the next account)
1. `Gateway.qml`: delete `property string mode`, the two `if (mode === "direct")` blocks in `recordMutation`/`recordEdit`, the one in `recordMutations`, `_writeDirect`, `_writeDirectBatch`; the 4 `mode !== "gateway"` guards (recordDelta, recordOperation, drainNow ~523, discardParked ~628) go away with their error strings `delta-requires-gateway-mode` / `operation-requires-gateway-mode` (check callers of those strings first: `git grep -n "requires-gateway-mode"`). Fix the header comment and the 2 stale comments (`TransactionStore.qml:208`, `Main.qml:331`).
2. Tests: `git grep -n "Gateway.mode" -- tests qml` (79 uses, 22 files). Delete every `Gateway.mode = "gateway"` and the `_prevMode` save/restore (18 lines). In `tst_Gateway.qml` delete `test_recordDelta_requires_gateway_mode`, `test_recordOperation_requires_gateway_mode`, `test_discardParked_refuses_outside_gateway_mode`, `test_recordMutations_direct_mode_is_unaffected_by_chunking`, the `init()` line 62 and its long comment, and rewrite the header SCOPE NOTE. Add a pin `typeof Gateway.mode === "undefined"`.
3. Danger: in `init()` the forced `"direct"` also kept tests off the network. Without it `drainNow()` runs; the guard that protects is `!AuthStore.idToken` in `_send*` (see the test header). Keep `AuthStore.idToken = ""` in `init()`. Check FirebaseService writes: after this slice nothing in `tst_Gateway` may reach `FirebaseService.put`.
4. Run `node --test` (unchanged), push, CI is the only oracle.

## Open items / risks
- Q4 (damaged returns) and Q5 (`valueAtCost` client-stated) stay open for S2e/S2d.
- S2d/S2e wait for S1b deployed (met: Taher 2026-10-21).
- Skill 124 rule 3 (`typeof` on an absent singleton member gives `"undefined"`) is untested locally; if CI fails `test_client_cutover_api_is_gone`, replace with `verify(!("runCutover" in Gateway))`-style or drop the pin.

## NEXT
Taher reviews/merges. Then S2a-2 in a new session on a new branch off `main`.
