# P2 (tax-identity fields) — status review, 2026-10-31

**Type:** docs only, no code changed, so no test plan (nothing to test). Read-only review of `main` @ `f18445e` plus all 42 remote branches.
**Method:** grep + read. I did not dispatch a reviewer subagent (no such tool in this session); the review is mine alone. Nothing was built or run.

## Verdict

P2 is **0% implemented**. Only the *decision* exists. No design spec, no plan, no test plan, no branch, no PR.

## Done

| Item | Where |
|---|---|
| Scope locked: product `hsnCode` (4/6/8 digits, empty allowed), `gstin` on supplier / order-customer / tenant (15 chars + checksum) | Master roadmap `specs/2026-06-06-india-compliance-roadmap-design.md` §3 row P2 and §4.4 |
| "Client-only, no gateway" decision | Same file; `AGENTS.md` P2 bullet; `SKILLS.md` Skill 24 |
| Guidance for implementers ("add to `_clone()` / normalizer and the dialogs") | Skill 24 |
| Confirmed not started on 2026-09-24 | `specs/2026-09-24-compliance-reassessment-CHECKPOINT.md` |

## Verified absent (nothing to reuse)

- `grep -i "hsnCode|gstin"` over `qml/`, `functions/lib/`, `firestore.rules`, `tests/`, `test/`: **0 hits** on `main`.
- Same grep over every remote branch: **0 hits**. No stale branch to salvage (unlike P1).
- No validator, no UI field, no export/import column, no test.

## Pending (all of it)

Touch points, found by using `taxPercent` as the template (14 source files, ~30 test files reference it):

| Slice | Work | Files (expected) |
|---|---|---|
| P2-a | Pure validators: HSN 4/6/8 digits; GSTIN 15-char format + mod-36 checksum. QML helper + server mirror with shared parity fixtures (pattern exists: `OrderMath` / `orderMath.js`) | new `qml/helper/TaxIdentity.js`, `functions/lib/taxIdentity.js`, tests |
| P2-b | Product `hsnCode`: store normalize + `_clone()` (CAS shape-mismatch risk, see `learnings`), Add/Edit dialogs, xlsx export column (`StockSnapshotMath` header/row contract) and import column (`ImportMath`, `ImportPreviewDialog`) | `InventoryStore`, `DataModel`, `Logic`, `AddProductDialog`, `EditProductDialog`, `StockSnapshotMath`, `ImportMath`, `ImportPreviewDialog` |
| P2-c | Supplier `gstin`: `_normalizeSuppliers`, create/update fields (`contact` is the model), supplier form | `SupplierStore`, supplier dialog(s) |
| P2-d | Order-customer `gstin`: order has only `customer/email/phone` strings, no customer entity. New order + detail edit; normalize + clone | `OrdersStore`, `NewOrderDialog`, `OrderDetailDialog` |
| P2-e | Tenant `gstin`: tenant doc, owner-only by rules (`allow update: if isOwner`); profile form + `ProfileSettingsMath.buildChangeSet` role gate | `AuthStore`, `AuthService`, `ProfileSettingsMath`, settings page |
| P2-f | Per slice: tests (unit, regression, functional, rules, e2e, monkey), test plan, AGENTS / README / Skill / SKILLS-INDEX | docs |

Not a P2 file but affected: audit_log `before/after` snapshots carry the new fields automatically (no work).

## Gaps in the spec itself (must be settled before code)

1. **"Client-only" is stale.** Written before P0/S2c. Since S2c every `inventory` write goes through the gateway, so server validation is cheap now. Client-only validation is bypassable by any direct caller; for an auditor-facing field that is weak.
2. **Order-line HSN snapshot not specified.** `taxPercent` is snapshotted per order line (specs 2026-06-26 time-of-supply / mixed-vintage). HSN edited after a sale would otherwise rewrite history in any future report.
3. **`PartyStore` is device-local name strings**, not supplier docs. "GSTIN on supplier" means `SupplierStore` only. Party names get no GSTIN.
4. **HSN digit tier by turnover** (4 / 6 / 8) needs the tenant's turnover, which is not stored anywhere. Spec only says "format valid when non-empty".
5. **Special GSTIN shapes** (UIN, government deductors, etc.): I did not verify they pass the standard checksum. Needs CA confirmation before strict checksum rejects real numbers.

## Decisions for Taher (default = my recommendation)

| # | Question | Options | Recommend |
|---|---|---|---|
| Q1 | Server-side validation too? | A client only (spec) / B client + server reject / C client + server warn-only | B. Cost: a bad value that slips past the client becomes a terminal write error (parked write). Client pre-validation makes that rare |
| Q2 | Snapshot HSN on order lines? | A no / B yes | B. Cost: line shape change, `orderMath.js` parity, CAS clone symmetry tests |
| Q3 | Enforce HSN digit length by turnover tier? | A format only / B tenant turnover setting + enforce | A now; B after CA answers (same pattern as P1 S2e) |
| Q4 | Strict GSTIN checksum? | A format only / B format + checksum | B, unless CA says special shapes fail it (gap 5) |
| Q5 | Slice order | b -> a first? | a, b, c, e, d. Customer GSTIN last: touches order dialogs that open PR #174 is also changing |

## Effort (my estimate, not measured)

Spec says S (days). Realistically 5 to 6 short sessions, one slice each, because of the free-plan token limit and ~30 test files that mention tax fields. P2-a is the only truly small one.

## Sequencing note

P2 has no dependency on P1 or the CA. Remaining P1 (S2d-2, S2e, S3, S4 per `AGENTS.md`; not re-audited here) is partly waiting on the CA. P2 is a candidate filler while that wait lasts.
