# CHECKPOINT: 2026-11-17 P1 S4b-2 stock register PAGE (InventoryManagerUI) - resume here

**Branch:** `feat/2026-11-17-p1-s4b2-register-page` (from `main` @ `db64115`, PR #198 merged). PR #204 (S2e-1) is open and independent. Design: `docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md` section 5 + the S4b-2 addendum (written in step 6).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking (PAT in the chat prompt only, never in the repo or `.git/config`); tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; commit messages carry `dextran52@gmail.com`; update SKILLS / AGENTS / README as needed.
**Previous checkpoint archived:** `specs/2026-11-16-p1-s4b1-pr198-merged-prev-CHECKPOINT.md`.

## Scope of THIS PR (S4b-2a): the page, its entry point and its wiring
In: `qml/helper/StockRegisterFlow.js` (pure page controller), `qml/pages/StockRegisterPage.qml` (thin painter), `ProfilePage` entry row, `Main.qml` overlay (Back, tab change, workspace change, role loss, sign-out, tabbar hide), dormancy pin SRS-04 replaced by a pin on the ONE caller.
Out (S4b-2b, next PR): emulator e2e from the client request to the real endpoint (S4a KNOWN-ISSUES 9), the device timing of a large register (S4b-1 item 12), share/export (S4c, waits for the CA), value columns (S2e).

## Steps
- [x] 0. Memory + repo rules + skills read; fresh clone; PR list read (#204 open, #203 AP3a open, #202 open); main CHECKPOINT archived.
- [x] 1. Read the engine (`StockRegisterModel.js`, `StockRegisterService.qml`), `Main.qml` overlays (staff / activity pattern), `ProfilePage`, `ChipScroller`, `GlassHeader`, `FilterSheet` custom days, Skills 155, 156, 161, 172.
- [x] 2. `StockRegisterFlow.js` written (state in, state out; service injected).
- [x] 3. `stockRegisterFlow.test.js`: battery F1-F22 (incl. a 4000-step monkey with 4 invariants), SRF-02 purity guard, SRF-03 pairing, SRF-04 hand mutants. Run: 4/4 green, ~100 mutants all killed (16 first survivors: 6 test gaps fixed, 6 redundant lines deleted from the code, 4 equivalent mutants dropped).
- [ ] 4. `StockRegisterPage.qml`, `ProfilePage` row, `Main.qml` wiring.
- [ ] 5. Wiring tests (`stockRegisterPageWiring.test.js`), SRS-04 replaced, QML twin `tests/tst_StockRegisterFlow.qml`, whole script suite.
- [ ] 6. Design addendum, test plan, KNOWN-ISSUES, Skill 173, SKILLS-INDEX, AGENTS, README.
- [ ] 7. Push, read CI, fix.

## NEXT (if this session stops)
Continue at the first unchecked step. Everything so far is pure and dormant (nothing in the app calls the flow yet), so the branch is safe to push at any step.
