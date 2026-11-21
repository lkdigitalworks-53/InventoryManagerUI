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
- [ ] 3. Code: `qtyIndex`/`cartQty`/`availableFor` (NP), `scopeOf`/`heldAtCompletion`/`ceilingFor`/`availableFor` (Edit), `build` scope (PM), both dialogs.
- [ ] 4. Tests: NOP/EOP/SHEET cases (+ twins regenerated), `pickerS5dWiring.test.js`, NOW-03/EOW-03 updated on purpose, bench smoke, mutants.
- [ ] 5. Docs: test plan (checks 134 to 140, status row), KNOWN-ISSUES (14, 19c, 25 amended; 74+ new), Skill 180 + index, AGENTS, README.
- [ ] 6. Push, open PR, read CI.
- [ ] 7. Final report: done / open decisions / device checks 134 to 140 / next = S5e.

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`.
