# P1 S2d-2: a kind hint for server-derived stock rows (imported-order sales count as `sale`)

Status: **built** on `feat/2026-11-18-p1-s2d2-derived-kind-hint` (cut from `main` @ `591077e`). Parents: `2026-09-24-p1-server-side-stock-movements-design.md`, `2026-10-28-p1-s2d-kinds-on-deltas-design.md` (decision K9 names this slice), `2026-11-13-p1-s2e1-reason-policy-and-cost-design.md`.
Test plan: `../test-plans/2026-11-18-p1-s2d2-derived-kind-hint-test-plan.md`. Honesty note: the Node tests were RUN here against the real server code; the QML twins and e2e are CI only (no Qt in the sandbox, by rule). The app was not built or run.

## 1. Problem, and why this slice was chosen
Completing an imported order deducts stock in **clamp mode**: if stock is short, the deduction is cut to what exists instead of being refused (`InventoryStore.deductStock(..., clampInsteadOfReject = true)`). The server only knows the quantity it actually applied, so the client cannot send explicit ledger rows for it. An explicit row of the ordered quantity next to a clamp makes the server answer `409 movement-qty-mismatch`; that answer is terminal for a queued write, so the stock deduction would be **lost** (S2d design, K9). The server therefore derives the row itself, and always wrote it as `adjustment`.

Effect in the stock register: the `sale` column understates supplies for imported orders, and the same quantity shows as a stock correction (KNOWN-ISSUES, P1 S4a item 7). A tax officer reading "supplies" would see too little.

Why this slice and not another open one:
- S2e-2 (pickers), S4c (print layout) wait on the CA (see `../CA-QUESTIONS.md`).
- S4b-2 (register page) is Felgo UI, provable only on a device, not in this sandbox.
- S3 (`batchRef`) is large and only adds traceability.
- S2d-2 is small, fully testable in Node against the real server, and makes the register's supplies correct. It was queued next in S4a SR-D1.

## 2. Contract

New optional field on `recordDelta` only: **`kindHint`**, a string. It names the kind of the row the server derives.

| Rule | Result |
|---|---|
| absent or `null` | exactly as before: derived `adjustment` |
| a kind in `HINT_KINDS` (`receipt`, `sales_return`, `sale`, `adjustment`) | the derived row gets that kind, value 0, empty reason (derived rows keep these) |
| any other string, or a non-string | 400 `invalid-kind-hint` |
| together with explicit `movements` | 400 `kind-hint-with-movements` |
| entity is not `inventory`, or no `stock` delta | 400 `invalid-kind-hint` |
| the hint's direction does not match the applied delta (for example `sale` but stock went up) | the row degrades to `adjustment`; the stock change is **never** refused |
| sent to `recordMutation`, `recordMutationsBatch` or an operation op | 400 `kind-hint-not-supported` (never silently ignored) |

`HINT_KINDS` is computed as the kinds that need neither a reason nor a stamped value (`MOVEMENT_KINDS` minus `REASON_REQUIRED` minus `VALUE_KINDS`), so a new sensitive kind added later cannot become hintable by accident.

## 3. Decisions (each with the alternative that lost)

| # | Decision | Lost alternative and why | Cost |
|---|---|---|---|
| H1 | A **hint** that names the kind, the server derives the quantity. | Explicit movements next to the clamp: `movement-qty-mismatch` when the clamp bites, deduction lost. Server clamp-aware movements: the server would have to re-split a client list on a quantity the client never saw. | One more field on one endpoint. |
| H2 | **`HINT_KINDS` excludes every kind that needs a reason or a value.** | Any kind: a client could write a reasonless `theft` or an unvalued `gift` and bypass the S2e-1 policy. | A clamped deduction can never be a loss; that is correct, losses are explicit. |
| H3 | **Direction mismatch degrades to `adjustment`**, never refuses. | Refuse (400): a terminal 4xx on a queued stock change loses the change; an unlabelled correct stock is better than a lost deduction. | A wrongly hinted call shows as a stock correction, as today. |
| H4 | The hint is sent **only in clamp mode**. Exact mode keeps explicit movements. | Always send both: the server refuses both together (H5). | none |
| H5 | **Hint with explicit movements is refused** (400). | Prefer one silently: hides a caller bug. | The client never does it (validated before queueing). |
| H6 | The other three write paths **refuse a hint** (400 `kind-hint-not-supported`). | Ignore it: a caller would believe it was recorded. | none |
| H7 | **Outbox coalescing: derived calls merge only with an equal hint.** | Merge any two derived calls: a `sale` merged with an unlabelled call would mislabel one of them. Drop the hint on merge: loses the label for both. | Two clamped deductions with different kinds queue as two items (rare: imported-order completion is the only clamped caller and always says `sale`). |
| H8 | The client **drops an unacceptable hint and keeps the stock change** (`_kindHintFor`), exactly like explicit movements (K13). | Refuse the call: the credit and deduction paths are fire-and-forget, a refusal is a silently lost deduction. | A bad label becomes `adjustment`, with a console warning. |
| H9 | `Gateway.recordDelta` **refuses a bad hint before queueing** (`bad-request` + `detail`) for callers that hand it a bad hint directly. | Let the server answer 400: terminal for a queued write. | none |
| H10 | **Old server ignores the field, old client sends none**: deploy order is free. | Versioned endpoint: heavier than the need. | Until functions are deployed, the row stays `adjustment` (today's behaviour). |
| H11 | The three new error codes are classed as **app problems** (`FailureCause._BUG_CODES`). | Show a retry prompt: retrying cannot help. | none |

## 4. What changed
- Server: `movementLogic.js` (`HINT_KINDS`, `validateKindHint`), `gatewayLogic.js` (`validateDeltaRequest`, `validateMutationRequest`, `applyDelta`), `batchMutationLogic.js`, `operationLogic.js`, `index.js` (`recordDelta` passes the hint).
- Client: `StockMovements.js` (`HINT_KINDS`, `validateKindHint`, `canCoalesce`), `Gateway.qml`, `OutboxStore.qml`, `InventoryStore.qml` (`_kindHintFor`, `deductStock`), `DataModel.qml` (`completeImportedOrder` passes `"sale"`), `FailureCause.js`.
- No Firestore rules change, no index change, no migration (old rows keep `adjustment`; the ledger is immutable).

## 5. Costs and risks, said plainly
- **Old rows stay wrong.** Imported orders completed before this deploy remain `adjustment` in the ledger. The register will show them as stock corrections. Not backfilled (the ledger is immutable; a correcting row pair would invent history).
- **Two copies of the rule** (server and client). `stockMovementsParity.test.js` and the new client-to-server test (`kindHintClient.test.js`) fail when they drift.
- **Deploy before use.** Until functions are deployed to dev, the hint is ignored.
- **Client and server report different codes for a faulty movement** because they check the pieces in a different order. Pre-existing, not caused by the hint; both sides refuse. Logged in KNOWN-ISSUES.

## 6. Not in scope
S2e-2 pickers, S3 `batchRef`, S4b-2 register page, S4c print layout, any CA-dependent decision (see `../CA-QUESTIONS.md`).

## 7. Advice on what comes next (honest)
1. **Deploy functions to dev and run the imported-order device step** (test plan, step 1). It is the only proof the register now shows `sale` for an imported order.
2. **Send `CA-QUESTIONS.md`** (sections 2 and 3 first). S2e-2 and S4c both wait on it; building them first risks throwing the work away.
3. **S4b-2 (register page) next** if the CA is slow: it needs no CA answer to ship with kinds visible by type, but it can only be proved on a device.
