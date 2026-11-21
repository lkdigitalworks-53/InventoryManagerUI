# CHECKPOINT: 2026-11-20 P1 S4b-2 (stock register page on the phone) - resume here

**Branch:** `feat/2026-11-20-p1-s4b2-register-page`, cut from `main` @ `6951b1d` (#205 S2d-2 merged).
**Design:** `docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md` section 5 (designed there; this session adds section 8 "S4b-2 as built" with the calls below).
**Previous checkpoint archived:** `specs/2026-11-20-pr205-sweep-merged-prev-CHECKPOINT.md`.
**Commit rule (this session's prompt):** every commit message carries `allibaas52@gmail.com`; git user email is the same. (Earlier PRs used `lkdwtaher@gmail.com` then `tsadmin@gmail.com`: do not rewrite them.)
**Rules in force:** no build/run; no Qt in the sandbox (CI is the oracle); branch + push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; one short scope per session (token-limited, multi-account). Node tests run here: `cd functions && npm ci && node --test`; `.github` suite: `node --test .github/scripts/__tests__`. PAT per command via `git -c http.extraHeader`, never stored in the repo, a doc or memory.

## Why S4b-2 (not S3 or S2e-2)
- S2e-2 pickers and S4c export wait for the CA answers (CA-QUESTIONS.md). S3 (`batchRef`) is queued behind C-3 Phase 3 per the P1 design table.
- S4b-2 needs no CA answer, makes P1 visible on a dev tenant, and shows what derived `adjustment` rows look like (design section 7 advice 1).

## Scope of THIS PR (kept to one chat turn)
In: pure page glue `qml/helper/StockRegisterPage.js`; page `qml/pages/StockRegisterPage.qml`; "Stock register" row in ProfilePage (role-gated); overlay + Back + close-on-change wiring in `Main.qml`; `StockRegisterService.clear()` on sign-out; Node tests + wiring tests + QML twin; test plan; docs.
Out (documented in KNOWN-ISSUES): emulator e2e QML-to-endpoint case, date-picker for custom range (typed YYYY-MM-DD in v1), share/print/export (S4c), value columns (S2e), device role-gating proof (needs a non-owner login).

## Steps (tick as done)
- [x] 0. Clone, read memory + P1 designs + service/model + Main/Profile patterns, picked S4b-2, cut branch.
- [x] 1. Pure glue `StockRegisterPage.js` + Node tests (67 tests, 52 hand mutants killed; mutants run under a non-UTC zone because the sandbox is UTC).
- [x] 2. Page QML + ProfilePage row + Main wiring + sign-out clear.
- [x] 3. Wiring tests (63, incl. page function bodies run in a vm + 31 page mutants) + QML twin tests/tst_StockRegisterPage.qml; SRS-04 dormancy replaced by SRW-13; sessionRecheckWiring pin extended for the new overlay. Whole .github suite 1193 green.
- [x] 4. Test plan `test-plans/2026-11-20-p1-s4b2-register-page-test-plan.md` + README row (device steps 1..22).
- [x] 5. Docs: design section 8, KNOWN-ISSUES (S4b-2 section), ATOMIC-OPERATIONS-STATUS 13, README, AGENTS, Skill 178 + SKILLS-INDEX; row extracted to `qml/components/StockRegisterRow.qml` per qt-qml skill.
- [ ] 6. Push, open PR, read CI on the new head, fix reds.

## NEXT (if this session stops)
Continue at the first unchecked step. Each commit is independent. Do not force-push.
