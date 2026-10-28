# P1 S2d: typed stock-movement kinds on client deltas (design)

Status: S2d-1 built on `feat/2026-10-28-p1-s2d1-movement-kinds`. Parent: `2026-10-19-p1-s2-design.md` (S2d row), `2026-09-24-p1-server-side-stock-movements-design.md` (server contract, D2/D3). Decisions below were DEFAULTED because Taher asked for one turn with no interactive gate; each is vetoable.

## Problem
Since S1a/S1b the server writes a `stock_movement` row inside every `recordDelta` transaction, but the client never says why stock moved, so every row is a derived `adjustment`. A restock, a customer return and an exchange are indistinguishable in the register that CGST Rule 56(2) needs.

## Contract (unchanged, already deployed)
`recordDelta` accepts `movements: [{ kind, qty, reason? }]` on `entity: "inventory"`: `deltas.stock` present, signed qtys sum to the APPLIED delta, each qty matches its kind's direction, at most 50, reason at most 500, no clamp that changes the delta. Absent `movements`: server derives one row.

## Decisions
| # | Decision | Chosen | Rejected, why |
|---|---|---|---|
| K1 | Where the rules live | pure `qml/helper/StockMovements.js` mirroring the server, drift pinned by a Node parity test | inline checks in stores: untestable, drift unseen |
| K2 | Bad `movements` | refuse in `Gateway.recordDelta` before queueing (`bad-request` + `detail`) | let the server 4xx: terminal, the queued stock change is parked/dropped |
| K3 | Coalescing | explicit joins explicit only (movements concatenate, cap 50, no clamp); mixed queues as its own item | synthesise an `adjustment` row for the derived side: invents a ledger row the user never caused |
| K4 | restock | `receipt`, reason = the typed reason; refuse qty <= 0 / non-finite before the batch write | send valueAtCost: only meaningful for loss/theft (S2e), YAGNI |
| K5 | customer return | `sales_return`, reason `Return - order <id>` | `sale` with negative qty: forbidden by direction rule |
| K6 | reopen a completed order | `sales_return`, `Order reopened - sale reversed - order <id>` | `adjustment`: leaves an unexplained +row, register supplies overstated. CA to confirm |
| K7 | rollback of a failed exchange | `sales_return`, `Rollback - order edit failed - order <id>`; pair `sale` + `sales_return` nets supplies to 0 | `adjustment`: same overstatement |
| K8 | exchange / modify-up addition | `sale`, reject mode (floor) | none |
| K9 | imported-order completion (clamp) | stays derived `adjustment` for now | explicit `sale` + clamp: when the clamp bites the server answers 409 `movement-qty-mismatch`, the fire-and-forget deduction is lost = stock never deducted. Needs a server "kind hint" for derived rows (S2d-2, needs a deploy and Taher's call) |
| K10 | damaged return | no row (unchanged) | `destroyed` row: needs the S2e UI choice (Q4) |

## Not in scope
S2d-2 kind hint; S2e pickers (loss, theft, destroyed, free_sample, gift, write_off, valueAtCost); S3 `sale` per FIFO portion; S4 register.

## Risks
- Client/server drift: Node parity test (constants + 4000-case monkey) fails on drift.
- A kind added to the server but not the client is simply unreachable; the reverse is refused locally.
- Old server (not redeployed): the field would be ignored or rejected; S1a/S1b are deployed and device-passed, so n/a today. Check before any new tenant/project.
