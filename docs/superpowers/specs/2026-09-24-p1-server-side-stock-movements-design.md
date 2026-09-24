# P1 Stock Movements: server-side atomic ledger rows — Design

**Date:** 2026-09-24
**Status:** Written for review. Merging this PR = approving decisions D1-D10 as written. Anything you
disagree with: comment on the PR before merge; implementation starts in a new session on a new branch.
**Parent:** `2026-06-06-india-compliance-roadmap-design.md` §4.3 (P1, CGST Rule 56(2)).
**Supersedes:** the client-side approach on `feature/p1-stock-movement-taxonomy` (stale, unmerged, left untouched).
**Skills used:** `superpowers:brainstorming`, `superpowers:writing-plans`, `qt-development-skills:qt-qml`
(no QML in this slice), `ponytail:ponytail`.

## 1. Problem

CGST 56(2) needs an immutable, typed record of every stock movement (receipt, sale, loss, theft, ...) from which
an opening / receipts / supplies / closing register can be derived. The old P1 branch wrote a movement row from
the client as a **second, separate** write after the stock change. That fails the roadmap's own rule (spec §4.2:
"working-tier doc **and** ledger entry in one transaction"): a crash, kill or offline gap between the two writes
leaves stock changed with no ledger row, and the client also authors the row body (identity, time), so it is forgeable.

## 2. What already exists (ponytail ladder: reuse first)

- `recordDelta` and `recordOperation` already apply stock changes in one Firestore transaction with a server-stamped
  `audit_log` entry, idempotent by `requestId`. No new endpoint is needed.
- `firestore.rules` already denies all client writes to `stock_movements`; ledger collections are Admin-SDK only.
- `Gateway.mode = "gateway"` is live, so every stock change already goes through these endpoints.
- `recordOperation` `completeOrder` (C-3 Phase 1, merged) is where `sale` movements will ride once Phase 3 lands.

So the change is: teach the two existing transactions to also write movement rows. One new pure module, small edits to two.

## 3. Decisions (each with the alternative that lost)

