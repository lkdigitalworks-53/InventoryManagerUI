# CHECKPOINT: 2026-11-12 R5b, activity_log inside the restock operation + recordPurchase removal - resume here

**Branch:** `feat/2026-11-12-r5b-activity-log-in-op`, cut from `main` @ `66d3f8d` (#195 merged, #191 R5a merged). Design: `docs/superpowers/specs/2026-11-12-r5b-activity-in-operation-design.md` (decisions D-R5b-1..D-R5b-8, all vetoable in the PR; the questions Taher would be grilled on are answered there with the recommendation taken).
**Commit identity:** `lkdwtaher@gmail.com` as git user AND last line of every commit message. The PAT comes from the chat prompt only, passed per command with `git -c http.extraHeader=...`, never in a URL, `.git/config`, the repo or memory.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests and a test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`. Server deploy BEFORE the client.
**Skills used:** `brainstorming` (design doc written; the user's one-turn rule replaced the approval gate, decisions are vetoable in the PR), `qt-qml` (ActivityLog.adopt, no layout change), `qt-ui-design` (N/A: no visible UI change; the feed row looks the same), `ponytail` (one op entity, one stamping helper, no new endpoint).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-12-p1-s4a-followups-merged-prev-CHECKPOINT.md`.
**Test plan:** `docs/superpowers/test-plans/2026-11-12-r5b-activity-in-operation-test-plan.md`.

## Steps
- [x] 0. Read memory, ATOMIC-OPERATIONS-STATUS, R5a design notes, operationLogic, ActivityLog, RestockPlan, InventoryStore restock; branch cut; baseline restock tests 88/88.
- [x] 1. Design doc + this checkpoint written.
- [x] 2. SERVER (23 tests, 16/16 mutants): `activity` operation-only entity in `operationLogic.js` (validate, stamp, `{{$stock}}`), tests, FailureCause codes.
- [x] 3. CLIENT (planner, adopt, hooks, QML twins, e2e x2): `RestockPlan` activity op + `reflect`, `ActivityLog.adopt`, `InventoryStore` hooks (+ legacy fallback), QML twins.
- [x] 4. P2: `TransactionStore.recordPurchase` removed, D-1 drift guard moved to a pinned key list.
- [x] 5. Docs (test plan, README, SKILLS 166 + index, AGENTS, STATUS 13, KNOWN-ISSUES 24-28): test plan, README, SKILLS, AGENTS, ATOMIC-OPERATIONS-STATUS section 13, KNOWN-ISSUES.
- [x] 6. Pushed. PR #197. CI on `bde06ca`: QML red (4 test-side cases, stale op counts + one tie), fixed in `e4c490c`; CI on `e4c490c`: Functions, QML, E2E, Rules all green (read 2026-11-13 via API). Deploy Check runs on merge.

## NEXT (if this session stops)
Continue at the first unchecked step. Deploy order when merged: functions first, then the client build.

---

# REVIEW SWEEP 1 of PR #197 (2026-11-13, one chat turn, NO parallel agents) - resume here

**Who/how:** session prompt of 2026-11-13. Commit identity `tsadmin@gmail.com` as git user AND last line of every commit message (newer prompt wins over `lkdwtaher@`; the three R5b commits above keep the old one, history NOT rewritten). Fixes go ON the PR head branch `feat/2026-11-12-r5b-activity-log-in-op` (the PR IS that branch; a second branch would be a second PR). PAT only per command via `git -c http.extraHeader`, remote URL clean.
**Skills used:** `requesting-code-review` (inline: the user forbids parallel agents), `qt-qml-review` (Phase 1 python lint run on the changed QML, filtered to changed lines; Phase 2 done inline, six domains, on `adopt` + two small edits; qmllint not available, no Qt in the sandbox), `ponytail-audit` (finding format).
**Rules in force:** no build or run of the app; CI is the oracle for QML and rules; Node tests of `functions/` DO run here (`cd functions && npm ci && node --test`, baseline 1711/1711 on head `cd08418`).

## Steps
- [x] R0. Clone, checkout PR head, read CHECKPOINT, design D-R5b-1..8, full prod diff (server, planner, ActivityLog, InventoryStore, TransactionStore), all new tests, docs diff; baseline 1711/1711 locally.
- [x] R1. Probed the server with a script (real `validateOperationRequest` + `applyOperation` on the strict fake DB). Confirmed: F1 four activity rows accepted in ONE operation (design says one); F2 a row naming product p2 accepted while the delta is on p1; F3 `{{$stock}}` in the TITLE stored raw. Lint (qt-qml-review Phase 1) on changed lines: 24 hits, 0 real (22 `var` = repo convention 1452 vs 5, 1 JS-2 and 1 ORD-1 false positives).
- [x] R2. SERVER FIX F1+F2+F3 in `checkActivityOp` (`functions/lib/operationLogic.js`): one activity op per operation; no `{{$stock}}` in the title; the row names a product an EARLIER inventory delta of this operation changed, token or not (token keeps `activity-stock-missing`, else `invalid-activity`). Tests: A-7 last line flips on purpose, A-10..A-13 new, emulator e2e twin (CI only, opIndex 5/4/4). Functions 1715/1715 (was 1711), scripts 1049/1049, 9/9 real hand mutants killed (a 10th was equivalent: `concat([])`). Commit 1 = this one.
- [x] R3. TEST HYGIENE (tests and test plan only, zero prod change): the three new `restockWire` cases were labelled W-20/21/22 and collided with the existing W-20 (two already shared it, a third made it three); renamed W-23..W-25 and the test plan rows; `B-2` had `a || b` between two possible ids, now ONE exact key list (proves the id carries the injected clock's year). 57/57 in the two files. The older W-20 pair (lines 312 and 414) is NOT touched (KNOWN-ISSUES). Commit 2 = this one.
- [x] R4. DOCS (commit 3 = this one): stale `recordPurchase` mentions fixed (MigrationService comment, SKILLS.md two places); test plan section 10 + counts; Skill 166 rules 10-12; README and AGENTS sentences; KNOWN-ISSUES 29-32 (W-20 pair, id not pinned = decision, adopt vs stale fetch = unverified, lint noted). Left as history on purpose: `ATOMIC-OPERATIONS-STATUS.md` section 10 P2 line and the old plans/specs (they describe their own date).
- [x] R5. Pushed after every commit. CI on head `2874f1d` (read 2026-11-13 via API): Functions 1715/1715, QML 3026/3026, Rules 129/129, E2E 114/114 (113 + the new F1-F3 emulator case), 4984 of 4984. Sweep 1 of PR #197 is DONE.
- [x] R6 Done in sweep 2 below: KNOWN-ISSUES 30 stays a recorded decision (id not pinned), 31 analysed by reading the code (real, not new in R5b, fix proposed as a separate PR). The three R5b-original commits keep `lkdwtaher@` (history not rewritten). Deploy order when merged: functions FIRST, then the client build.

# REVIEW SWEEP 2 of PR #197 (2026-11-13, one chat turn, NO parallel agents) - resume here

**Who/how:** session prompt of 2026-11-13 07:48 IST (superpowers requesting-code-review, qt-qml-review, ponytail-audit, caveman full). Commit identity `lkdwtaher@gmail.com` as git user AND last line of every commit message (this prompt names it; sweep 1 used another address and stays as it is). Fixes go ON the PR head branch. PAT only per command via `git -c http.extraHeader`, remote URL clean. No build, no Qt.
**Rules in force:** same as sweep 1. Node tests run here (`cd functions && npm ci && node --test`; scripts: `node --test .github/scripts/__tests__/*.test.js`).

## Steps
- [x] T0. Clone, checkout PR head `1bad9ee`, memory read, baseline functions 1715/1715.
- [x] T1. Read whole server diff, applyOperation, runMints, checkPlaceholders, recordOperation handler (no role gate there = known decision, KNOWN-ISSUES ~399), firestore rules (activity_log client-writable), full client diff (RestockPlan, ActivityLog.adopt, InventoryStore hooks, RestockFlow), legacy activityText parity, new QML tests.
- [x] T2. PROBE (`scratchpad/probe2.js`): FOUND subtitle stored at 1600 chars from a 1000-char template (token x 100 x 16-digit stock); minted ids can also push the title over 200. Literal id `act-squat` accepted (KNOWN-ISSUES 30, decision stays). Max-float stock refused by the existing movement check.
- [x] T3. FIX `stampActivity` (`functions/lib/operationLogic.js`): refuse a non-doc / non-string title or subtitle (was a TypeError inside the transaction), re-prove both caps on the stored text. Tests B-12..B-15, 4/4 killed with the fix reverted. Adopt twin AD-8 + `tst_ActivityLog` case (a held id below the insertion point).
- [x] T4. DOCS: test plan section 11 + counts, KNOWN-ISSUES 31 (confidence 85, not new in R5b, fix proposed), Skill 166 rule 13, this checkpoint.
- [x] T5. Counts: functions 1720/1720 (+5), scripts 1049/1049. QML twin and CI: read after push.
- [ ] T6 (NEXT SESSION): read CI on the sweep 2 head; separate small PR for KNOWN-ISSUES 31 (merge by id in `ActivityLog._fetchFromFirebase`) if Taher wants it; R6 device test of the whole restock arc (test plan section 7 + step 13).

## NEXT (if this session stops)
Continue at the first unchecked R-step. Each commit is independent and revertable. Never force-push this branch.
