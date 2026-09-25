# P1 Stock Movements: server-side atomic ledger rows — Design (rev 2)

**Date:** 2026-09-24 (rev 2 after the open-questions session)
**Status:** All decisions below are settled with Taher (P1-P8 in the session log). Remaining open items are listed in section 8 and belong to later slices.
**Parent:** `2026-06-06-india-compliance-roadmap-design.md` §4.3 (P1, CGST Rule 56(2)).
**Supersedes:** the client-side approach on `feature/p1-stock-movement-taxonomy` (stale, non-atomic, left untouched; never rebase it).
**Environment fact (Taher, 2026-09-24):** everything is DEV only. No production code is published; testing means new tenants and users with new products and orders.
So there is no backward-compatibility, backfill or migration burden yet. Manual functions deploy by Taher is still a step.
**Skills used:** `superpowers:brainstorming`, `superpowers:writing-plans`, `ponytail:ponytail-audit`, `qt-development-skills:qt-qml` (no QML logic in S1).

## 1. Problem

CGST 56(2) needs an immutable, typed record of every stock movement (receipt, sale, loss, theft, ...) from which an opening / receipts / supplies / closing register
can be derived. The old branch wrote a movement row from the client as a second write after the stock change: not atomic (a crash or offline gap leaves stock changed
with no row) and forgeable (the client authors the row). It also could not be complete: `InventoryStore.qml` sends `stock` inside whole-record `recordMutation` on
create (~520), `updateProduct` (~623), bulk import (~908) and edit (~1283), and `firestore.rules` still lets any member write `inventory` directly. A ledger with
holes fails an audit.

## 2. What already exists (ponytail ladder: reuse first)

`recordDelta`, `recordMutation`, `recordMutationsBatch` and `recordOperation` already apply changes in one Firestore transaction with a server-stamped `audit_log`
entry, idempotent by `requestId`. `firestore.rules` already denies client writes to `stock_movements`. So the change is one new pure module plus a small hook in each
of the four transactions. No new endpoint.

## 3. Decisions (each with the alternative that lost)

**D1. Server-side atomic write (Taher: "B").** Lost: client second write (not atomic, forgeable); hybrid (two mechanisms).

**D2. The server builds the row; the client only describes the event.** Optional `movements: [{ kind, qty, reason?, valueAtCost? }]` on `recordDelta`. The server stamps
`id`, `productId` (= `entityId`), `actorUid`, `actorRole`, `serverTimestamp`, `clientTimestamp`, `requestId`, `derived`, and inside an operation `operationId`/`opType`/`opIndex`.
Client-supplied identity fields are dropped.

**D3. Invariant: the movements' signed quantities sum to exactly the stock delta the server APPLIED** (after floors and clamps). `qty` is signed, so per product
`Σqty` = closing − opening. Mismatch = `409 movement-qty-mismatch`, nothing written. Explicit movements together with a clamp that changes the applied delta are rejected
(client cannot know the applied value). The derived path (D11) has no such problem: it records the applied delta itself, so a drift-repair clamp on `completeOrder`
still completes and the row shows what actually moved; the clamp stays visible in `audit_log`.

**D4. Kind enum = the spec's nine plus `sales_return` = 10,** with a direction rule: increase-only `receipt`, `sales_return`; decrease-only `sale`, `loss`, `theft`,
`destroyed`, `write_off`, `free_sample`, `gift`; either way `adjustment`. A wrong sign is `400 invalid-movement-qty`. `sales_return` because Rule 56(2) has no return column
and a return should not read as a sign-flipped `sale`. `opening_balance` is an audit action, not a kind.

**D5. Close the generic write path.** `stock_movement` leaves `ENTITY_COLLECTIONS` (which every client endpoint, locks and `recordOperation` validate against), so the only
way a `stock_movements` row exists is through D2/D11.

**D6. Explicit movements only through `recordDelta` on `inventory` with a `stock` delta.** `recordMutation`, `recordMutationsBatch` and mutation ops reject `movements`
(`400 movements-not-supported`); they get server-derived rows (D11). Delta ops inside `recordOperation` accept explicit movements (S3 uses this).

**D7. Deterministic ids, replay-safe.** Row id = `{auditId}~m{j}` (`auditId` = `requestId`; batch `requestId:entityId`; operation `requestId~opIndex`). A retry replays from the existing
audit entry and writes nothing, so no duplicates and no dedupe code.

**D8. Write budget (Firestore: 500 writes per transaction).** Operation: `2 x ops + 1 + rows <= 500`, every op on entity `inventory` counting at least 1 row, explicit movements counting
their length; over = `400 operation-too-large`. 166 inventory ops = 499 writes; 200 non-inventory ops = 401. `recordDelta`: at most 50 explicit movements. Batch: see D13.

**D9. Row fields: keep `valueAtCost` (client-supplied number >= 0), cut `batchRef` until S3.** `valueAtCost` matters for the input tax credit reversal on loss, theft, destroyed, gift and
free samples; confirm the exact rule with the CA. It is client-stated (risk R1); derived rows carry 0. `batchRef` is only meaningful for per-FIFO-portion `sale` rows, so S3 adds it (schemaless,
so adding later is free).

**D10. Dev-only, no compatibility layer.** `movements` is optional and old code paths keep working, but nothing is designed around old clients or prod data. Deploy order: server slices first
(Taher deploys functions to dev), then client slices.

