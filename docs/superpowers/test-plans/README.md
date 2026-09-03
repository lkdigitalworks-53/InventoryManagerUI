# Test plans — combined index

Every test-plan document in this repo, in one folder (`docs/superpowers/test-plans/`), so
verifying a feature doesn't mean hunting across `docs/superpowers/`, `docs/superpowers/specs/`,
and `docs/superpowers/plans/` for the right one. Moved here 2026-08-22 (git history preserved via
`git mv`); nothing about content changed, and every cross-reference to the old paths elsewhere in
the repo was updated to match.

Two kinds of document live here, and the distinction matters when you're deciding how much to
trust a "covered" claim:

- **Automated test plans** (no "on-device" in the filename) — map a feature's commits to specific
  `tests/`/`functions/test/` files and, where stated, whether those tests were genuinely *run* in
  the session that wrote the plan or only written/traced. Always check which — several of these
  plans are explicit that a Qt/Firebase toolchain wasn't available in that session's sandbox.
- **On-device test plans** — manual click-through checklists for behavior that can't run under
  `qmltestrunner` at all (full Felgo `App` context, real device/emulator build, QXlsx file I/O).
  These have no pass/fail history recorded here; the checkbox lists are for whoever runs them.

## Index, newest first

| Date | Document | Branch / feature | What it is |
|---|---|---|---|
| 2026-09-02 | [`2026-09-02-price-adjust-tax-delta-test-plan.md`](2026-09-02-price-adjust-tax-delta-test-plan.md) | `fix/2026-09-02-price-adjust-tax-delta` | Automated + on-device, standard format (Skill 49). Two bugs, same root cause, fixed together: a completed-order discount/price edit on a taxable line leaving the order's tax stale (with a residual after a subsequent return), and the Analysis/Reports "Tax" column silently missing the same `price_adjust` tax delta (`RealisedMath.js`, both QML and Node ports). 26 new/extended cases across 6 files. The Node side (`functions/lib/realisedMath.js`) was genuinely run this session — `node --test` 9/9 on the new cases, full `functions/` suite 194/194 — a rare case of real executed proof in a session with no Qt toolchain; the QML side is written/hand-traced, CI-pending. |
| 2026-08-28 | [`2026-08-28-async-stock-batch-id-minting-test-plan.md`](2026-08-28-async-stock-batch-id-minting-test-plan.md) | `feature/async-stock-batch-id-minting` | Automated + on-device, follows the same happy/negative/edge/monkey/regression structure as the 2026-07-14 plan below (id minting, for a different entity). Unit tests (`tests/tst_StockBatchStore.qml`, `tests/tst_InventoryStore_upsertMany.qml`) and 1 E2E file written but not yet run against a live emulator. On-device happy path confirmed by Taher (2026-08-29); offline-depth (N1/N2/N4) and multi-device (E2) sections corrected/blocked by pre-existing, out-of-scope gaps — see the plan's Status note. |
| 2026-08-22 | [`2026-08-22-pr_taher_bug_fixes-test-plan.md`](2026-08-22-pr_taher_bug_fixes-test-plan.md) | `pr_taher_bug_fixes` | Automated + on-device, standard format (Skill 49). Unit/Regression/E2E sections (25 cases genuinely run, scratch-copy Qt-version workaround, see `SKILLS.md` Skill 46) + an on-device plan with Happy Path/Negative/Edge Cases/Affected Areas/Regression Tests sections. |
| 2026-08-08 | [`2026-08-08-review-round2-test-plan.md`](2026-08-08-review-round2-test-plan.md) | `fix/async-write-sequencing-review-fixes` (round 2) | Automated + on-device. Current-state plan for the whole async-write-sequencing feature after 3 implementation passes. Node tests (`functions/`) genuinely run (94/94 at the time); QML tests written/traced but not run (no toolchain in that session); a 9-item on-device checklist for what has zero automated coverage at all. Supersedes the two entries below for anything touching this feature past 2026-08-06. |
| 2026-08-08 | [`2026-08-08-async-write-sequencing-test-plan-in-detail.md`](2026-08-08-async-write-sequencing-test-plan-in-detail.md) | `fix/async-write-sequencing-review-fixes` (the 8 Critical fixes, C1–C8) | Automated. Predecessor to the round-2 plan above — covers the first review round's fixes specifically. Read alongside the round-2 plan, not instead of it, for anything the round-2 plan says it added to or changed. |
| 2026-07-29 | [`2026-07-29-async-write-sequencing-test-plan.md`](2026-07-29-async-write-sequencing-test-plan.md) | `feature/p0-gateway-*` → async-write-sequencing design | Plan-only at the time it was written ("no implementation code exists yet, per standing rule") — the original pre-build test plan for the 4-component design (client single-flight, record locking, server CAS backstop, atomic deltas). Superseded by the two entries above once implementation happened; kept for the original design-time reasoning. |
| 2026-07-17 | [`2026-07-17-test-plan-part2.md`](2026-07-17-test-plan-part2.md) | `fix/order-import-stock-and-holistic-bugs` | Automated. Part 2 — everything committed after the 2026-07-14 plan was written (3 Critical fixes, 5 bugs from Taher's own on-device testing, 10 more from the original rescue-review backlog). Read together with part 1. |
| 2026-07-14 | [`2026-07-14-test-plan.md`](2026-07-14-test-plan.md) | `fix/order-import-stock-and-holistic-bugs` | Automated. Part 1. Carries its own addendum note flagging it incomplete on its own as of 2026-07-17 — several RBAC-gate claims in Section 2 were later made false by further commits on the same branch. Read part 2 alongside it. |
| 2026-07-11 | [`2026-07-11-p0-gateway-test-plan.md`](2026-07-11-p0-gateway-test-plan.md) | `feature/p0-gateway-orders-staff-suppliers` | Automated + on-device. Three tiers: unit tests verified CI-safe at the time, automated tests written but needing a local run to trust, and manual on-device scenarios with no automated equivalent. |
| 2026-07-11 | [`2026-07-11-on-device-test-plan-adjustment-reason.md`](2026-07-11-on-device-test-plan-adjustment-reason.md) | Product-adjustment "Reason" field | On-device only, by design — no pure-JS logic to extract (reason is a passthrough string) and every touched file is page-level QML/App-context stores. |
| 2026-07-10 | [`2026-07-10-on-device-test-plan-tax-size.md`](2026-07-10-on-device-test-plan-tax-size.md) | Product tax export/import + Size field | On-device, with a named automated counterpart (`tests/tst_ImportMath.qml`, Taxable/Tax % cell parsing) for the part that could be extracted. |
| 2026-06-19 | [`2026-06-19-on-device-test-plan-revenue-reconciliation.md`](2026-06-19-on-device-test-plan-revenue-reconciliation.md) | `spec/analysis-revenue-reconciliation` | On-device. The single-net-revenue-definition reconciliation invariant across screen/breakdowns/exports, plus return/exchange/modify/restock/tax-edit scenarios. |

## Chains worth knowing before reading just one file

- **Order-import-stock**: `2026-07-14` → `2026-07-17-part2`. Read both; part 1 alone is
  out of date.
- **Async-write-sequencing**: `2026-07-29` (pre-build design) → `2026-08-08-in-detail` (round 1
  build) → `2026-08-08-review-round2` (current state, supersedes both for overlap). Read round-2
  first; fall back to the earlier two only for design-time rationale round-2 doesn't repeat.
- **`pr_taher_bug_fixes`** (this session) doesn't supersede anything above — unrelated feature
  area, no overlap with any prior plan's scope.

## Adding a new test plan

Same convention as every file above: `YYYY-MM-DD-<branch-or-feature>-test-plan.md` (or
`YYYY-MM-DD-on-device-test-plan-<feature>.md` for a manual-only checklist), written into this
folder directly (not `specs/` or `plans/`), and a row added to the index table above — newest
first, with a one-line note in "Chains worth knowing" if it supersedes or extends an existing one.
