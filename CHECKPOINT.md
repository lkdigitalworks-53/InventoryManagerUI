# Session Checkpoint — Code review of `docs/async-write-sequencing-design`

**Started:** 2026-08-06
**Branch:** `review/async-write-sequencing-audit` (created off `docs/async-write-sequencing-design`
at commit `b51779b`, local only — not pushed, no go-ahead given this session).
**Status:** Review COMPLETE. Round 1 and round 2 both done and written up in
`docs/superpowers/specs/2026-08-06-async-write-sequencing-code-review.md` (8 Critical, 5 Important
findings, plus test-suite/lint/ponytail sections). Nothing implemented yet — review-only session so
far, awaiting Taher's direction on what to fix and in what order.
**Skills invoked:** `superpowers:using-superpowers` (implicit), `superpowers:requesting-code-review`,
`qt-development-skills:qt-qml-review`, `ponytail:ponytail-review`.

## Task

Taher asked for a deep review of the entire async-write-sequencing feature (design, test plan, and
code, first commit `430bd7e` through branch tip `b51779b` — 13 commits) for: regressions in
existing functionality, gaps for future issues, pending implementation, and a full bug list — to be
written up as a document and committed. Explicit instruction: be honest, don't rubber-stamp, grill
decisions, act as a senior engineer trying to make this the best-written code in the repo.

## Step log

1. Cloned `InventoryManagerUI` fresh into the sandbox (per standing session instructions).
2. Read the mandatory `superpowers:using-superpowers` skill, then the three explicitly-invoked
   skills (`requesting-code-review` + its `code-reviewer.md` template, `qt-qml-review`,
   `ponytail-review`). No subagent-dispatch tool is available in this environment, so the
   code-reviewer template's review criteria were applied directly rather than via a dispatched
   subagent — noted as a methodology deviation, not silently substituted.
3. Checked out `docs/async-write-sequencing-design`. Confirmed via `git merge-base`/`git log` that
   commit `430bd7e` and everything through `b99b0bd` is ALREADY merged into `main` (via the
   `pr_taher_bug_fixes` merge) — only the branch's last 2 commits (`afea51d`, `b51779b`) are unique
   to it. Reviewed the FULL feature (`430bd7e^..b51779b`, 32 files, +4031/-352), not just the
   2-commit diff against main, since that's what Taher actually asked to have reviewed.
4. Read the design doc, test plan, and the prior session's own 673-line checkpoint in full before
   touching any code — needed to know which gaps were already self-flagged vs. genuinely new
   findings, per Taher's ask not to just repeat what's already documented as known-open.
5. Read `functions/lib/gatewayLogic.js`, `functions/lib/lockLogic.js`, `functions/index.js` in
   full; `qml/model/Gateway.qml`, `OutboxStore.qml`, `LockManager.qml` in full; the order-completion
   path in `DataModel.qml`/`OrdersStore.qml`/`StockBatchStore.qml`/`InventoryStore.qml`.
6. Wrote up round-1 findings: `docs/superpowers/specs/2026-08-06-async-write-sequencing-code-review.md`
   (6 Critical, 3 Important so far). Committing this checkpoint + the review doc now, per Taher's
   explicit request to write up findings before continuing, so nothing is lost if interrupted.

## Round 1 findings summary (see the review doc for full detail)

**Critical:**
- C1 — `Gateway._send`/`_sendBatch` never got the 409-conflict handling the design doc's §5
  requires; Component 3's CAS backstop is server-tested but client-inert. A real conflict now
  retries forever with stale `before` instead of reconciling.
- C2 — `InventoryStore.restock()` was never converted to `recordDelta` (design doc says it should
  be) — and the checkpoint's own text at one point asserts this WAS done, which is factually wrong
  per the actual code. Compounds with C1.
- C3 — `StockBatchStore.consumeFifo()` runs before `deductStock`'s delta callback resolves in
  `_tryCompleteOrder`, with no rollback if the delta is later rejected — FIFO batches get
  decremented for orders that don't end up completing.
- C4 — `LockManager._classifyAcquireResponse` doesn't check HTTP status, so 400/401/403/500
  responses get misclassified as "someone else holds this lock" instead of "error" — same bug
  class the checkpoint documents fixing for the delta path, reintroduced here.