**D11. Every stock change on `inventory` leaves a ledger row, derived when the client says nothing.** `recordDelta` without movements: one `adjustment`. `recordOperation` delta op:
`sale` for `completeOrder` (falls back to `adjustment` for an increase). `recordMutation` / batch / mutation op: create with stock => `receipt`, update / delete / `opening_balance` =>
`adjustment` by the stock difference (delete counts as stock going to 0; absent or non-numeric stock counts as 0). Zero change derives nothing. Derived rows carry `derived: true`, `reason ""`,
`valueAtCost 0`. Consequence: product create, edit, bulk import and delete cannot bypass the ledger and need no client rewrite for completeness; a manual edit is honestly typed `adjustment`,
and intent kinds (`loss`, `theft`, ...) come from the S2 pickers over `recordDelta`. Lost: routing every client path through explicit deltas first (bigger, and the client could still forget one).

**D12. Cleanup and lock in S2 (cheap because dev-only).** Delete `Gateway.mode = "direct"` and its direct-write paths (a flag flip skips `audit_log` and the ledger), delete
`runCutover` + `cutoverLogic.js` + its test (~350 lines, one-shot migration, Taher confirmed "rest looks good"), drop `stock_movement` from `Gateway._collections`, and lock
`inventory` in `firestore.rules` so nothing can write stock except through the functions (rules test + Taher deploys rules).

**D13. `MAX_BATCH_SIZE` 200 -> 150** (an inventory batch item writes doc + audit + row = 3; 150 x 3 = 450). Mirrored in `Gateway.maxBatchSize` (S1b Task 5, CI-verified).

## 4. Slices (each its own PR and session)

| Slice | Deliverable | Depends on | Sandbox-testable |
|---|---|---|---|
| S1a | `movementLogic.js`; `recordDelta` + `recordOperation` delta ops (explicit + derived rows); write budget; close `stock_movement` | nothing | Yes (`node --test`) |
| S1b | `recordMutation`, `recordMutationsBatch`, operation mutation ops derive rows; batch cap 150 + client mirror | S1a deployed + checklist | Server yes; QML mirror via CI |
| S2 | Client kind pickers (restock => `receipt`, manual stock change with picker => `recordDelta`, returns => `sales_return`/`destroyed`); delete `direct` mode and `runCutover`; lock `inventory` in rules | S1b deployed + checklist | QML via CI; rules test in emulator job |
| S3 | `sale` rows inside `completeOrder` per FIFO portion (add `batchRef`), after C-3 Phase 3 | S1a, C-3 Phase 3 | QML via CI |
| S4 | Opening / receipts / supplies / closing register; composite index | S2, S3 | Pure math yes; UI via CI |

Plans: S1a and S1b exist (`plans/2026-09-24-p1-server-side-stock-movements-s1a.md`, `...-s1b.md`). S2-S4 are planned in their own sessions: they touch code C-3 Phase 3 will rewrite.

## 5. Error contract (all `400` unless noted)

New: `invalid-movements`, `too-many-movements` (> 50 explicit), `invalid-movement-kind`, `invalid-movement-qty`, `invalid-movement-value`, `invalid-movement-reason`,
`movements-require-inventory`, `movements-require-stock-delta`, `movements-not-supported`; `409 movement-qty-mismatch` (`field: "stock"`, `current`, `opIndex` in an operation).
Existing `operation-too-large` now also means the write budget (D8). `unsupported-entity` now also answers `stock_movement`.

## 6. Testing

See `test-plans/2026-09-24-p1-stock-movements-test-plan.md`. S1a and S1b are fully covered by `node --test` in the sandbox (pure logic, `applyDelta`, `applyMutation`, batch, `applyOperation`
over an in-memory transaction fake, handler pass-through). QML and e2e edits are CI-only. Firestore rules tests change only in S2.

## 7. Resolved questions (from the first version of this spec)

- **Q1 role gating for `loss`/`theft`/`write_off`:** none now. Rows record `actorRole`; gating is a policy call to add when misuse shows up.
- **Q2 opening balance:** no `opening_balance` kind, no snapshot. New tenants start at 0 and every stock change writes a row (D11), so opening for a period = Σ movements before it. Initial stock and imports are `receipt`.
- **Q3 drift-repair clamp:** solved by D3 + D11 (derived row records the applied delta).
- **Q4 composite index (`productId` + `serverTimestamp`):** deferred to S4.

## 8. Still open

- **S2:** intent-kind picker UX (which screens, required or optional); whether a manual stock edit in the product form should split into "edit fields" (whole-record) and "change stock" (delta with kind).
- **S3:** per-FIFO-portion explicit movements with `batchRef` versus one derived `sale` row per product line.
- **S4:** register period boundaries and how returns/adjustments are grouped in the 56(2) columns (confirm with the CA).

## 9. Risks

- **R1** `valueAtCost` is client-stated; the quantity is server-verified. Revisit if an auditor wants server-derived cost.
- **R2** until S2 locks the rules, a member can still write `inventory` directly (rules fallback), bypassing every server path. Dev-only for now; S2 closes it before any prod.
- **R3** deploy is manual: a client that sends `movements` to an un-redeployed function silently gets no rows. S2 must not ship before the deploy is confirmed.
- **R4** derived rows are coarse (`adjustment` for edits) until S2 pickers exist.
- **R5** batch cap change (D13) affects client chunking and three QML/e2e pins; only CI can prove it.
