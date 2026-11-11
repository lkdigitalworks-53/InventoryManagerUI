# CHECKPOINT: 2026-11-11 P1 S4a stock register read model (server) - resume here

**Branch:** `feat/2026-11-11-p1-s4a-stock-register-server`, cut from `main` @ `977cde0` (#187 picker S2 and #186 L4b merged).
**Commit identity:** every commit message ends with `dextran52@gmail.com` (this session's prompt). The previous checkpoint says Taher moved to `allibaas52@gmail.com` on 2026-11-09: CONFIRM which is current (KNOWN-ISSUES, P1 S4a item 11). The PAT comes from the chat prompt only, passed per command with `git -c http.extraHeader=...`, never in a URL, `.git/config`, the repo or memory.
**Rules in force:** no build or run until Taher says so; no Qt in the sandbox (CI is the QML oracle; this slice has no QML); always a branch; push without asking; short scope per chat turn; honest trade-offs; tests and a test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`.
**Skills used:** `brainstorming` (design with defaulted decisions SR-D1..D13), `qt-qml` and `qt-ui-design` (consulted, no UI in this slice), `ponytail` (smallest change: one pure module, one handler, no index, no schema change).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-11-picker-s2-merged-prev-CHECKPOINT.md` (picker S2, #187 merged).

## Why this slice
Asked: next tasks of the compliance P1 roadmap, design and implement in one turn. Read of `main`: S1a/S1b/S2a-c/S2d-1/S2f merged; owner-demotion = S2f-7 (already merged); open: S2d-2, S2e (CA), S3, S4. NOTHING reads `stock_movements`, so P1 is invisible. Chose S4a (server register read model): sandbox-testable end to end, no dependency on S3 (the design's "S4 depends on S3" is wrong for the register, SR-D13).

## Steps
- [x] 1. Read memory, `ATOMIC-OPERATIONS-STATUS`, P1 design, S2 design, S2d design, KNOWN-ISSUES, `movementLogic`, `computeAnalysis`, harness.
- [x] 2. Branch, previous checkpoint archived.
- [x] 3. `functions/lib/stockRegisterMath.js` (pure accumulator, `parseWindow`, `toMillis`, `canViewRegister`).
- [x] 4. `computeStockRegister` in `functions/index.js` + `streamAllPaged` (stream, cap 250 000, 413).
- [x] 5. Tests: `stockRegisterMath.test.js` 29, `index.handlers.stockRegister.test.js` 17, `stockRegister.guard.test.js` 8, membership matrix +10. Functions 1424/1424, `.github/scripts` 1049/1049.
- [x] 6. 25 hand mutants: 24 killed first run, the `-0` survivor killed by SR-11b, final 25/25.
- [x] 7. Docs: design, test plan (+ index row), KNOWN-ISSUES (11 items), README, AGENTS, Skill 162 (+ `SKILLS-INDEX.md` regenerated), `ATOMIC-OPERATIONS-STATUS` section 11.
- [x] 8. Pushed `9134471`, PR #193 opened (REST API, `gh pr create` needs GraphQL). CI on that head: Functions, QML, Rules, E2E all success; PR Test Summary Comment success; Deploy Check skipped (runs on merge).
- [ ] 9. For Taher: veto window on SR-D1..D13; merge; approve the functions deploy; device steps in the test plan are `curl` checks (no UI yet).

## State
Server only. Nothing in the app calls the endpoint. QML untouched, rules untouched.

## NEXT (in this order, my recommendation)
1. Read CI on this PR. Fix whatever is red.
2. **S4b** client: `StockRegisterService.qml` (POST with local-midnight offset ISO, on demand only) + Stock Register page (period picker, per-product rows, mismatch banner, skipped-rows note), role-gated owner/admin/manager. Needs a design pass first (UI).
3. **S2d-2** server kind hint for the clamped imported-order deduction (then client passes `sale`).
4. Restrict `stock_movements` read to owner/admin/manager in the rules BEFORE S2e (KNOWN-ISSUES, P1 S4a item 1).
5. S2e after the CA; S3 only if per-batch traceability is asked for. R5b (atomic ops) is independent: see PR #191 and `areas` notes.


---
# REVIEW SWEEP of PR #193 (2026-11-11, same branch, no stacked PR) - resume here
**Asked:** deep full sweep with `requesting-code-review`, `qt-qml-review` (N/A: PR has zero QML files), `ponytail-audit`; fixes in the SAME PR; no parallel agents; split into chunks; robustness first; show done/next at the end.
**Commit identity (RESOLVED):** `taher.lkdw@gmail.com`, as git user AND last line of every commit message (Taher, this session). Supersedes `dextran52@` / `allibaas52@` above; KNOWN-ISSUES P1 S4a item 11 is closed by this.
**PAT:** from chat prompt only; clone URL reset, pushes use `-c http.extraHeader`. Not in repo/memory.
**Sweep steps**
- [x] R0. Read skills, memory, PR body, math module, handler, harness, tests (54/54 pass locally on Node 22).
- [x] R1. Findings confirmed with a concrete case (see list below).
- [x] R2. Chunk 1 code fixes + tests, pushed `19247fd`: F1, F2, F3, F4 fixed; SR-29..32, SRH-18..22 new; 5/5 fix-mutants killed; functions 1433/1433.
- [x] R3. Chunk 2 docs + guard: SRG-09 (budget < timeout, mutant killed), design section 7 (SR-D14..17), KNOWN-ISSUES 11 closed + 12..18 added, test plan counts + steps 7/8/10b/10c/20 (8 and 20 BLOCKED: no staff login exists), Skill 162 rules 10..14, README sentence. Functions 1434/1434, `.github/scripts` 1049/1049.
- [x] R4. Pushed `5a82b44`; CI on it: Functions, QML, Rules, E2E all success, PR Test Summary Comment success, Deploy Check skipped (runs on merge). Sweep summary posted as a PR comment.
**Findings (concrete cases)**
- F1: `from:"2026-02-30T00:00:00Z"` parses to 2 Mar (V8 rolls over). Register for a wrong period, no error.
- F2: cap 250 000 rows at 500 rows/page = 500 sequential reads; ~100-250 ms each = 50-125 s vs 120 s function timeout. Timeout kill sends no CORS headers: client sees a no-answer, not a code.
- F3: `scopedDb` + `deriveContext` run before the `try`: a transient Firestore error there is an unhandled rejection (no JSON answer).
- F4: `DATABASE_ID_FOR_ENV["constructor"]` is truthy -> not the safe `prd` fallback. Pre-existing, every handler.

**Open decisions for Taher (defaults in brackets, nothing blocks the merge)**
- D-R1 restrict `stock_movements` read to owner/admin/manager: now in this PR, or its own small PR before S2e [own PR, needs a rules deploy + emulator rules test that only CI can run].
- D-R2 `productName` snapshot in ledger rows so deleted products stay readable (KNOWN-ISSUES 13) [before S4b].
- D-R3 `count()` pre-check so an over-cap request is cheap (item 14) [skip, revisit with the running balance].
- D-R4 fix the unwrapped `deriveContext` in the other handlers (item 16) [own PR].
- Dependabot: 1 critical + 10 high open on the default branch (item 18) [look before the next deploy].
**Next (in order):** read CI on the sweep head; Taher vetoes/merges; approve functions deploy; S4b design pass (client page); S2d-2.
