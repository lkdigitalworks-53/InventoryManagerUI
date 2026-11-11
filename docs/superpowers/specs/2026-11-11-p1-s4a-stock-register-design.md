# P1 S4a: the stock register read model (server) — design

Status: built on `feat/2026-11-11-p1-s4a-stock-register-server`. Parent: `2026-09-24-p1-server-side-stock-movements-design.md` (slice S4, section 8 "Still open: S4"), `2026-06-06-india-compliance-roadmap-design.md` section 4.3 (CGST Rule 56(2)).
Decisions SR-D1 to SR-D13 were DEFAULTED because Taher asked for one chat turn with no interactive gate (same practice as K1-K14 and R4-D1..). Each is vetoable in the PR. Where a default has a real cost it says so.

## 1. Where P1 stands (read from `main` @ `977cde0`, 2026-11-11)

| Slice | State | Evidence |
|---|---|---|
| S1a, S1b server rows (derive + explicit) | merged, deployed, device-passed | #146 and S1b, checklists done 2026-10-21 |
| S2a/S2b/S2c cleanup and `inventory` lock | merged | `direct` mode and `runCutover` deleted, rules lock |
| S2d-1 typed kinds on client deltas | merged (#170) | restock `receipt`, returns `sales_return`, exchange `sale` |
| S2f-1..7 authz hardening, S2f-3 wording, `provisionMember` add-only | merged | owner-demotion slice = S2f-7 (#165), already done |
| **S2d-2** kind hint for the clamped imported-order deduction | open | KNOWN-ISSUES "Imported-order completion is typed `adjustment`" |
| **S2e** intent pickers (loss, theft, destroyed, write_off, free_sample, gift, valueAtCost) | open, parked on the CA | S2 design Q1 |
| **S3** `sale` per FIFO portion with `batchRef` | open | no `batchRef` anywhere in `functions/` or `qml/` |
| **S4** the register itself | **nothing existed**: no code reads `stock_movements` | `grep stock_movements qml/` returns nothing |

So the ledger has been filling since S1a and no screen or endpoint reads it. That is the gap this slice starts closing.

## 2. What this slice is

S4 is split like every other P1 slice, so it fits a chat turn and one device pass:

| Slice | Deliverable | Sandbox-testable |
|---|---|---|
| **S4a (this PR)** | `functions/lib/stockRegisterMath.js` (pure) + `computeStockRegister` endpoint (read-only) | Yes, all of it (`node --test`) |
| S4b (next) | client `StockRegisterService.qml` + a Stock Register page (period picker, per-product rows, share/export), role-gated like Analysis | QML in CI, Felgo layer on device |
| S4c (later) | printable/exported register in the CA's column layout, after the CA answers section 8 of the P1 design | pure math yes |

Deploy: the change is under `functions/`, so merging asks for the deploy approval (`deploy-check`). Nothing calls the endpoint until S4b, so deploying early is safe.

## 3. Contract

`POST /computeStockRegister` with `Authorization: Bearer <idToken>`, body `{ env, from, to }`.
- `from`, `to`: epoch milliseconds, or an ISO-8601 instant WITH an offset (`2026-04-01T00:00:00+05:30`, `...Z`). Period is `[from, to)`.
- 200 `{ ok, window:{fromMs,toMs}, readAt, kinds:[10 kinds], products:[row...], counts:{products,rowsSeen,rowsInWindow,mismatches,skipped:{noProduct,badKind,badQty,badTime}} }`.
- Row: `{ productId, name|null, deleted, opening, kinds:{<kind>:{in,out}}, inTotal, outTotal, closing, currentStock, ledgerStock, reconciles, movementCount }`. `closing = opening + inTotal - outTotal`.
- Errors: 405 `method-not-allowed`, 401 `missing-token` / `invalid-token`, 403 `no-tenant-context` / `role-not-allowed`, 400 `invalid-window`, 413 `ledger-too-large`, 504 `ledger-scan-timeout` (SR-D15), 500 `compute-failed`. A bound that is not a real calendar instant (`2026-02-30`, `T24:00:00`) is a 400 `invalid-window` (SR-D14).

## 4. Decisions (each with the alternative that lost)

| # | Decision | Chosen | Rejected, why |
|---|---|---|---|
| SR-D1 | Which slice first | S4a (register read model) | S3 `batchRef`: nice traceability but the register needs only kind, qty and time per product; the P1 design table said S4 depends on S3, that dependency is not real (see SR-D13). S2d-2: small, closes a typing hole, but changes the outbox on the client; it is queued next. S2e: UI work parked on the CA |
| SR-D2 | Source of the balances | the LEDGER only (`opening` = sum of rows before `from`). Inventory `stock` is a cross-check (`reconciles`) | opening = current stock minus later rows: cheaper reads but wrong the moment one stock change has no row, and a register that quietly trusts the mutable doc is not an audit trail |
| SR-D3 | Where it is computed | server endpoint (like `computeAnalysis`) | client reads `stock_movements` over REST (members may read it): the phone would page the whole ledger over mobile data on every open |
| SR-D4 | Period and time zone | half-open `[from, to)`; offset required on ISO strings | inclusive `to`: an instant would belong to two adjacent periods. Offset-less ISO: the server would read it as UTC while the phone meant local midnight, moving every boundary by 5.5 hours for India. The client builds local midnights with an offset (S4b) |
| SR-D5 | Output shape | IN and OUT per kind, all 10 kinds always present, plus totals | one column per printed 56(2) heading: which kinds go in which column is open (P1 design section 8, S4), do not guess a legal layout. Adding columns later is a presentation change, not a data change |
| SR-D6 | Reading strategy | stream the whole ledger page by page, fold into per-product sums, keep nothing (memory O(products)); hard cap 250 000 rows then 413; 1000 rows per page and a 100 s scan budget then 504 (SR-D15) | load all rows (`readAllPaged`, as `computeAnalysis` does): O(rows) memory, would OOM on a long ledger. A `where serverTimestamp < to` query: needs rows after `to` for the cross-check and adds an index to deploy |
| SR-D7 | Who may read | owner, admin, manager; staff gets 403 | any member: the ledger will carry cost values (today every `valueAtCost` is 0, S2e writes the real ones). NOTE the rules still let every member read `stock_movements` directly (KNOWN-ISSUES), so this gate protects the endpoint, not the data |
| SR-D8 | The cross-check | `reconciles` per product = ledger total of ALL rows equals the inventory `stock`; advisory | a transaction around both reads: a read-only transaction over 250k docs is not what Firestore transactions are for. A sale landing between the two reads can flag one product for one answer; run it again |
| SR-D9 | Deleted products | kept, `deleted: true`, `name: null`, `currentStock 0` | dropping them: the register would lose their sales and the opening of any period they lived in. A delete writes a row taking stock to 0, so they reconcile. Limit: the ledger row carries no product name, so a deleted product shows only its id (KNOWN-ISSUES, P1 S4a item 13) |
| SR-D10 | Bad rows | skipped and COUNTED by reason; a row against its kind's direction counts as `badQty` | fail the whole request: one corrupt row would hide every other product. Silently fold in: a balance nobody can explain |
| SR-D11 | `valueAtCost` | not in the register | sum it per kind now: derived rows carry 0 and only S2e pickers will write real values, so every figure would be 0 today. Added in S2e with the pickers |
| SR-D12 | Index | none (`orderBy("__name__")` paging only) | composite `productId + serverTimestamp` (P1 design Q4): only needed when a per-product history screen exists |
| SR-D13 | The "S4 depends on S3" claim | corrected here: S3 is optional for the register | keep it: would delay the only user-visible P1 deliverable for a field (`batchRef`) the register does not read |

## 5. Costs and risks, said plainly

- **Reads are billed.** One request reads every ledger row once, so a ledger of N rows costs N Firestore reads per request, plus the inventory. At 100 000 rows that is a few US cents per open and the 250 000 cap bounds one request near 15 US cents, from Firestore's list price of about US$0.06 per 100 000 reads in US regions (UNVERIFIED for this project's region and plan: check the console price before relying on it). That is fine for a compliance report opened a few times a month and wrong for a screen that auto-refreshes. S4b must fetch on demand only (a button), never on page load or resume.
- **Latency.** 1000 rows per page, one sequential round trip each: 250 000 rows is 250 round trips, tens of seconds (it was 500 round trips at 500 per page, close to the timeout). The function timeout is 120 s; the scan stops starting pages after 100 s and answers 504 `ledger-scan-timeout` as JSON (a platform kill sends no body and no CORS headers).
- **The way out when it hurts:** a running per-product balance written inside the same transactions as the rows (opening for a period = a stored checkpoint plus the rows since). That is a write-path change in `recordDelta`, `recordMutation`, batch and operation, so it is its own design; not done here and not needed before real volume.
- **Cap is a cliff, not a slope.** Past 250 000 rows the endpoint answers 413 for every period. The running-balance design above replaces the full scan; until it exists the cap is the limit. An over-cap request still pays for the 250 000 reads it makes before it answers 413 (KNOWN-ISSUES, P1 S4a item 14).
- **Deploy order:** server first. Nothing in the app calls the endpoint yet.

## 6. Advice on what comes next (honest)

1. **S4b the page, before S3 and S2e.** It is what makes P1 visible, it needs only this endpoint, and it will show what the derived `adjustment` rows really look like on a dev tenant, which tells us whether S2e pickers are urgent.
2. **S2d-2 right after:** small, makes imported-order sales count as `sale` (today they are `adjustment`, so the register understates supplies for imported orders).
3. **S3 only if an auditor asks for per-batch traceability.** The register does not need it.
4. **S2e waits for the CA** (loss, theft, gift, free sample, input tax credit reversal on `valueAtCost`). Building pickers first risks throwing them away (S2 design Q1).

## 7. Review sweep of PR #193 (2026-11-11, same PR)

Four defects found and fixed here, each with a test that fails when the fix is reverted (5 of 5 mutants killed):

| # | Decision | Chosen | Rejected, why |
|---|---|---|---|
| SR-D14 | Impossible calendar dates in `from` / `to` | refuse: every field range-checked, day checked against the month and leap year, hour 24 refused (400 `invalid-window`) | accept what `Date.parse` accepts: it rolls `2026-02-30` over to 2 March and reads `T24:00:00` as next midnight, so a typo gives a register for the wrong period with no error |
| SR-D15 | Time budget of the scan | 1000-row pages, 100 s budget checked before each page, then JSON 504 `ledger-scan-timeout` | rely on the 120 s platform timeout: at 500 rows per page the 250 000 cap alone is 500 round trips, the kill sends no CORS headers, so the app sees "no answer" instead of a code. A `count()` pre-check (cheap 413) is a real option, not done, see KNOWN-ISSUES item 14 |
| SR-D16 | Membership lookup failure | `scopedDb` + `deriveContext` inside a `try`: transient Firestore error answers 500 `compute-failed` | leave it outside, as the older handlers do: an unhandled rejection returns no JSON. The older handlers keep that shape (KNOWN-ISSUES item 16) |
| SR-D17 | `env` lookup in `scopedDb` (shared by EVERY handler) | own keys only: `constructor`, `toString`, `__proto__` fall back to the default database like any unknown env | leave it: `DATABASE_ID_FOR_ENV["constructor"]` is truthy, so the fail-safe fallback was skipped and a function object was passed as database id |

Open for Taher, not decided here (details in KNOWN-ISSUES): restrict the `stock_movements` read rule now or before S2e (item 1), write a product-name snapshot into ledger rows so deleted products stay readable (item 13), a `count()` pre-check so an over-cap request is cheap (item 14).
