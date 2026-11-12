# CHECKPOINT: 2026-11-12 R5b, activity_log inside the restock operation + recordPurchase removal - resume here

**Branch:** `feat/2026-11-12-r5b-activity-log-in-op`, cut from `main` @ `66d3f8d` (#195 merged, #191 R5a merged). Design: `docs/superpowers/specs/2026-11-12-r5b-activity-in-operation-design.md` (decisions D-R5b-1..D-R5b-8, all vetoable in the PR; the questions Taher would be grilled on are answered there with the recommendation taken).
**Commit identity:** `lkdwtaher@gmail.com` as git user AND last line of every commit message. The PAT comes from the chat prompt only, passed per command with `git -c http.extraHeader=...`, never in a URL, `.git/config`, the repo or memory.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests and a test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`. Server deploy BEFORE the client.
**Skills used:** `brainstorming` (design doc written; the user's one-turn rule replaced the approval gate, decisions are vetoable in the PR), `qt-qml` (ActivityLog.adopt, no layout change), `qt-ui-design` (N/A: no visible UI change; the feed row looks the same), `ponytail` (one op entity, one stamping helper, no new endpoint).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-12-p1-s4a-followups-merged-prev-CHECKPOINT.md`.
**Test plan:** `docs/superpowers/test-plans/2026-11-12-r5b-activity-in-operation-test-plan.md`.

## Steps
- [x] 0. Read memory, ATOMIC-OPERATIONS-STATUS, R5a design notes, operationLogic, ActivityLog, RestockPlan, InventoryStore restock; branch cut; baseline restock tests 88/88.
- [ ] 1. Design doc + this checkpoint committed.
- [ ] 2. SERVER: `activity` operation-only entity in `operationLogic.js` (validate, stamp, `{{$stock}}`), tests, FailureCause codes.
- [ ] 3. CLIENT: `RestockPlan` activity op + `reflect`, `ActivityLog.adopt`, `InventoryStore` hooks (+ legacy fallback), QML twins.
- [ ] 4. P2: `TransactionStore.recordPurchase` removed, D-1 drift guard moved to a pinned key list.
- [ ] 5. Docs: test plan, README, SKILLS, AGENTS, ATOMIC-OPERATIONS-STATUS section 13, KNOWN-ISSUES.
- [ ] 6. Push, read CI, report done / pending / next.

## NEXT (if this session stops)
Continue at the first unchecked step. Deploy order when merged: functions first, then the client build.
