# P1 S2e-1: which stock events need a reason, and who stamps their cost value

Status: **built** on `feat/2026-11-13-p1-s2e1-reason-policy-and-cost-snapshot` (stacked on PR #198). Parent: `2026-09-24-p1-server-side-stock-movements-design.md`, `2026-10-19-p1-s2-design.md` (Q1: wait for the CA; answered 2026-11-13), `2026-11-12-p1-s4b-register-client-design.md`.
This slice is the SERVER contract and the client mirror only. The pickers (S2e-2) that let a person choose loss/theft/gift come next; until then nothing sends these kinds, so the change is invisible in the app.

## 1. What Taher decided (2026-11-13)
- Adjustment stays allowed, reason optional. (He first said "not manual"; on my objection that it keeps opening + in - out = closing he took my recommendation.)
- Cost value: use the product's cost price; no GST detail on purchases yet. "You decide" on how.
- Reasons: mandatory where sensitive, my research decides which.
- The app is for any kind of business vendor, not only Al-Libaas.

## 2. Research (CGST Act and Rules, read 2026-11-13)
- **17(5)(h)**: ITC is not available on goods lost, stolen, destroyed, written off, or disposed of by way of gift or free samples. These are exactly the six non-supply outward events Rule 56(2) lists in the stock account. A reason on the movement is the evidence for the reversal workings and for an officer's "what happened".
- **Gifts** are also the one kind where who received it matters: Schedule I treats gifts between related persons as supply, and gifts to employees up to Rs 50,000 a year are outside it. A reason ("staff Diwali gift") records that.
- **Free samples**: the same ITC block today, but the 57th GST Council (8 Oct 2026) recommended removing it; not law yet as far as my sources say. Sales staff give samples all day, so a forced reason is friction on the highest-volume kind, for a rule that may go away. Optional.
- **Rule 56(8) (numbering differs by source)**: entries are not erased or overwritten; incorrect entries are struck out under attestation and the correct one made. This is why a reason is captured when the row is written: it cannot be added later.
- Rule 56(2) excludes composition dealers (section 10). The register is optional for them; the feature stays on for everyone.

## 3. Decisions (each with the alternative that lost)

| # | Decision | Lost alternative and why | Cost |
|---|---|---|---|
| E1 | **Required reason: loss, theft, destroyed, write_off, gift.** At least **3 characters after trim**. | All six required: free_sample friction (above). None required: Taher asked for mandatory where sensitive. | A person recording a free sample may skip the why; an auditor may later ask. Accepted. |
| E2 | Optional reason: free_sample, adjustment, receipt, sale, sales_return. | adjustment required: Taher chose optional; the derived adjustment from a product edit has no reason by design. | Stock corrections from a form edit have blank reasons. |
| E3 | The rule lives in **one server function** (`validateMovements`), so the single-delta endpoint and `recordOperation` ops both enforce it, plus a **client mirror** with a parity test over every kind x reason and 3000 random lists. | Client-only check: a bad client would write unreasoned theft rows. Server-only check: a terminal 4xx on a queued stock change loses the write (see the header of `qml/helper/StockMovements.js`), so the client must refuse BEFORE queuing. | Two files to change together; the parity test fails when they drift. |
| E4 | The server error is `movement-reason-required`, classed as an **app problem** in `FailureCause.js` (the picker blocks the person first, so reaching the server is a bug). | A person-facing message: it would invite a UI that lets the person submit, and a queued write that then fails. | None. |
| E5 | **The server stamps `valueAtCost`** for the six non-supply outward kinds = `qty x product.price` (cost; `sellingPrice` is never used), rounded half-up to paise, from the product doc it already reads inside the transaction. A client-sent value is **ignored**. | Trust a client number: any client could mis-state the value an ITC reversal is computed from. Read cost at REPORT time: changing a product's cost later would silently rewrite old reports. | Stamped once, never revised: if the cost was wrong when the loss happened, the row keeps it (ledger is immutable). |
| E6 | **Missing or invalid cost stamps 0** and the loss is still recorded. | Refuse a loss when the product has no cost: a real loss must always be recordable. | 0 is indistinguishable from a genuinely zero-cost item (KNOWN-ISSUES 2). |
| E7 | Other kinds (sale, receipt, sales_return, adjustment) keep whatever value they carried. | Stamp every kind: FIFO batch cost is the right basis for a sale's cost of goods and is client-managed today; not this slice. | Only the six are valued. |
| E8 | The cost is the product's **current** `price`, not the FIFO batch layer. | FIFO cost layers (`stock_batches`): more accurate for goods bought at several prices; needs the purchase-order design Taher deferred. | Approximate for multi-price stock (KNOWN-ISSUES 1). |

## 4. Built for every vendor, not one shop (Taher's point)
Checked against the code and the law, not assumed:
- **Words are generic.** Kind labels (Received, Sold, Loss, Theft, Gift, ...) and the reason prompt contain no business-specific wording; no `Al-Libaas` string exists in `qml/` or `functions/`.
- **Quantities are decimals** (kg, metres): `valueFor` rounds money to paise, quantities are untouched.
- **Policy is global, not per tenant.** One list in two files. A per-tenant override would be built only when a real vendor needs it.
- **Gaps, listed not hidden (KNOWN-ISSUES 12):** composition dealers (register optional by law, feature still on), manufacturers (Rule 56(2) also names raw materials, finished goods, scrap, wastage: no product class exists), service-only vendors (no stock: the S4b-2 entry should hide when there is no inventory), vendors outside India (periods are fixed IST, D2 of S4b), cost possibly entered with GST included (unknown, KNOWN-ISSUES 3).

## 5. What shipped
- `functions/lib/movementLogic.js`: `REASON_REQUIRED`, `MIN_REASON_LENGTH`, `VALUE_KINDS`, `unitCostOf`, `valueFor`; `buildRows` stamps when `ctx.unitCost` is given.
- `gatewayLogic.applyDelta` and `operationLogic.applyOperation` pass `unitCost` read from the product doc inside the transaction (the cost as it stood before the change). Mutation and batch paths only write derived kinds (never stamped), so they are unchanged.
- `qml/helper/StockMovements.js`: `reasonRequired(kind)`, `reasonProblem(kind, reason)` (the words for the picker), validate returns `movement-reason-required`.
- `FailureCause.js` / `tst_FailureCause.qml`: new terminal code.

## 6. Costs and risks, said plainly
- **Invisible until S2e-2.** No screen sends these kinds yet.
- **Existing tests needed reasons.** 17 existing tests failed because their fixtures used a required kind with no reason or a one-letter reason; 7 fixture lines in 6 files were given a real reason. No assertion was weakened, and the tests that expected a client value to survive now expect the stamped value (that is the new behaviour).
- **Float money.** A first test caught `2.5 x 19.99 = 49.97` instead of 49.98 (binary float). Fixed with an absolute 1e-6 paise nudge; a relative nudge was tried and wrongly moved a large honest value by whole paise (both are test cases and mutants).
- **A reason of "xxx" passes.** Length only; a content check would be a guess.

## 7. Advice on what comes next (honest)
1. **S2e-2 pickers or S4b-2 register page first?** The register page shows only receipts, sales and adjustments until pickers exist. I would do **S2e-2 first**: the register is far more convincing with loss and gift rows, and S2e-2 closes the reason and cost loop end to end on a device. Cost: S2e-2 is UI on several screens (S2 design Q4/Q5 are still open: which screens, and whether a manual stock edit splits into "edit fields" and "change stock").
2. S4b-2 columns, decided: Opening | Receipts | Supplies | Other outward (types visible in detail) | Stock correction (adjustment, net) | Closing.
3. Ask the CA the one remaining question that changes code: whether the cost on a loss should be **tax-exclusive**, and whether a gift needs the recipient as a field rather than free text.
