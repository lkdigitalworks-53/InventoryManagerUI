# CHECKPOINT — 2026-09-26: Sales Analysis deleted-product breakdown labels (DELETE-FEATURE-ROADMAP item 3) — INVESTIGATION, awaiting decisions

**Session date:** 2026-09-26
**Branch:** `fix/2026-09-26-sales-analysis-deleted-product-labels`, off `main` @ `9be6303` (PR #80 merged, item 2 done).
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-21-staff-delete-ui-CHECKPOINT.md`
**Skills invoked by Taher:** `superpowers:brainstorming` (design gate before code), `qt-development-skills:qt-qml`.
Caveman mode FULL applies to chat replies only; repo docs and commits are normal prose.
**Commit identity:** `Taher (via Claude session) <dextran52@gmail.com>`.

## Standing instructions from Taher

- Branch only, never `main`; push when a meaningful step is done without asking (Taher reviews in the GitHub PR).
- Do not build or run the app; no Qt tooling in the sandbox; CI is the only signal for QML.
- Every change: tests aiming at 100% coverage (unit, functional, rules, e2e, regression; happy path, negative, edge,
  multi-scenario, monkey), a test plan from the template, and `SKILLS.md` / `AGENTS.md` / `README.md` updated as needed.
- Honest advisor: show trade-offs, grill before deciding, do not simply agree. Ask before deciding anything on this
  ticket specifically — do not assume scope.
- The GitHub PAT is used for `git push` and the PR API only; never written into the repo.
- Session-token-budget model: Taher runs sessions from multiple claude.ai accounts; keep each session's scope small
  enough to land a reviewable, resumable state in the remote branch before tokens run out.

## Step log (append-only; resume from the last ticked step)

- [x] 1. Read project notes (index, overview, ways-of-working, engineering-lessons, item-1 and item-2 area files)
      and confirmed item 2 (`PR #80`) is merged into `main` — roadmap item 3 is next, per Taher's standing note
      that each roadmap item is its own session.
- [x] 2. Cloned repo fresh, created this branch, archived the previous checkpoint.
- [x] 3. Read roadmap item 3 (`docs/superpowers/DELETE-FEATURE-ROADMAP.md`) and its origin write-up in
      `KNOWN-ISSUES.md` ("Delete: Sales Analysis... Five other tabs' breakdown labels audited, not fixed").
- [x] 4. Traced the actual code paths (findings below) — the roadmap/KNOWN-ISSUES text says the real fix needs a
      "schema-level change across every write path," which is only half true once traced to source.

## Findings (all verified in code this session)

- **Affected surface**: `SalesPage.qml`'s `_breakdownByDimension()` (Purchased, Sold tabs; Revenue's `field` branch)
  and `InventoryStore.realisedProfitByDimension()` → `RealisedMath.byDimension()` (Revenue tab's money aggregation,
  Profit's Realised sub-mode) — five tabs total, matching the roadmap's list.
- **`productId` → name breakdown ("(uncategorised)"-style bug, but for name)**: **not actually a missing-data
  problem.** Every `TransactionStore` doc-creation function (`recordPurchase`, `recordSaleFromOrder`,
  `recordCreated`, `recordCreatedMany`, `recordReturn`, `recordPriceAdjust`) already stamps `productName` onto the
  entry at creation time — confirmed by reading each function body. The bug is purely on the **read side**:
  `SalesPage._breakdownByDimension()` builds a fresh `productName` map from **live** `InventoryStore.products`
  and passes that into `BreakdownMath.breakdown()`, ignoring the `productName` already sitting on each entry. A
  deleted product's historical entries still carry their real name; the read path just doesn't use it.
  → **This half is a small, contained, read-side fix. No schema change, no backend change, no backward-compat
  question** — the data needed has existed on every entry since it was created.
- **`productId` → category breakdown ("(uncategorised)" bug)**: **is** a real missing-data problem. Grepped every
  `TransactionStore` doc shape — none of them has a `category` field. `RealisedMath.byDimension()` and
  `SalesPage._breakdownByDimension()` both resolve category exclusively via live `categoryOf(pid)` →
  `InventoryStore.getById(pid).category`, which returns nothing once the product is deleted. Fixing this for real
  does mean adding a `category` field to every entry-creation call site — a genuine write-path change, exactly as
  the roadmap says, but scoped to one field, not a rewrite.
- **Write-path fan-out for the category stamp**, if done: `recordPurchase`, `recordSaleFromOrder`, `recordCreated`,
  `recordCreatedMany`, `recordReturn`, `recordPriceAdjust` are the candidates — still need to confirm which of
  these actually feed the five affected tabs' bucket walks (`recordFieldChange`/`recordStockAdjustment`/
  `recordPhotoChange` look like pure audit-trail entries, not counted in Purchased/Sold/Revenue; not yet confirmed
  either way).
- **Historical entries**: any entry written before a category-stamping fix ships has no `category` field regardless
  of the fix — old entries for an already-deleted product would still show "(uncategorised)" unless separately
  backfilled. `KNOWN-ISSUES.md` has an existing, separate precedent of *declining* a backfill for a related delete
  gap ("dev environment only; Firestore gets cleared and re-verified from scratch each time") — worth Taher's
  explicit call here rather than assumed to carry over.
- **Compliance-ledger angle**: `TransactionStore._push()` routes every entry through the "compliance gateway" for
  an "immutable audit_log entry" (comment, `TransactionStore.qml`) — this codebase already treats transaction
  records as point-in-time, append-only history (which is exactly why `productName` is stamped rather than
  live-looked-up). Stamping `category` the same way — value at time of transaction, not "current/last-known" — is
  consistent with that existing design and with how a product's category could legitimately change between a sale
  and a later deletion. Flagging this as my recommendation, not assuming it.

## Open questions for Taher (not yet decided — see chat)

1. Scope this session: fix the **name** bug alone (read-side only, low risk, no write-path change) now, and take
   the **category** bug (write-path change across several `TransactionStore` functions + a historical-gap
   question) as its own separate session — or attempt both here.
2. If category is stamped: at time-of-transaction (my recommendation, matches the existing immutable-ledger
   design and how `productName` already works) or something else?
3. Historical entries that predate the fix: leave as a documented, known gap (no backfill — precedent exists for
   a related issue) or backfill?

## Not done yet

- No design spec written (waiting on the above).
- No code changed.
- No tests written.
- Which `TransactionStore` doc kinds actually feed the Purchased/Sold/Revenue bucket walks — not fully confirmed,
  next step once scope is agreed.
