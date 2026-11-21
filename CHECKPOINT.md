# CHECKPOINT: 2026-11-21 picker S5d (measure the rebuild, cart index) - resume here

**Branch:** `feat/2026-11-21-picker-s5d-cart-index-and-bench` (cut from `main` @ `68afa5c`, PR #206 S5c merged).
**Commit rule:** every commit message carries `lkdwtaher@gmail.com` (project instructions) and the session attribution trailers.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; PAT per command via `git -c http.extraHeader`, never in `.git/config`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-20-pr206-merged-prev-CHECKPOINT.md`.
**Plan:** `docs/superpowers/plans/2026-11-21-product-picker-v2-s5d-measure-and-cart-index.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5d rows).

## Steps
- [x] 0. Clone, memory read, roadmap read: S1-S5c merged; S5d = measure then tune (KI 14, 19c, 25); S5e open.
- [x] 1. Measured with `scripts/bench/pickerBench.cjs` (real helpers in Node): cart scan = 83% of a 60-line rebuild; Edit Order re-reads the ListModel per product; dry run <= 4.3 ms; categories 6 ms at 20k. Details in the plan.
- [x] 2. Plan written (decisions S5d-D1..D7).
- [x] 3. Code pushed `73ae111`: `qtyIndex`/`cartQty`/`availableFor` (NP), `scopeOf`/`heldAtCompletion`/`ceilingFor`/`availableFor` (Edit), `build` scope (PM), both dialogs, `scripts/bench/pickerBench.cjs`.
- [x] 4. Tests: 22 new (NOP 5, EOP 4, SHEET 3, S5D 10), twins regenerated, NOW-03/EOW-03/EOW-11 updated on purpose. Functions 2130/2130 (main 2108), scripts 1061/1061. 32 hand mutants: 30 killed, 2 equivalent, 1 real gap closed.
- [x] 5. Docs: test plan (checks 134 to 140, status rows), KNOWN-ISSUES (14, 19c, 25, 42 amended; 74 to 80 new), Skill 181 + index, AGENTS, README, plan Result section.
- [x] 6. Pushed; PR #210 opened (was `dirty`: main took #208, Skill 180 and KI 74-82). Merged main in (no rebase, no force), my Skill 180 -> 181, my KI 74-80 -> 83-89, main's checkpoint archived as `specs/2026-11-21-no1-merged-prev-CHECKPOINT.md`. Functions 2171/2171, scripts 1061/1061 on the merged tree. CI NOT read yet on the merge head.
- [ ] 7. Final report: done / open decisions / device checks 134 to 140 / next = S5e.

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`.