- C5 — `OrdersStore.approveAllPending()` (wired to a `Logic.approveAllPending` signal that's
  declared but never emitted — confirmed dead via grep) bypasses stock deduction, sale recording,
  locking, CAS, and delta entirely. Not currently reachable, but a landmine given how similar its
  name is to the real, safe `OrdersPage._approveAllPending()`.
- C6 — Leftover debug `console.log`s in `gatewayLogic.js`/`index.js`, one dumping full
  before/after document contents (customer PII, cost prices) to Cloud Functions logs on every
  mutation.

**Important:**
- I1 — `applyMutationsBatch` (untouched by this branch) has no CAS check at all — Component 3's
  guarantee isn't actually uniform across the app.
- I2 — Bulk order approval (`OrdersPage._approveAllPending`) never acquires a per-order lock —
  not discussed in the design's own §7.1 lock-point table.
- I3 — `lockLogic.js`'s `validateAcquireRequest` doesn't check `entity` against the known entity
  allowlist, unlike its `gatewayLogic.js` siblings.

## Round 2 findings (added to the same review doc)

Reviewed the three lock-wired dialogs, `_tryAdjustOrder`'s exchange path, `firestore.rules`, every
relevant `tests/tst_*.qml` file plus `functions/test/lockLogic.test.js`, a full QML lint pass
(`qt_qml_lint.py`) over all 11 touched files, and a ponytail duplication pass. Two new Critical
findings surfaced that outrank everything from round 1 in severity:

- **New C1 (top severity):** `OrdersStore._normalizeOrder` (rewritten in the branch's very last
  commit, `b51779b`, by Taher directly — not through an AI-reviewed session) reads
  `inv.consumption` instead of `lp.consumption` — `inv` is the product/inventory record, which has
  no `consumption` field. Result: FIFO lineage silently wiped on every single order normalization
  (universal, not edge-case), AND a hard TypeError crash whenever an order line's product is
  `null`/deleted/missing (`InventoryStore.getById` returns `null`, `null.consumption` throws). The
  existing `tests/tst_OrdersStore_normalization.qml` (added one commit earlier) will hit this crash
  the moment it's actually run, before reaching its own assertions — good news, since it means the
  fix is self-verifying once `qmltestrunner` finally runs.
- **New C2:** `firestore.rules` was never updated to lock down the new `locks/**` collection (design
  doc §4 explicitly calls for this, same pattern as the existing `audit_log`/`transactions` lockdown)
  — confirmed via `git log` that the rules file is untouched anywhere in this branch's 13 commits.
  The generic tenant-collection fallback rule means any signed-in tenant member can read/write lock
  docs directly from the client, completely bypassing `acquireLock`/`releaseLock`. This makes
  Component 2 (the largest single piece of this whole feature) an unenforced convention today, not
  an actual guarantee.

All round-1 findings (previously C1–C6, I1–I3) carried forward, renumbered C3–C8 in the final doc,
plus two new Important findings: dialogs' "try again" messaging doesn't actually retry lock
acquisition (all 3 dialogs, same pattern), and the test-suite gap analysis showing exactly why C3/C6
(client-side bugs) slipped past an otherwise-solid 85/85 server-side test suite — both test files
exist and are well-written, they just never vary the one input (HTTP status on a well-formed body)
that the bugs live in.

Final doc also includes: a direct "regressions / gaps / pending implementation" section answering
Taher's questions explicitly, a severity-ordered fix-priority list, and a ponytail section
(duplicate approve-all paths, duplicate classify-response logic that already diverged once).

## Pending review item closed out

Did the full (not spot-checked) read of `functions/test/gatewayLogic.test.js` (528 lines) and
`functions/test/lockLogic.test.js` (201 lines) I'd flagged as outstanding. Both are genuinely
thorough — CAS backstop (reject/accept/idempotency/key-order-insensitivity), delta floor/clamp
behavior, lock grant/expired/renew/reject/boundary, and every `validate*` happy/unhappy path are
all covered well. No new findings. This does confirm I3 precisely as suspected: there's no test for
`validateAcquireRequest` against an unrecognized `entity` value, consistent with the implementation
itself not checking it either — already captured in the review doc, nothing to add.

**Review is now fully closed out** — both rounds, plus this final coverage check. Pushed to origin
(`review/async-write-sequencing-audit`, 2 commits) using a one-time PAT Taher provided and is
rotating afterward, per the standing per-push permission rule. Waiting on Taher's direction for
which findings to actually implement, and in what order — no code changes made this session.
