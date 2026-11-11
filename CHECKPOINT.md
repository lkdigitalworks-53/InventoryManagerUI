# CHECKPOINT: 2026-11-11 P1 S4a follow-ups, ONE PR, four commits - resume here

**Branch:** `feat/2026-11-11-p1-s4a-followups`, cut from `main` @ `3c03306` (#193 merged). Plan: `docs/superpowers/plans/2026-11-11-p1-s4a-followups-one-pr-plan.md` (decisions D-R1..D-R4 were taken by Taher on 2026-11-11, so no re-grill).
**Commit identity:** `allibaas52@gmail.com` as git user AND last line of every commit message (this session's prompt; the plan says `taher.lkdw@`, the newer prompt wins; confirm once). The PAT comes from the chat prompt only, passed per command with `git -c http.extraHeader=...`, never in a URL, `.git/config`, the repo or memory.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; one commit per slice, each revertable; tests and a test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`.
**Skills used:** `brainstorming` (design already written and decided: the plan), `qt-qml` and `qt-ui-design` (N/A: zero QML in this PR; QML only READ to check how the client classifies a 5xx), `ponytail` (one helper, no new abstraction per slice).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-11-p1-s4a-merged-prev-CHECKPOINT.md`.
**Test plan:** `docs/superpowers/test-plans/2026-11-11-p1-s4a-followups-test-plan.md` (one section per slice, filled as each slice lands).

## Steps
- [x] 0. Read memory, plan, AGENTS conventions, skills; branch cut; identity set.
- [x] 1. SLICE 1 (D-R4) code: `deriveContextSafe` + `CONTEXT_FAILED` next to `deriveContext`; ten older handlers use it, each with its OWN 500 code (`write-unavailable` for the four write handlers, `lock-failed`, `release-failed`, `auth-failed`, `compute-failed`, `write-failed` x2). Never a terminal code: the client parks a write on `write-rejected` only (`StuckWrites.js`), every other JSON 500 retries like a platform 500. `computeStockRegister` untouched (its inline try also wraps `scopedDb`).
- [x] 1b. SLICE 1 tests: membership matrix +33 table cases (11 handlers x 3 failing reads), non-Error throws, refusal untouched, 200-run monkey, 3 guards; harness `logErrors`. Functions 1525/1525, scripts 1049/1049. 4/4 hand mutants killed (raw call in one handler, terminal code, swallow to null, no log).
- [x] 1c. SLICE 1 docs: test plan + index row, KNOWN-ISSUES 16 closed, Skill 164 (+ `SKILLS-INDEX.md`), README paragraph. Commit + push: see next line.
- [x] 2. SLICE 2 (D-R2) `productName` snapshot in ledger rows: `cleanProductName` + `nameFor` in `movementLogic`; `buildRows` writes `productName` only when usable; four writers pass it (`applyMutation`, `applyDelta`, `applyMutationsBatch`, `applyOperation`); register keeps the latest named row per product (equal instants: greater name). Tests `productName.test.js` 27, SRG-06 extended; functions 1552/1552; 15/15 hand mutants killed. Docs: design SR-D9, S4a test plan step 4, KNOWN-ISSUES 13 closed, Skill 163 rule 15, README, test plan section. Pushed: see commit after this one.
- [ ] 3. SLICE 3 (D-R1) restrict `stock_movements` read rule (CI is the only rules oracle).
- [ ] 4. SLICE 4 (D-R3, droppable) `count()` pre-check.
- [ ] 5. PR body, CI read, done / pending / next.

## NEXT (if this session stops)
Continue at the first unchecked step above. Each slice is independent: if a slice goes red in CI, revert that commit only.