**D1. Server-side atomic write (approved by Taher, "B").** Alternatives: client second write (not atomic, forgeable);
hybrid (two mechanisms, keeps A's gap).

**D2. The server builds the row; the client only describes the event.** Client sends
`movements: [{ kind, qty, reason?, valueAtCost?, batchRef? }]` next to the stock delta. Server stamps `id`, `productId`
(= the delta's `entityId`, never client-supplied), `actorUid`, `actorRole`, `serverTimestamp`, `clientTimestamp`,
`requestId`, and for operations `operationId`/`opType`/`opIndex`. Client-supplied identity fields are dropped.
Alternative rejected: accept a client-built row body (forgeable, the exact P0 gap for `stock_batches`/`transactions` that is out of scope here).

**D3. Invariant: the movements' signed quantities sum to exactly the stock delta the server applied.**
`qty` is signed (+ increases stock, − decreases), so per product `Σqty` = closing − opening, which makes the register a plain sum.
Checked inside the transaction against the applied delta (after floors and clamps), never the requested one.
Mismatch = `409 movement-qty-mismatch`, nothing written. Trade-off: a clamped delta (drift repair, D3 of the C-3 spec)
with movements is rejected, because the clamp changes the applied delta. Slice S3 (sale via `completeOrder`) must decide
how drift repair is ledgered; the lazy, honest default is that it does NOT carry movements and is separately visible in `audit_log`.
Alternative rejected: server auto-writes an `adjustment` row for the difference (hides drift behind a plausible-looking row).

**D4. Kind enum = the spec's nine plus `sales_return` = 10 values,** with a direction rule per kind:
increase-only `receipt`, `sales_return`; decrease-only `sale`, `loss`, `theft`, `destroyed`, `write_off`, `free_sample`, `gift`;
either way `adjustment`. A wrong sign (a `theft` of +3) is `400 invalid-movement-qty`. `sales_return` keeps the reasoning from the
old branch: Rule 56(2) has no return column and a return is mechanically a reduction in supply; a distinct kind stops it reading as a
sign-flipped `sale`. `opening_balance` is an audit action, not a kind.

**D5. Close the generic write path.** `stock_movement` is removed from `ENTITY_COLLECTIONS`, which the three client endpoints
(`recordMutation`, `recordDelta`, `recordMutationsBatch`), locks and `recordOperation` all validate against. After this, the only
way a `stock_movements` row can come to exist is through D2. Without this, D2 is decorative: a client could still post any row body
via `recordMutation`. Cost: none today (no code on `main` writes that entity; the old branch is discarded). Note: `Gateway.qml`'s
client-side `_collections` table still lists it; removed in S2.

**D6. Movements attach to `inventory` deltas that include a `stock` field, and only to delta ops** (not mutation ops).
`400 movements-require-inventory`, `movements-require-stock-delta`, `movements-require-delta-op`. Alternative rejected:
movements on arbitrary entities (no meaning, more surface).

**D7. Movement ids are deterministic:** `{auditId}~m{j}` (`auditId` = `requestId` for `recordDelta`, `{requestId}~{opIndex}` for an
operation). A retry replays from the existing audit entry and writes nothing, so no duplicate rows and no dedupe logic of its own.

**D8. Write budget.** Firestore allows 500 writes per transaction; `recordOperation` already uses up to 401 (200 docs + 200 audits +
1 marker). Total movements per operation are capped at 90 (491 worst case); `recordDelta` allows 50. Over the cap =
`400 too-many-movements`. A test builds the max-size operation and asserts ≤ 500 writes. Alternative rejected: raising nothing and hoping.

**D9. `valueAtCost` is client-supplied, a finite number ≥ 0 (magnitude of cost basis), informational.** The server cannot know the
cost basis of a sale without reading `stock_batches` in the same transaction, which adds reads and coupling to batch shape.
Known residual risk R1: a staff client can misstate value. Mitigations: the quantity is server-verified (D3), `audit_log` keeps
the request, and value can be recomputed from `batchRef` for audit. Revisit if an auditor asks for server-derived cost.

**D10. Backward compatible, deploy order fixed.** `movements` is optional; old clients keep working and simply produce no rows.
Order: merge server slice, Taher deploys functions to dev (D4 of the C-3 spec), then the client slices. Backfill of history is out of
scope: rows exist only from the first deploy of S2 onward (see open question Q2).

## 4. Slices (each its own PR; one session each)

| Slice | Deliverable | Depends on | Sandbox-testable |
|---|---|---|---|
| S1 | Server: `movementLogic.js`, `recordDelta` + `recordOperation` write rows, close generic path | nothing | Yes, `node --test` |
| S2 | Client: `Gateway.recordDelta` sends `movements`; wire restock (`receipt`), manual adjust (kind picker, required), returns (`sales_return`, `destroyed`); drop `stock_movement` from `Gateway._collections` | S1 merged + deployed | QML via CI only |
| S3 | `sale` movements inside `completeOrder` (per FIFO portion, `batchRef` + `valueAtCost`) | S1, C-3 Phase 3 | QML via CI only |
| S4 | Register report: opening / receipts / supplies / closing per product and period | S2, S3 | Pure math testable; UI via CI |

Only S1 has a plan today (`plans/2026-09-24-p1-server-side-stock-movements-s1.md`). S2-S4 get plans in their own sessions.
Reason: S2-S4 touch code that C-3 Phase 3 will rewrite, so planning them now would be planning against code that is about to change.

## 5. Error contract added (all `400` unless noted)

`invalid-movements`, `too-many-movements`, `invalid-movement-kind`, `invalid-movement-qty`, `invalid-movement-value`,
`invalid-movement-reason`, `invalid-movement-batch-ref`, `movements-require-inventory`, `movements-require-stock-delta`,
`movements-require-delta-op`; `409 movement-qty-mismatch` (with `field: "stock"`, `current`, and `opIndex` inside an operation).
`unsupported-entity` now also answers `stock_movement`.

## 6. Testing (see `test-plans/2026-09-24-p1-stock-movements-test-plan.md`)

S1 is fully covered by `node --test`: pure validator/sum/row-builder, `applyDelta`, `applyOperation` (atomicity, replay, cap,
mismatch rollback), handler pass-through, closed entity. Firestore rules tests need no change (ledger writes already denied).

## 7. Open questions (do not block S1; decide before the slice named)

- **Q1 (S2):** should `loss`, `theft`, `write_off` require owner/manager role? Today any role that can edit stock can pick them.
  Not in S1: role gating is a policy decision and a `staff` restriction changes real workflows.
- **Q2 (S4):** opening balance for periods before the first movement row. Options: a one-time `opening_balance` snapshot per product
  at S2 deploy, or derive opening from current stock minus `Σqty` since. The second needs no backfill job but is only correct if
  every stock change since deploy carried a movement (S2 + S3 must leave no stock path without one).
- **Q3 (S3):** how drift repair (clamped, D3) is ledgered. Default in D3: no movements, visible in `audit_log` only.
- **Q4 (S4):** Firestore composite index for `stock_movements` by `productId` + `serverTimestamp`; add with the report.

## 8. Risks

- R1 client-stated `valueAtCost` (D9).
- R2 stock changes that bypass `recordDelta`/`recordOperation` (e.g. whole-record `recordMutation` on inventory, still used by
  some `InventoryStore` paths) would produce no rows. S2 must enumerate every stock-writing path; the S2 plan starts with that grep.
- R3 deploy is manual (Taher); until deployed, S2's `movements` field is ignored by the old function and rows silently do not appear.
  S2 must not ship before the function is confirmed deployed.
