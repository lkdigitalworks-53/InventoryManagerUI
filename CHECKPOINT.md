# CHECKPOINT — 2026-09-26: Sales Analysis deleted-product breakdown labels (DELETE-FEATURE-ROADMAP item 3) — FIX COMPLETE, ready for CI + review

**Session date:** 2026-09-26
**Branch:** `fix/2026-09-26-sales-analysis-deleted-product-labels`, off `main` @ `9be6303` (PR #80 merged, item 2 done).
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-21-staff-delete-ui-CHECKPOINT.md`
**Skills invoked by Taher:** `superpowers:brainstorming`, `qt-development-skills:qt-qml`, `caveman:caveman` (chat replies only).
**Commit identity:** `Taher (via Claude session) <dextran52@gmail.com>`.

## Standing instructions from Taher (unchanged from prior sessions)

- Branch only, never `main`; push when a meaningful step is done without asking (Taher reviews in the GitHub PR).
- Do not build or run the app; no Qt tooling in the sandbox; CI is the only signal for QML.
- Every change: tests aiming at 100% coverage, a test plan from the template, `SKILLS.md`/`AGENTS.md`/`README.md`
  updated as needed.
- Honest advisor: show trade-offs, grill before deciding, do not simply agree.
- The GitHub PAT is used for `git push` and the PR API only; never written into the repo. **Flagged to Taher:
  rotate it — it was pasted in plaintext into this chat.**
- Session-token-budget model: keep each session's scope small enough to land a reviewable, resumable state.

## Step log (this session, in order)

1. Read project notes; confirmed item 2 (PR #80) merged into `main` — item 3 is next.
2. Cloned repo, created this branch, archived the item-2 checkpoint.
3. Read roadmap item 3 + its `KNOWN-ISSUES.md` origin write-up.
4. Traced the actual code: `productName` already stamped on every `TransactionStore` entry
   (read-side-only bug); `category` never stamped anywhere (real write-path gap).
5. Wrote the investigation checkpoint, committed, **pushed** — asked Taher 3 scope questions.
6. Taher's answers: attempt both name+category this session; stamp category at time-of-transaction;
   no backfill needed (dev-only, tests clean per PR) — recorded in memory and this file.
7. Wrote the full design (`docs/superpowers/specs/2026-09-26-...-design.md`): write-path plan for
   all 5 `TransactionStore` functions incl. the non-trivial `recordReturn`/`recordPriceAdjust` case
   (product may already be deleted by return time — resolved via `_stampedCategoryFor()` reusing the
   original sale's stamp); read-path plan for `BreakdownMath.js`/`RealisedMath.js`/
   `SalesPage._namedProductMap`; explicitly scoped out `BreakdownMath._revenue()` (dead code — traced
   and confirmed unreachable from `SalesPage.qml`'s actual wiring) and the category *filter* (vs.
   *label*) in `_passesScope`.
8. Implemented the write side: `recordPurchase`/`recordCreated`/`recordSaleFromOrder` stamp
   `category`; `recordReturn`/`recordPriceAdjust` via the new `_stampedCategoryFor()` helper.
9. Implemented the read side: `BreakdownMath._categoryKey`/`_productNameKey` gained an `entry`
   fallback param, live-wins preserved via `productCategory.hasOwnProperty()`;
   `RealisedMath.byDimension`/`_accumulatePriceAdjust`'s three category spots updated;
   `SalesPage._namedProductMap` gained `_stampedProductName()`.
10. **Found mid-implementation**: a live server-side parity port (`functions/lib/breakdownMath.js` /
    `realisedMath.js`) has the byte-identical bug, called by a real Cloud Function
    (`computeAnalysis`) reading the same Firestore collections. Ported the identical fix there too.
11. Installed `functions/` deps (network-allowlisted npm registry) and ran `npm test` for real —
    **baseline 243/243 passing** before adding new cases.
12. Wrote 24 new QML test cases (`tst_BreakdownMath.qml` +6, `tst_RealisedMath.qml` +4, new
    `tst_TransactionStore_categoryStamp.qml` +14) and 8 mirrored Node cases.
13. Ran `npm test` again: **250/251 — one real failure**,
    `bydimension_category_live_product_wins_over_stale_stamp`. Root cause: the first-pass fix
    (`e.category || categoryOf(...)`) let a stale stamp override a still-live product's CURRENT
    category — precedence backwards. `categoryOf` returning `""` for both "deleted" and "exists,
    empty" made this ambiguous by construction.
14. Fixed for real: `categoryOf` now returns `null` for "deleted" vs. `""` for "exists, no category"
    (3 QML definitions in `InventoryStore.qml` + 1 Node definition in `functions/index.js`, all using
    `getById`'s existing null-vs-object distinction). Added `_resolvedCategory()` helper (QML + Node)
    that checks this explicitly. Fixed the 3 QML test mocks and 3 Node test mocks that had
    (correctly, under the old contract) used `""` to mean "deleted" — updated to `null`.
15. Re-ran `npm test`: **251/251 passing.** Recorded as SKILLS.md Skill 71 (generalizable lesson) and
    in `KNOWN-ISSUES.md`'s resolution follow-up — genuine TDD evidence, not staged.
16. Updated docs: `KNOWN-ISSUES.md` (resolved item 3's entry + 2 adjacent out-of-scope findings:
    category filter dropdown, order-wide price-adjust spread), roadmap item 3 marked RESOLVED,
    `README.md` changelog entry, `SKILLS.md` Skill 71.
17. Wrote the test plan (`docs/superpowers/test-plans/2026-09-26-...-test-plan.md`, Skill 49 format)
    — includes the honest "first pass had a real bug, caught by the test suite" writeup and the
    Node-version-count caveat (sandbox Node 22.22.2 vs. `functions/package.json`'s pinned `"20"`).
18. This checkpoint rewrite, commit, push, open the PR (this batch).

## Decisions made this session (see `/areas/sales-analysis-breakdown-labels.md` in memory)

| # | Question | Answer |
|---|---|---|
| Q1 | Scope | Both name + category, one pass |
| Q2 | Category semantics | At time-of-transaction |
| Q3 | Historical backfill | None needed — dev-only, clean tests per PR |

## What's genuinely verified vs. traced-only

- **Verified by real execution**: all 251 Node `functions/` tests, including 8 new ones covering this
  fix's exact logic in the server-side parity port. The precedence bug this session found and fixed
  was caught this way, not by inspection.
- **Traced, not run**: all 24 new QML test cases (no Qt toolchain in this sandbox) — same status as
  every other QML test in every prior session on this repo. Needs a CI pass before merge.
- **Not automatable at all**: `SalesPage.qml`'s page-level rendering (Felgo `App` context) — on-device
  cases in the test plan are the only coverage.

## Not done / open for Taher's review

- CI hasn't run on this branch yet — QML test count is unverified until it does.
- The 2 adjacent findings (category filter dropdown, order-wide price-adjust spread) are
  intentionally NOT fixed — documented in `KNOWN-ISSUES.md`, flagged for Taher's awareness, not a
  silent gap.
- Rotate the GitHub PAT pasted into this chat (flagged, not resolved by me — Taher's action).
